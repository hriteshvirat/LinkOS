package com.linkos.features.workspace

import android.view.MotionEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Tablet
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInteropFilter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun TabletScreen(
    onNavigateBack: () -> Unit,
    viewModel: TabletViewModel = hiltViewModel()
) {
    val isSecondDisplayActive by viewModel.isSecondDisplayActive.collectAsState()
    val isXiaomiTablet by viewModel.isXiaomiTablet.collectAsState()
    val context = LocalContext.current
    var selectedTab by remember { mutableIntStateOf(0) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(32.dp)
                                .clip(RoundedCornerShape(8.dp))
                                .background(Brush.linearGradient(GradientProductivity)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Outlined.Tablet,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        Column {
                            Text("Tablet Workspace", fontWeight = FontWeight.Bold, color = Color.White)
                            if (isXiaomiTablet) {
                                Text("Xiaomi Stylus Engine Active", style = MaterialTheme.typography.bodySmall, color = LinkOSCyan, fontSize = 11.sp)
                            }
                        }
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
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // Mode Tabs
            PrimaryTabRow(
                selectedTabIndex = selectedTab,
                containerColor = DarkSurfaceElevated,
                contentColor = LinkOSCyan
            ) {
                Tab(
                    selected = selectedTab == 0,
                    onClick = {
                        HapticUtils.lightTap(context)
                        selectedTab = 0
                    }
                ) {
                    Text("Wireless Display", modifier = Modifier.padding(12.dp), fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                }
                Tab(
                    selected = selectedTab == 1,
                    onClick = {
                        HapticUtils.lightTap(context)
                        selectedTab = 1
                    }
                ) {
                    Text("Drawing Stylus", modifier = Modifier.padding(12.dp), fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                }
                Tab(
                    selected = selectedTab == 2,
                    onClick = {
                        HapticUtils.lightTap(context)
                        selectedTab = 2
                    }
                ) {
                    Text("Dev Dashboard", modifier = Modifier.padding(12.dp), fontWeight = FontWeight.Bold, style = MaterialTheme.typography.labelMedium)
                }
            }

            when (selectedTab) {
                0 -> {
                    // Wireless Display Mode
                    GlassCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                        cornerRadius = 20.dp,
                        glowColor = LinkOSCyan
                    ) {
                        Column(
                            modifier = Modifier.fillMaxSize(),
                            verticalArrangement = Arrangement.Center,
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Icon(Icons.Default.DesktopWindows, contentDescription = null, tint = LinkOSCyan, modifier = Modifier.size(56.dp))
                            Spacer(Modifier.height(14.dp))
                            Text(
                                text = if (isSecondDisplayActive) "Second Display Streaming at 2560x1600" else "Extend your Mac desktop wirelessly",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                            Spacer(Modifier.height(16.dp))
                            Button(
                                onClick = {
                                    HapticUtils.mediumTap(context)
                                    viewModel.toggleSecondDisplay()
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = if (isSecondDisplayActive) LinkOSRed else LinkOSCyan),
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier.pressScale(onClick = {})
                            ) {
                                Text(if (isSecondDisplayActive) "Disconnect Second Display" else "Enable Second Display", fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                }
                1 -> {
                    // Drawing Tablet Surface with Stylus Input
                    GlassCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .pointerInteropFilter { motionEvent ->
                                val x = motionEvent.x
                                val y = motionEvent.y
                                val pressure = motionEvent.pressure
                                val tiltX = motionEvent.getAxisValue(MotionEvent.AXIS_TILT)
                                viewModel.sendStylusStroke(x, y, pressure, tiltX, 0f)
                                true
                            },
                        cornerRadius = 20.dp,
                        glowColor = LinkOSPurple
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxSize()
                                .background(Color(0xFF0C0E14)),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Default.Draw, contentDescription = null, tint = LinkOSPurple, modifier = Modifier.size(52.dp))
                                Text("Stylus Drawing Surface", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = TextPrimary)
                                Text("Supports pressure sensitivity & tilt angle", style = MaterialTheme.typography.bodySmall, color = TextTertiary)
                            }
                        }
                    }
                }
                2 -> {
                    // Multi-pane Tablet Dev Dashboard
                    GlassCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                        cornerRadius = 20.dp
                    ) {
                        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("Tablet Multi-Pane Workspace", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = TextPrimary)
                            Text("Reference Screen • File Shelf • Live Terminal Monitor", style = MaterialTheme.typography.bodyMedium, color = TextSecondary)
                        }
                    }
                }
            }
        }
    }
}
