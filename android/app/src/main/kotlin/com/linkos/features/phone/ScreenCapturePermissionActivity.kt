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
        
        fun launch(context: Context) {
            val intent = Intent(context, ScreenCapturePermissionActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LinkOSLogger.info("[PhoneMirroring] (PASS) ScreenCapturePermissionActivity created. Launching MediaProjection permission intent prompt", "PhoneMirroring")
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CODE)
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
                }
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
            } else {
                LinkOSLogger.error("[PhoneMirroring] (FAIL) MediaProjection permission denied/cancelled by user or resultCode ($resultCode) is not OK", "PhoneMirroring")
            }
        }
        finish()
    }
}
