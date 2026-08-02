package com.linkos.core.network

import com.linkos.core.logging.LinkOSLogger
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class InviteListener @Inject constructor(
    private val webSocketClient: WebSocketClient
) {
    private var serverSocket: ServerSocket? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var isListening = false

    fun startListening() {
        if (isListening) return
        isListening = true
        scope.launch {
            try {
                serverSocket = ServerSocket(52638)
                LinkOSLogger.info("InviteListener started on port 52638", "Network")
                while (isActive && isListening) {
                    val socket = serverSocket?.accept() ?: break
                    handleIncomingConnection(socket)
                }
            } catch (e: Exception) {
                LinkOSLogger.error("InviteListener failed: ${e.message}", "Network")
            }
        }
    }

    fun stopListening() {
        isListening = false
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            // Ignore
        }
        serverSocket = null
    }

    private fun handleIncomingConnection(socket: Socket) {
        scope.launch {
            try {
                val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
                val line = reader.readLine() ?: ""
                socket.close()

                if (line.isNotEmpty()) {
                    val json = JSONObject(line)
                    if (json.optString("action") == "CONNECT_TO") {
                        val host = json.getString("host")
                        val port = json.getInt("port")
                        val mode = json.optString("mode", "PIN")
                        LinkOSLogger.info("Received connection invite to $host:$port (mode: $mode)", "Network")
                        withContext(Dispatchers.Main) {
                            webSocketClient.connect(host, port)
                            // If Mac initiated PIN pairing, trigger showing/entering PIN
                            if (mode == "PIN") {
                                webSocketClient.setPendingPairingInitiator("mac")
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to parse connection invite: ${e.message}", "Network")
            }
        }
    }
}
