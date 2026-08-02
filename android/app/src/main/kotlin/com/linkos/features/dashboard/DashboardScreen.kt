package com.linkos.features.dashboard

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.StaggeredAnimatedVisibility
import com.linkos.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DashboardScreen(
    onNavigateBack: () -> Unit,
    viewModel: DashboardViewModel = hiltViewModel()
) {
    val metrics by viewModel.metrics.collectAsState()

    Scaffold(
        topBar = {
            Column {
                TopAppBar(
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                modifier = Modifier
                                    .size(32.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(Brush.linearGradient(GradientSystem)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    Icons.Outlined.Speed,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Text("System Dashboard", fontWeight = FontWeight.Bold, color = Color.White)
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = onNavigateBack) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
                        }
                    },
                    actions = {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(end = 12.dp)
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(8.dp)
                                    .clip(CircleShape)
                                    .background(StatusConnected)
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "LIVE",
                                style = MaterialTheme.typography.labelSmall,
                                fontWeight = FontWeight.Bold,
                                color = StatusConnected,
                                letterSpacing = 1.sp
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkSurface)
                )
                HorizontalDivider(color = DarkBorder, thickness = 1.dp)
            }
        },
        containerColor = DarkBackground
    ) { paddingValues ->
        LazyVerticalGrid(
            columns = GridCells.Fixed(2),
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // CPU Card
            item {
                StaggeredAnimatedVisibility(visible = true, index = 0) {
                    val totalCpu = (metrics.cpuUserPercent + metrics.cpuSystemPercent).coerceIn(0.0, 100.0)
                    MetricCard(
                        title = "CPU Usage",
                        value = "%.1f%%".format(totalCpu),
                        progress = (totalCpu / 100.0).toFloat(),
                        subtitle = "User: %.1f%% • Sys: %.1f%%".format(metrics.cpuUserPercent, metrics.cpuSystemPercent),
                        icon = Icons.Default.Memory,
                        accentGradient = GradientNavigation,
                        glowColor = LinkOSBlue
                    )
                }
            }

            // RAM Card
            item {
                StaggeredAnimatedVisibility(visible = true, index = 1) {
                    val totalGb = metrics.memoryTotalBytes / (1024.0 * 1024.0 * 1024.0)
                    val usedGb = metrics.memoryUsedBytes / (1024.0 * 1024.0 * 1024.0)
                    val ramPercent = if (totalGb > 0) (usedGb / totalGb) else 0.0
                    MetricCard(
                        title = "RAM Memory",
                        value = "%.1f GB".format(usedGb),
                        progress = ramPercent.toFloat(),
                        subtitle = "Used of %.0f GB (%.0f%%)".format(totalGb, ramPercent * 100),
                        icon = Icons.Default.SdCard,
                        accentGradient = GradientProductivity,
                        glowColor = LinkOSPurple
                    )
                }
            }

            // Battery Card
            item {
                StaggeredAnimatedVisibility(visible = true, index = 2) {
                    val batColor = if (metrics.batteryPercent < 20) LinkOSRed else LinkOSGreen
                    MetricCard(
                        title = "Mac Battery",
                        value = "%.0f%%".format(metrics.batteryPercent),
                        progress = (metrics.batteryPercent / 100.0).toFloat(),
                        subtitle = if (metrics.isCharging) "Charging ⚡" else "On Battery 🔋",
                        icon = if (metrics.isCharging) Icons.Default.BatteryChargingFull else Icons.Default.BatteryFull,
                        accentGradient = if (metrics.batteryPercent < 20) GradientAdvanced else GradientSystem,
                        glowColor = batColor
                    )
                }
            }

            // Storage SSD Card
            item {
                StaggeredAnimatedVisibility(visible = true, index = 3) {
                    val diskTotalGb = metrics.diskTotalBytes / (1024.0 * 1024.0 * 1024.0)
                    val diskFreeGb = metrics.diskFreeBytes / (1024.0 * 1024.0 * 1024.0)
                    val diskUsedGb = diskTotalGb - diskFreeGb
                    val diskPercent = if (diskTotalGb > 0) (diskUsedGb / diskTotalGb) else 0.0
                    MetricCard(
                        title = "SSD Storage",
                        value = "%.0f GB Free".format(diskFreeGb),
                        progress = diskPercent.toFloat(),
                        subtitle = "Total: %.0f GB".format(diskTotalGb),
                        icon = Icons.Default.Storage,
                        accentGradient = GradientProductivity,
                        glowColor = LinkOSCyan
                    )
                }
            }
        }
    }
}

@Composable
private fun MetricCard(
    title: String,
    value: String,
    progress: Float,
    subtitle: String,
    icon: ImageVector,
    accentGradient: List<Color>,
    glowColor: Color
) {
    val animatedProgress by animateFloatAsState(
        targetValue = progress.coerceIn(0f, 1f),
        animationSpec = tween(600, easing = FastOutSlowInEasing),
        label = "progress"
    )

    GlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = 16.dp,
        glowColor = glowColor,
        padding = 14.dp
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Brush.linearGradient(accentGradient)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(icon, contentDescription = title, tint = Color.White, modifier = Modifier.size(18.dp))
                }
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }

            Text(
                text = value,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                color = TextPrimary
            )

            LinearProgressIndicator(
                progress = { animatedProgress },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(CircleShape),
                color = glowColor,
                trackColor = glowColor.copy(alpha = 0.15f)
            )

            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = TextTertiary,
                fontSize = 11.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}
