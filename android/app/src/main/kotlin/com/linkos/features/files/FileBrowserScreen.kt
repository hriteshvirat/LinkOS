package com.linkos.features.files

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.Image
import androidx.compose.ui.layout.ContentScale
import com.linkos.core.network.ConnectionPhase
import com.linkos.ui.components.ConnectionStatusBanner

private fun formatModificationDate(ms: Long): String {
    val date = java.util.Date(ms)
    val sdf = java.text.SimpleDateFormat("MM/dd/yy hh:mm a", java.util.Locale.getDefault())
    return sdf.format(date)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FileBrowserScreen(
    onNavigateBack: () -> Unit,
    viewModel: FileBrowserViewModel = hiltViewModel()
) {
    val currentPath by viewModel.currentPath.collectAsState()
    val files by viewModel.files.collectAsState()
    val thumbnails by viewModel.thumbnails.collectAsState()
    val viewMode by viewModel.viewMode.collectAsState()
    val context = LocalContext.current
    val clipboardManager = LocalClipboardManager.current
    val connectionPhase by viewModel.connectionPhase.collectAsState()
    val isConnected = connectionPhase == ConnectionPhase.CONNECTED
    val errorState by viewModel.errorState.collectAsState()
    
    val filePickerLauncher = rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.GetContent()
    ) { uri: android.net.Uri? ->
        if (uri != null) {
            viewModel.uploadFile(uri, context)
        }
    }

    var searchQuery by remember { mutableStateOf("") }
    var showHidden by remember { mutableStateOf(false) }

    // Dialog state for Renaming / Confirming actions
    var activeItemForRename by remember { mutableStateOf<FileItem?>(null) }
    var renameNewName by remember { mutableStateOf("") }

    // Filter and sort files (folders first, then files alphabetically)
    val filteredFiles = remember(files, searchQuery, showHidden) {
        files.filter { item ->
            val matchesSearch = item.name.contains(searchQuery, ignoreCase = true)
            val matchesHidden = showHidden || !item.isHidden
            matchesSearch && matchesHidden
        }.sortedWith { a, b ->
            if (a.isDirectory != b.isDirectory) {
                if (a.isDirectory) -1 else 1
            } else {
                val dateDiff = b.modificationDateMs.compareTo(a.modificationDateMs)
                if (dateDiff != 0) {
                    dateDiff
                } else {
                    a.name.compareTo(b.name, ignoreCase = true)
                }
            }
        }
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
                                    .background(Brush.linearGradient(GradientProductivity)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    Icons.Outlined.FolderOpen,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text("File Explorer", fontWeight = FontWeight.Bold, color = Color.White)
                                Text(
                                    text = currentPath,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary,
                                    fontSize = 11.sp,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = onNavigateBack) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
                        }
                    },
                    actions = {

                        IconButton(onClick = {
                            showHidden = !showHidden
                            HapticUtils.lightTap(context)
                        }) {
                            Icon(
                                imageVector = if (showHidden) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                contentDescription = "Toggle Hidden Files",
                                tint = if (showHidden) LinkOSBlue else TextSecondary
                            )
                        }
                        IconButton(onClick = {
                            viewModel.toggleViewMode()
                            HapticUtils.lightTap(context)
                        }) {
                            Icon(
                                imageVector = if (viewMode == FileViewMode.LIST) Icons.Default.GridView else Icons.Default.List,
                                contentDescription = "Toggle Layout",
                                tint = TextSecondary
                            )
                        }
                        IconButton(onClick = {
                            HapticUtils.lightTap(context)
                            viewModel.loadDirectory(currentPath)
                        }) {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = TextSecondary)
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkSurface)
                )
                HorizontalDivider(color = DarkBorder, thickness = 1.dp)
            }
        },
        floatingActionButton = {
            val uploadProgress by viewModel.uploadProgress.collectAsState()
            val isUploading = uploadProgress != null
            
            ExtendedFloatingActionButton(
                onClick = {
                    if (isUploading) {
                        HapticUtils.mediumTap(context)
                        viewModel.cancelUpload()
                    } else if (isConnected) {
                        HapticUtils.lightTap(context)
                        filePickerLauncher.launch("*/*")
                    } else {
                        Toast.makeText(context, "Connect a device to continue", Toast.LENGTH_SHORT).show()
                    }
                },
                modifier = Modifier.pressScale(),
                containerColor = LinkOSPurple,
                contentColor = Color.White,
                shape = RoundedCornerShape(14.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    if (isUploading) {
                        CircularProgressIndicator(
                            progress = { uploadProgress ?: 0f },
                            modifier = Modifier.size(14.dp),
                            color = LinkOSCyan,
                            strokeWidth = 2.dp
                        )
                        Text("Cancel (${(uploadProgress!! * 100).toInt()}%)", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    } else {
                        Icon(
                            imageVector = Icons.Default.Upload,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(16.dp)
                        )
                        Text(
                            text = "Upload",
                            color = Color.White,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
            }
        },
        containerColor = DarkBackground
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            ConnectionStatusBanner(isConnected = isConnected)
            
            // 1. Breadcrumbs Bar
            val pathSegments = currentPath.split("/").filter { it.isNotEmpty() }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .background(DarkSurfaceElevated)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Macintosh HD/Users",
                    color = if (currentPath == "/Users") TextPrimary else LinkOSBlue,
                    fontSize = 13.sp,
                    fontWeight = if (currentPath == "/Users") FontWeight.Bold else FontWeight.SemiBold,
                    modifier = Modifier.clickable {
                        if (currentPath != "/Users") {
                            HapticUtils.lightTap(context)
                            viewModel.loadDirectory("/Users")
                        }
                    }
                )
                
                var accumulatedPath = "/Users"
                pathSegments.drop(1).forEach { segment ->
                    accumulatedPath += "/$segment"
                    val segmentPath = accumulatedPath
                    Icon(Icons.Default.ChevronRight, contentDescription = null, tint = TextTertiary, modifier = Modifier.size(14.dp))
                    Text(
                        text = segment,
                        color = if (segmentPath == currentPath) TextPrimary else LinkOSBlue,
                        fontSize = 13.sp,
                        fontWeight = if (segmentPath == currentPath) FontWeight.Bold else FontWeight.SemiBold,
                        modifier = Modifier.clickable {
                            if (segmentPath != currentPath) {
                                HapticUtils.lightTap(context)
                                viewModel.loadDirectory(segmentPath)
                            }
                        }
                    )
                }
            }

            // 2. Search Box
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("Search files and folders...", color = TextTertiary, fontSize = 14.sp) },
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

            // 2.5 Progress Indicator overlay card for active transfers (Upload or Download)
            val uploadProgress by viewModel.uploadProgress.collectAsState()
            val uploadFileName by viewModel.uploadFileName.collectAsState()
            val downloadProgress by viewModel.downloadProgress.collectAsState()
            val downloadFileName by viewModel.downloadFileName.collectAsState()
            val isUploadPaused by viewModel.isUploadPaused.collectAsState()

            if (uploadProgress != null || downloadProgress != null) {
                val progress = uploadProgress ?: downloadProgress ?: 0f
                val fileName = uploadFileName ?: downloadFileName ?: "File"
                val isDownloading = downloadProgress != null
                val isPaused = if (!isDownloading) isUploadPaused else false
                
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp)
                        .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp)),
                    colors = CardDefaults.cardColors(containerColor = Color.White.copy(alpha = 0.03f)),
                    shape = RoundedCornerShape(14.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                CircularProgressIndicator(
                                    progress = { progress },
                                    modifier = Modifier.size(20.dp),
                                    color = if (isPaused) Color.Yellow else LinkOSCyan,
                                    strokeWidth = 2.dp
                                )
                                Column {
                                    Text(
                                        text = fileName,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = TextPrimary,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.widthIn(max = 200.dp)
                                    )
                                    Text(
                                        text = when {
                                            isPaused -> "Paused"
                                            isDownloading -> "Downloading..."
                                            else -> "Uploading..."
                                        },
                                        fontSize = 11.sp,
                                        color = if (isPaused) Color.Yellow else TextSecondary
                                    )
                                }
                            }
                            
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                if (!isDownloading) {
                                    IconButton(
                                        onClick = {
                                            if (isPaused) {
                                                viewModel.resumeUpload()
                                            } else {
                                                viewModel.pauseUpload()
                                            }
                                        },
                                        modifier = Modifier
                                            .size(32.dp)
                                            .background(Color.White.copy(alpha = 0.06f), CircleShape)
                                    ) {
                                        Icon(
                                            imageVector = if (isPaused) Icons.Default.PlayArrow else Icons.Default.Pause,
                                            contentDescription = if (isPaused) "Resume" else "Pause",
                                            tint = if (isPaused) Color.Green else TextPrimary,
                                            modifier = Modifier.size(16.dp)
                                        )
                                    }
                                }
                                
                                IconButton(
                                    onClick = {
                                        if (isDownloading) {
                                            viewModel.cancelDownload()
                                        } else {
                                            viewModel.cancelUpload()
                                        }
                                    },
                                    modifier = Modifier
                                        .size(32.dp)
                                        .background(Color.Red.copy(alpha = 0.1f), CircleShape)
                                ) {
                                    Icon(
                                        imageVector = Icons.Default.Close,
                                        contentDescription = "Cancel",
                                        tint = Color.Red,
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                        }
                        
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            LinearProgressIndicator(
                                progress = { progress },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(6.dp)
                                    .clip(RoundedCornerShape(3.dp)),
                                color = if (isPaused) Color.Yellow else LinkOSCyan,
                                trackColor = Color.White.copy(alpha = 0.05f)
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween
                            ) {
                                Text(
                                    text = "${(progress * 100).toInt()}%",
                                    fontSize = 11.sp,
                                    color = TextSecondary,
                                    fontWeight = FontWeight.SemiBold
                                )
                                Text(
                                    text = "WiFi Link",
                                    fontSize = 11.sp,
                                    color = TextTertiary
                                )
                            }
                        }
                    }
                }
            }

            // 3. Lazy Column listing
            if (errorState == "permission_denied") {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                        .padding(24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(
                            imageVector = Icons.Default.Lock,
                            contentDescription = null,
                            tint = Color(0xFFEF4444),
                            modifier = Modifier.size(64.dp)
                        )
                        Text(
                            text = "Access Denied",
                            style = MaterialTheme.typography.titleMedium,
                            color = Color.White,
                            fontWeight = FontWeight.Bold
                        )
                        Text(
                            text = "Please grant Full Disk Access to LinkOS on your Mac under System Settings -> Privacy & Security -> Full Disk Access to browse this folder.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = TextSecondary,
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center
                        )
                        Button(
                            onClick = {
                                viewModel.loadDirectory(currentPath)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = LinkOSBlue)
                        ) {
                            Text("Retry", color = Color.White)
                        }
                    }
                }
            } else if (filteredFiles.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(Icons.Default.FolderOpen, contentDescription = null, tint = TextTertiary, modifier = Modifier.size(48.dp))
                        Text("No matching files found", style = MaterialTheme.typography.bodyMedium, color = TextTertiary)
                    }
                }
            } else {
                if (viewMode == FileViewMode.LIST) {
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .padding(horizontal = 16.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(count = filteredFiles.size, key = { index -> filteredFiles[index].id }) { index ->
                            val item = filteredFiles[index]
                            var isMenuExpanded by remember { mutableStateOf(false) }

                            val ext = item.mimeType.lowercase()
                            val isThumbnailCapable = !item.isDirectory && ext in listOf("png", "jpg", "jpeg", "gif", "webp", "mp4", "mov", "mkv")
                            if (isThumbnailCapable) {
                                DisposableEffect(item.path) {
                                    viewModel.fetchThumbnail(item.path)
                                    onDispose {
                                        viewModel.cancelFetchThumbnail(item.path)
                                    }
                                }
                            }

                            Box {
                                FileRowItem(
                                    item = item,
                                    thumbnailBitmap = thumbnails[item.path],
                                    onClick = {
                                        HapticUtils.lightTap(context)
                                        if (item.isDirectory) {
                                            viewModel.loadDirectory(item.path)
                                        } else {
                                            isMenuExpanded = true
                                        }
                                    }
                                )

                                    // Touch Dropdown Menu Context Options
                                    DropdownMenu(
                                        expanded = isMenuExpanded,
                                        onDismissRequest = { isMenuExpanded = false },
                                        modifier = Modifier.background(DarkSurfaceElevated)
                                    ) {
                                        DropdownMenuItem(
                                            text = { Text("Rename", color = TextPrimary) },
                                            onClick = {
                                                isMenuExpanded = false
                                                activeItemForRename = item
                                                renameNewName = item.name
                                            },
                                            leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null, tint = LinkOSCyan) }
                                        )
                                        DropdownMenuItem(
                                            text = { Text("Delete", color = Color.Red) },
                                            onClick = {
                                                isMenuExpanded = false
                                                HapticUtils.lightTap(context)
                                                viewModel.performFileOperation("delete", item.path)
                                                Toast.makeText(context, "Deleting ${item.name}...", Toast.LENGTH_SHORT).show()
                                            },
                                            leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null, tint = Color.Red) }
                                        )
                                         if (!item.isDirectory) {
                                             DropdownMenuItem(
                                                 text = { Text("Download", color = TextPrimary) },
                                                 onClick = {
                                                     isMenuExpanded = false
                                                     HapticUtils.lightTap(context)
                                                     viewModel.downloadFile(item.path)
                                                     Toast.makeText(context, "Downloading ${item.name}...", Toast.LENGTH_SHORT).show()
                                                 },
                                                 leadingIcon = { Icon(Icons.Default.Download, contentDescription = null, tint = LinkOSPurple) }
                                             )
                                         }
                                    }
                            }
                        }
                    }
                } else {
                    LazyVerticalGrid(
                        columns = GridCells.Fixed(3),
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f)
                            .padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        items(count = filteredFiles.size, key = { index -> filteredFiles[index].id }) { index ->
                            val item = filteredFiles[index]
                            var isMenuExpanded by remember { mutableStateOf(false) }

                            val ext = item.mimeType.lowercase()
                            val isThumbnailCapable = !item.isDirectory && ext in listOf("png", "jpg", "jpeg", "gif", "webp", "mp4", "mov", "mkv")
                            if (isThumbnailCapable) {
                                DisposableEffect(item.path) {
                                    viewModel.fetchThumbnail(item.path)
                                    onDispose {
                                        viewModel.cancelFetchThumbnail(item.path)
                                    }
                                }
                            }

                            Box {
                                FileGridItem(
                                    item = item,
                                    thumbnailBitmap = thumbnails[item.path],
                                    onClick = {
                                        HapticUtils.lightTap(context)
                                        if (item.isDirectory) {
                                            viewModel.loadDirectory(item.path)
                                        } else {
                                            isMenuExpanded = true
                                        }
                                    }
                                )

                                    // Touch Dropdown Menu Context Options
                                    DropdownMenu(
                                        expanded = isMenuExpanded,
                                        onDismissRequest = { isMenuExpanded = false },
                                        modifier = Modifier.background(DarkSurfaceElevated)
                                    ) {
                                        DropdownMenuItem(
                                            text = { Text("Rename", color = TextPrimary) },
                                            onClick = {
                                                isMenuExpanded = false
                                                activeItemForRename = item
                                                renameNewName = item.name
                                            },
                                            leadingIcon = { Icon(Icons.Default.Edit, contentDescription = null, tint = LinkOSCyan) }
                                        )
                                        DropdownMenuItem(
                                            text = { Text("Delete", color = Color.Red) },
                                            onClick = {
                                                isMenuExpanded = false
                                                HapticUtils.lightTap(context)
                                                viewModel.performFileOperation("delete", item.path)
                                                Toast.makeText(context, "Deleting ${item.name}...", Toast.LENGTH_SHORT).show()
                                            },
                                            leadingIcon = { Icon(Icons.Default.Delete, contentDescription = null, tint = Color.Red) }
                                        )
                                         if (!item.isDirectory) {
                                             DropdownMenuItem(
                                                 text = { Text("Download", color = TextPrimary) },
                                                 onClick = {
                                                     isMenuExpanded = false
                                                     HapticUtils.lightTap(context)
                                                     viewModel.downloadFile(item.path)
                                                     Toast.makeText(context, "Downloading ${item.name}...", Toast.LENGTH_SHORT).show()
                                                 },
                                                 leadingIcon = { Icon(Icons.Default.Download, contentDescription = null, tint = LinkOSPurple) }
                                             )
                                         }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Rename Dialog
        activeItemForRename?.let { item ->
            AlertDialog(
                onDismissRequest = { activeItemForRename = null },
                title = { Text("Rename File/Folder", color = TextPrimary) },
                text = {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("Enter new name for:", color = TextSecondary, fontSize = 12.sp)
                        Text(item.name, color = TextPrimary, fontWeight = FontWeight.Bold)
                        OutlinedTextField(
                            value = renameNewName,
                            onValueChange = { renameNewName = it },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = LinkOSBlue,
                                unfocusedBorderColor = DarkSurfaceHighest
                            )
                        )
                    }
                },
                confirmButton = {
                    TextButton(onClick = {
                        val parent = item.path.substringBeforeLast('/', "")
                        val newPath = if (parent.isNotEmpty()) "$parent/$renameNewName" else "/$renameNewName"
                        viewModel.performFileOperation("rename", item.path, newPath)
                        activeItemForRename = null
                        HapticUtils.lightTap(context)
                    }) {
                        Text("Rename", color = LinkOSBlue)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { activeItemForRename = null }) {
                        Text("Cancel", color = TextSecondary)
                    }
                },
                containerColor = DarkSurfaceElevated
            )
        }
    }

@Composable
private fun FileRowItem(
    item: FileItem,
    thumbnailBitmap: androidx.compose.ui.graphics.ImageBitmap?,
    onClick: () -> Unit
) {
    GlassCard(
        modifier = Modifier
            .fillMaxWidth()
            .pressScale(onClick = onClick),
        cornerRadius = 14.dp,
        padding = 12.dp,
        glowColor = if (item.isDirectory) LinkOSBlue else GlassBorder
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            val icon: ImageVector = if (item.isDirectory) Icons.Default.Folder else getFileIcon(item.mimeType)
            val (badgeGradient, iconTint) = if (item.isDirectory) {
                GradientNavigation to Color.White
            } else {
                listOf(DarkSurfaceElevated, DarkSurfaceHighest) to LinkOSPurple
            }

            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Brush.linearGradient(badgeGradient)),
                contentAlignment = Alignment.Center
            ) {
                if (thumbnailBitmap != null) {
                    Image(
                        bitmap = thumbnailBitmap,
                        contentDescription = "Thumbnail",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop
                    )
                } else {
                    Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(20.dp))
                }
            }

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = item.name,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                val sizeText = if (item.isDirectory) "Directory" else "%.1f KB".format(item.sizeBytes / 1024.0)
                val dateText = formatModificationDate(item.modificationDateMs)
                Text(
                    text = "$sizeText • $dateText",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextTertiary,
                    fontSize = 11.sp
                )
            }

            if (item.isDirectory) {
                Icon(Icons.Default.ChevronRight, contentDescription = null, tint = TextTertiary, modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
private fun FileGridItem(
    item: FileItem,
    thumbnailBitmap: androidx.compose.ui.graphics.ImageBitmap?,
    onClick: () -> Unit
) {
    GlassCard(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .pressScale(onClick = onClick),
        cornerRadius = 14.dp,
        padding = 8.dp,
        glowColor = if (item.isDirectory) LinkOSBlue else GlassBorder
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(
                        if (item.isDirectory) {
                            Brush.linearGradient(GradientNavigation)
                        } else {
                            Brush.linearGradient(listOf(DarkSurfaceElevated, DarkSurfaceHighest))
                        }
                    ),
                contentAlignment = Alignment.Center
            ) {
                if (thumbnailBitmap != null) {
                    Image(
                        bitmap = thumbnailBitmap,
                        contentDescription = "Thumbnail",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Crop
                    )
                } else {
                    val icon = if (item.isDirectory) Icons.Default.Folder else getFileIcon(item.mimeType)
                    val iconTint = if (item.isDirectory) Color.White else LinkOSPurple
                    Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(36.dp))
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = item.name,
                color = TextPrimary,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 4.dp)
            )
        }
    }
}

private fun getFileIcon(ext: String): ImageVector {
    return when (ext.lowercase()) {
        "png", "jpg", "jpeg", "gif", "webp", "heic" -> Icons.Default.Image
        "mp4", "mov", "mkv", "avi" -> Icons.Default.Movie
        "mp3", "wav", "flac", "m4a" -> Icons.Default.MusicNote
        "pdf", "txt", "doc", "docx", "rtf", "md" -> Icons.Default.Description
        "swift", "kt", "js", "py", "json", "html", "css" -> Icons.Default.Code
        "zip", "rar", "7z", "tar", "gz" -> Icons.Default.FolderOpen
        "dmg", "pkg", "iso", "app" -> Icons.Default.Build
        else -> Icons.Default.InsertDriveFile
    }
}
