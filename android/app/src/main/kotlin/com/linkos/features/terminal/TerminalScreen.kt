package com.linkos.features.terminal

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalScreen(
    onNavigateBack: () -> Unit,
    viewModel: TerminalViewModel = hiltViewModel()
) {
    val terminalOutput by viewModel.terminalOutput.collectAsState()
    var commandInput by remember { mutableStateOf("") }
    val scrollState = rememberScrollState()
    val context = LocalContext.current

    LaunchedEffect(terminalOutput) {
        scrollState.animateScrollTo(scrollState.maxValue)
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
                                    Icons.Outlined.Terminal,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Text("Mac Shell Terminal", fontWeight = FontWeight.Bold, color = Color.White)
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
                            viewModel.clearTerminal()
                        }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear Screen", tint = TextSecondary)
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
            // Terminal Output Surface
            GlassCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                cornerRadius = 16.dp,
                glowColor = LinkOSGreen,
                padding = 0.dp
            ) {
                SelectionContainer {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color(0xFF090B10))
                            .padding(14.dp)
                    ) {
                        Text(
                            text = terminalOutput,
                            color = Color(0xFF4ADE80), // Retro green terminal
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                            lineHeight = 18.sp,
                            modifier = Modifier.verticalScroll(scrollState)
                        )
                    }
                }
            }

            // Virtual Modifier Keys Toolbar
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                TerminalKeyButton("Ctrl+C", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendSignal(2)
                }
                TerminalKeyButton("Ctrl+D", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendInput("\u0004")
                }
                TerminalKeyButton("Ctrl+Z", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendSignal(20)
                }
                TerminalKeyButton("Tab", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendInput("\t")
                }
                TerminalKeyButton("Esc", modifier = Modifier.weight(1f)) {
                    HapticUtils.lightTap(context)
                    viewModel.sendInput("\u001b")
                }
            }

            // Command Prompt Input Line
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedTextField(
                    value = commandInput,
                    onValueChange = { commandInput = it },
                    placeholder = { Text("$ command...", fontFamily = FontFamily.Monospace, color = TextTertiary, fontSize = 13.sp) },
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                        fontFamily = FontFamily.Monospace,
                        color = TextPrimary
                    ),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = LinkOSGreen,
                        unfocusedBorderColor = DarkBorder,
                        focusedContainerColor = DarkSurface,
                        unfocusedContainerColor = DarkSurface
                    ),
                    shape = RoundedCornerShape(12.dp)
                )

                IconButton(
                    onClick = {
                        if (commandInput.isNotBlank()) {
                            HapticUtils.lightTap(context)
                            viewModel.sendInput(commandInput + "\n")
                            commandInput = ""
                        }
                    },
                    modifier = Modifier
                        .size(48.dp)
                        .pressScale(onClick = {}),
                    colors = IconButtonDefaults.iconButtonColors(containerColor = LinkOSGreen)
                ) {
                    Icon(Icons.Default.Send, contentDescription = "Execute", tint = Color.Black, modifier = Modifier.size(18.dp))
                }
            }
        }
    }
}

@Composable
private fun TerminalKeyButton(
    label: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier.height(34.dp),
        contentPadding = PaddingValues(horizontal = 2.dp, vertical = 2.dp),
        shape = RoundedCornerShape(8.dp),
        colors = ButtonDefaults.filledTonalButtonColors(
            containerColor = DarkSurfaceElevated,
            contentColor = TextSecondary
        )
    ) {
        Text(label, fontSize = 11.sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
    }
}
