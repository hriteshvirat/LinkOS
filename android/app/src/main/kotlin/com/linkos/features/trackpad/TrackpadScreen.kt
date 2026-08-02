package com.linkos.features.trackpad

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.GlassCard
import com.linkos.ui.components.HapticFeedback
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*

import com.linkos.ui.components.FileDragDropTarget
import com.linkos.features.files.FileBrowserViewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrackpadScreen(
    onNavigateBack: () -> Unit,
    viewModel: TrackpadViewModel = hiltViewModel(),
    fileBrowserViewModel: FileBrowserViewModel = hiltViewModel()
) {
    val context = LocalContext.current
    val configuration = androidx.compose.ui.platform.LocalConfiguration.current
    val isLandscape = configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val coroutineScope = rememberCoroutineScope()
    val uploadProgress by fileBrowserViewModel.uploadProgress.collectAsState()
    val uploadFileName by fileBrowserViewModel.uploadFileName.collectAsState()
    
    var lastGesture by remember { mutableStateOf("Ready") }
    var isTouching by remember { mutableStateOf(false) }
    var touchPositions by remember { mutableStateOf<List<Offset>>(emptyList()) }
    var isKeyboardOpen by remember { mutableStateOf(false) }
    var isToolbarExpanded by remember { mutableStateOf(false) }
    var keyboardInputText by remember { mutableStateOf("") }
    val keyboardFocusRequester = remember { FocusRequester() }

    LaunchedEffect(isKeyboardOpen) {
        if (isKeyboardOpen) {
            keyboardFocusRequester.requestFocus()
        }
    }

    Scaffold(
        topBar = {
            if (!isLandscape) {
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
                                    Icons.Default.TouchApp,
                                    contentDescription = null,
                                    tint = Color.White,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(Modifier.width(10.dp))
                            Text("Magic Trackpad", fontWeight = FontWeight.Bold, color = Color.White)
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = onNavigateBack) {
                            Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextSecondary)
                        }
                    },
                    actions = {
                        // Expand/Collapse Utility Toolbar Toggle
                        IconButton(onClick = {
                            isToolbarExpanded = !isToolbarExpanded
                            HapticFeedback.leftClick(context)
                        }) {
                            Icon(
                                if (isToolbarExpanded) Icons.Default.ExpandLess else Icons.Default.Build,
                                contentDescription = "Toggle Utility Controls",
                                tint = if (isToolbarExpanded) LinkOSBlue else TextSecondary
                            )
                        }
                        
                        // Toggle Keyboard
                        IconButton(onClick = {
                            isKeyboardOpen = !isKeyboardOpen
                            HapticFeedback.leftClick(context)
                        }) {
                            Icon(
                                Icons.Default.Keyboard,
                                contentDescription = "Toggle Keyboard",
                                tint = if (isKeyboardOpen) LinkOSBlue else TextSecondary
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkBackground)
                )
            }
        },
        containerColor = DarkBackground
    ) { paddingValues ->
        FileDragDropTarget(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues),
            onFilesDropped = { uris ->
                uris.forEach { fileBrowserViewModel.uploadFile(it, context) }
            }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(
                        horizontal = if (isLandscape) 0.dp else 14.dp,
                        vertical = if (isLandscape) 0.dp else 8.dp
                    ),
                verticalArrangement = Arrangement.spacedBy(if (isLandscape) 0.dp else 8.dp)
            ) {
                // Upload progress card
                if (uploadProgress != null && uploadFileName != null) {
                    Card(
                        modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
                        colors = CardDefaults.cardColors(containerColor = DarkSurfaceElevated)
                    ) {
                        Row(
                            modifier = Modifier.padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            CircularProgressIndicator(
                                progress = { uploadProgress!! },
                                color = LinkOSPurple,
                                modifier = Modifier.size(20.dp)
                            )
                            Spacer(Modifier.width(12.dp))
                            Text(
                                text = "Syncing: $uploadFileName (${(uploadProgress!! * 100).toInt()}%)",
                                color = TextPrimary,
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.weight(1f)
                            )
                            IconButton(
                                onClick = { fileBrowserViewModel.cancelUpload() },
                                modifier = Modifier.size(24.dp)
                            ) {
                                Icon(Icons.Default.Close, contentDescription = "Cancel", tint = TextSecondary, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            // Hidden TextField for Soft Keyboard capture
            if (isKeyboardOpen) {
                OutlinedTextField(
                    value = keyboardInputText,
                    onValueChange = { newText ->
                        if (newText.length > keyboardInputText.length) {
                            val addedChar = newText.substring(keyboardInputText.length)
                            viewModel.sendText(addedChar)
                        } else if (newText.length < keyboardInputText.length) {
                            viewModel.sendSpecialKey("backspace")
                        }
                        keyboardInputText = newText
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .alpha(0.01f)
                        .focusRequester(keyboardFocusRequester),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text)
                )

                // Virtual Quick Key Toolbar
                if (!isLandscape) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(6.dp)
                    ) {
                        QuickKeyButton(label = "Esc", modifier = Modifier.weight(1f)) {
                            viewModel.sendSpecialKey("escape")
                        }
                        QuickKeyButton(label = "Tab", modifier = Modifier.weight(1f)) {
                            viewModel.sendSpecialKey("tab")
                        }
                        QuickKeyButton(label = "Space", modifier = Modifier.weight(1f)) {
                            viewModel.sendSpecialKey("space")
                        }
                        QuickKeyButton(label = "⌫", modifier = Modifier.weight(1f)) {
                            viewModel.sendSpecialKey("backspace")
                        }
                        QuickKeyButton(label = "↵ Enter", modifier = Modifier.weight(1f)) {
                            viewModel.sendSpecialKey("enter")
                        }
                    }
                }
            }

            // PERMANENT Left Click & Right Click Buttons (Directly below Top App Bar)
            if (!isLandscape) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = {
                            HapticFeedback.leftClick(context)
                            viewModel.sendClick("left")
                            lastGesture = "Left Click Button"
                        },
                        modifier = Modifier
                            .weight(1f)
                            .height(42.dp),
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1E2330))
                    ) {
                        Icon(Icons.Default.Mouse, contentDescription = null, tint = LinkOSBlue, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Left Click", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                    }
                    Button(
                        onClick = {
                            HapticFeedback.rightClick(context)
                            viewModel.sendClick("right")
                            lastGesture = "Right Click Button"
                        },
                        modifier = Modifier
                            .weight(1f)
                            .height(42.dp),
                        shape = RoundedCornerShape(8.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1E2330))
                    ) {
                        Icon(Icons.Default.MoreVert, contentDescription = null, tint = LinkOSCyan, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Right Click", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
                    }
                }
            }

            // Collapsible Utility Toolbar (Modifiers, Media, Shortcuts)
            AnimatedVisibility(visible = isToolbarExpanded && !isLandscape) {
                GlassCard(
                    modifier = Modifier.fillMaxWidth(),
                    cornerRadius = 14.dp,
                    padding = 12.dp
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        // Modifiers Row
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                        ) {
                            QuickKeyButton(label = "⇧ Shift", modifier = Modifier.weight(1f)) {
                                viewModel.sendSpecialKey("shift")
                                HapticUtils.lightTap(context)
                            }
                            QuickKeyButton(label = "⌘ Cmd", modifier = Modifier.weight(1f)) {
                                viewModel.sendSpecialKey("command")
                                HapticUtils.lightTap(context)
                            }
                            QuickKeyButton(label = "⌥ Option", modifier = Modifier.weight(1f)) {
                                viewModel.sendSpecialKey("option")
                                HapticUtils.lightTap(context)
                            }
                            QuickKeyButton(label = "⌃ Control", modifier = Modifier.weight(1f)) {
                                viewModel.sendSpecialKey("control")
                                HapticUtils.lightTap(context)
                            }
                        }

                        // System Shortcuts Row
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            ActionButton(
                                modifier = Modifier.weight(1f),
                                label = "Mission Control",
                                icon = Icons.Default.ViewCarousel,
                                accentColor = LinkOSPurple
                            ) {
                                HapticFeedback.missionControl(context)
                                viewModel.sendGesture("mission_control")
                                lastGesture = "Mission Control"
                            }
                            ActionButton(
                                modifier = Modifier.weight(1f),
                                label = "Launchpad",
                                icon = Icons.Default.GridView,
                                accentColor = LinkOSCyan
                            ) {
                                HapticFeedback.launchpad(context)
                                viewModel.sendLaunchpad()
                                lastGesture = "Launchpad"
                            }
                        }

                        // Media controls row
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            IconButton(onClick = { viewModel.sendMediaKey("brightness_down"); lastGesture = "Brightness -" }) {
                                Icon(Icons.Default.BrightnessLow, contentDescription = "Brightness Down", tint = TextSecondary)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("brightness_up"); lastGesture = "Brightness +" }) {
                                Icon(Icons.Default.BrightnessHigh, contentDescription = "Brightness Up", tint = TextSecondary)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("previous"); lastGesture = "Previous" }) {
                                Icon(Icons.Default.SkipPrevious, contentDescription = "Previous", tint = TextSecondary)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("play_pause"); lastGesture = "Play/Pause" }) {
                                Icon(Icons.Default.PlayArrow, contentDescription = "Play/Pause", tint = LinkOSBlue)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("next"); lastGesture = "Next" }) {
                                Icon(Icons.Default.SkipNext, contentDescription = "Next", tint = TextSecondary)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("mute"); lastGesture = "Mute" }) {
                                Icon(Icons.Default.VolumeOff, contentDescription = "Mute", tint = TextSecondary)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("vol_down"); lastGesture = "Vol -" }) {
                                Icon(Icons.Default.VolumeDown, contentDescription = "Volume Down", tint = TextSecondary)
                            }
                            IconButton(onClick = { viewModel.sendMediaKey("vol_up"); lastGesture = "Vol +" }) {
                                Icon(Icons.Default.VolumeUp, contentDescription = "Volume Up", tint = TextSecondary)
                            }
                        }
                    }
                }
            }

            // Status Bar
            if (!isLandscape) {
                GlassCard(
                    modifier = Modifier.fillMaxWidth(),
                    padding = 8.dp,
                    cornerRadius = 12.dp
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                modifier = Modifier
                                    .size(8.dp)
                                    .clip(CircleShape)
                                    .background(StatusConnected)
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = lastGesture,
                                style = MaterialTheme.typography.labelMedium,
                                color = TextSecondary,
                                fontWeight = FontWeight.Medium
                            )
                        }
                        Text(
                            text = "Touch Surface (Supports Multi-touch)",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextTertiary,
                            fontSize = 10.sp
                        )
                    }
                }
            }

            // Main Trackpad Area + Vertical Scroll Strip
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // Trackpad Surface with Low-latency Multi-touch Gesture Engine
                GlassCard(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .pointerInput(Unit) {
                            awaitPointerEventScope {
                                var pressTime = 0L
                                var maxPointers = 0
                                var isDragging = false
                                var isPinching = false
                                var initialPinchDistance = 0f
                                var threeFingerStartPos = Offset.Zero
                                var isThreeFingerDragging = false
                                var wasScrollingOrPinching = false
                                var gestureTriggered = false
                                var lastPressedCount = 0
                                var twoFingerHoldStartTime = 0L
                                var twoFingerHoldTriggered = false
                                var twoFingerInitialPos = Offset.Zero
                                var lastScrollTime = 0L
                                var singleFingerStartPos = Offset.Zero
                                var hasMovedSignificantDistance = false
                                var isScrolling = false
                                var lastTouchPos: Offset? = null
                                var lastFiveFingerPinchDistance = 0f
                                var isFiveFingerPinching = false
                                var fiveFingerHoldStartTime = 0L
                                var isFiveFingerReady = false
                                var fiveFingerInitialPos = Offset.Zero
                                var lastFiveFingerCount = 0
                                var subPixelDx = 0f
                                var subPixelDy = 0f
                                
                                while (true) {
                                    val event = awaitPointerEvent()
                                    val changes = event.changes
                                    val pressedCount = changes.filter { it.pressed }.size
                                    touchPositions = changes.filter { it.pressed }.map { it.position }
                                     
                                     if (pressedCount > 0) {
                                         if (!isTouching) {
                                             isTouching = true
                                         }
                                     }
                                     // Detect 3+ fingers on ANY event type — not just Press
                                     // This catches fingers arriving one-by-one or close together
                                     if (pressedCount >= 3) {
                                         if (lastGesture != "Multi-Finger Held" && !isFiveFingerPinching) {
                                             lastGesture = "Multi-Finger Held"
                                         }
                                         val activeChanges = changes.filter { it.pressed }
                                         val center = activeChanges.map { it.position }.reduce { acc, offset -> acc + offset } / activeChanges.size.toFloat()
                                         val currentDistance = activeChanges.map { (it.position - center).getDistance() }.sum()

                                         if (fiveFingerHoldStartTime == 0L) {
                                             // First detection — cancel other gestures and start timer
                                             isScrolling = false
                                             isDragging = false
                                             isPinching = false
                                             twoFingerHoldTriggered = false
                                             isFiveFingerReady = false
                                             isFiveFingerPinching = false
                                             fiveFingerHoldStartTime = System.currentTimeMillis()
                                             fiveFingerInitialPos = center
                                             lastFiveFingerPinchDistance = currentDistance
                                             lastTouchPos = center
                                         }

                                         // Check hold timer here — fires on EVERY event (Press, Move, Release)
                                         // so simultaneous placement (no Move events) is recognised instantly
                                         if (!isFiveFingerReady && fiveFingerHoldStartTime > 0L) {
                                             val holdDuration = System.currentTimeMillis() - fiveFingerHoldStartTime
                                              // 30ms for simultaneous placement, 80ms max for staggered
                                              val threshold = if (pressedCount >= 3 && event.type == PointerEventType.Press) 0L else 30L
                                             if (holdDuration >= threshold) {
                                                 isFiveFingerReady = true
                                                 isFiveFingerPinching = false
                                                 lastFiveFingerPinchDistance = currentDistance
                                                 lastFiveFingerCount = activeChanges.size
                                                 HapticFeedback.leftClick(context)
                                                 lastGesture = "Zoom Ready"
                                             }
                                         }
                                     }
                                    
                                    if (event.type == PointerEventType.Press) {
                                         if (pressedCount > maxPointers) {
                                             maxPointers = pressedCount
                                         }
                                          if (pressedCount == 1 && changes.any { it.previousPressed.not() }) {
                                              pressTime = System.currentTimeMillis()
                                              maxPointers = 1
                                              isDragging = false
                                              isPinching = false
                                              isScrolling = false
                                              wasScrollingOrPinching = false
                                              gestureTriggered = false
                                              twoFingerHoldStartTime = 0L
                                              twoFingerHoldTriggered = false
                                              isFiveFingerReady = false
                                              isFiveFingerPinching = false
                                              fiveFingerHoldStartTime = 0L
                                              singleFingerStartPos = changes.first().position
                                              hasMovedSignificantDistance = false
                                              lastTouchPos = changes.first().position
                                              subPixelDx = 0f
                                              subPixelDy = 0f
                                          } else if (pressedCount == 2) {
                                             val activeChanges = changes.filter { it.pressed }
                                             if (activeChanges.size == 2) {
                                                 val p1 = activeChanges[0].position
                                                 val p2 = activeChanges[1].position
                                                 initialPinchDistance = (p1 - p2).getDistance()
                                                 twoFingerHoldStartTime = System.currentTimeMillis()
                                                 twoFingerHoldTriggered = false
                                                 twoFingerInitialPos = (p1 + p2) / 2f
                                                 isScrolling = false
                                                 isPinching = false
                                                 lastTouchPos = (p1 + p2) / 2f
                                             }
                                          }
                                    }
                                    
                                    // Pointer count transition shield to prevent cursor jumping
                                    if (event.type == PointerEventType.Move) {
                                        if (isFiveFingerPinching || isFiveFingerReady) {
                                            if (pressedCount < 3) {
                                                isFiveFingerReady = false
                                                isFiveFingerPinching = false
                                                fiveFingerHoldStartTime = 0L
                                            }
                                        }
                                        if (pressedCount != lastPressedCount) {
                                            val wasMulti = lastPressedCount >= 3
                                            val isMulti = pressedCount >= 3
                                            lastPressedCount = pressedCount
                                            if (!(wasMulti && isMulti)) {
                                                continue
                                            }
                                        }
                                    }
                                    lastPressedCount = pressedCount
                                    
                                    if (event.type == PointerEventType.Move) {
                                        isDragging = true
                                        if (pressedCount > maxPointers) {
                                            maxPointers = pressedCount
                                        }
                                        if (pressedCount == 1) {
                                              if (maxPointers == 1) {
                                                  val change = changes.first { it.pressed }
                                                  val currentPos = change.position
                                                  val delta = currentPos - (lastTouchPos ?: currentPos)
                                                  lastTouchPos = currentPos
                                                  
                                                  val distance = (currentPos - singleFingerStartPos).getDistance()
                                                  if (!hasMovedSignificantDistance) {
                                                      if (distance > 0.5f) {
                                                          hasMovedSignificantDistance = true
                                                      }
                                                  }
                                                  
                                                  if (hasMovedSignificantDistance) {
                                                      subPixelDx += delta.x
                                                      subPixelDy += delta.y
                                                      val accumulatedLength = Math.sqrt((subPixelDx * subPixelDx + subPixelDy * subPixelDy).toDouble()).toFloat()
                                                      if (accumulatedLength > 0.05f) {
                                                          val scaleFactor = 0.7f / density
                                                          viewModel.sendMove(subPixelDx * scaleFactor, subPixelDy * scaleFactor)
                                                          subPixelDx = 0f
                                                          subPixelDy = 0f
                                                          if (lastGesture != "Moving") {
                                                              lastGesture = "Moving"
                                                          }
                                                      }
                                                  }
                                              }
                                          } else if (pressedCount == 2 && maxPointers <= 2) {
                                             val activeChanges = changes.filter { it.pressed }
                                             if (activeChanges.size == 2) {
                                                 val change1 = activeChanges[0]
                                                 val change2 = activeChanges[1]
                                                 val currentPos = (change1.position + change2.position) / 2f
                                                 
                                                 // If they move too much before hold, cancel hold detection
                                                 val movementFromStart = (currentPos - twoFingerInitialPos).getDistance()
                                                 if (twoFingerHoldStartTime > 0L && !twoFingerHoldTriggered && movementFromStart > 15f) {
                                                     twoFingerHoldStartTime = 0L
                                                 }
                                                 
                                                 val holdDuration = System.currentTimeMillis() - twoFingerHoldStartTime
                                                 if (twoFingerHoldStartTime > 0L && holdDuration >= 350L && !twoFingerHoldTriggered && !wasScrollingOrPinching) {
                                                     twoFingerHoldTriggered = true
                                                     HapticFeedback.leftClick(context)
                                                     viewModel.sendGesture("drag_start")
                                                     if (lastGesture != "Two-Finger Drag Started") {
                                                         lastGesture = "Two-Finger Drag Started"
                                                     }
                                                 }
                                                 
                                                 if (twoFingerHoldTriggered) {
                                                     val moveDelta = currentPos - (lastTouchPos ?: currentPos)
                                                     lastTouchPos = currentPos
                                                     val scaleFactor = 0.7f / density
                                                     viewModel.sendMove(moveDelta.x * scaleFactor, moveDelta.y * scaleFactor)
                                                     if (lastGesture != "Two-Finger Dragging") {
                                                         lastGesture = "Two-Finger Dragging"
                                                     }
                                                 } else {
                                                     // Only allow scrolling if they move more than the threshold
                                                     if (isScrolling || movementFromStart > 8f) {
                                                         isScrolling = true
                                                         wasScrollingOrPinching = true
                                                         val delta = currentPos - (lastTouchPos ?: currentPos)
                                                         lastTouchPos = currentPos
                                                         viewModel.sendScroll(delta.x * 1.0f, delta.y * 1.0f)
                                                         lastScrollTime = System.currentTimeMillis()
                                                         if (lastGesture != "Scrolling") {
                                                             lastGesture = "Scrolling"
                                                         }
                                                     }
                                                 }
                                             }
                                           } else if (pressedCount >= 3) {
                                                 isScrolling = false
                                                 isDragging = false
                                                 isPinching = false
                                                 twoFingerHoldTriggered = false
                                                val activeChanges = changes.filter { it.pressed }
                                                if (activeChanges.size >= 3) {
                                                    val center = activeChanges.map { it.position }.reduce { acc, offset -> acc + offset } / activeChanges.size.toFloat()
                                                    val currentDistance = activeChanges.map { (it.position - center).getDistance() }.sum()
                                                    
                                                    if (isFiveFingerReady) {
                                                        val activeCount = activeChanges.size
                                                        if (activeCount != lastFiveFingerCount || lastFiveFingerPinchDistance == 0f) {
                                                            lastFiveFingerPinchDistance = currentDistance
                                                            lastFiveFingerCount = activeCount
                                                        }
                                                        isFiveFingerPinching = true
                                                        wasScrollingOrPinching = true
                                                        val scale = currentDistance / lastFiveFingerPinchDistance
                                                        lastFiveFingerPinchDistance = currentDistance
                                                        viewModel.sendZoom(scale.toDouble())
                                                        if (lastGesture != "Zooming") {
                                                            lastGesture = "Zooming"
                                                        }
                                                    }
                                                }
                                            }
                                     } else if (event.type == PointerEventType.Release) {
                                         val duration = System.currentTimeMillis() - pressTime
                                         
                                         if (pressedCount < 2) {
                                             if (twoFingerHoldTriggered) {
                                                 viewModel.sendGesture("drag_end")
                                                 twoFingerHoldTriggered = false
                                                 twoFingerHoldStartTime = 0L
                                             }
                                         }
                                         
                                         if (pressedCount == 0) {
                                             isTouching = false
                                             lastGesture = "Idle"
                                             lastFiveFingerPinchDistance = 0f
                                             val isScrollRecently = (System.currentTimeMillis() - lastScrollTime) < 300L
                                             if (!gestureTriggered && !wasScrollingOrPinching && !isScrollRecently && !hasMovedSignificantDistance && (!isDragging || duration < 250)) {
                                                 if (maxPointers == 1) {
                                                     HapticFeedback.leftClick(context)
                                                     viewModel.sendClick("left", isTap = true)
                                                     lastGesture = "Left Click"
                                                 } else if (maxPointers == 2) {
                                                     HapticFeedback.rightClick(context)
                                                     viewModel.sendClick("right", isTap = true)
                                                     lastGesture = "Two-Finger Right Click"
                                                 }
                                             }
                                             maxPointers = 0
                                         }
                                     }
                                 }
                             }
                         },
                    cornerRadius = 20.dp,
                    padding = 0.dp
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .drawBehind {
                                val gridSize = 40f
                                val dotColor = Color(0x0DFFFFFF)
                                val cols = (size.width / gridSize).toInt()
                                val rows = (size.height / gridSize).toInt()

                                for (col in 1..cols) {
                                    for (row in 1..rows) {
                                        drawCircle(
                                            color = dotColor,
                                            radius = 1.5f,
                                            center = Offset(col * gridSize, row * gridSize)
                                        )
                                    }
                                }

                                 // Draw visual highlights for 1, 2, and 5 active fingers
                                 val positions = touchPositions
                                 if (positions.size == 1 || positions.size == 2 || positions.size >= 4) {
                                    positions.forEach { pos ->
                                        drawCircle(
                                            brush = Brush.radialGradient(
                                                colors = listOf(
                                                    LinkOSBlue.copy(alpha = 0.3f),
                                                    LinkOSBlue.copy(alpha = 0.1f),
                                                    Color.Transparent
                                                ),
                                                center = pos,
                                                radius = 80f
                                            ),
                                            center = pos,
                                            radius = 80f
                                        )
                                        drawCircle(
                                            color = LinkOSBlue.copy(alpha = 0.6f),
                                            center = pos,
                                            radius = 6f
                                        )
                                    }
                                }
                            }
                    ) {
                        if (!isTouching) {
                            Column(
                                modifier = Modifier.align(Alignment.Center),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Icon(
                                    Icons.Default.TouchApp,
                                    contentDescription = null,
                                    tint = TextTertiary.copy(alpha = 0.4f),
                                    modifier = Modifier.size(44.dp)
                                )
                                Text(
                                    text = "Touch to move cursor",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextTertiary.copy(alpha = 0.4f)
                                )
                            }
                        }
                    }
                }

                // Dedicated Scroll Strip with Clickable Arrows and sensitivity boost
                GlassCard(
                    modifier = Modifier
                        .width(50.dp)
                        .fillMaxHeight(),
                    cornerRadius = 20.dp,
                    padding = 0.dp
                ) {
                    Column(
                        modifier = Modifier.fillMaxSize(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.SpaceBetween
                    ) {
                        // Scroll Up Arrow Button (Page Up -> scroll delta y = 40f positive)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                                .pointerInput(Unit) {
                                    coroutineScope {
                                        awaitPointerEventScope {
                                            while (true) {
                                                val down = awaitFirstDown()
                                                down.consume()
                                                HapticFeedback.leftClick(context)
                                                viewModel.sendScroll(0f, 40f)
                                                lastGesture = "Scroll Up"
                                                
                                                val job = launch {
                                                    delay(400)
                                                    while (isActive) {
                                                        HapticFeedback.leftClick(context)
                                                        viewModel.sendScroll(0f, 15f)
                                                        delay(100)
                                                    }
                                                }
                                                
                                                waitForUpOrCancellation()
                                                job.cancel()
                                            }
                                        }
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Scroll Up", tint = TextTertiary)
                        }

                        // Middle Draggable Scroll Strip with increased sensitivity (0.85f)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f)
                                .pointerInput(Unit) {
                                    detectDragGestures { change, dragAmount ->
                                        change.consume()
                                        // 0.85f sensitivity boost
                                        viewModel.sendScroll(0f, dragAmount.y * 0.85f)
                                        lastGesture = "Scrolling"
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Text("SCROLL", fontSize = 9.sp, fontWeight = FontWeight.Bold, color = TextTertiary)
                        }

                        // Scroll Down Arrow Button (Page Down -> scroll delta y = -40f negative)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(50.dp)
                                .pointerInput(Unit) {
                                    coroutineScope {
                                        awaitPointerEventScope {
                                            while (true) {
                                                val down = awaitFirstDown()
                                                down.consume()
                                                HapticFeedback.leftClick(context)
                                                viewModel.sendScroll(0f, -40f)
                                                lastGesture = "Scroll Down"
                                                
                                                val job = launch {
                                                    delay(400)
                                                    while (isActive) {
                                                        HapticFeedback.leftClick(context)
                                                        viewModel.sendScroll(0f, -15f)
                                                        delay(100)
                                                    }
                                                }
                                                
                                                waitForUpOrCancellation()
                                                job.cancel()
                                            }
                                        }
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Scroll Down", tint = TextTertiary)
                        }
                    }
                }
            }
        }
    }
}
}

@Composable
private fun QuickKeyButton(
    label: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    Button(
        onClick = onClick,
        modifier = modifier.height(38.dp),
        shape = RoundedCornerShape(8.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1E2330)),
        contentPadding = PaddingValues(horizontal = 4.dp)
    ) {
        Text(label, fontSize = 12.sp, color = Color.White, fontWeight = FontWeight.Bold)
    }
}

@Composable
private fun ActionButton(
    modifier: Modifier = Modifier,
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    accentColor: Color = LinkOSBlue,
    onClick: () -> Unit
) {
    GlassCard(
        modifier = modifier.pressScale(onClick = onClick),
        cornerRadius = 14.dp,
        padding = 12.dp
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(
                imageVector = icon,
                contentDescription = label,
                tint = accentColor,
                modifier = Modifier.size(18.dp)
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = label,
                style = MaterialTheme.typography.labelMedium,
                color = TextPrimary,
                fontWeight = FontWeight.SemiBold
            )
        }
    }
}
