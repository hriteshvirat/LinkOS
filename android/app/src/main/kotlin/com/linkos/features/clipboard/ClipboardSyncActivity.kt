package com.linkos.features.clipboard

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import com.linkos.core.logging.LinkOSLogger

class ClipboardSyncActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Suppress all enter/exit animations — this activity must be invisible.
        window.setWindowAnimations(0)
        // FLAG_NOT_TOUCH_MODAL: prevent the translucent overlay from dimming the background.
        // FLAG_LAYOUT_IN_SCREEN: keep layout stable so there's no visual shift.
        window.addFlags(
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
        )

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            readAndSyncClipboard()
        }
    }

    private fun readAndSyncClipboard() {
        com.linkos.ui.components.HapticUtils.lightTap(this)
        try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboardManager.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val text = clip.getItemAt(0).text?.toString()
                if (!text.isNullOrEmpty()) {
                    LinkOSLogger.info("Background ClipboardSyncActivity read copy: ${text.take(30)}", "ClipboardSync")
                    
                    val serviceIntent = Intent("com.linkos.action.CLIPBOARD_SYNCED").apply {
                        setPackage(packageName)
                        putExtra("text", text)
                    }
                    sendBroadcast(serviceIntent)
                } else {
                    android.widget.Toast.makeText(this, "Clipboard is empty or contains non-text data", android.widget.Toast.LENGTH_SHORT).show()
                }
            } else {
                android.widget.Toast.makeText(this, "Clipboard is empty or contains non-text data", android.widget.Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to read clipboard in background helper activity: ${e.message}", "ClipboardSync")
        }
        // Move LinkOS back to the foreground in Recents before finishing,
        // so this invisible activity doesn't appear as a separate task card.
        moveTaskToBack(true)
        finish()
    }
}
