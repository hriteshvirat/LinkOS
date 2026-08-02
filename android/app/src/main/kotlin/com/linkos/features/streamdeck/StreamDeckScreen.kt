package com.linkos.features.streamdeck

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.StaggeredAnimatedVisibility
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StreamDeckScreen(
    onNavigateBack: () -> Unit,
    viewModel: StreamDeckViewModel = hiltViewModel()
) {
    val buttons by viewModel.buttons.collectAsState()
    val context = LocalContext.current
    var searchQuery by remember { mutableStateOf("") }

    val filteredButtons = remember(buttons, searchQuery) {
        if (searchQuery.isBlank()) buttons
        else buttons.filter { it.label.contains(searchQuery, ignoreCase = true) }
    }

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
                                    .background(Brush.linearGradient(GradientAdvanced)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    Icons.Outlined.GridView,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Text("Macro Shortcuts", fontWeight = FontWeight.Bold, color = Color.White)
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
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            // Search bar
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("Search macros...", color = TextTertiary, fontSize = 13.sp) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = TextTertiary, modifier = Modifier.size(18.dp)) },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { searchQuery = "" }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear", tint = TextTertiary, modifier = Modifier.size(16.dp))
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = LinkOSBlue,
                    unfocusedBorderColor = DarkBorder,
                    focusedContainerColor = DarkSurface,
                    unfocusedContainerColor = DarkSurface,
                    focusedTextColor = TextPrimary,
                    unfocusedTextColor = TextPrimary
                ),
                shape = RoundedCornerShape(12.dp)
            )

            Text(
                text = "MACRO ACTION GRID",
                style = MaterialTheme.typography.labelSmall,
                color = TextTertiary,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.5.sp,
                modifier = Modifier.padding(start = 4.dp)
            )

            AnimatedContent(
                targetState = filteredButtons,
                transitionSpec = { fadeIn() togetherWith fadeOut() },
                label = "macro_grid_anim"
            ) { displayedButtons ->
                if (displayedButtons.isEmpty()) {
                    Box(
                        modifier = Modifier.fillMaxSize(),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(Icons.Default.SearchOff, contentDescription = null, tint = TextTertiary, modifier = Modifier.size(48.dp))
                            Spacer(Modifier.height(12.dp))
                            Text("No macros match \"$searchQuery\"", color = TextTertiary, style = MaterialTheme.typography.bodyMedium)
                        }
                    }
                } else {
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(3),
                        modifier = Modifier.fillMaxSize(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        itemsIndexed(displayedButtons, key = { _, button -> button.id }) { index, button ->
                            StaggeredAnimatedVisibility(visible = true, index = index) {
                                StreamTile(
                                    button = button,
                                    onClick = {
                                        HapticUtils.mediumTap(context)
                                        viewModel.triggerButton(button)
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StreamTile(button: StreamButton, onClick: () -> Unit) {
    val accentColor = parseHexColor(button.colorHex)

    GlassCard(
        modifier = Modifier
            .aspectRatio(1f)
            .pressScale(onClick = onClick),
        cornerRadius = 16.dp,
        glowColor = accentColor,
        enableGlow = true,
        padding = 8.dp
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Icon container — increased from 44dp to 52dp (~18% size boost)
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(accentColor.copy(alpha = 0.2f)),
                contentAlignment = Alignment.Center
            ) {
                val isEmoji = button.iconType == "emoji" || isSingleEmoji(button.iconName)
                if (isEmoji) {
                    // Render emoji as Text for correct Unicode glyph rendering
                    Text(
                        text = button.iconName,
                        fontSize = 24.sp,
                        textAlign = TextAlign.Center
                    )
                } else {
                    Icon(
                        imageVector = getStreamIcon(button.iconName),
                        contentDescription = button.label,
                        tint = accentColor,
                        modifier = Modifier.size(28.dp) // increased from 24dp
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = button.label,
                style = MaterialTheme.typography.labelSmall,
                color = TextPrimary,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

/** Returns true if the string is a single Unicode emoji character (or emoji sequence). */
private fun isSingleEmoji(s: String): Boolean {
    if (s.isBlank() || s.length > 8) return false
    val codePoints = s.codePoints().toArray()
    // Emoji ranges: Emoticons, Misc Symbols, Dingbats, Supplemental, etc.
    return codePoints.all { cp ->
        (cp in 0x1F300..0x1FAFF) || // Emoji block
        (cp in 0x2600..0x27BF) ||   // Misc symbols + dingbats
        (cp == 0x200D) ||            // ZWJ
        (cp == 0xFE0F) ||            // Variation selector
        (cp in 0x1F1E0..0x1F1FF)    // Regional indicators (flags)
    }
}

private fun parseHexColor(hex: String): Color {
    return try {
        Color(android.graphics.Color.parseColor(hex))
    } catch (_: Exception) {
        LinkOSBlue
    }
}

/**
 * Maps macOS SF Symbol names and common Material icon names to the nearest Android Material icon.
 * SF Symbol names from macOS StreamDeckButtonConfig are mapped here for display on Android.
 * When no match is found, SmartButton is the fallback.
 */
private fun getStreamIcon(name: String): ImageVector {
    return when (name.lowercase().replace(".", "_").replace(" ", "_")) {
        // Volume / Audio
        "volume_off", "speaker_slash", "speaker_slash_fill", "speaker_x_mark_fill" -> Icons.Default.VolumeOff
        "volume_up", "speaker_3", "speaker_3_fill", "speaker_wave_3_fill" -> Icons.Default.VolumeUp
        "volume_down", "speaker_1", "speaker_1_fill" -> Icons.Default.VolumeDown
        "speaker", "speaker_fill", "speaker_wave_1_fill" -> Icons.Default.VolumeDown
        "headphones", "headphones_circle", "earbuds" -> Icons.Default.Headphones
        "music_note", "music_note_list", "music_quarternote_3" -> Icons.Default.MusicNote
        "mic", "mic_fill", "microphone" -> Icons.Default.Mic
        "mic_slash", "mic_slash_fill" -> Icons.Default.MicOff

        // Media
        "play", "play_fill", "play_circle", "play_circle_fill" -> Icons.Default.PlayArrow
        "pause", "pause_fill", "pause_circle", "pause_circle_fill" -> Icons.Default.Pause
        "stop", "stop_fill", "stop_circle" -> Icons.Default.Stop
        "play_arrow", "playpause", "playpause_fill" -> Icons.Default.PlayArrow
        "forward", "forward_fill", "forward_end", "forward_end_fill" -> Icons.Default.SkipNext
        "backward", "backward_fill", "backward_end", "backward_end_fill" -> Icons.Default.SkipPrevious
        "repeat", "repeat_1", "arrow_2_circlepath" -> Icons.Default.Repeat
        "shuffle" -> Icons.Default.Shuffle

        // Camera / Photo
        "camera", "camera_fill", "camera_circle", "camera_circle_fill" -> Icons.Default.Camera
        "camera_on_rectangle", "camera_on_rectangle_fill" -> Icons.Default.CameraEnhance
        "photo", "photo_fill", "photo_on_rectangle" -> Icons.Default.Photo
        "video", "video_fill", "video_circle", "video_badge_plus" -> Icons.Default.Videocam
        "photo_stack", "rectangle_stack", "rectangle_stack_fill" -> Icons.Default.PhotoLibrary

        // System / Settings
        "gear", "gearshape", "gearshape_fill", "gearshape_2", "settings" -> Icons.Default.Settings
        "gear_circle", "gear_circle_fill" -> Icons.Default.Settings
        "wrench", "wrench_fill", "wrench_and_screwdriver", "wrench_and_screwdriver_fill" -> Icons.Default.Build
        "hammer", "hammer_fill" -> Icons.Default.Build
        "lock", "lock_fill", "lock_circle", "lock_shield" -> Icons.Default.Lock
        "lock_open", "lock_open_fill" -> Icons.Default.LockOpen
        "power", "power_circle", "power_circle_fill" -> Icons.Default.Power
        "sleep", "moon", "moon_fill", "moon_circle" -> Icons.Default.DarkMode
        "sun_max", "sun_max_fill", "brightness_high" -> Icons.Default.BrightnessHigh
        "sun_min", "sun_min_fill", "brightness_low" -> Icons.Default.BrightnessLow
        "wifi", "wifi_circle", "wifi_square" -> Icons.Default.Wifi
        "wifi_slash", "wifi_exclamationmark" -> Icons.Default.WifiOff
        "airplane", "airplane_circle" -> Icons.Default.AirplanemodeActive
        "battery_100", "battery_100_bolt" -> Icons.Default.BatteryFull
        "battery_25", "battery_0" -> Icons.Default.BatteryAlert

        // Files / Folders
        "folder", "folder_fill", "folder_circle" -> Icons.Default.Folder
        "folder_badge_plus", "folder_badge_plus_fill" -> Icons.Default.CreateNewFolder
        "doc", "doc_fill", "doc_circle" -> Icons.Default.Description
        "doc_text", "doc_text_fill", "doc_richtext" -> Icons.Default.Article
        "arrow_down_doc", "arrow_down_doc_fill" -> Icons.Default.Download
        "arrow_up_doc", "arrow_up_doc_fill" -> Icons.Default.Upload
        "tray_and_arrow_down", "tray_and_arrow_down_fill" -> Icons.Default.Download
        "externaldrive", "externaldrive_fill" -> Icons.Default.Storage
        "internaldrive", "internaldrive_fill" -> Icons.Default.Storage
        "trash", "trash_fill", "trash_circle" -> Icons.Default.Delete
        "archivebox", "archivebox_fill" -> Icons.Default.Archive
        "icloud", "icloud_fill", "icloud_and_arrow_up" -> Icons.Default.Cloud
        "icloud_and_arrow_down", "icloud_and_arrow_down_fill" -> Icons.Default.CloudDownload

        // Communication
        "message", "message_fill", "message_circle" -> Icons.Default.Message
        "phone", "phone_fill", "phone_circle" -> Icons.Default.Phone
        "phone_slash", "phone_slash_fill" -> Icons.Default.PhoneDisabled
        "envelope", "envelope_fill", "envelope_circle" -> Icons.Default.Email
        "bell", "bell_fill", "bell_circle" -> Icons.Default.Notifications
        "bell_slash", "bell_slash_fill" -> Icons.Default.NotificationsOff
        "bubble_left", "bubble_left_fill", "bubble_right", "bubble_right_fill" -> Icons.Default.Chat
        "video_badge_plus_fill" -> Icons.Default.VideoCall
        "facetime", "video_call" -> Icons.Default.VideoCall

        // Navigation / Location
        "map", "map_fill" -> Icons.Default.Map
        "location", "location_fill", "location_circle" -> Icons.Default.LocationOn
        "location_slash", "location_slash_fill" -> Icons.Default.LocationOff
        "arrow_up", "arrow_up_circle" -> Icons.Default.ArrowUpward
        "arrow_down", "arrow_down_circle" -> Icons.Default.ArrowDownward
        "arrow_left", "arrow_left_circle" -> Icons.Default.ArrowBack
        "arrow_right", "arrow_right_circle" -> Icons.Default.ArrowForward
        "chevron_left", "chevron_left_circle" -> Icons.Default.ChevronLeft
        "chevron_right", "chevron_right_circle" -> Icons.Default.ChevronRight
        "house", "house_fill", "house_circle" -> Icons.Default.Home

        // Apps / Browser
        "safari", "globe", "globe_americas", "globe_europe_africa", "globe_asia_australia" -> Icons.Default.Public
        "browser", "app_badge", "macwindow" -> Icons.Default.OpenInBrowser
        "terminal", "terminal_fill" -> Icons.Default.Terminal
        "code", "chevron_left_slash_chevron_right", "curlybraces" -> Icons.Default.Code
        "app", "app_fill", "apps" -> Icons.Default.Apps
        "keyboard", "keyboard_fill" -> Icons.Default.Keyboard
        "command", "command_circle" -> Icons.Default.Keyboard
        "escape", "escape_fill" -> Icons.Default.Keyboard

        // Search / Actions
        "magnifyingglass", "magnifyingglass_circle", "search" -> Icons.Default.Search
        "plus", "plus_circle", "plus_circle_fill" -> Icons.Default.Add
        "minus", "minus_circle", "minus_circle_fill" -> Icons.Default.Remove
        "xmark", "xmark_circle", "xmark_circle_fill" -> Icons.Default.Close
        "checkmark", "checkmark_circle", "checkmark_circle_fill" -> Icons.Default.Check
        "square_and_pencil", "pencil", "pencil_circle" -> Icons.Default.Edit
        "square_and_arrow_up", "square_and_arrow_up_fill" -> Icons.Default.Share
        "square_and_arrow_down", "square_and_arrow_down_fill" -> Icons.Default.Download
        "arrow_clockwise", "arrow_counterclockwise" -> Icons.Default.Refresh
        "star", "star_fill", "star_circle" -> Icons.Default.Star
        "heart", "heart_fill", "heart_circle" -> Icons.Default.Favorite
        "bookmark", "bookmark_fill", "bookmark_circle" -> Icons.Default.Bookmark
        "tag", "tag_fill", "tag_circle" -> Icons.Default.Label
        "eye", "eye_fill", "eye_circle" -> Icons.Default.Visibility
        "eye_slash", "eye_slash_fill" -> Icons.Default.VisibilityOff
        "scissors", "scissors_fill" -> Icons.Default.ContentCut
        "doc_on_clipboard", "doc_on_clipboard_fill" -> Icons.Default.ContentPaste
        "doc_on_doc", "doc_on_doc_fill" -> Icons.Default.ContentCopy

        // AI / Special
        "brain", "brain_head_profile", "cpu", "cpu_fill" -> Icons.Default.Psychology
        "wand_and_stars", "wand_and_stars_inverse", "sparkles", "wand_and_rays" -> Icons.Default.AutoAwesome
        "lightbulb", "lightbulb_fill", "lightbulb_circle" -> Icons.Default.Lightbulb
        "bolt", "bolt_fill", "bolt_circle", "lightning" -> Icons.Default.FlashOn
        "flame", "flame_fill" -> Icons.Default.LocalFireDepartment
        "person", "person_fill", "person_circle" -> Icons.Default.Person
        "person_2", "person_2_fill" -> Icons.Default.Group
        "rectangle_3_group", "rectangle_grid_2x2", "square_grid_2x2" -> Icons.Default.GridView
        "display", "desktopcomputer", "laptopcomputer" -> Icons.Default.Computer
        "iphone", "phone_fill_arrow_up_right" -> Icons.Default.PhoneAndroid
        "printer", "printer_fill" -> Icons.Default.Print

        // Fallback for explicitly named material icons (from older Android-only setups)
        "volume_off" -> Icons.Default.VolumeOff
        "public" -> Icons.Default.Public
        "play_arrow" -> Icons.Default.PlayArrow
        "add_circle" -> Icons.Default.AddCircle
        "lock" -> Icons.Default.Lock

        else -> Icons.Default.SmartButton
    }
}
