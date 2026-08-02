package com.linkos.features.workspace

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.StaggeredAnimatedVisibility
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeviceDashboardScreen(
    onNavigateBack: () -> Unit,
    viewModel: WorkspaceViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val cpuLoad by viewModel.cpuLoad.collectAsState()
    val ramUsed by viewModel.ramUsageBytes.collectAsState()
    val ramTotal by viewModel.ramTotalBytes.collectAsState()

    // Keep memory trend log lists for drawing historic charts (up to 30 elements)
    val cpuHistory = remember { mutableStateListOf<Float>() }
    val ramHistory = remember { mutableStateListOf<Float>() }

    // Update histories whenever viewModel values tick
    LaunchedEffect(cpuLoad) {
        if (cpuHistory.size > 30) {
            cpuHistory.removeFirst()
        }
        cpuHistory.add(cpuLoad.toFloat())
    }

    LaunchedEffect(ramUsed, ramTotal) {
        val ratio = if (ramTotal > 0) ramUsed.toFloat() / ramTotal else 0f
        if (ramHistory.size > 30) {
            ramHistory.removeFirst()
        }
        ramHistory.add(ratio)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(Brush.linearGradient(GradientNavigation)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Default.Analytics,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        Text("Device Dashboard", fontWeight = FontWeight.Bold, color = Color.White)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
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
                .padding(horizontal = 16.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Spacer(Modifier.height(4.dp))

            // Telemetry Overview Meters
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                // CPU Card
                GlassCard(
                    modifier = Modifier.weight(1f),
                    cornerRadius = 14.dp,
                    padding = 12.dp
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("HOST CPU", style = MaterialTheme.typography.labelSmall, color = TextTertiary)
                        Spacer(Modifier.height(8.dp))
                        CircularProgressIndicator(
                            progress = { cpuLoad.toFloat() },
                            color = LinkOSBlue,
                            trackColor = DarkSurfaceHighest,
                            strokeWidth = 6.dp,
                            modifier = Modifier.size(64.dp)
                        )
                        Spacer(Modifier.height(8.dp))
                        Text("%.1f%%".format(cpuLoad * 100), fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 16.sp)
                    }
                }

                // RAM Card
                GlassCard(
                    modifier = Modifier.weight(1f),
                    cornerRadius = 14.dp,
                    padding = 12.dp
                ) {
                    val ramRatio = if (ramTotal > 0) ramUsed.toFloat() / ramTotal else 0f
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("HOST RAM", style = MaterialTheme.typography.labelSmall, color = TextTertiary)
                        Spacer(Modifier.height(8.dp))
                        CircularProgressIndicator(
                            progress = { ramRatio },
                            color = LinkOSPurple,
                            trackColor = DarkSurfaceHighest,
                            strokeWidth = 6.dp,
                            modifier = Modifier.size(64.dp)
                        )
                        Spacer(Modifier.height(8.dp))
                        Text("%.1f GB".format(ramUsed / (1024.0 * 1024.0 * 1024.0)), fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 16.sp)
                    }
                }
            }

            // CPU Trend Line Chart
            GlassCard(
                modifier = Modifier.fillMaxWidth(),
                cornerRadius = 16.dp,
                padding = 16.dp
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("CPU Load Trend (Real-time)", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = TextPrimary)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(100.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color(0xFF0F111A))
                    ) {
                        TrendLineChart(points = cpuHistory, color = LinkOSBlue)
                    }
                }
            }

            // RAM Trend Line Chart
            GlassCard(
                modifier = Modifier.fillMaxWidth(),
                cornerRadius = 16.dp,
                padding = 16.dp
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("RAM Footprint History", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = TextPrimary)
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(100.dp)
                            .clip(RoundedCornerShape(8.dp))
                            .background(Color(0xFF0F111A))
                    ) {
                        TrendLineChart(points = ramHistory, color = LinkOSPurple)
                    }
                }
            }

            // Connection health and diagnostics
            GlassCard(
                modifier = Modifier.fillMaxWidth(),
                cornerRadius = 16.dp,
                padding = 16.dp
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Ecosystem Diagnoses", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = TextPrimary)
                    Divider(color = DarkSurfaceHighest)
                    DiagnosticRow(label = "QoS Profile", value = "Optimal", tint = Color(0xFF00FF66))
                    DiagnosticRow(label = "Host Thermal", value = "Nominal", tint = Color(0xFF00FF66))
                    DiagnosticRow(label = "RTT Control", value = "16 ms", tint = LinkOSCyan)
                    DiagnosticRow(label = "WiFi Signal", value = "Excellent (-42dB)", tint = LinkOSBlue)
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun DiagnosticRow(label: String, value: String, tint: Color) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, color = TextSecondary, fontSize = 13.sp)
        Text(value, color = tint, fontWeight = FontWeight.Bold, fontSize = 13.sp)
    }
}

@Composable
private fun TrendLineChart(points: List<Float>, color: Color) {
    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .padding(vertical = 12.dp, horizontal = 8.dp)
    ) {
        if (points.size < 2) return@Canvas
        
        val width = size.width
        val height = size.height
        val stepX = width / (points.size - 1)
        
        val path = Path().apply {
            val startY = height - (points[0] * height)
            moveTo(0f, startY)
            for (i in 1 until points.size) {
                val nextX = i * stepX
                val nextY = height - (points[i] * height)
                lineTo(nextX, nextY)
            }
        }
        
        drawPath(
            path = path,
            color = color,
            style = Stroke(width = 4f)
        )
    }
}
