package com.linkos.core.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
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

    // --- Input & Gesture Injection Helpers ---

    fun injectClick(x: Float, y: Float) {
        val path = android.graphics.Path()
        path.moveTo(x, y)
        val builder = GestureDescription.Builder()
        builder.addStroke(GestureDescription.StrokeDescription(path, 0, 50))
        dispatchGesture(builder.build(), null, null)
    }

    fun injectSwipe(startX: Float, startY: Float, endX: Float, endY: Float, duration: Long) {
        val path = android.graphics.Path()
        path.moveTo(startX, startY)
        path.lineTo(endX, endY)
        val builder = GestureDescription.Builder()
        builder.addStroke(GestureDescription.StrokeDescription(path, 0, duration))
        dispatchGesture(builder.build(), null, null)
    }

    fun injectText(text: String) {
        val rootNode = rootInActiveWindow ?: return
        val focusedNode = rootNode.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        val arguments = android.os.Bundle()
        arguments.putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    fun injectBackspace() {
        val rootNode = rootInActiveWindow ?: return
        val focusedNode = rootNode.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: return
        val currentText = focusedNode.text?.toString() ?: ""
        if (currentText.isNotEmpty()) {
            val newText = currentText.substring(0, currentText.length - 1)
            val arguments = android.os.Bundle()
            arguments.putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
            focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        }
    }
}
