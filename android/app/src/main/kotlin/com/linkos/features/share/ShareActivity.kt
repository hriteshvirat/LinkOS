package com.linkos.features.share

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Base64
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.WebSocketClient
import com.linkos.ui.theme.DarkBackground
import com.linkos.ui.theme.DarkSurface
import com.linkos.ui.theme.LinkOSBlue
import com.linkos.ui.theme.LinkOSTheme
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.InputStream
import java.security.MessageDigest
import javax.inject.Inject

@AndroidEntryPoint
class ShareActivity : ComponentActivity() {

    @Inject
    lateinit var connectionStateManager: ConnectionStateManager

    @Inject
    lateinit var webSocketClient: WebSocketClient

    @Inject
    lateinit var keystoreManager: com.linkos.core.security.KeystoreManager

    private var sharedUris = mutableStateListOf<Uri>()
    private var isUploading = mutableStateOf(false)
    private var progressValue = mutableStateOf(0.0f)
    private var currentFileName = mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)

        val isPaired = keystoreManager.getString("is_paired") == "true"
        val lastHost = keystoreManager.getString("last_mac_host")
        val lastPort = keystoreManager.getString("last_mac_port")?.toIntOrNull()
        if (connectionStateManager.phase.value == com.linkos.core.network.ConnectionPhase.DISCONNECTED) {
            if (isPaired && !lastHost.isNullOrEmpty() && lastPort != null) {
                connectionStateManager.connect(lastHost, lastPort, method = "TRUSTED")
            } else {
                Toast.makeText(this, "LinkOS is not paired with a Mac. Please open the app to pair.", Toast.LENGTH_LONG).show()
            }
        }

        setContent {
            LinkOSTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = DarkBackground
                ) {
                    ShareScreen()
                }
            }
        }
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        val type = intent.type

        sharedUris.clear()
        if (Intent.ACTION_SEND == action && type != null) {
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (uri != null) {
                sharedUris.add(uri)
            } else {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                if (text != null) {
                    try {
                        val tempFile = java.io.File(cacheDir, "shared_text.txt")
                        tempFile.writeText(text)
                        sharedUris.add(Uri.fromFile(tempFile))
                    } catch (e: Exception) {
                        LinkOSLogger.error("Failed to parse shared text: ${e.message}", "ShareActivity")
                    }
                }
            }
        } else if (Intent.ACTION_SEND_MULTIPLE == action && type != null) {
            val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (uris != null) {
                sharedUris.addAll(uris.filterNotNull())
            }
        }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    fun ShareScreen() {
        val connectedDevice by connectionStateManager.connectedDevice.collectAsState()
        val phase by connectionStateManager.phase.collectAsState()

        val connectedName = connectedDevice?.name ?: "Paired Mac"
        val isConnected = phase == com.linkos.core.network.ConnectionPhase.CONNECTED
        val hasTimedOut = remember { mutableStateOf(false) }

        LaunchedEffect(isConnected) {
            if (!isConnected) {
                hasTimedOut.value = false
                delay(15000)
                if (!isConnected) {
                    hasTimedOut.value = true
                }
            } else {
                hasTimedOut.value = false
            }
        }

        LaunchedEffect(isConnected, sharedUris.size) {
            if (isConnected && sharedUris.isNotEmpty() && !isUploading.value) {
                startUploads()
            }
        }

        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Share to LinkOS", fontWeight = FontWeight.Bold) },
                    navigationIcon = {
                        IconButton(onClick = { finish() }) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = Color.White)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkBackground)
                )
            },
            containerColor = DarkBackground
        ) { paddingValues ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues)
                    .padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Icon(
                    Icons.Default.CloudUpload,
                    contentDescription = null,
                    tint = LinkOSBlue,
                    modifier = Modifier.size(72.dp)
                )
                Spacer(Modifier.height(24.dp))

                if (hasTimedOut.value) {
                    Text(
                        "Connection Failed",
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        color = Color.Red
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Could not connect to your Mac. Please verify both devices are on the same Wi-Fi network and try again.",
                        fontSize = 14.sp,
                        color = Color.Gray,
                        textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.height(24.dp))
                    Button(
                        onClick = {
                            hasTimedOut.value = false
                            val lastHost = keystoreManager.getString("last_mac_host")
                            val lastPort = keystoreManager.getString("last_mac_port")?.toIntOrNull()
                            if (!lastHost.isNullOrEmpty() && lastPort != null) {
                                webSocketClient.connect(lastHost, lastPort, method = "TRUSTED")
                            }
                        },
                        colors = ButtonDefaults.buttonColors(containerColor = LinkOSBlue)
                    ) {
                        Text("Retry Connection", color = Color.White)
                    }
                } else if (!isConnected) {
                    Text(
                        "Connecting to Mac...",
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        color = Color.White
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Ensure your paired Mac is awake and LinkOS is active.",
                        fontSize = 14.sp,
                        color = Color.Gray,
                        textAlign = TextAlign.Center
                    )
                } else if (isUploading.value) {
                    Text(
                        "Uploading Files...",
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        color = Color.White
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        currentFileName.value,
                        fontSize = 14.sp,
                        color = Color.LightGray,
                        textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.height(16.dp))
                    LinearProgressIndicator(
                        progress = { progressValue.value },
                        modifier = Modifier.fillMaxWidth().height(6.dp),
                        color = LinkOSBlue,
                        trackColor = Color.White.copy(alpha = 0.1f)
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "${(progressValue.value * 100).toInt()}% complete",
                        fontSize = 12.sp,
                        color = Color.Gray
                    )
                } else {
                    Text(
                        "Ready to Share",
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        color = Color.White
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Sending ${sharedUris.size} files to $connectedName",
                        fontSize = 14.sp,
                        color = Color.LightGray,
                        textAlign = TextAlign.Center
                    )
                    Spacer(Modifier.height(24.dp))
                    Button(
                        onClick = { startUploads() },
                        colors = ButtonDefaults.buttonColors(containerColor = LinkOSBlue)
                    ) {
                        Text("Send Now", color = Color.White)
                    }
                }
            }
        }
    }

    private fun startUploads() {
        isUploading.value = true
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                val urisCopy = ArrayList(sharedUris)
                for ((index, uri) in urisCopy.withIndex()) {
                    uploadSingleUri(uri)
                }
                withContext(Dispatchers.Main) {
                    Toast.makeText(this@ShareActivity, "Files shared successfully!", Toast.LENGTH_SHORT).show()
                    delay(800)
                    finish()
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Sharesheet upload failed: ${e.message}", "ShareActivity")
                withContext(Dispatchers.Main) {
                    Toast.makeText(this@ShareActivity, "Upload failed: ${e.message}", Toast.LENGTH_LONG).show()
                    isUploading.value = false
                }
            }
        }
    }

    private suspend fun uploadSingleUri(uri: Uri) {
        val resolver = contentResolver
        var name = "shared_file"
        var size = 0L

        try {
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIdx != -1) name = cursor.getString(nameIdx)
                    if (sizeIdx != -1) size = cursor.getLong(sizeIdx)
                }
            }
        } catch (e: Exception) {
            if (uri.scheme == "file") {
                name = uri.lastPathSegment ?: "shared_file"
                size = java.io.File(uri.path ?: "").length()
            } else {
                LinkOSLogger.error("Failed to query URI metadata: ${e.message}", "ShareActivity")
            }
        }

        withContext(Dispatchers.Main) {
            currentFileName.value = name
            progressValue.value = 0.0f
        }

        val inputStream = resolver.openInputStream(uri) ?: throw Exception("Cannot open stream")
        val chunkSize = 4 * 1024 * 1024 // 4 MB chunk size
        val buffer = ByteArray(chunkSize)
        val transferId = java.util.UUID.randomUUID().toString()

        var bytesReadTotal = 0L
        var chunkIndex = 0
        val totalChunks = if (size > 0) Math.ceil(size.toDouble() / chunkSize).toInt() else 1

        inputStream.use { stream ->
            while (true) {
                val read = stream.read(buffer)
                if (read == -1) break

                val chunkData = if (read < chunkSize) buffer.copyOf(read) else buffer
                val base64 = Base64.encodeToString(chunkData, Base64.NO_WRAP)
                val sha = calculateSha256(chunkData)

                val payload = buildJsonObject {
                    put("action", "upload_chunk")
                    put("transferId", transferId)
                    put("chunkIndex", chunkIndex)
                    put("totalChunks", totalChunks)
                    put("offsetBytes", bytesReadTotal)
                    put("chunkDataBase64", base64)
                    put("checksumSha256", sha)
                    put("fileName", name)
                }.toString()

                LinkOSLogger.info("[FileTransfer] [${System.currentTimeMillis()}] [$transferId] Stage: ChunkSent - Uploading $name chunk $chunkIndex/$totalChunks size $read bytes", "ShareActivity")
                
                webSocketClient.sendEnvelope("files", payload, type = "request")

                bytesReadTotal += read
                chunkIndex++

                if (size > 0) {
                    val progress = bytesReadTotal.toFloat() / size
                    withContext(Dispatchers.Main) {
                        progressValue.value = Math.min(progress, 1f)
                    }
                }
                delay(30)
            }
        }
        
        LinkOSLogger.info("[FileTransfer] [${System.currentTimeMillis()}] [$transferId] Stage: Completed - Finished sending $name", "ShareActivity")
    }

    private fun calculateSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(bytes)
        return hash.joinToString("") { "%02x".format(it) }
    }
}
