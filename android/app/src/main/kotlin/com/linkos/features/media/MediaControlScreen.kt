package com.linkos.features.media

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.pressScale
import com.linkos.ui.components.rememberPulseScale
import com.linkos.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MediaControlScreen(
    onNavigateBack: () -> Unit,
    viewModel: MediaControlViewModel = hiltViewModel()
) {
    val mediaInfo by viewModel.mediaInfo.collectAsState()
    val context = LocalContext.current

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
                                    .background(Brush.linearGradient(GradientMedia)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    Icons.Outlined.Tune,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Text("Media & Hardware Controls", fontWeight = FontWeight.Bold, color = Color.White)
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = onNavigateBack) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkSurface)
                )
                HorizontalDivider(color = DarkBorder, thickness = 1.dp)
            }
        },
        containerColor = DarkBackground
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Album Art & Now Playing Card
            GlassCard(
                modifier = Modifier.fillMaxWidth(),
                cornerRadius = 20.dp,
                glowColor = LinkOSPink,
                enableGlow = mediaInfo.isPlaying
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(8.dp)
                ) {
                    // Album art placeholder with pulsing glow when playing
                    val artScale = if (mediaInfo.isPlaying) rememberPulseScale(0.98f, 1.02f, 2000) else 1f
                    Box(
                        modifier = Modifier
                            .size(140.dp)
                            .scale(artScale)
                            .clip(RoundedCornerShape(20.dp))
                            .background(Brush.linearGradient(GradientMedia)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            Icons.Default.MusicNote,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(64.dp)
                        )
                    }

                    // Track info
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Text(
                            text = mediaInfo.title,
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.Bold,
                            color = TextPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Text(
                            text = mediaInfo.artist,
                            style = MaterialTheme.typography.bodyMedium,
                            color = LinkOSPink,
                            fontWeight = FontWeight.Medium
                        )
                        Text(
                            text = mediaInfo.album,
                            style = MaterialTheme.typography.bodySmall,
                            color = TextTertiary
                        )
                    }

                    // Playback Controls Row
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(24.dp)
                    ) {
                        FilledTonalIconButton(
                            onClick = {
                                HapticUtils.lightTap(context)
                                viewModel.triggerAction("previous")
                            },
                            modifier = Modifier
                                .size(48.dp)
                                .pressScale(onClick = {}),
                            shape = CircleShape,
                            colors = IconButtonDefaults.filledTonalIconButtonColors(
                                containerColor = DarkSurfaceElevated,
                                contentColor = TextPrimary
                            )
                        ) {
                            Icon(Icons.Default.SkipPrevious, contentDescription = "Previous", modifier = Modifier.size(24.dp))
                        }

                        IconButton(
                            onClick = {
                                HapticUtils.mediumTap(context)
                                viewModel.triggerAction("play_pause")
                            },
                            modifier = Modifier
                                .size(64.dp)
                                .pressScale(onClick = {}),
                            colors = IconButtonDefaults.iconButtonColors(containerColor = LinkOSPink)
                        ) {
                            Icon(
                                imageVector = if (mediaInfo.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = "Play/Pause",
                                tint = Color.White,
                                modifier = Modifier.size(32.dp)
                            )
                        }

                        FilledTonalIconButton(
                            onClick = {
                                HapticUtils.lightTap(context)
                                viewModel.triggerAction("next")
                            },
                            modifier = Modifier
                                .size(48.dp)
                                .pressScale(onClick = {}),
                            shape = CircleShape,
                            colors = IconButtonDefaults.filledTonalIconButtonColors(
                                containerColor = DarkSurfaceElevated,
                                contentColor = TextPrimary
                            )
                        ) {
                            Icon(Icons.Default.SkipNext, contentDescription = "Next", modifier = Modifier.size(24.dp))
                        }
                    }
                }
            }

            // Hardware Sliders Card (Volume & Brightness)
            GlassCard(
                modifier = Modifier.fillMaxWidth(),
                cornerRadius = 20.dp
            ) {
                Column(
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    // Volume Control
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    imageVector = if (mediaInfo.volume > 0f) Icons.Default.VolumeUp else Icons.Default.VolumeOff,
                                    contentDescription = null,
                                    tint = LinkOSOrange,
                                    modifier = Modifier.size(18.dp)
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    text = "Mac Volume",
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    color = TextPrimary
                                )
                            }
                            Text(
                                text = "${(mediaInfo.volume * 100).toInt()}%",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = LinkOSOrange
                            )
                        }
                        Slider(
                            value = mediaInfo.volume,
                            onValueChange = { viewModel.setVolume(it) },
                            colors = SliderDefaults.colors(
                                thumbColor = LinkOSOrange,
                                activeTrackColor = LinkOSOrange,
                                inactiveTrackColor = DarkBorder
                            )
                        )
                    }

                    HorizontalDivider(color = DarkBorder.copy(alpha = 0.5f))

                    // Brightness Control
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    imageVector = Icons.Default.WbSunny,
                                    contentDescription = null,
                                    tint = LinkOSYellow,
                                    modifier = Modifier.size(18.dp)
                                )
                                Spacer(Modifier.width(8.dp))
                                Text(
                                    text = "Mac Brightness",
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    color = TextPrimary
                                )
                            }
                            Text(
                                text = "${(mediaInfo.brightness * 100).toInt()}%",
                                style = MaterialTheme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = LinkOSYellow
                            )
                        }
                        Slider(
                            value = mediaInfo.brightness,
                            onValueChange = { viewModel.setBrightness(it) },
                            colors = SliderDefaults.colors(
                                thumbColor = LinkOSYellow,
                                activeTrackColor = LinkOSYellow,
                                inactiveTrackColor = DarkBorder
                            )
                        )
                    }
                }
            }
        }
    }
}

private val LinkOSYellow = Color(0xFFFBBF24)
