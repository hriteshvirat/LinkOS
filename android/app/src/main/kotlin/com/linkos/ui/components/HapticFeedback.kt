package com.linkos.ui.components

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.content.getSystemService

/**
 * Premium haptic feedback engine for LinkOS.
 * Provides distinct vibrational patterns for different interaction events,
 * designed to feel premium and Apple-like.
 */
object HapticFeedback {

    private fun vibrator(context: Context): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService<VibratorManager>()?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService<Vibrator>()
        }
    }

    private fun vibrate(context: Context, effect: VibrationEffect) {
        vibrator(context)?.vibrate(effect)
    }

    // MARK: - Trackpad Gestures

    /** Short, crisp pulse for left click. */
    fun leftClick(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            vibrate(context, VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
        } else {
            vibrate(context, VibrationEffect.createOneShot(20, VibrationEffect.DEFAULT_AMPLITUDE))
        }
    }

    /** Two consecutive short, crisp pulses for right click. */
    fun rightClick(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            vibrate(context, VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
        } else {
            vibrate(context, VibrationEffect.createWaveform(longArrayOf(0, 20, 60, 20), -1))
        }
    }

    /** Single, distinct medium pulse for drag start. */
    fun dragStart(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            vibrate(context, VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK))
        } else {
            vibrate(context, VibrationEffect.createOneShot(40, 180))
        }
    }

    /** Soft, damping release pulse for drag release. */
    fun dragRelease(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            vibrate(context, VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
        } else {
            vibrate(context, VibrationEffect.createOneShot(15, 80))
        }
    }

    /** Fluid, ascending vibration pattern for Mission Control. */
    fun missionControl(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 15, 30, 20, 30, 25),
            intArrayOf(0, 100, 0, 150, 0, 200),
            -1
        ))
    }

    /** Dense, broad cluster pulse for Launchpad. */
    fun launchpad(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 10, 10, 10, 10, 10, 10, 10),
            intArrayOf(0, 120, 0, 140, 0, 160, 0, 180),
            -1
        ))
    }

    // MARK: - Clipboard Events

    /** Light, clean tap confirming clipboard capture. */
    fun clipboardCopied(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            vibrate(context, VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
        } else {
            vibrate(context, VibrationEffect.createOneShot(10, 100))
        }
    }

    /** Successful receipt indicator for clipboard sync. */
    fun clipboardSynced(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 10, 40, 10),
            intArrayOf(0, 80, 0, 120),
            -1
        ))
    }

    // MARK: - File Transfer Events

    /** Accelerating trigger vibration for file transfer start. */
    fun fileTransferStarted(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 15, 20, 20, 20, 25),
            intArrayOf(0, 80, 0, 120, 0, 160),
            -1
        ))
    }

    /** Success chime vibration for file transfer completion. */
    fun fileTransferCompleted(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 30, 60, 30),
            intArrayOf(0, 200, 0, 120),
            -1
        ))
    }

    // MARK: - Connection Events

    /** Satisfying confirmation pattern for connection established. */
    fun connectionEstablished(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 20, 40, 30, 40, 20),
            intArrayOf(0, 100, 0, 160, 0, 220),
            -1
        ))
    }

    /** Two deep alerts indicating connection recovery. */
    fun reconnected(context: Context) {
        vibrate(context, VibrationEffect.createWaveform(
            longArrayOf(0, 40, 80, 40),
            intArrayOf(0, 180, 0, 180),
            -1
        ))
    }
    
    // MARK: - Scroll & Spaces

    /** Subtle tick for spaces swipe gesture. */
    fun spacesSwipe(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            vibrate(context, VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
        } else {
            vibrate(context, VibrationEffect.createOneShot(15, 100))
        }
    }
}
