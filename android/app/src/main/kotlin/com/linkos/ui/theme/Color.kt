package com.linkos.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * LinkOS color palette — dark-mode-first, high-contrast, premium aesthetic.
 * Meets Material 3 accessibility guidelines for contrast ratio.
 */

// Primary brand colors
val LinkOSBlue = Color(0xFF3B82F6)
val LinkOSBlueDark = Color(0xFF2563EB)
val LinkOSBlueLight = Color(0xFF60A5FA)

// Accent colors
val LinkOSPurple = Color(0xFF8B5CF6)
val LinkOSCyan = Color(0xFF06B6D4)
val LinkOSGreen = Color(0xFF10B981)
val LinkOSOrange = Color(0xFFF59E0B)
val LinkOSRed = Color(0xFFEF4444)
val LinkOSPink = Color(0xFFEC4899)

// Dark theme surface colors (layered depth)
val DarkBackground = Color(0xFF0B0E17)
val DarkSurface = Color(0xFF141923)
val DarkSurfaceElevated = Color(0xFF1E2536)
val DarkSurfaceHighest = Color(0xFF283248)
val DarkCard = Color(0xFF161C2A)
val DarkBorder = Color(0xFF2C364C)

// Glass effect colors
val GlassBackground = Color(0x1F2A364F)  // Semi-transparent glass
val GlassBorder = Color(0x4D3B82F6)      // Vibrant 30% LinkOS Blue
val GlassHighlight = Color(0x1AFFFFFF)

// High-Contrast Text Colors
val TextPrimary = Color(0xFFFFFFFF)       // Pure white (High Contrast)
val TextSecondary = Color(0xFFC9CDD4)     // High-legibility light slate
val TextTertiary = Color(0xFFC9CDD4)      // High-legibility light slate
val TextDisabled = Color(0xFF64748B)

// Status colors
val StatusConnected = Color(0xFF10B981)
val StatusDisconnected = Color(0xFF94A3B8)
val StatusWarning = Color(0xFFF59E0B)
val StatusError = Color(0xFFEF4444)

// Gradient pairs
val GradientBluePurple = listOf(LinkOSBlue, LinkOSPurple)
val GradientCyanBlue = listOf(LinkOSCyan, LinkOSBlue)
val GradientGreenCyan = listOf(LinkOSGreen, LinkOSCyan)

// ── Feature category accent gradients ──────────────────────────────
val GradientNavigation = listOf(Color(0xFF3B82F6), Color(0xFF6366F1))
val GradientProductivity = listOf(Color(0xFF06B6D4), Color(0xFF8B5CF6))
val GradientMedia = listOf(Color(0xFFEC4899), Color(0xFFF59E0B))
val GradientSystem = listOf(Color(0xFF10B981), Color(0xFF06B6D4))
val GradientAdvanced = listOf(Color(0xFFF59E0B), Color(0xFFEF4444))

// ── Semantic animation / state colors ──────────────────────────────
val ConnectionGlow = Color(0xFF10B981)          // Success glow for connected state
val ConnectionGlowSoft = Color(0x3310B981)      // Subtle ambient glow (20% opacity)
val PulseBlue = Color(0x553B82F6)               // Pulsing discover animation
val ShimmerHighlight = Color(0x33FFFFFF)         // Shimmer loading effect

// ── Glass tint variants ────────────────────────────────────────────
val GlassGreen = Color(0x1A10B981)
val GlassBlue = Color(0x1A3B82F6)
val GlassPurple = Color(0x1A8B5CF6)
val GlassCyan = Color(0x1A06B6D4)
val GlassOrange = Color(0x1AF59E0B)
val GlassPink = Color(0x1AEC4899)
val GlassRed = Color(0x1AEF4444)
