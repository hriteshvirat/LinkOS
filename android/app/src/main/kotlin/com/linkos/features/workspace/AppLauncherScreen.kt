package com.linkos.features.workspace

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
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
fun AppLauncherScreen(
    onNavigateBack: () -> Unit,
    viewModel: WorkspaceViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val appList by viewModel.appList.collectAsState()
    
    var searchQuery by remember { mutableStateOf("") }
    
    // Pinned application states
    val pinnedApps = remember { mutableStateListOf("Finder", "Safari", "Terminal") }
    
    // Sort and filter apps alphabetically
    val sortedFilteredApps = remember(appList, searchQuery) {
        appList.filter { it.contains(searchQuery, ignoreCase = true) }
            .sortedWith(compareBy { it.lowercase() })
    }

    LaunchedEffect(Unit) {
        viewModel.queryAppsList()
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
                                .background(Brush.linearGradient(GradientProductivity)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                Icons.Default.GridView,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                        Spacer(Modifier.width(10.dp))
                        Text("Remote App Launcher", fontWeight = FontWeight.Bold, color = Color.White)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
                    }
                },
                actions = {
                    IconButton(onClick = {
                        HapticUtils.lightTap(context)
                        viewModel.queryAppsList()
                    }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh Applications List", tint = TextSecondary)
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
        ) {
            // 1. Search Box
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("Search Mac applications...", color = TextTertiary, fontSize = 14.sp) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = TextSecondary) },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(10.dp)),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = LinkOSBlue,
                    unfocusedBorderColor = DarkSurfaceHighest,
                    focusedContainerColor = DarkSurfaceElevated,
                    unfocusedContainerColor = DarkSurfaceElevated
                )
            )

            if (sortedFilteredApps.isEmpty() && appList.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        CircularProgressIndicator(color = LinkOSCyan, modifier = Modifier.size(36.dp))
                        Text("Discovering installed apps on Mac...", style = MaterialTheme.typography.bodyMedium, color = TextSecondary)
                    }
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(3),
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    // Pinned Header section if search query is empty
                    if (searchQuery.isEmpty()) {
                        val pinnedList = sortedFilteredApps.filter { pinnedApps.contains(it) }
                        if (pinnedList.isNotEmpty()) {
                            itemsIndexed(pinnedList, key = { index, item -> "pinned_$item" }) { index, appName ->
                                AppLauncherGridItem(
                                    appName = appName,
                                    isPinned = true,
                                    onTogglePin = {
                                        HapticUtils.lightTap(context)
                                        pinnedApps.remove(appName)
                                    },
                                    onClick = {
                                        HapticUtils.lightTap(context)
                                        viewModel.launchAppOnMac(appName)
                                        Toast.makeText(context, "Launching $appName on Mac...", Toast.LENGTH_SHORT).show()
                                    }
                                )
                            }
                        }
                    }

                    // Remaining apps list
                    val remainingApps = if (searchQuery.isEmpty()) {
                        sortedFilteredApps.filter { !pinnedApps.contains(it) }
                    } else {
                        sortedFilteredApps
                    }

                    itemsIndexed(remainingApps, key = { _, item -> item }) { index, appName ->
                        StaggeredAnimatedVisibility(visible = true, index = index) {
                            AppLauncherGridItem(
                                appName = appName,
                                isPinned = false,
                                onTogglePin = {
                                    HapticUtils.lightTap(context)
                                    pinnedApps.add(appName)
                                },
                                onClick = {
                                    HapticUtils.lightTap(context)
                                    viewModel.launchAppOnMac(appName)
                                    Toast.makeText(context, "Launching $appName on Mac...", Toast.LENGTH_SHORT).show()
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun AppLauncherGridItem(
    appName: String,
    isPinned: Boolean,
    onTogglePin: () -> Unit,
    onClick: () -> Unit
) {
    val isRunning = remember(appName) {
        listOf("Finder", "Safari", "Terminal", "VSCode", "Xcode").contains(appName)
    }

    GlassCard(
        modifier = Modifier
            .aspectRatio(0.9f)
            .pressScale(onClick = onClick),
        cornerRadius = 14.dp,
        padding = 8.dp,
        glowColor = if (isPinned) LinkOSCyan else GlassBorder
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            // Pin Toggle button in top right corner
            Icon(
                imageVector = if (isPinned) Icons.Default.PushPin else Icons.Default.PushPin,
                contentDescription = null,
                tint = if (isPinned) LinkOSCyan else TextTertiary.copy(alpha = 0.3f),
                modifier = Modifier
                    .size(14.dp)
                    .align(Alignment.TopEnd)
                    .clickable { onTogglePin() }
            )

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(top = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                val (gradient, tint) = getAppIconColor(appName)
                Box(
                    modifier = Modifier
                        .size(42.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Brush.linearGradient(gradient)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = getAppIcon(appName),
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(24.dp)
                    )
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    text = appName,
                    color = TextPrimary,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                
                if (isRunning) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier.padding(top = 2.dp)
                    ) {
                        Box(
                            modifier = Modifier
                                .size(5.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(Color(0xFF00FF66))
                        )
                        Text("RUNNING", color = Color(0xFF00FF66), fontSize = 8.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

private fun getAppIcon(appName: String): ImageVector {
    return when (appName.lowercase()) {
        "finder" -> Icons.Default.FolderOpen
        "safari" -> Icons.Default.Explore
        "terminal" -> Icons.Default.Code
        "vscode", "visual studio code" -> Icons.Default.Edit
        "xcode" -> Icons.Default.Build
        "system settings" -> Icons.Default.Settings
        "music" -> Icons.Default.MusicNote
        "activity monitor" -> Icons.Default.Analytics
        else -> Icons.Default.AutoAwesome
    }
}

private fun getAppIconColor(appName: String): kotlin.Pair<List<Color>, Color> {
    return when (appName.lowercase()) {
        "finder" -> kotlin.Pair(GradientNavigation, Color.White)
        "safari" -> kotlin.Pair(GradientProductivity, Color.White)
        "terminal" -> kotlin.Pair(listOf(Color.Black, DarkSurfaceHighest), Color(0xFF00FF66))
        "xcode" -> kotlin.Pair(listOf(Color(0xFF007AFF), Color(0xFF0056B3)), Color.White)
        "music" -> kotlin.Pair(listOf(Color(0xFFFF2D55), Color(0xFFD3003F)), Color.White)
        else -> kotlin.Pair(listOf(DarkSurfaceElevated, DarkSurfaceHighest), LinkOSPurple)
    }
}
