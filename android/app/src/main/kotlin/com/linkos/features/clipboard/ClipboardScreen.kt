package com.linkos.features.clipboard

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ClipboardScreen(
    onNavigateBack: () -> Unit,
    viewModel: ClipboardViewModel = hiltViewModel()
) {
    val history by viewModel.history.collectAsState()
    val localClipboardManager = LocalClipboardManager.current
    val context = LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    val coroutineScope = rememberCoroutineScope()
    var searchQuery by remember { mutableStateOf("") }
    var inputText by remember { mutableStateOf("") }

    val filteredHistory = remember(history, searchQuery) {
        history.filter {
            searchQuery.isEmpty() || (it.fullText ?: it.previewText).contains(searchQuery, ignoreCase = true)
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
                                    Icons.Outlined.ContentPaste,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Text("Universal Clipboard", fontWeight = FontWeight.Bold, color = Color.White)
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = onNavigateBack) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
                        }
                    },
                    actions = {
                        if (history.any { !it.isPinned }) {
                            IconButton(onClick = {
                                HapticUtils.mediumTap(context)
                                viewModel.clearAllUnpinned()
                                coroutineScope.launch {
                                    snackbarHostState.showSnackbar("Cleared unpinned history")
                                }
                            }) {
                                Icon(Icons.Default.DeleteSweep, contentDescription = "Clear unpinned", tint = TextSecondary)
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkSurface)
                )
                HorizontalDivider(color = DarkBorder, thickness = 1.dp)
            }
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        containerColor = DarkBackground
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            // Quick Type Text to sync manually
            GlassCard(
                modifier = Modifier.fillMaxWidth(),
                glowColor = LinkOSCyan,
                cornerRadius = 16.dp
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    OutlinedTextField(
                        value = inputText,
                        onValueChange = { inputText = it },
                        placeholder = { Text("Type text to sync to Mac clipboard...", color = TextTertiary, fontSize = 13.sp) },
                        modifier = Modifier.weight(1f),
                        singleLine = false,
                        maxLines = 2,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = LinkOSCyan,
                            unfocusedBorderColor = DarkBorder,
                            focusedContainerColor = DarkSurface,
                            unfocusedContainerColor = DarkSurface,
                            focusedTextColor = TextPrimary,
                            unfocusedTextColor = TextPrimary
                        ),
                        shape = RoundedCornerShape(12.dp)
                    )
                    IconButton(
                        onClick = {
                            if (inputText.isNotBlank()) {
                                HapticUtils.lightTap(context)
                                viewModel.sendToMac(inputText)
                                viewModel.addClipboardItem(inputText)
                                inputText = ""
                                coroutineScope.launch {
                                    snackbarHostState.showSnackbar("Synced to Mac clipboard")
                                }
                            }
                        },
                        modifier = Modifier
                            .size(44.dp)
                            .pressScale(onClick = {}),
                        colors = IconButtonDefaults.iconButtonColors(containerColor = LinkOSCyan)
                    ) {
                        Icon(Icons.Default.Send, contentDescription = "Copy to Mac", tint = Color.White, modifier = Modifier.size(18.dp))
                    }
                }
            }

            // Search Bar
            OutlinedTextField(
                value = searchQuery,
                onValueChange = { searchQuery = it },
                placeholder = { Text("Search clipboard history...", color = TextTertiary, fontSize = 13.sp) },
                modifier = Modifier.fillMaxWidth(),
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = TextSecondary, modifier = Modifier.size(18.dp)) },
                trailingIcon = {
                    if (searchQuery.isNotEmpty()) {
                        IconButton(onClick = { searchQuery = "" }) {
                            Icon(Icons.Default.Close, contentDescription = "Clear", tint = TextSecondary)
                        }
                    }
                },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = LinkOSCyan,
                    unfocusedBorderColor = DarkBorder,
                    focusedContainerColor = DarkSurface,
                    unfocusedContainerColor = DarkSurface,
                    focusedTextColor = TextPrimary,
                    unfocusedTextColor = TextPrimary
                ),
                shape = RoundedCornerShape(12.dp)
            )

            // Current Clipboard Card
            if (filteredHistory.isNotEmpty() && searchQuery.isEmpty()) {
                Text(
                    text = "CURRENT CLIPBOARD",
                    style = MaterialTheme.typography.labelSmall,
                    color = TextTertiary,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.5.sp,
                    modifier = Modifier.padding(start = 4.dp)
                )
                val currentItem = filteredHistory.first()
                val currentText = currentItem.fullText ?: currentItem.previewText
                ClipboardItemCard(
                    item = currentItem,
                    isCurrent = true,
                    onCopyLocal = {
                        HapticUtils.lightTap(context)
                        localClipboardManager.setText(AnnotatedString(currentText))
                        coroutineScope.launch {
                            snackbarHostState.showSnackbar("Copied again")
                        }
                    },
                    onSendToDevice = {
                        HapticUtils.lightTap(context)
                        viewModel.sendToMac(currentText)
                        coroutineScope.launch {
                            snackbarHostState.showSnackbar("Resent to Mac")
                        }
                    },
                    onTogglePin = {
                        HapticUtils.lightTap(context)
                        viewModel.togglePin(currentItem.id)
                    },
                    onDelete = {
                        HapticUtils.lightTap(context)
                        viewModel.deleteItem(currentItem.id)
                    }
                )
            }

            Text(
                text = "CLIPBOARD HISTORY",
                style = MaterialTheme.typography.labelSmall,
                color = TextTertiary,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.5.sp,
                modifier = Modifier.padding(start = 4.dp)
            )

            val remainingHistory = if (searchQuery.isEmpty() && filteredHistory.isNotEmpty()) {
                filteredHistory.drop(1)
            } else {
                filteredHistory
            }

            if (remainingHistory.isEmpty()) {
                GlassCard(
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    cornerRadius = 16.dp
                ) {
                    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            Icon(Icons.Outlined.ContentPaste, contentDescription = null, tint = TextTertiary, modifier = Modifier.size(44.dp))
                            Text("No history matching search", style = MaterialTheme.typography.titleMedium, color = TextSecondary, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    itemsIndexed(remainingHistory, key = { _, item -> item.id }) { index, item ->
                        val itemText = item.fullText ?: item.previewText
                        StaggeredAnimatedVisibility(visible = true, index = index) {
                            ClipboardItemCard(
                                item = item,
                                isCurrent = false,
                                onCopyLocal = {
                                    HapticUtils.lightTap(context)
                                    localClipboardManager.setText(AnnotatedString(itemText))
                                    coroutineScope.launch {
                                        snackbarHostState.showSnackbar("Copied to device clipboard")
                                    }
                                },
                                onSendToDevice = {
                                    HapticUtils.lightTap(context)
                                    viewModel.sendToMac(itemText)
                                    coroutineScope.launch {
                                        snackbarHostState.showSnackbar("Sent to Mac")
                                    }
                                },
                                onTogglePin = {
                                    HapticUtils.lightTap(context)
                                    viewModel.togglePin(item.id)
                                },
                                onDelete = {
                                    HapticUtils.lightTap(context)
                                    viewModel.deleteItem(item.id)
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
private fun ClipboardItemCard(
    item: ClipboardHistoryItem,
    isCurrent: Boolean,
    onCopyLocal: () -> Unit,
    onSendToDevice: () -> Unit,
    onTogglePin: () -> Unit,
    onDelete: () -> Unit
) {
    val cardGlow = if (isCurrent) LinkOSCyan else if (item.isPinned) LinkOSOrange else GlassBorder
    val labelText = if (item.sourceApp?.lowercase()?.contains("mac") == true) "From Mac" else "From Phone"

    GlassCard(
        modifier = Modifier.fillMaxWidth(),
        cornerRadius = 14.dp,
        padding = 12.dp,
        glowColor = cardGlow,
        enableGlow = isCurrent || item.isPinned
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = labelText.uppercase(),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (isCurrent) LinkOSCyan else TextTertiary
                )
                Text(
                    text = java.text.SimpleDateFormat("hh:mm a", java.util.Locale.getDefault()).format(java.util.Date(item.timestamp)),
                    fontSize = 10.sp,
                    color = TextTertiary
                )
            }

            Text(
                text = item.fullText ?: item.previewText,
                style = MaterialTheme.typography.bodyMedium,
                color = TextPrimary,
                maxLines = 4,
                overflow = TextOverflow.Ellipsis,
                lineHeight = 20.sp
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                IconButton(onClick = onTogglePin, modifier = Modifier.size(32.dp)) {
                    Icon(
                        imageVector = if (item.isPinned) Icons.Default.PushPin else Icons.Outlined.PushPin,
                        contentDescription = "Pin",
                        tint = if (item.isPinned) LinkOSOrange else TextTertiary,
                        modifier = Modifier.size(16.dp)
                    )
                }

                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FilledTonalIconButton(
                        onClick = onCopyLocal,
                        modifier = Modifier.size(32.dp),
                        shape = RoundedCornerShape(8.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = DarkSurfaceElevated,
                            contentColor = TextSecondary
                        )
                    ) {
                        Icon(Icons.Default.ContentCopy, contentDescription = "Copy Again", modifier = Modifier.size(15.dp))
                    }
                    FilledTonalIconButton(
                        onClick = onSendToDevice,
                        modifier = Modifier.size(32.dp),
                        shape = RoundedCornerShape(8.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = LinkOSBlue.copy(alpha = 0.15f),
                            contentColor = LinkOSBlue
                        )
                    ) {
                        Icon(Icons.Default.Send, contentDescription = "Copy to Mac", modifier = Modifier.size(15.dp))
                    }
                    FilledTonalIconButton(
                        onClick = onDelete,
                        modifier = Modifier.size(32.dp),
                        shape = RoundedCornerShape(8.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(
                            containerColor = LinkOSRed.copy(alpha = 0.12f),
                            contentColor = LinkOSRed
                        )
                    ) {
                        Icon(Icons.Default.Delete, contentDescription = "Delete", modifier = Modifier.size(15.dp))
                    }
                }
            }
        }
    }
}
