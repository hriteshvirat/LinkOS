package com.linkos.ui.components

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.runtime.Composable
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback

/**
 * Haptic feedback utilities for LinkOS.
 * Provides consistent tactile feedback patterns across the app.
 */
object HapticUtils {

    fun lightTap(context: Context) {
        vibrate(context, 20L, VibrationEffect.EFFECT_TICK)
    }

    fun mediumTap(context: Context) {
        vibrate(context, 35L, VibrationEffect.EFFECT_CLICK)
    }

    fun success(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val vibrator = getVibrator(context) ?: return
            vibrator.vibrate(
                VibrationEffect.createWaveform(
                    longArrayOf(0, 30, 80, 50),
                    intArrayOf(0, 120, 0, 200),
                    -1
                )
            )
        } else {
            vibrate(context, 80L, VibrationEffect.EFFECT_HEAVY_CLICK)
        }
    }

    fun error(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val vibrator = getVibrator(context) ?: return
            vibrator.vibrate(
                VibrationEffect.createWaveform(
                    longArrayOf(0, 60, 50, 60),
                    intArrayOf(0, 255, 0, 255),
                    -1
                )
            )
        } else {
            vibrate(context, 100L, VibrationEffect.EFFECT_DOUBLE_CLICK)
        }
    }

    fun connectionEstablished(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val vibrator = getVibrator(context) ?: return
            vibrator.vibrate(
                VibrationEffect.createWaveform(
                    longArrayOf(0, 20, 60, 30, 60, 50),
                    intArrayOf(0, 80, 0, 120, 0, 200),
                    -1
                )
            )
        } else {
            vibrate(context, 120L, VibrationEffect.EFFECT_HEAVY_CLICK)
        }
    }

    private fun vibrate(context: Context, durationMs: Long, effectId: Int) {
        try {
            val vibrator = getVibrator(context) ?: return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                vibrator.vibrate(VibrationEffect.createPredefined(effectId))
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(durationMs)
            }
        } catch (_: Exception) {}
    }

    private fun getVibrator(context: Context): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }
}
