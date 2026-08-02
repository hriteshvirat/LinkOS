package com.linkos.features.files

import android.content.Context
import android.os.Environment
import android.util.Base64
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AndroidFileHandler @Inject constructor(
    @ApplicationContext private val context: Context,
    private val connectionStateManager: ConnectionStateManager,
    private val webSocketClient: WebSocketClient
) : ConnectionStateSubscriber {

    override val subscriberId = "android_file_handler"
    private val activeTransferPaths = java.util.concurrent.ConcurrentHashMap<String, File>()
    private val receivedChunks = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.CopyOnWriteArraySet<Int>>()
    private val responseAwaiters = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<String>>()
    // File handle pool: one RandomAccessFile per transferId, closed only on completion or error.
    private val activeFileHandles = java.util.concurrent.ConcurrentHashMap<String, java.io.RandomAccessFile>()
    private val fileHandleLock = java.util.concurrent.ConcurrentHashMap<String, Any>() // per-transfer mutex objects

    private val _downloadProgress = MutableStateFlow<Float?>(null)
    val downloadProgress = _downloadProgress.asStateFlow()

    private val _downloadFileName = MutableStateFlow<String?>(null)
    val downloadFileName = _downloadFileName.asStateFlow()

    var activeUploadJob: kotlinx.coroutines.Job? = null
    var activeTransferId: String? = null
    val isUploadPaused = MutableStateFlow(false)

    init {
        connectionStateManager.subscribe(this)
        LinkOSLogger.info("AndroidFileHandler initialized and listening on FILE_TRANSFER", "Files")
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.FILE_TRANSFER) return
        
        var activeCorrelationId = UUID.randomUUID().toString()
        try {
            val text = String(payload, Charsets.UTF_8)
            val json = JSONObject(text)
            
            val action = json.optString("action")
            if (action.isEmpty() || fromDeviceId == "android_peer") return
            
            val correlationId = json.optString("correlationId", UUID.randomUUID().toString())
            activeCorrelationId = correlationId
            
            if (action == "cancel" || action == "pause" || action == "resume") {
                val requestedTransferId = json.optString("transferId")
                if (requestedTransferId.isNotEmpty()) {
                    when (action) {
                        "cancel" -> {
                            if (activeTransferId == requestedTransferId) {
                                activeUploadJob?.cancel()
                                activeUploadJob = null
                                isUploadPaused.value = false
                                activeTransferId = null
                                LinkOSLogger.info("[$requestedTransferId] Upload cancelled by remote Mac", "Files")
                            } else {
                                closeAndRemoveHandle(requestedTransferId)
                                activeTransferPaths.remove(requestedTransferId)?.delete()
                                receivedChunks.remove(requestedTransferId)
                                _downloadProgress.value = null
                                _downloadFileName.value = null
                                LinkOSLogger.info("[$requestedTransferId] Download cancelled by remote Mac, partial file deleted", "Files")
                            }
                        }
                        "pause" -> {
                            if (activeTransferId == requestedTransferId) {
                                isUploadPaused.value = true
                                LinkOSLogger.info("[$requestedTransferId] Upload paused by remote Mac", "Files")
                            } else {
                                _downloadProgress.value = null
                            }
                        }
                        "resume" -> {
                            if (activeTransferId == requestedTransferId) {
                                isUploadPaused.value = false
                                LinkOSLogger.info("[$requestedTransferId] Upload resumed by remote Mac", "Files")
                            }
                        }
                    }
                }
                return
            }
            
            LinkOSLogger.info("AndroidFileHandler received action '$action' for path: ${json.optString("path")}", "Files")
            
            when (action) {
                "list" -> {
                    val path = json.optString("path", "")
                    val showHidden = json.optBoolean("showHidden", false)
                    val filesList = listAndroidDirectory(path, showHidden)
                    
                    val payload = JSONObject().apply {
                        put("payload", filesList.toString())
                    }.toString()
                    
                    webSocketClient.sendEnvelope("files", payload, type = "event")
                }
                "operation" -> {
                    val opType = json.optString("operation_type")
                    val source = json.optString("source")
                    val dest = if (json.has("destination")) json.optString("destination") else null
                    val success = performOperation(opType, source, dest)
                    
                    val payload = JSONObject().apply {
                        put("status", if (success) "success" else "error")
                    }.toString()
                    
                    webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                }
                "download" -> {
                    val path = json.optString("path")
                    val requestedTransferId = if (json.has("transferId")) json.optString("transferId") else null
                    kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
                        try {
                            uploadFileToMac(path, correlationId, requestedTransferId)
                        } catch (e: Exception) {
                            val payload = JSONObject().apply {
                                put("status", "error")
                                put("message", "Failed to download file from Android: ${e.message}")
                            }.toString()
                            webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                        }
                    }
                }
                "thumbnail" -> {
                    val path = json.optString("path")
                    kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
                        try {
                            val file = File(path)
                            if (file.exists() && file.isFile) {
                                val mimeType = file.extension.lowercase()
                                val bitmap = if (mimeType in listOf("png", "jpg", "jpeg", "webp", "gif")) {
                                    val options = android.graphics.BitmapFactory.Options().apply {
                                        inSampleSize = 4
                                    }
                                    android.graphics.BitmapFactory.decodeFile(file.absolutePath, options)
                                } else if (mimeType in listOf("mp4", "3gp", "mkv", "mov")) {
                                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                                        android.media.ThumbnailUtils.createVideoThumbnail(file, android.util.Size(128, 128), null)
                                    } else {
                                        android.media.ThumbnailUtils.createVideoThumbnail(file.absolutePath, android.provider.MediaStore.Video.Thumbnails.MINI_KIND)
                                    }
                                } else {
                                    null
                                }
                                
                                if (bitmap != null) {
                                    val outStream = java.io.ByteArrayOutputStream()
                                    bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 70, outStream)
                                    val bytes = outStream.toByteArray()
                                    val base64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
                                    
                                    val payload = JSONObject().apply {
                                        put("status", "success")
                                        put("thumbnailBase64", base64)
                                    }.toString()
                                    webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                                } else {
                                    val payload = JSONObject().apply {
                                        put("status", "error")
                                        put("message", "Unsupported file type or thumbnail generation failed")
                                    }.toString()
                                    webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                                }
                            } else {
                                val payload = JSONObject().apply {
                                    put("status", "error")
                                    put("message", "File not found")
                                }.toString()
                                webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                            }
                        } catch (e: Exception) {
                            val payload = JSONObject().apply {
                                put("status", "error")
                                put("message", "Thumbnail error: ${e.message}")
                            }.toString()
                            webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                        }
                    }
                }
                "upload_chunk" -> {
                    val transferId = json.optString("transferId")
                    val chunkIndex = json.optInt("chunkIndex")
                    val totalChunks = json.optInt("totalChunks")
                    val offsetBytes = json.optLong("offsetBytes")
                    val chunkDataBase64 = json.optString("chunkDataBase64")
                    val checksumSha256 = json.optString("checksumSha256")
                    val fileSha256 = json.optString("fileSha256")
                    val totalSize = json.optLong("totalSize")
                    val fileName = json.optString("fileName")
                    val targetDirectory = json.optString("targetDirectory")
                    
                    var targetDirFile = if (targetDirectory == "~" || targetDirectory.isEmpty() || targetDirectory == "/" || targetDirectory.equals("Downloads", ignoreCase = true)) {
                        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "LinkOS")
                    } else {
                        File(targetDirectory)
                    }
                    
                    if (!targetDirFile.exists()) {
                        val created = targetDirFile.mkdirs()
                        if (!created && !targetDirFile.exists()) {
                            targetDirFile = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "LinkOS")
                            targetDirFile.mkdirs()
                        }
                    } else if (!targetDirFile.canWrite()) {
                        targetDirFile = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "LinkOS")
                        targetDirFile.mkdirs()
                    }
                    
                    _downloadFileName.value = fileName
                    _downloadProgress.value = (chunkIndex + 1).toFloat() / totalChunks.toFloat()
                    
                    val finalFile = activeTransferPaths.getOrPut(transferId) {
                        val originalFile = File(fileName)
                        var targetFile = File(targetDirFile, originalFile.name)
                        if (targetFile.exists()) {
                            val nameWithoutExt = originalFile.nameWithoutExtension
                            val ext = originalFile.extension
                            val timestampedName = "${nameWithoutExt}_${System.currentTimeMillis()}" + (if (ext.isNotEmpty()) ".$ext" else "")
                            targetFile = File(targetDirFile, timestampedName)
                        }
                        targetFile.parentFile?.mkdirs()
                        targetFile
                    }
                    
                    val chunkData = Base64.decode(chunkDataBase64, Base64.NO_WRAP)
                    val sha = calculateSha256(chunkData)
                    if (sha != checksumSha256) {
                        throw Exception("Checksum mismatch")
                    }
                    
                    val writeStartMs = System.currentTimeMillis()

                    // File handle pool: open once per transferId, reuse for all chunks.
                    val lockObj = fileHandleLock.getOrPut(transferId) { Any() }
                    synchronized(lockObj) {
                        val raf = activeFileHandles.getOrPut(transferId) {
                            val newRaf = java.io.RandomAccessFile(finalFile, "rw")
                            // Pre-allocate to totalSize on first open — creates a sparse file
                            // so seeks to any offset are safe regardless of chunk arrival order.
                            if (totalSize > 0L) {
                                newRaf.setLength(totalSize)
                            }
                            newRaf
                        }
                        raf.seek(offsetBytes)
                        raf.write(chunkData)
                    }

                    val writeMs = System.currentTimeMillis() - writeStartMs
                    
                    val chunkSet = receivedChunks.getOrPut(transferId) { java.util.concurrent.CopyOnWriteArraySet() }
                    chunkSet.add(chunkIndex)

                    LinkOSLogger.info("[$transferId] CHUNK $chunkIndex/${totalChunks - 1} offset=$offsetBytes time=${writeMs}ms sha=ok", "Files")
                    
                    if (chunkSet.size == totalChunks) {
                        if (!finalFile.exists() || finalFile.length() == 0L) {
                            throw Exception("File transfer completed but output file is missing or empty")
                        }
                        
                        // 1. Verify file size
                        val actualSize = finalFile.length()
                        if (totalSize > 0L && actualSize != totalSize) {
                            closeAndRemoveHandle(transferId)
                            finalFile.delete()
                            receivedChunks.remove(transferId)
                            activeTransferPaths.remove(transferId)
                            throw Exception("Verification failed: size mismatch (expected $totalSize, got $actualSize)")
                        }
                        
                        // 2. Verify file checksum
                        if (fileSha256.isNotEmpty()) {
                            val actualFileSha = calculateFileSha256(finalFile)
                            if (!actualFileSha.equals(fileSha256, ignoreCase = true)) {
                                closeAndRemoveHandle(transferId)
                                finalFile.delete()
                                receivedChunks.remove(transferId)
                                activeTransferPaths.remove(transferId)
                                throw Exception("Verification failed: SHA256 checksum mismatch (expected $fileSha256, got $actualFileSha)")
                            }
                        }
                        
                        // Close & flush the pooled handle before declaring success
                        closeAndRemoveHandle(transferId)
                        activeTransferPaths.remove(transferId)
                        receivedChunks.remove(transferId)
                        
                        val modificationDateMs = json.optLong("modificationDateMs", 0L)
                        if (modificationDateMs > 0L) {
                            finalFile.setLastModified(modificationDateMs)
                        }
                        _downloadProgress.value = null
                        _downloadFileName.value = null
                        
                        android.media.MediaScannerConnection.scanFile(
                            context,
                            arrayOf(finalFile.absolutePath),
                            null
                        ) { path, uri ->
                            LinkOSLogger.info("MediaScanner scanned downloaded file: $path -> $uri", "Files")
                        }
                        
                        showCompletionNotification(finalFile.name)
                        LinkOSLogger.info("[FileTransfer] [${System.currentTimeMillis()}] [$transferId] Stage: Completed - Saved & Verified to ${finalFile.absolutePath}", "Files")
                        
                        val notifyPayload = JSONObject().apply {
                            put("action", "file_received")
                            put("path", finalFile.absolutePath)
                        }.toString()
                        webSocketClient.sendEnvelope("files", notifyPayload, type = "event")
                        
                        val savedFolder = targetDirFile.name
                        val handler = android.os.Handler(android.os.Looper.getMainLooper())
                        handler.post {
                            android.widget.Toast.makeText(context, "✓ Saved to $savedFolder", android.widget.Toast.LENGTH_SHORT).show()
                        }
                    }
                    
                    val payload = JSONObject().apply {
                        put("status", "success")
                        put("transferId", transferId)
                        put("chunkIndex", chunkIndex)
                    }.toString()
                    webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
                }
            }
        } catch (e: Exception) {
            _downloadProgress.value = null
            _downloadFileName.value = null
            LinkOSLogger.error("Error in AndroidFileHandler: ${e.message}", "Files")
            val payload = JSONObject().apply {
                put("status", "error")
                if (e.message?.contains("Verification failed") == true) {
                    put("code", "ERR_VERIFICATION_FAILED")
                }
                put("message", e.message)
            }.toString()
            webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = activeCorrelationId)
        }
    }

    private fun listAndroidDirectory(path: String, showHidden: Boolean = false): JSONArray {
        val arr = JSONArray()
        
        val targetPath = if (path.isEmpty() || path == "/" || path == "~") {
            Environment.getExternalStorageDirectory().absolutePath
        } else {
            path
        }
        
        val root = File(targetPath)
        if (!root.exists() || !root.isDirectory) return arr
        
        val files = root.listFiles() ?: return arr
        val storageRoot = Environment.getExternalStorageDirectory().absolutePath
        
        for (f in files) {
            val name = f.name
            
            if (!showHidden) {
                // 1. Check if the file is hidden natively (starts with dot or has hidden attribute)
                if (f.isHidden || name.startsWith(".")) {
                    continue
                }
                
                // 2. Curated platform metadata and system files
                val lowerName = name.lowercase()
                if (lowerName == "lost.dir" || 
                    lowerName == "system volume information" || 
                    lowerName == ".nomedia" || 
                    lowerName == ".thumbnails" || 
                    lowerName == ".files" || 
                    lowerName == ".ds_store" || 
                    (lowerName == "android" && f.parentFile?.absolutePath == storageRoot)) {
                    continue
                }
                
                // 3. Temporary files matching prefix ~$ or extensions .tmp, .temp, .lnk
                if (name.startsWith("~$") || 
                    name.endsWith(".tmp", ignoreCase = true) || 
                    name.endsWith(".temp", ignoreCase = true) || 
                    name.endsWith(".lnk", ignoreCase = true)) {
                    continue
                }
            }
            
            val fileObj = JSONObject().apply {
                put("id", f.absolutePath)
                put("name", f.name)
                put("path", f.absolutePath)
                put("isDirectory", f.isDirectory)
                put("sizeBytes", if (f.isDirectory) 0L else f.length())
                put("modificationDateMs", f.lastModified())
                put("mimeType", f.extension)
                put("permissions", "rwxr-xr-x")
                put("isHidden", f.isHidden || name.startsWith("."))
            }
            arr.put(fileObj)
        }
        return arr
    }

    private fun performOperation(opType: String, source: String, dest: String?): Boolean {
        val srcFile = File(source)
        
        return try {
            when (opType) {
                "delete" -> srcFile.deleteRecursively()
                "rename", "move" -> {
                    if (dest != null) {
                        srcFile.renameTo(File(dest))
                    } else {
                        false
                    }
                }
                "copy" -> {
                    if (dest != null) {
                        srcFile.copyRecursively(File(dest), overwrite = true)
                    } else {
                        false
                    }
                }
                "create_folder" -> {
                    val folder = File(source)
                    folder.mkdirs()
                }
                else -> false
            }
        } catch (e: Exception) {
            false
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {}

    override suspend fun onResponseReceived(correlationId: String, payload: String, fromDeviceId: String) {
        responseAwaiters.remove(correlationId)?.complete(payload)
    }

    private fun showCompletionNotification(fileName: String) {
        val channelId = "linkos_downloads_channel"
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            val chan = android.app.NotificationChannel(channelId, "LinkOS Downloads", android.app.NotificationManager.IMPORTANCE_DEFAULT)
            notificationManager.createNotificationChannel(chan)
        }
        val builder = androidx.core.app.NotificationCompat.Builder(context, channelId)
            .setContentTitle("Download Complete")
            .setContentText("$fileName received successfully")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setAutoCancel(true)
        notificationManager.notify(9911, builder.build())
    }

    /**
     * Flush, close, and remove the pooled RandomAccessFile for a transfer.
     * Safe to call multiple times — is a no-op if no handle exists.
     */
    private fun closeAndRemoveHandle(transferId: String) {
        val raf = activeFileHandles.remove(transferId)
        fileHandleLock.remove(transferId)
        try {
            raf?.fd?.sync() // Ensure all bytes are flushed to disk
            raf?.close()
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to close file handle for [$transferId]: ${e.message}", "Files")
        }
    }

    private fun calculateSha256(bytes: ByteArray): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(bytes)
        return hash.joinToString("") { "%02x".format(it) }
    }

    private fun calculateFileSha256(file: File): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(8192)
        val fis = java.io.FileInputStream(file)
        try {
            var read = fis.read(buffer)
            while (read != -1) {
                digest.update(buffer, 0, read)
                read = fis.read(buffer)
            }
        } finally {
            fis.close()
        }
        val hash = digest.digest()
        return hash.joinToString("") { "%02x".format(it) }
    }

    suspend fun uploadFileToMac(filePath: String, correlationId: String, requestedTransferId: String? = null) = kotlinx.coroutines.coroutineScope {
        val file = File(filePath)
        if (!file.exists() || !file.isFile) {
            throw Exception("File does not exist or is not a file")
        }
        
        val fileSize = file.length()
        val fileName = file.name
        
        val chunkSize = 4 * 1024 * 1024 // 4 MB chunk size for faster transfers
        val transferId = requestedTransferId ?: UUID.randomUUID().toString()
        val fileSha256 = calculateFileSha256(file)
        
        val totalChunks = if (fileSize > 0) {
            Math.ceil(fileSize.toDouble() / chunkSize).toInt()
        } else {
            1
        }
        
        val semaphore = kotlinx.coroutines.sync.Semaphore(16)
        val exceptionList = java.util.concurrent.CopyOnWriteArrayList<Throwable>()
        
        val inputStream = file.inputStream()
        inputStream.use { stream ->
            var totalBytesRead = 0L
            var chunkIndex = 0
            
            while (exceptionList.isEmpty()) {
                val buffer = ByteArray(chunkSize)
                val bytesRead = stream.read(buffer)
                if (bytesRead == -1) break
                
                val currentChunkIndex = chunkIndex
                val currentOffsetBytes = totalBytesRead
                val chunkData = if (bytesRead < chunkSize) {
                    buffer.copyOf(bytesRead)
                } else {
                    buffer
                }
                
                semaphore.acquire() // Sliding window backpressure
                
                launch(kotlinx.coroutines.Dispatchers.IO) {
                    try {
                        sendChunkWithRetry(
                            transferId = transferId,
                            chunkIndex = currentChunkIndex,
                            totalChunks = totalChunks,
                            offsetBytes = currentOffsetBytes,
                            chunkData = chunkData,
                            fileName = fileName,
                            fileSha256 = fileSha256,
                            totalSize = fileSize
                        )
                    } catch (e: Throwable) {
                        exceptionList.add(e)
                    } finally {
                        semaphore.release()
                    }
                }
                
                totalBytesRead += bytesRead
                chunkIndex++
            }
        }
        
        if (exceptionList.isNotEmpty()) {
            throw exceptionList.first()
        }
        
        // Send a final success response for the download request
        val payload = JSONObject().apply {
            put("status", "success")
            put("transferId", transferId)
        }.toString()
        webSocketClient.sendEnvelope("files", payload, type = "response", correlationId = correlationId)
        LinkOSLogger.info("Symmetric download upload complete to Mac: $filePath", "Files")
    }

    private suspend fun sendChunkWithRetry(
        transferId: String,
        chunkIndex: Int,
        totalChunks: Int,
        offsetBytes: Long,
        chunkData: ByteArray,
        fileName: String,
        fileSha256: String,
        totalSize: Long
    ) {
        val maxRetries = 3
        var attempt = 0
        
        val base64Data = Base64.encodeToString(chunkData, Base64.NO_WRAP)
        val checksum = calculateSha256(chunkData)
        
        val chunkPayload = JSONObject().apply {
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
            put("targetDirectory", "~")
        }.toString()
        
        while (attempt <= maxRetries) {
            val correlationId = UUID.randomUUID().toString()
            val deferred = kotlinx.coroutines.CompletableDeferred<String>()
            responseAwaiters[correlationId] = deferred
            
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
                responseAwaiters.remove(correlationId)
            }
            
            attempt++
            if (attempt <= maxRetries) {
                kotlinx.coroutines.delay(200L * attempt)
            }
        }
        
        throw Exception("Chunk $chunkIndex failed after $maxRetries retries")
    }

    fun cancelDownload(transferId: String) {
        closeAndRemoveHandle(transferId)
        val file = activeTransferPaths.remove(transferId)
        file?.delete()
        receivedChunks.remove(transferId)
        _downloadProgress.value = null
        _downloadFileName.value = null
        
        val cancelPayload = JSONObject().apply {
            put("action", "cancel")
            put("transferId", transferId)
        }.toString()
        webSocketClient.sendEnvelope("files", cancelPayload, type = "request")
        LinkOSLogger.info("[$transferId] Download cancelled by local user, partial file deleted", "Files")
    }

    fun cancelAllDownloads() {
        for (tid in activeTransferPaths.keys) {
            cancelDownload(tid)
        }
    }

    fun registerAwaiter(correlationId: String, deferred: kotlinx.coroutines.CompletableDeferred<String>) {
        responseAwaiters[correlationId] = deferred
    }

    fun unregisterAwaiter(correlationId: String) {
        responseAwaiters.remove(correlationId)
    }
}
