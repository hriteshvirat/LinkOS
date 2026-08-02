package com.linkos.ui.components

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.linkos.ui.theme.ShimmerHighlight

// ── Staggered Reveal ────────────────────────────────────────────────
// Use: Pass index & isVisible to stagger appearance of items in a list.

@Composable
fun StaggeredAnimatedVisibility(
    visible: Boolean,
    index: Int,
    delayPerItem: Int = 60,
    content: @Composable AnimatedVisibilityScope.() -> Unit
) {
    val delayMs = index * delayPerItem
    var show by remember { mutableStateOf(false) }

    LaunchedEffect(visible) {
        if (visible) {
            kotlinx.coroutines.delay(delayMs.toLong())
            show = true
        } else {
            show = false
        }
    }

    AnimatedVisibility(
        visible = show,
        enter = fadeIn(tween(350)) + slideInVertically(
            initialOffsetY = { it / 4 },
            animationSpec = tween(350, easing = FastOutSlowInEasing)
        ) + scaleIn(
            initialScale = 0.92f,
            animationSpec = tween(350, easing = FastOutSlowInEasing)
        ),
        exit = fadeOut(tween(200)),
        content = content
    )
}

// ── Press Scale Animation ───────────────────────────────────────────
// Makes any composable slightly shrink on press for tactile feedback.

fun Modifier.pressScale(
    pressedScale: Float = 0.96f,
    onClick: () -> Unit = {}
): Modifier = composed {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (isPressed) pressedScale else 1f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessMedium
        ),
        label = "pressScale"
    )
    this
        .scale(scale)
        .clickable(
            interactionSource = interactionSource,
            indication = null,
            onClick = onClick
        )
}

// ── Connection Success Pulse ────────────────────────────────────────
// A pulsing ring animation for the connected state.

@Composable
fun rememberPulseScale(
    minScale: Float = 1f,
    maxScale: Float = 1.08f,
    durationMs: Int = 1500
): Float {
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val scale by infiniteTransition.animateFloat(
        initialValue = minScale,
        targetValue = maxScale,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMs, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulseScale"
    )
    return scale
}

// ── Shimmer Loading Effect ──────────────────────────────────────────
// Use as background modifier for skeleton loading placeholders.

fun Modifier.shimmerEffect(): Modifier = composed {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val translateAnim by transition.animateFloat(
        initialValue = -300f,
        targetValue = 1300f,
        animationSpec = infiniteRepeatable(
            animation = tween(1200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "shimmerTranslate"
    )
    background(
        brush = Brush.linearGradient(
            colors = listOf(
                Color.Transparent,
                ShimmerHighlight,
                Color.Transparent
            ),
            start = Offset(translateAnim, 0f),
            end = Offset(translateAnim + 400f, 200f)
        )
    )
}

// ── Fade-Slide Enter Transition ─────────────────────────────────────
// Pre-defined EnterTransition for consistent screen-level entrances.

val screenEnterTransition: EnterTransition =
    fadeIn(tween(400)) + slideInVertically(
        initialOffsetY = { it / 6 },
        animationSpec = tween(400, easing = FastOutSlowInEasing)
    )

val screenExitTransition: ExitTransition =
    fadeOut(tween(250))
