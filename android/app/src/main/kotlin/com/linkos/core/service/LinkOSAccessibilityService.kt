package com.linkos.core.service

import android.accessibilityservice.AccessibilityService
import android.view.accessibility.AccessibilityEvent

class LinkOSAccessibilityService : AccessibilityService() {
    companion object {
        var instance: LinkOSAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }
}
