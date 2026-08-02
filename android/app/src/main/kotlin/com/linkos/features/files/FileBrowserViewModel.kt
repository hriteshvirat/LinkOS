package com.linkos.features.files

import android.content.Context
import android.widget.Toast
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Base64
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.ConnectionPhase
import com.linkos.core.network.PeerDevice
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.json.JSONObject
import java.io.InputStream
import java.security.MessageDigest
import javax.inject.Inject

@Serializable
data class FileItem(
    val id: String,
    val name: String,
    val path: String,
    val isDirectory: Boolean,
    val sizeBytes: Long = 0L,
    val modificationDateMs: Long = 0L,
    val mimeType: String = "",
    val permissions: String = "rwxr-xr-x",
    val isHidden: Boolean = false
)

enum class FileViewMode {
    LIST, GRID
}

@HiltViewModel
class FileBrowserViewModel @Inject constructor(
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: Context,
    private val connectionStateManager: ConnectionStateManager,
    private val webSocketClient: WebSocketClient,
    private val androidFileHandler: AndroidFileHandler,
    private val keystoreManager: com.linkos.core.security.KeystoreManager
) : ViewModel(), ConnectionStateSubscriber {

    override val subscriberId = "file_browser_view_model"

    private val _currentPath = MutableStateFlow("/Users")
    val currentPath: StateFlow<String> = _currentPath.asStateFlow()

    private val _files = MutableStateFlow<List<FileItem>>(emptyList())
    val files: StateFlow<List<FileItem>> = _files.asStateFlow()

    // Upload Progress states
    private val _uploadProgress = MutableStateFlow<Float?>(null)
    val uploadProgress: StateFlow<Float?> = _uploadProgress.asStateFlow()

    private val _uploadFileName = MutableStateFlow<String?>(null)
    val uploadFileName: StateFlow<String?> = _uploadFileName.asStateFlow()

    // Download Progress states
    val downloadProgress = androidFileHandler.downloadProgress
    val downloadFileName = androidFileHandler.downloadFileName

    private val _thumbnails = MutableStateFlow<Map<String, androidx.compose.ui.graphics.ImageBitmap>>(emptyMap())
    val thumbnails: StateFlow<Map<String, androidx.compose.ui.graphics.ImageBitmap>> = _thumbnails.asStateFlow()
    private val fetchingThumbnails = java.util.concurrent.ConcurrentHashMap<String, Boolean>()
    private val activeFetchJobs = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.Job>()

    private val _viewMode = MutableStateFlow(FileViewMode.LIST)
    val viewMode: StateFlow<FileViewMode> = _viewMode.asStateFlow()

    /** Exposes the connection phase so the composable doesn't need a static reference. */
    val connectionPhase: StateFlow<ConnectionPhase> = connectionStateManager.phase

    private val json = Json { ignoreUnknownKeys = true }
    private var activeUploadJob: Job?
        get() = androidFileHandler.activeUploadJob
        set(value) { androidFileHandler.activeUploadJob = value }

    private var activeTransferId: String?
        get() = androidFileHandler.activeTransferId
        set(value) { androidFileHandler.activeTransferId = value }

    val isUploadPaused: StateFlow<Boolean>
        get() = androidFileHandler.isUploadPaused.asStateFlow()

    private val _errorState = MutableStateFlow<String?>(null)
    val errorState: StateFlow<String?> = _errorState.asStateFlow()

    private var homeDirectory: String? = null

    private val directoryCache = java.util.concurrent.ConcurrentHashMap<String, Pair<List<FileItem>, Long>>()

    init {
        connectionStateManager.subscribe(this)
        try {
            val sharedPrefs = context.getSharedPreferences("linkos_files", Context.MODE_PRIVATE)
            val savedMode = sharedPrefs.getString("view_mode", FileViewMode.LIST.name)
            _viewMode.value = FileViewMode.valueOf(savedMode ?: FileViewMode.LIST.name)
        } catch (e: Exception) {}
        _currentPath.value = "/Users"
        loadDirectory("/Users")
    }

    fun toggleViewMode() {
        val nextMode = if (_viewMode.value == FileViewMode.LIST) FileViewMode.GRID else FileViewMode.LIST
        _viewMode.value = nextMode
        try {
            val sharedPrefs = context.getSharedPreferences("linkos_files", Context.MODE_PRIVATE)
            sharedPrefs.edit().putString("view_mode", nextMode.name).apply()
        } catch (e: Exception) {}
    }

    private fun sanitizePath(path: String?): String {
        if (path.isNullOrEmpty()) {
            return "/Users"
        }
        val segments = path.split("/")
        for (segment in segments) {
            if (segment.startsWith(".") && segment != "." && segment != "..") {
                return "/Users"
            }
            val lower = segment.lowercase()
            if (lower == "node_modules" || 
                lower == "library" || 
                lower == "developer" || 
                lower == "pako" || 
                lower == "build") {
                return "/Users"
            }
        }
        if (path != "/Users" && !path.startsWith("/Users/")) {
            return "/Users"
        }
        return path
    }

    override suspend fun onConnectionPhaseChanged(phase: ConnectionPhase, device: PeerDevice?) {
        if (phase == ConnectionPhase.CONNECTED) {
            withContext(Dispatchers.Main) {
                directoryCache.clear()
                val current = _currentPath.value
                loadDirectory(current)
            }
        }
    }

    fun downloadFile(filePath: String) {
        val payload = buildJsonObject {
            put("action", "download")
            put("path", filePath)
        }.toString()
        viewModelScope.launch {
            webSocketClient.sendEnvelope("files", payload, type = "request")
        }
    }

    fun fetchThumbnail(filePath: String) {
        if (_thumbnails.value.containsKey(filePath)) return
        if (fetchingThumbnails.putIfAbsent(filePath, true) != null) return

        val sanitized = sanitizePath(filePath)
        val job = viewModelScope.launch {
            val correlationId = java.util.UUID.randomUUID().toString()
            val deferred = kotlinx.coroutines.CompletableDeferred<String>()
            androidFileHandler.registerAwaiter(correlationId, deferred)
            
            try {
                val payload = buildJsonObject {
                    put("action", "thumbnail")
                    put("path", sanitized)
                }.toString()
                
                webSocketClient.sendEnvelope(
                    channel = "files",
                    payload = payload,
                    type = "request",
                    correlationId = correlationId
                )
                
                val responsePayload = kotlinx.coroutines.withTimeout(10000L) {
                    deferred.await()
                }
                
                val responseJson = JSONObject(responsePayload)
                val base64 = responseJson.optString("thumbnailBase64", "")
                if (base64.isNotEmpty()) {
                    val imageBitmap = withContext(Dispatchers.IO) {
                        try {
                            val decodedBytes = Base64.decode(base64, Base64.DEFAULT)
                            val bitmap = BitmapFactory.decodeByteArray(decodedBytes, 0, decodedBytes.size)
                            bitmap?.asImageBitmap()
                        } catch (e: Exception) {
                            null
                        }
                    }
                    if (imageBitmap != null) {
                        withContext(Dispatchers.Main) {
                            _thumbnails.value = _thumbnails.value + (filePath to imageBitmap)
                        }
                    }
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to fetch thumbnail for $filePath: ${e.message}", "Files")
            } finally {
                androidFileHandler.unregisterAwaiter(correlationId)
                activeFetchJobs.remove(filePath)
                fetchingThumbnails.remove(filePath)
            }
        }
        activeFetchJobs[filePath] = job
        job.invokeOnCompletion {
            activeFetchJobs.remove(filePath)
            fetchingThumbnails.remove(filePath)
        }
    }

    fun cancelFetchThumbnail(filePath: String) {
        activeFetchJobs[filePath]?.cancel()
        activeFetchJobs.remove(filePath)
        fetchingThumbnails.remove(filePath)
    }

    fun loadDirectory(path: String) {
        _errorState.value = null
        val sanitized = sanitizePath(path)
        val cachedEntry = directoryCache[sanitized]
        if (cachedEntry != null) {
            val (cachedFiles, timestamp) = cachedEntry
            if (System.currentTimeMillis() - timestamp < 3000L) {
                _files.value = cachedFiles
                _currentPath.value = sanitized
                return
            }
        }
        _currentPath.value = sanitized
        val payload = buildJsonObject {
            put("action", "list")
            put("path", sanitized)
        }.toString()
        
        viewModelScope.launch {
            webSocketClient.sendEnvelope("files", payload, type = "request")
        }
    }

    fun performFileOperation(operationType: String, source: String, destination: String? = null) {
        val payload = buildJsonObject {
            put("action", "operation")
            put("operation_type", operationType)
            put("source", source)
            if (destination != null) {
                put("destination", destination)
            }
        }.toString()
        
        viewModelScope.launch {
            webSocketClient.sendEnvelope("files", payload, type = "request")
        }
    }

    fun cancelUpload() {
        val tid = activeTransferId
        activeUploadJob?.cancel()
        activeUploadJob = null
        androidFileHandler.isUploadPaused.value = false
        _uploadProgress.value = null
        _uploadFileName.value = null
        
        if (tid != null) {
            val cancelPayload = buildJsonObject {
                put("action", "cancel")
                put("transferId", tid)
            }.toString()
            viewModelScope.launch {
                webSocketClient.sendEnvelope("files", cancelPayload, type = "request")
            }
            activeTransferId = null
        }
        LinkOSLogger.info("File upload cancelled by user", "Files")
    }

    fun pauseUpload() {
        androidFileHandler.isUploadPaused.value = true
        activeTransferId?.let { tid ->
            val pausePayload = buildJsonObject {
                put("action", "pause")
                put("transferId", tid)
            }.toString()
            viewModelScope.launch {
                webSocketClient.sendEnvelope("files", pausePayload, type = "request")
            }
        }
    }

    fun resumeUpload() {
        androidFileHandler.isUploadPaused.value = false
        activeTransferId?.let { tid ->
            val resumePayload = buildJsonObject {
                put("action", "resume")
                put("transferId", tid)
            }.toString()
            viewModelScope.launch {
                webSocketClient.sendEnvelope("files", resumePayload, type = "request")
            }
        }
    }

    fun cancelDownload() {
        androidFileHandler.cancelAllDownloads()
    }

    private fun calculateFileSha256(uri: Uri, context: Context): String {
        val digest = MessageDigest.getInstance("SHA-256")
        context.contentResolver.openInputStream(uri)?.use { stream ->
            val buffer = ByteArray(8192)
            while (true) {
                val read = stream.read(buffer)
                if (read == -1) break
                digest.update(buffer, 0, read)
            }
        }
        val hash = digest.digest()
        return hash.joinToString("") { String.format("%02x", it) }
    }

    private suspend fun sendChunkWithRetry(
        transferId: String,
        chunkIndex: Int,
        totalChunks: Int,
        offsetBytes: Long,
        chunkData: ByteArray,
        fileName: String,
        targetDirectory: String,
        fileSha256: String,
        totalSize: Long
    ) {
        val maxRetries = 3
        var attempt = 0
        
        val base64Data = Base64.encodeToString(chunkData, Base64.NO_WRAP)
        val checksum = calculateSha256(chunkData)
        
        val chunkPayload = buildJsonObject {
            put("action", "upload_chunk")
            put("transferId", transferId)
            put("chunkIndex", chunkIndex)
            put("totalChunks", totalChunks)
            put("offsetBytes", offsetBytes)
            put("chunkDataBase64", base64Data)
            put("checksumSha256", checksum)
            put("fileSha256", fileSha256)
            put("totalSize", totalSize)
            put("fileName", fileName)
            put("targetDirectory", targetDirectory)
        }.toString()
        
        while (attempt <= maxRetries) {
            val correlationId = java.util.UUID.randomUUID().toString()
            val deferred = kotlinx.coroutines.CompletableDeferred<String>()
            androidFileHandler.registerAwaiter(correlationId, deferred)
            
            try {
                webSocketClient.sendEnvelope(
                    channel = "files",
                    payload = chunkPayload,
                    type = "request",
                    correlationId = correlationId
                )
                
                // Wait for response with a timeout of 20 seconds
                val responsePayload = kotlinx.coroutines.withTimeout(20000L) {
                    deferred.await()
                }
                
                val responseJson = JSONObject(responsePayload)
                val status = responseJson.optString("status")
                if (status == "success") {
                    return // Chunk upload succeeded!
                } else {
                    val errMsg = responseJson.optString("message", "Unknown error")
                    LinkOSLogger.warning("[FileTransfer] Retry ${attempt + 1}/$maxRetries for chunk $chunkIndex due to error: $errMsg", "Files")
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                LinkOSLogger.warning("[FileTransfer] Retry ${attempt + 1}/$maxRetries for chunk $chunkIndex due to timeout", "Files")
            } catch (e: Exception) {
                LinkOSLogger.warning("[FileTransfer] Retry ${attempt + 1}/$maxRetries for chunk $chunkIndex due to: ${e.message}", "Files")
            } finally {
                androidFileHandler.unregisterAwaiter(correlationId)
            }
            
            attempt++
            if (attempt <= maxRetries) {
                kotlinx.coroutines.delay(200L * attempt)
            }
        }
        
        throw Exception("Chunk $chunkIndex failed after $maxRetries retries")
    }

    fun uploadFile(uri: Uri, context: Context) {
        cancelUpload()
        
        activeUploadJob = viewModelScope.launch(Dispatchers.IO) {
            try {
                val contentResolver = context.contentResolver
                var fileName = "uploaded_file"
                var fileSize = 0L
                
                contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (cursor.moveToFirst()) {
                        if (nameIndex != -1) cursor.getString(nameIndex)?.let { fileName = it }
                        if (sizeIndex != -1) fileSize = cursor.getLong(sizeIndex)
                    }
                }
                
                withContext(Dispatchers.Main) {
                    _uploadFileName.value = fileName
                    _uploadProgress.value = 0f
                }
                
                val fileSha256 = try {
                    calculateFileSha256(uri, context)
                } catch (e: Exception) {
                    ""
                }
                
                val inputStream: InputStream? = contentResolver.openInputStream(uri)
                if (inputStream == null) {
                    LinkOSLogger.error("Failed to open input stream for: $fileName", "Files")
                    return@launch
                }
                
                val chunkSize = 4 * 1024 * 1024 // 4 MB chunk size
                val buffer = ByteArray(chunkSize)
                val transferId = java.util.UUID.randomUUID().toString()
                activeTransferId = transferId
                
                var totalBytesRead = 0L
                var chunkIndex = 0
                val totalChunks = if (fileSize > 0) {
                    Math.ceil(fileSize.toDouble() / chunkSize).toInt()
                } else {
                    1
                }
                
                inputStream.use { stream ->
                    while (true) {
                        while (androidFileHandler.isUploadPaused.value) {
                            kotlinx.coroutines.delay(500)
                        }
                        val bytesRead = stream.read(buffer)
                        if (bytesRead == -1) break
                        
                        val chunkData = if (bytesRead < chunkSize) {
                            buffer.copyOf(bytesRead)
                        } else {
                            buffer
                        }
                        
                        sendChunkWithRetry(
                            transferId = transferId,
                            chunkIndex = chunkIndex,
                            totalChunks = totalChunks,
                            offsetBytes = totalBytesRead,
                            chunkData = chunkData,
                            fileName = fileName,
                            targetDirectory = "~",
                            fileSha256 = fileSha256,
                            totalSize = fileSize
                        )
                        
                        totalBytesRead += bytesRead
                        chunkIndex++
                        
                        if (fileSize > 0) {
                            val progress = totalBytesRead.toFloat() / fileSize
                            withContext(Dispatchers.Main) {
                                val currentVal = _uploadProgress.value ?: 0f
                                if (progress > currentVal) {
                                    _uploadProgress.value = Math.min(progress, 0.99f)
                                }
                            }
                        }
                    }
                }
                
                withContext(Dispatchers.Main) {
                    _uploadProgress.value = 1f
                    // Reset after success delay
                    kotlinx.coroutines.delay(1000)
                    _uploadProgress.value = null
                    _uploadFileName.value = null
                    Toast.makeText(context, "✓ Uploaded to Mac", Toast.LENGTH_SHORT).show()
                    loadDirectory(_currentPath.value)
                }
                LinkOSLogger.info("File upload complete: $fileName", "Files")
                
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to upload file: ${e.message}", "Files")
                withContext(Dispatchers.Main) {
                    _uploadProgress.value = null
                    _uploadFileName.value = null
                    Toast.makeText(context, "Upload failed: ${e.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun calculateSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(bytes)
        return hash.joinToString("") { "%02x".format(it) }
    }

    fun navigateUp() {
        val path = _currentPath.value
        val parent = path.substringBeforeLast('/', "")
        if (parent.isNotEmpty()) {
            loadDirectory(parent)
        }
    }

    // ConnectionStateSubscriber implementations

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.FILE_TRANSFER) return
        
        try {
            val text = String(payload, Charsets.UTF_8)
            if (text.startsWith("{")) {
                val jsonObj = JSONObject(text)
                
                if (jsonObj.has("error")) {
                    val errorType = jsonObj.getString("error")
                    withContext(Dispatchers.Main) {
                        _errorState.value = errorType
                    }
                    return
                }
                
                val action = jsonObj.optString("action")
                if (action == "file_received") {
                    withContext(Dispatchers.Main) {
                        loadDirectory(_currentPath.value)
                    }
                    return
                }
                
                // Case 1: Wrapped JSON path list payload
                if (jsonObj.has("currentPath") && jsonObj.has("files")) {
                    val resolvedPath = jsonObj.getString("currentPath")
                    val filesStr = jsonObj.getJSONArray("files").toString()
                    val parsed = json.decodeFromString<List<FileItem>>(filesStr)
                    
                    withContext(Dispatchers.Main) {
                        _currentPath.value = resolvedPath
                        _files.value = parsed
                        directoryCache[resolvedPath] = Pair(parsed, System.currentTimeMillis())
                        
                        // Set home directory if not set yet, or if resolved path starts with /Users/ and is the short path
                        if (homeDirectory == null && resolvedPath.startsWith("/Users/")) {
                            val parts = resolvedPath.split("/").filter { it.isNotEmpty() }
                            if (parts.size >= 2 && parts[0] == "Users") {
                                homeDirectory = "/Users/${parts[1]}"
                            }
                        }
                        
                    }
                    return
                }
                
                // Case 2: Status response envelope check
                val payloadText = jsonObj.optString("payload")
                if (payloadText.isNotEmpty()) {
                    if (payloadText.startsWith("[")) {
                        val parsed = json.decodeFromString<List<FileItem>>(payloadText)
                        withContext(Dispatchers.Main) {
                            _files.value = parsed
                            directoryCache[_currentPath.value] = Pair(parsed, System.currentTimeMillis())
                        }
                    } else {
                        val resp = JSONObject(payloadText)
                        val status = resp.optString("status")
                        if (status == "success") {
                            if (!resp.has("transferId")) {
                                loadDirectory(_currentPath.value)
                            }
                        } else if (status == "error") {
                            val errMsg = resp.optString("message", "Upload failed")
                            withContext(Dispatchers.Main) {
                                cancelUpload()
                                Toast.makeText(context, "Error: $errMsg", Toast.LENGTH_LONG).show()
                            }
                        }
                    }
                }
            } else if (text.startsWith("[")) {
                val parsed = json.decodeFromString<List<FileItem>>(text)
                withContext(Dispatchers.Main) {
                    _files.value = parsed
                    directoryCache[_currentPath.value] = Pair(parsed, System.currentTimeMillis())
                }
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to parse remote directory response: ${e.message}", "Files")
        }
    }



    override suspend fun onResponseReceived(correlationId: String, payload: String, fromDeviceId: String) {
        onMessageReceived(MessageChannel.FILE_TRANSFER, payload.toByteArray(Charsets.UTF_8), fromDeviceId)
    }

    override suspend fun onQoSChanged(state: QoSState) {
        // QoS adjustments
    }
}
