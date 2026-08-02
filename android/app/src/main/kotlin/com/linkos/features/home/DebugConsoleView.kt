package com.linkos.features.home

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.widget.Toast
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionState
import com.linkos.ui.components.GlassCard
import com.linkos.ui.theme.*
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun DebugConsoleView(
    connectionState: ConnectionState,
    lastFailureStage: String?,
    onClose: () -> Unit
) {
    val context = LocalContext.current
    var logText by remember { mutableStateOf("") }
    
    // Refresh log buffer
    LaunchedEffect(Unit) {
        while (true) {
            val stateName = connectionState.name
            logText = LinkOSLogger.generatePairingReport(stateName, lastFailureStage)
            kotlinx.coroutines.delay(1000)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF070B14))
            .padding(16.dp)
    ) {
        Column(
            modifier = Modifier.fillMaxSize()
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.BugReport,
                        contentDescription = null,
                        tint = Color(0xFF64FFDA),
                        modifier = Modifier.size(28.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "LinkOS Debug Console",
                        style = MaterialTheme.typography.titleLarge,
                        color = Color.White,
                        fontWeight = FontWeight.Bold
                    )
                }
                IconButton(onClick = onClose) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Body
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
            ) {
                // Device Metadata
                GlassCard(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text("SYSTEM DETAILS", fontWeight = FontWeight.Bold, color = Color(0xFF64FFDA), fontSize = 12.sp)
                        Spacer(modifier = Modifier.height(6.dp))
                        Text("Device: ${Build.MANUFACTURER} ${Build.MODEL}", color = Color.White, fontSize = 14.sp)
                        Text("Android Version: ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})", color = Color.White, fontSize = 14.sp)
                        Text("Wifi Status: Connected", color = Color.White, fontSize = 14.sp)
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))

                // Connection State Trackers
                GlassCard(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Text("CONNECTION STATE", fontWeight = FontWeight.Bold, color = Color(0xFF64FFDA), fontSize = 12.sp)
                        Spacer(modifier = Modifier.height(8.dp))
                        
                        val states = listOf(
                            ConnectionState.DISCONNECTED,
                            ConnectionState.CONNECTING,
                            ConnectionState.PAIRING,
                            ConnectionState.CONNECTED
                        )
                        
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            states.forEach { state ->
                                val isCurrent = state == connectionState
                                Box(
                                    modifier = Modifier
                                        .weight(1f)
                                        .background(
                                            if (isCurrent) Color(0xFF64FFDA).copy(alpha = 0.2f) else Color.Transparent,
                                            shape = RoundedCornerShape(4.dp)
                                        )
                                        .border(
                                            1.dp,
                                            if (isCurrent) Color(0xFF64FFDA) else Color.Gray.copy(alpha = 0.3f),
                                            shape = RoundedCornerShape(4.dp)
                                        )
                                        .padding(vertical = 6.dp, horizontal = 4.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Text(
                                        text = state.name,
                                        fontSize = 9.sp,
                                        fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                                        color = if (isCurrent) Color(0xFF64FFDA) else Color.Gray
                                    )
                                }
                            }
                        }
                    }
                }

                Spacer(modifier = Modifier.height(12.dp))

                // Console Logs Viewer
                Text(
                    text = "DIAGNOSTICS LOG OUTPUT",
                    fontWeight = FontWeight.Bold,
                    color = Color(0xFF64FFDA),
                    fontSize = 12.sp,
                    modifier = Modifier.padding(vertical = 4.dp)
                )
                
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp)
                        .background(Color.Black, shape = RoundedCornerShape(6.dp))
                        .border(1.dp, Color.Gray.copy(alpha = 0.3f), shape = RoundedCornerShape(6.dp))
                        .padding(8.dp)
                ) {
                    Text(
                        text = logText,
                        color = Color(0xFF00FF00),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 11.sp,
                        modifier = Modifier
                            .fillMaxSize()
                            .verticalScroll(rememberScrollState())
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                // Buttons Group
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            val clip = ClipData.newPlainText("LinkOS Logs", logText)
                            clipboard.setPrimaryClip(clip)
                            Toast.makeText(context, "Logs copied to clipboard!", Toast.LENGTH_SHORT).show()
                        },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1F2937))
                    ) {
                        Text("Copy Logs", color = Color.White)
                    }

                    Button(
                        onClick = {
                            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_SUBJECT, "LinkOS Pairing Log")
                                putExtra(Intent.EXTRA_TEXT, logText)
                            }
                            context.startActivity(Intent.createChooser(shareIntent, "Share logs via"))
                        },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1F2937))
                    ) {
                        Text("Share Logs", color = Color.White)
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = {
                            try {
                                val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                                val logFile = File(downloadsDir, "pairing_log.txt")
                                FileOutputStream(logFile).use { fos ->
                                    fos.write(logText.toByteArray())
                                }
                                Toast.makeText(context, "Saved pairing_log.txt to Downloads!", Toast.LENGTH_LONG).show()
                            } catch (e: Exception) {
                                Toast.makeText(context, "Failed to save logs: ${e.message}", Toast.LENGTH_SHORT).show()
                            }
                        },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1F2937))
                    ) {
                        Text("Save Logs", color = Color.White)
                    }

                    Button(
                        onClick = {
                            LinkOSLogger.clearBuffer()
                            logText = LinkOSLogger.generatePairingReport(connectionState.name, lastFailureStage)
                            Toast.makeText(context, "Logs cleared!", Toast.LENGTH_SHORT).show()
                        },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFDC2626))
                    ) {
                        Text("Clear Logs", color = Color.White)
                    }
                }
            }
        }
    }
}
