package com.linkos.features.phone

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import com.linkos.core.logging.LinkOSLogger

class ScreenCapturePermissionActivity : Activity() {
    companion object {
        private const val REQUEST_CODE = 4213
        
        fun launch(context: Context, sessionId: String) {
            val intent = Intent(context, ScreenCapturePermissionActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("SESSION_ID", sessionId)
            }
            context.startActivity(intent)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkOSLogger.info("[PhoneMirroring] (PASS) ScreenCapturePermissionActivity created. Launching MediaProjection permission intent prompt", "PhoneMirroring")
        checkPermissionChecklist()
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CODE)
    }

    private fun checkPermissionChecklist() {
        val accessibilityActive = com.linkos.core.service.LinkOSAccessibilityService.instance != null
        if (!accessibilityActive) {
            LinkOSLogger.warning("[PhoneMirroring] (WARNING) AccessibilityService is NOT currently bound! Remote interaction requires Accessibility permission.", "PhoneMirroring")
            try {
                android.widget.Toast.makeText(this, "Enable LinkOS in Accessibility Settings for remote input control", android.widget.Toast.LENGTH_LONG).show()
                val accessIntent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(accessIntent)
            } catch (e: Exception) {
                LinkOSLogger.error("[PhoneMirroring] Failed to open Accessibility settings: ${e.message}", "PhoneMirroring")
            }
        } else {
            LinkOSLogger.info("[PhoneMirroring] (PASS) Permission Checklist validated: AccessibilityService actively bound.", "PhoneMirroring")
        }

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
            if (!android.provider.Settings.System.canWrite(this)) {
                LinkOSLogger.warning("[PhoneMirroring] (WARNING) WRITE_SETTINGS permission is NOT granted! Prompting user settings redirect...", "PhoneMirroring")
                try {
                    android.widget.Toast.makeText(this, "Allow LinkOS to modify system settings to support remote screen rotation", android.widget.Toast.LENGTH_LONG).show()
                    val writeIntent = Intent(android.provider.Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                        data = android.net.Uri.parse("package:$packageName")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(writeIntent)
                } catch (e: Exception) {
                    LinkOSLogger.error("[PhoneMirroring] Failed to open write settings screen: ${e.message}", "PhoneMirroring")
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CODE) {
            LinkOSLogger.info("[PhoneMirroring] (PASS) onActivityResult received: requestCode=$requestCode, resultCode=$resultCode", "PhoneMirroring")
            if (resultCode == RESULT_OK && data != null) {
                LinkOSLogger.info("[PhoneMirroring] (PASS) MediaProjection permission granted by user. Starting PhoneSessionService foreground service intent", "PhoneMirroring")
                val serviceIntent = Intent(this, PhoneSessionService::class.java).apply {
                    action = "START_STREAM"
                    putExtra("RESULT_CODE", resultCode)
                    putExtra("DATA", data)
                    putExtra("SESSION_ID", intent.getStringExtra("SESSION_ID"))
                }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
            } else {
                LinkOSLogger.error("[PhoneMirroring] (FAIL) MediaProjection permission denied/cancelled by user or resultCode ($resultCode) is not OK", "PhoneMirroring")
                val serviceIntent = Intent(this, PhoneSessionService::class.java).apply {
                    action = "PERMISSION_DENIED"
                    putExtra("SESSION_ID", intent.getStringExtra("SESSION_ID"))
                }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
            }
        }
        finish()
    }
}
