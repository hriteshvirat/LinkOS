package com.linkos.features.remotedesktop

import android.app.Activity
import android.content.pm.ActivityInfo
import androidx.compose.animation.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.hilt.navigation.compose.hiltViewModel
import com.linkos.ui.components.HapticUtils
import com.linkos.ui.components.pressScale
import com.linkos.ui.theme.*
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteDesktopScreen(
    onNavigateBack: () -> Unit,
    viewModel: RemoteDesktopViewModel = hiltViewModel()
) {
    val isStreaming by viewModel.isStreaming.collectAsState()
    val fps by viewModel.fps.collectAsState()
    val frameBitmap by viewModel.frameBitmap.collectAsState()
    val connectionProgress by viewModel.connectionProgress.collectAsState()
    val connectionTimeout by viewModel.connectionTimeout.collectAsState()

    val context = LocalContext.current
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    val activity = context as? Activity
    var containerSize by remember { mutableStateOf(IntSize.Zero) }

    // Remote Control States
    var isFullscreen by remember { mutableStateOf(false) }
    var isControlExpanded by remember { mutableStateOf(false) }
    var isControlVisible by remember { mutableStateOf(true) }
    var controlOffset by remember { mutableStateOf(Offset(200f, 300f)) }
    var lastInteractionTime by remember { mutableStateOf(System.currentTimeMillis()) }

    var lastTapTime by remember { mutableLongStateOf(0L) }
    var isTrackpadHelpVisible by remember { mutableStateOf(false) }
    var touchPositions by remember { mutableStateOf<List<Offset>>(emptyList()) }
    var isTouching by remember { mutableStateOf(false) }

    // Hidden Keyboard state
    var isKeyboardFocused by remember { mutableStateOf(false) }
    var textInput by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboardController = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    
    LaunchedEffect(isKeyboardFocused) {
        if (isKeyboardFocused) {
            focusRequester.requestFocus()
            keyboardController?.show()
        } else {
            focusManager.clearFocus()
            keyboardController?.hide()
        }
    }

    // Auto-hide controls timer
    LaunchedEffect(lastInteractionTime, isControlVisible) {
        if (isControlVisible) {
            delay(5000)
            isControlExpanded = false
            isControlVisible = false
        }
    }

    // Keep floating controls inside screen boundaries when orientation rotates
    LaunchedEffect(containerSize) {
        if (containerSize.width > 0 && containerSize.height > 0) {
            val screenW = containerSize.width
            val screenH = containerSize.height
            val newX = controlOffset.x.coerceIn(20f, screenW - 120f)
            val newY = controlOffset.y.coerceIn(20f, screenH - 120f)
            controlOffset = Offset(newX, newY)
        }
    }

    // Fullscreen and System UI bars side-effect
    LaunchedEffect(isFullscreen) {
        activity?.let { act ->
            val window = act.window
            val insetsController = WindowCompat.getInsetsController(window, window.decorView)
            if (isFullscreen) {
                act.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                insetsController.hide(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars())
                insetsController.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            } else {
                act.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                insetsController.show(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars())
            }
        }
    }

    DisposableEffect(Unit) {
        viewModel.startRemoteSession()
        onDispose {
            viewModel.stopRemoteSession()
            activity?.let { act ->
                act.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                val window = act.window
                val insetsController = WindowCompat.getInsetsController(window, window.decorView)
                insetsController.show(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars())
            }
        }
    }

    Scaffold(
        topBar = {
            if (!isFullscreen) {
                Column {
                    TopAppBar(
                        title = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Remote Desktop", fontWeight = FontWeight.Bold, color = Color.White)
                                Spacer(Modifier.width(10.dp))
                                Text(
                                    text = if (isStreaming && frameBitmap != null) "${fps} FPS • H.265" else connectionProgress,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = if (isStreaming && frameBitmap != null) StatusConnected else TextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                        },
                        navigationIcon = {
                            IconButton(onClick = onNavigateBack) {
                                Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = Color.White)
                            }
                        },
                        colors = TopAppBarDefaults.topAppBarColors(containerColor = DarkSurface)
                    )
                    HorizontalDivider(color = DarkBorder, thickness = 1.dp)
                }
            }
        },
        containerColor = Color.Black
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .then(if (isFullscreen) Modifier else Modifier.padding(paddingValues))
                .onSizeChanged { containerSize = it }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = {
                            lastInteractionTime = System.currentTimeMillis()
                            isControlVisible = true
                        }
                    )
                },
            contentAlignment = Alignment.Center
        ) {
            // Capture bitmap to a local val to prevent race condition NPE during recomposition
            val currentBitmap = frameBitmap
            when {
                connectionTimeout -> {
                    Card(
                        modifier = Modifier
                            .fillMaxWidth(0.85f)
                            .padding(16.dp),
                        shape = RoundedCornerShape(20.dp),
                        colors = CardDefaults.cardColors(containerColor = Color(0xFF1E2330))
                    ) {
                        Column(
                            modifier = Modifier.padding(24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.spacedBy(16.dp)
                        ) {
                            Icon(
                                Icons.Default.Warning,
                                contentDescription = null,
                                tint = Color(0xFFEF4444),
                                modifier = Modifier.size(48.dp)
                            )
                            Text(
                                text = "Connection Timed Out",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = Color.White
                            )
                            Text(
                                text = "Could not start video stream from macOS host. Ensure Screen Recording permission is granted.",
                                style = MaterialTheme.typography.bodySmall,
                                color = TextSecondary,
                                fontSize = 12.sp
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(12.dp)
                            ) {
                                Button(
                                    onClick = onNavigateBack,
                                    modifier = Modifier.weight(1f),
                                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2D3748))
                                ) {
                                    Text("Cancel", color = Color.White)
                                }
                                Button(
                                    onClick = { viewModel.startRemoteSession() },
                                    modifier = Modifier.weight(1f),
                                    colors = ButtonDefaults.buttonColors(containerColor = LinkOSBlue)
                                ) {
                                    Text("Retry", color = Color.White)
                                }
                            }
                        }
                    }
                }                currentBitmap != null -> {
                    Box(
                        modifier = Modifier
                            .fillMaxSize()
                            .background(Color(0xFF090B10))
                            .drawBehind {
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
                            .pointerInput(containerSize) {
                                awaitPointerEventScope {
                                    var pressTime = 0L
                                    var maxPointers = 0
                                    var isDragging = false
                                    var dragStartPos = Offset.Zero
                                    var gestureTriggered = false
                                    var hasMovedSignificantDistance = false
                                    var lastTouchPos: Offset? = null
                                    
                                    var lastFiveFingerPinchDistance = 0f
                                    var isFiveFingerPinching = false
                                    var fiveFingerHoldStartTime = 0L
                                    var isFiveFingerReady = false
                                    var fiveFingerInitialPos = Offset.Zero
                                    var lastFiveFingerCount = 0
                                    var twoFingerHoldStartTime = 0L
                                    var twoFingerHoldTriggered = false
                                    var twoFingerInitialPos = Offset.Zero
                                    var isScrolling = false
                                    var lastScrollTime = 0L
                                    var subPixelDx = 0f
                                    var subPixelDy = 0f

                                    while (true) {
                                        val event = awaitPointerEvent()
                                        // Update interaction timer
                                        lastInteractionTime = System.currentTimeMillis()

                                        val changes = event.changes.filter { !it.isConsumed }
                                        if (changes.isEmpty()) {
                                             continue
                                        }
                                        val pressedCount = changes.filter { it.pressed }.size
                                        
                                        // Update touch positions for visual highlights
                                        touchPositions = changes.filter { it.pressed }.map { it.position }
                                        
                                        if (pressedCount > 0) {
                                             if (!isTouching) {
                                                 isTouching = true
                                             }
                                        }

                                          // Detect 3+ fingers on ANY event type — not just Press
                                          // This catches fingers arriving one-by-one or close together
                                          if (pressedCount >= 3) {
                                              val activeChanges = changes.filter { it.pressed }
                                              val center = activeChanges.map { it.position }.reduce { acc, offset -> acc + offset } / activeChanges.size.toFloat()
                                              val currentDistance = activeChanges.map { (it.position - center).getDistance() }.sum()

                                              if (fiveFingerHoldStartTime == 0L) {
                                                  isScrolling = false
                                                  isDragging = false
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
                                                  // 0ms for simultaneous Press, 30ms for staggered
                                                  val threshold = if (pressedCount >= 3 && event.type == PointerEventType.Press) 0L else 30L
                                                  if (holdDuration >= threshold) {
                                                      isFiveFingerReady = true
                                                      isFiveFingerPinching = false
                                                      lastFiveFingerPinchDistance = currentDistance
                                                      lastFiveFingerCount = activeChanges.size
                                                      HapticUtils.lightTap(context)
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
                                                isScrolling = false
                                                twoFingerHoldStartTime = 0L
                                                twoFingerHoldTriggered = false
                                                isFiveFingerReady = false
                                                isFiveFingerPinching = false
                                                fiveFingerHoldStartTime = 0L
                                                dragStartPos = changes.first().position
                                                hasMovedSignificantDistance = false
                                                lastTouchPos = changes.first().position
                                                subPixelDx = 0f
                                                subPixelDy = 0f
                                            } else if (pressedCount == 2) {
                                                val activeChanges = changes.filter { it.pressed }
                                                if (activeChanges.size == 2) {
                                                    val p1 = activeChanges[0].position
                                                    val p2 = activeChanges[1].position
                                                    twoFingerHoldStartTime = System.currentTimeMillis()
                                                    twoFingerHoldTriggered = false
                                                    twoFingerInitialPos = (p1 + p2) / 2f
                                                    isScrolling = false
                                                    lastTouchPos = (p1 + p2) / 2f
                                                }
                                            }
                                        } else if (event.type == PointerEventType.Move) {
                                            if (isFiveFingerPinching || isFiveFingerReady) {
                                                if (pressedCount < 3) {
                                                    isFiveFingerReady = false
                                                    isFiveFingerPinching = false
                                                    fiveFingerHoldStartTime = 0L
                                                }
                                            }
                                            if (pressedCount > maxPointers) {
                                                maxPointers = pressedCount
                                            }

                                            if (pressedCount == 1) {
                                                 if (maxPointers == 1) {
                                                     val change = changes.first { it.pressed }
                                                     val currentPos = change.position
                                                     val delta = currentPos - (lastTouchPos ?: currentPos)
                                                     lastTouchPos = currentPos
                                                     val distance = (currentPos - dragStartPos).getDistance()
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
                                                              val scaleFactor = 0.6f / density
                                                              viewModel.sendMove(subPixelDx * scaleFactor, subPixelDy * scaleFactor)
                                                              subPixelDx = 0f
                                                              subPixelDy = 0f
                                                          }
                                                      }
                                                 }
                                            } else if (pressedCount == 2 && maxPointers <= 2) {
                                                val activeChanges = changes.filter { it.pressed }
                                                if (activeChanges.size == 2) {
                                                    val change1 = activeChanges[0]
                                                    val change2 = activeChanges[1]
                                                    val currentPos = (change1.position + change2.position) / 2f

                                                    val movementFromStart = (currentPos - twoFingerInitialPos).getDistance()
                                                    if (twoFingerHoldStartTime > 0L && !twoFingerHoldTriggered && movementFromStart > 15f) {
                                                        twoFingerHoldStartTime = 0L
                                                    }

                                                    val holdDuration = System.currentTimeMillis() - twoFingerHoldStartTime
                                                    if (twoFingerHoldStartTime > 0L && holdDuration >= 350L && !twoFingerHoldTriggered) {
                                                        twoFingerHoldTriggered = true
                                                        HapticUtils.lightTap(context)
                                                        viewModel.sendGesture("drag_start")
                                                    }

                                                    if (twoFingerHoldTriggered) {
                                                        val moveDelta = currentPos - (lastTouchPos ?: currentPos)
                                                        lastTouchPos = currentPos
                                                        val scaleFactor = 0.6f / density
                                                        viewModel.sendMove(moveDelta.x * scaleFactor, moveDelta.y * scaleFactor)
                                                    } else {
                                                        if (isScrolling || movementFromStart > 8f) {
                                                            isScrolling = true
                                                            val delta = currentPos - (lastTouchPos ?: currentPos)
                                                            lastTouchPos = currentPos
                                                            viewModel.sendScroll((delta.x * 0.8f).roundToInt(), (delta.y * 0.8f).roundToInt())
                                                            lastScrollTime = System.currentTimeMillis()
                                                        }
                                                    }
                                                }
                                              } else if (pressedCount >= 3) {
                                                  isScrolling = false
                                                  isDragging = false
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
                                                          val scale = currentDistance / lastFiveFingerPinchDistance
                                                          lastFiveFingerPinchDistance = currentDistance
                                                          viewModel.sendZoom(scale.toDouble())
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
                                                lastFiveFingerPinchDistance = 0f
                                                val isScrollRecently = (System.currentTimeMillis() - lastScrollTime) < 300L
                                                if (!gestureTriggered && !isScrollRecently && !hasMovedSignificantDistance && (!isDragging || duration < 250)) {
                                                    if (!isControlVisible) {
                                                        isControlVisible = true
                                                        lastInteractionTime = System.currentTimeMillis()
                                                    } else {
                                                        if (maxPointers == 1) {
                                                            val now = System.currentTimeMillis()
                                                            if (now - lastTapTime < 300) {
                                                                HapticUtils.lightTap(context)
                                                                viewModel.sendClick("left")
                                                                lastTapTime = 0L
                                                            } else {
                                                                HapticUtils.lightTap(context)
                                                                viewModel.sendClick("left")
                                                                lastTapTime = now
                                                            }
                                                        } else if (maxPointers == 2) {
                                                            HapticUtils.mediumTap(context)
                                                            viewModel.sendClick("right")
                                                        }
                                                    }
                                                }
                                                isDragging = false
                                                isScrolling = false
                                            }
                                        }
                                    }
                                }
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        Image(
                            bitmap = currentBitmap.asImageBitmap(),
                            contentDescription = "Live macOS Desktop Stream",
                            modifier = Modifier.fillMaxSize(),
                            contentScale = androidx.compose.ui.layout.ContentScale.Fit
                        )

                        // Floating Trackpad Toolbar Controls
                        if (isTrackpadHelpVisible) {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                                    .background(Color.Black.copy(alpha = 0.5f))
                                    .clickable { isTrackpadHelpVisible = false },
                                contentAlignment = Alignment.Center
                            ) {
                                Card(
                                    modifier = Modifier
                                        .fillMaxWidth(0.85f)
                                        .clickable(enabled = false) {}, // prevent click-through
                                    colors = CardDefaults.cardColors(containerColor = Color(0xFF1E2330).copy(alpha = 0.9f)),
                                    shape = RoundedCornerShape(16.dp)
                                ) {
                                    Column(
                                        modifier = Modifier.padding(16.dp),
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.spacedBy(12.dp)
                                    ) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Text("Trackpad Controls", fontWeight = FontWeight.Bold, color = Color.White, fontSize = 15.sp)
                                            IconButton(
                                                onClick = { isTrackpadHelpVisible = false },
                                                modifier = Modifier.size(24.dp)
                                            ) {
                                                Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White.copy(alpha = 0.6f))
                                            }
                                        }
                                        
                                        // Modifiers Row
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.spacedBy(6.dp)
                                        ) {
                                            val modifierBtnModifier = Modifier.weight(1f).height(36.dp)
                                            Button(
                                                onClick = { viewModel.sendSpecialKey("shift"); HapticUtils.lightTap(context) },
                                                modifier = modifierBtnModifier,
                                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.1f)),
                                                contentPadding = PaddingValues(0.dp)
                                            ) {
                                                Text("Shift", color = Color.White, fontSize = 11.sp)
                                            }
                                            Button(
                                                onClick = { viewModel.sendSpecialKey("command"); HapticUtils.lightTap(context) },
                                                modifier = modifierBtnModifier,
                                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.1f)),
                                                contentPadding = PaddingValues(0.dp)
                                            ) {
                                                Text("Cmd", color = Color.White, fontSize = 11.sp)
                                            }
                                            Button(
                                                onClick = { viewModel.sendSpecialKey("option"); HapticUtils.lightTap(context) },
                                                modifier = modifierBtnModifier,
                                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.1f)),
                                                contentPadding = PaddingValues(0.dp)
                                            ) {
                                                Text("Opt", color = Color.White, fontSize = 11.sp)
                                            }
                                            Button(
                                                onClick = { viewModel.sendSpecialKey("control"); HapticUtils.lightTap(context) },
                                                modifier = modifierBtnModifier,
                                                colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.1f)),
                                                contentPadding = PaddingValues(0.dp)
                                            ) {
                                                Text("Ctrl", color = Color.White, fontSize = 11.sp)
                                            }
                                        }

                                        // System Shortcuts Row
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                                        ) {
                                            Button(
                                                onClick = {
                                                    viewModel.sendGesture("mission_control")
                                                    HapticUtils.lightTap(context)
                                                },
                                                modifier = Modifier.weight(1f).height(38.dp),
                                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF6366F1))
                                            ) {
                                                Icon(Icons.Default.ViewCarousel, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                                                Spacer(Modifier.width(4.dp))
                                                Text("Mission", color = Color.White, fontSize = 11.sp, maxLines = 1)
                                            }
                                            Button(
                                                onClick = {
                                                    viewModel.sendGesture("launchpad")
                                                    HapticUtils.lightTap(context)
                                                },
                                                modifier = Modifier.weight(1f).height(38.dp),
                                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF06B6D4))
                                            ) {
                                                Icon(Icons.Default.GridView, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
                                                Spacer(Modifier.width(4.dp))
                                                Text("Launchpad", color = Color.White, fontSize = 11.sp, maxLines = 1)
                                            }
                                        }

                                        // Media Controls Row 1 (Brightness, Previous, Next)
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            IconButton(onClick = { viewModel.sendMediaKey("brightness_down"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.BrightnessLow, contentDescription = "Brightness Down", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                            IconButton(onClick = { viewModel.sendMediaKey("brightness_up"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.BrightnessHigh, contentDescription = "Brightness Up", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                            IconButton(onClick = { viewModel.sendMediaKey("previous"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.SkipPrevious, contentDescription = "Previous", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                            IconButton(onClick = { viewModel.sendMediaKey("play_pause"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.PlayArrow, contentDescription = "Play/Pause", tint = Color(0xFF3B82F6))
                                            }
                                            IconButton(onClick = { viewModel.sendMediaKey("next"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.SkipNext, contentDescription = "Next", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                        }

                                        // Media Controls Row 2 (Mute, Vol Down, Vol Up)
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceEvenly,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            IconButton(onClick = { viewModel.sendMediaKey("mute"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.VolumeOff, contentDescription = "Mute", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                            IconButton(onClick = { viewModel.sendMediaKey("vol_down"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.VolumeDown, contentDescription = "Volume Down", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                            IconButton(onClick = { viewModel.sendMediaKey("vol_up"); HapticUtils.lightTap(context) }) {
                                                Icon(Icons.Default.VolumeUp, contentDescription = "Volume Up", tint = Color.White.copy(alpha = 0.8f))
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Floating semi-transparent draggable bubble & palette
                        if (isControlVisible) {
                            Box(
                                modifier = Modifier
                                    .fillMaxSize()
                            ) {
                                // Floating menu wrapper
                                Box(
                                    modifier = Modifier
                                        .offset { IntOffset(controlOffset.x.roundToInt(), controlOffset.y.roundToInt()) }
                                        .pointerInput(containerSize) {
                                            detectDragGestures(
                                                onDragStart = {
                                                    lastInteractionTime = System.currentTimeMillis()
                                                },
                                                onDrag = { change, dragAmount ->
                                                    change.consume()
                                                    lastInteractionTime = System.currentTimeMillis()
                                                    val screenW = containerSize.width
                                                    val screenH = containerSize.height
                                                    val newX = (controlOffset.x + dragAmount.x).coerceIn(20f, screenW - 120f)
                                                    val newY = (controlOffset.y + dragAmount.y).coerceIn(20f, screenH - 120f)
                                                    controlOffset = Offset(newX, newY)
                                                }
                                            )
                                        }
                                        .clip(RoundedCornerShape(24.dp))
                                        .background(Color(0xFF1E2330).copy(alpha = 0.55f))
                                        .padding(8.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    if (!isControlExpanded) {
                                        // Small round collapsed control trigger button
                                        IconButton(
                                            onClick = {
                                                isControlExpanded = true
                                                lastInteractionTime = System.currentTimeMillis()
                                                HapticUtils.lightTap(context)
                                            },
                                            modifier = Modifier.size(44.dp)
                                        ) {
                                            Icon(Icons.Default.Menu, contentDescription = "Menu", tint = Color.White.copy(alpha = 0.8f))
                                        }
                                    } else {
                                        // Expanded palette grid
                                        Column(
                                            verticalArrangement = Arrangement.spacedBy(8.dp),
                                            horizontalAlignment = Alignment.CenterHorizontally
                                        ) {
                                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                IconButton(onClick = {
                                                    isTrackpadHelpVisible = !isTrackpadHelpVisible
                                                    lastInteractionTime = System.currentTimeMillis()
                                                    HapticUtils.lightTap(context)
                                                }) {
                                                    Icon(Icons.Default.Mouse, contentDescription = "Gestures Help", tint = Color.White)
                                                }
                                                IconButton(onClick = {
                                                    isKeyboardFocused = !isKeyboardFocused
                                                    lastInteractionTime = System.currentTimeMillis()
                                                    HapticUtils.lightTap(context)
                                                }) {
                                                    Icon(Icons.Default.Keyboard, contentDescription = "Keyboard", tint = Color.White)
                                                }
                                                IconButton(onClick = {
                                                    isFullscreen = !isFullscreen
                                                    lastInteractionTime = System.currentTimeMillis()
                                                    HapticUtils.lightTap(context)
                                                }) {
                                                    Icon(
                                                        if (isFullscreen) Icons.Default.FullscreenExit else Icons.Default.Fullscreen,
                                                        contentDescription = "Fullscreen",
                                                        tint = Color.White
                                                    )
                                                }
                                                IconButton(onClick = {
                                                    HapticUtils.lightTap(context)
                                                    onNavigateBack()
                                                }) {
                                                    Icon(Icons.Default.Close, contentDescription = "Disconnect", tint = LinkOSRed)
                                                }
                                            }
                                            // Collapse chevron
                                            IconButton(
                                                onClick = {
                                                    isControlExpanded = false
                                                    lastInteractionTime = System.currentTimeMillis()
                                                    HapticUtils.lightTap(context)
                                                },
                                                modifier = Modifier.size(24.dp)
                                            ) {
                                                Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Collapse", tint = Color.White.copy(alpha = 0.5f))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                else -> {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        CircularProgressIndicator(color = LinkOSBlue, strokeWidth = 3.dp, modifier = Modifier.size(44.dp))
                        Text(
                            text = if (connectionProgress.isNotBlank()) connectionProgress else "Connecting...",
                            color = Color.White,
                            fontWeight = FontWeight.SemiBold,
                            style = MaterialTheme.typography.bodyLarge
                        )
                        Text(
                            text = "Establishing secure video pipeline",
                            color = TextSecondary,
                            fontSize = 12.sp
                        )
                    }
                }
            }
            BasicTextField(
                value = textInput,
                onValueChange = { newVal ->
                    if (newVal.length > textInput.length) {
                        val addedChar = newVal.substring(textInput.length)
                        viewModel.sendText(addedChar)
                    } else if (newVal.length < textInput.length) {
                        viewModel.sendSpecialKey("backspace")
                    }
                    textInput = newVal
                },
                modifier = Modifier
                    .size(1.dp)
                    .alpha(0f)
                    .focusRequester(focusRequester)
                    .onFocusChanged {
                        if (!it.isFocused) {
                            isKeyboardFocused = false
                        }
                    },
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                    imeAction = androidx.compose.ui.text.input.ImeAction.Done
                ),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                    onDone = {
                        isKeyboardFocused = false
                    }
                )
            )
        }
    }
}
