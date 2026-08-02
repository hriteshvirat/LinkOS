package com.linkos.features.ai

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Psychology
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AIAgentScreen(
    onNavigateBack: () -> Unit,
    onNavigateToProviderConfig: () -> Unit,
    onNavigateToCustomCommands: () -> Unit,
    viewModel: AIViewModel = hiltViewModel()
) {
    val chatMessages by viewModel.chatMessages.collectAsState()
    val selectedProvider by viewModel.selectedProvider.collectAsState()
    val context = LocalContext.current
    var promptInput by remember { mutableStateOf("") }
    var showProviderMenu by remember { mutableStateOf(false) }

    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val keyboardHeight = WindowInsets.ime.asPaddingValues().calculateBottomPadding()

    LaunchedEffect(chatMessages.size) {
        if (chatMessages.isNotEmpty()) {
            listState.animateScrollToItem(chatMessages.size - 1)
        }
    }

    LaunchedEffect(keyboardHeight) {
        if (chatMessages.isNotEmpty()) {
            listState.animateScrollToItem(chatMessages.size - 1)
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
                                    .background(Brush.linearGradient(GradientAdvanced)),
                                contentAlignment = Alignment.Center
                            ) {
                                Icon(
                                    Icons.Outlined.Psychology,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text("Mac AI Assistant", fontWeight = FontWeight.Bold, color = Color.White)
                                Text(selectedProvider, style = MaterialTheme.typography.bodySmall, color = LinkOSPink, fontSize = 11.sp)
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
                            HapticUtils.lightTap(context)
                            showProviderMenu = true
                        }) {
                            Icon(Icons.Default.Settings, contentDescription = "AI Settings", tint = TextSecondary)
                        }
                        DropdownMenu(
                            expanded = showProviderMenu,
                            onDismissRequest = { showProviderMenu = false }
                        ) {
                            Text(
                                "Model",
                                style = MaterialTheme.typography.labelSmall,
                                color = TextTertiary,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
                            )
                            DropdownMenuItem(
                                text = { Text("Local (CoreML / Apple Silicon)", style = MaterialTheme.typography.bodyMedium) },
                                onClick = {
                                    HapticUtils.lightTap(context)
                                    viewModel.setProvider("Local (CoreML / Apple Silicon)")
                                    showProviderMenu = false
                                }
                            )
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text("AI Models...", style = MaterialTheme.typography.bodyMedium)
                                        Spacer(Modifier.width(8.dp))
                                        Icon(Icons.Default.ChevronRight, contentDescription = null, modifier = Modifier.size(16.dp))
                                    }
                                },
                                onClick = {
                                    HapticUtils.lightTap(context)
                                    showProviderMenu = false
                                    onNavigateToProviderConfig()
                                }
                            )
                            HorizontalDivider(color = DarkBorder, modifier = Modifier.padding(vertical = 4.dp))
                            DropdownMenuItem(
                                text = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text("Custom Commands...", style = MaterialTheme.typography.bodyMedium)
                                        Spacer(Modifier.width(8.dp))
                                        Icon(Icons.Default.Build, contentDescription = null, modifier = Modifier.size(16.dp))
                                    }
                                },
                                onClick = {
                                    HapticUtils.lightTap(context)
                                    showProviderMenu = false
                                    onNavigateToCustomCommands()
                                }
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .imePadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            // Chat Messages List
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                verticalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                itemsIndexed(chatMessages, key = { _, msg -> msg.id }) { index, msg ->
                    StaggeredAnimatedVisibility(visible = true, index = index) {
                        ChatMessageBubble(msg = msg)
                    }
                }
            }

            // Quick Actions Bar
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                QuickActionChip("Launch Cursor", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendPrompt("Launch Cursor")
                }
                QuickActionChip("Screenshot", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendPrompt("Take Screenshot")
                }
                QuickActionChip("System Health", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendPrompt("Check Mac health")
                }
            }

            // Prompt Input Line
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = promptInput,
                    onValueChange = { promptInput = it },
                    placeholder = { Text("Ask Mac AI assistant...", color = TextTertiary, fontSize = 13.sp) },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = LinkOSPink,
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
                        if (promptInput.isNotBlank()) {
                            HapticUtils.lightTap(context)
                            viewModel.sendPrompt(promptInput)
                            promptInput = ""
                        }
                    },
                    modifier = Modifier
                        .size(48.dp)
                        .pressScale(onClick = {}),
                    colors = IconButtonDefaults.iconButtonColors(containerColor = LinkOSPink)
                ) {
                    Icon(Icons.Default.Send, contentDescription = "Send", tint = Color.White, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
private fun ChatMessageBubble(msg: ChatMessage) {
    val isUser = msg.sender == "You"
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
    ) {
        GlassCard(
            modifier = Modifier.widthIn(max = 290.dp),
            cornerRadius = 14.dp,
            padding = 12.dp,
            glowColor = if (isUser) LinkOSBlue else LinkOSPink,
            enableGlow = !isUser
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    text = msg.sender,
                    style = MaterialTheme.typography.labelSmall,
                    color = if (isUser) LinkOSBlue else LinkOSPink,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    text = msg.text,
                    style = MaterialTheme.typography.bodyMedium,
                    color = TextPrimary,
                    lineHeight = 20.sp
                )
            }
        }
    }
}

@Composable
private fun QuickActionChip(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier.height(32.dp),
        contentPadding = PaddingValues(horizontal = 4.dp, vertical = 2.dp),
        shape = RoundedCornerShape(8.dp),
        colors = ButtonDefaults.filledTonalButtonColors(
            containerColor = DarkSurfaceElevated,
            contentColor = TextSecondary
        )
    ) {
        Text(label, style = MaterialTheme.typography.labelSmall, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
    }
}
