package com.linkos.ui.theme

import android.app.Activity
import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/**
 * LinkOS Material 3 Theme — dark-mode-first with premium aesthetics.
 */

private val DarkColorScheme = darkColorScheme(
    primary = LinkOSBlue,
    onPrimary = Color.White,
    primaryContainer = LinkOSBlueDark,
    onPrimaryContainer = LinkOSBlueLight,
    secondary = LinkOSPurple,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFF2D1B69),
    onSecondaryContainer = Color(0xFFE8DEFF),
    tertiary = LinkOSCyan,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFF004D5C),
    onTertiaryContainer = Color(0xFFB3EBFF),
    error = LinkOSRed,
    onError = Color.White,
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
    background = DarkBackground,
    onBackground = TextPrimary,
    surface = DarkSurface,
    onSurface = TextPrimary,
    surfaceVariant = DarkSurfaceElevated,
    onSurfaceVariant = Color.White,
    outline = Color(0xFF2A2A36),
    outlineVariant = Color(0xFF1E1E28),
    inverseSurface = Color(0xFFE6E1E5),
    inverseOnSurface = Color(0xFF1C1B1F),
    inversePrimary = LinkOSBlueDark,
    surfaceTint = LinkOSBlue,
)

private val LightColorScheme = lightColorScheme(
    primary = LinkOSBlueDark,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD6E4FF),
    onPrimaryContainer = Color(0xFF001A40),
    secondary = Color(0xFF7C5ABA),
    tertiary = Color(0xFF0891B2),
    background = Color(0xFFF8FAFC),
    surface = Color.White,
    onSurface = Color(0xFF0F172A),
    surfaceVariant = Color(0xFFF1F5F9),
    onSurfaceVariant = Color(0xFF475569),
)

@Composable
fun LinkOSTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalView.current.context
            if (darkTheme) dynamicDarkColorScheme(context)
            else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = Color.Transparent.toArgb()
            window.navigationBarColor = Color.Transparent.toArgb()
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !darkTheme
                isAppearanceLightNavigationBars = !darkTheme
            }
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = LinkOSTypography,
        shapes = LinkOSShapes,
        content = content
    )
}
