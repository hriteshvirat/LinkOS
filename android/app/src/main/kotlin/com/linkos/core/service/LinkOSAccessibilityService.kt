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

    var onForegroundAppChangedListener: ((String, String) -> Unit)? = null

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val packageName = event.packageName?.toString() ?: return
            var category = "app"
            
            val pkgLower = packageName.lowercase()
            
            val intent = android.content.Intent(android.content.Intent.ACTION_MAIN)
            intent.addCategory(android.content.Intent.CATEGORY_HOME)
            val launchers = packageManager.queryIntentActivities(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
            val isLauncher = launchers.any { it.activityInfo.packageName == packageName } ||
                             pkgLower.contains("launcher") || pkgLower.contains("trebuchet") || pkgLower.contains("homescreen") || pkgLower.contains("sec.android.app.launcher")
            
            if (isLauncher) {
                category = "launcher"
            } else if (pkgLower.contains("chrome") || pkgLower.contains("browser") || pkgLower.contains("firefox")) {
                category = "browser"
            } else if (pkgLower.contains("gallery") || pkgLower.contains("photos")) {
                category = "gallery"
            } else if (pkgLower.contains("settings")) {
                category = "settings"
            }
            
            onForegroundAppChangedListener?.invoke(packageName, category)
        }
    }
    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) {
            instance = null
        }
    }

    // --- Input & Gesture Injection Helpers ---

    private fun getScreenDimensions(): Pair<Float, Float> {
        val wm = getSystemService(android.content.Context.WINDOW_SERVICE) as? android.view.WindowManager
        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        wm?.defaultDisplay?.getRealMetrics(metrics) ?: run {
            val resMetrics = resources.displayMetrics
            metrics.widthPixels = resMetrics.widthPixels
            metrics.heightPixels = resMetrics.heightPixels
        }
        return Pair(metrics.widthPixels.toFloat(), metrics.heightPixels.toFloat())
    }

    private var isGestureExecuting = false
    private var pendingScrollDeltaX = 0f
    private var pendingScrollDeltaY = 0f
    private var lastScrollNormX = 0.5f
    private var lastScrollNormY = 0.5f
    private var scrollTimeoutRunnable: Runnable? = null

    private fun resetScrollTimeout() {
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        scrollTimeoutRunnable?.let { handler.removeCallbacks(it) }
        
        val runnable = Runnable {
            if (activeStroke != null) {
                com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] Scroll timeout reached. Cleaning up active stroke.", "InputPipeline")
                activeStroke = null
                isGestureExecuting = false
                pendingScrollDeltaX = 0f
                pendingScrollDeltaY = 0f
            }
        }
        scrollTimeoutRunnable = runnable
        handler.postDelayed(runnable, 200L)
    }

    fun resetGestureState() {
        isGestureExecuting = false
        pendingScrollDeltaX = 0f
        pendingScrollDeltaY = 0f
        activeStroke = null
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        scrollTimeoutRunnable?.let { handler.removeCallbacks(it) }
        com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] Gesture states reset for session cleanup.", "InputPipeline")
    }

    private fun dispatchWithCallback(gesture: GestureDescription, actionName: String, onFinish: (() -> Unit)? = null) {
        val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
        com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [5. DISPATCH] Calling dispatchGesture() for $actionName on Main Looper Handler...", "InputPipeline")
        val callback = object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                super.onCompleted(gestureDescription)
                com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [6 & 7. RESULT - SUCCESS] GestureResultCallback.onCompleted: $actionName executed successfully on Android UI!", "InputPipeline")
                onFinish?.invoke()
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                super.onCancelled(gestureDescription)
                com.linkos.core.logging.LinkOSLogger.error("[InputPipeline] [6 & 7. RESULT - FAILURE] GestureResultCallback.onCancelled: $actionName was CANCELLED by system (check display bounds or overlapping gestures).", "InputPipeline")
                onFinish?.invoke()
            }
        }
        val dispatched = dispatchGesture(gesture, callback, mainHandler)
        if (dispatched) {
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [5. DISPATCH - SUCCESS] dispatchGesture() immediately returned TRUE for $actionName. Awaiting callback...", "InputPipeline")
        } else {
            com.linkos.core.logging.LinkOSLogger.error("[InputPipeline] [5. DISPATCH - FAIL] dispatchGesture() immediately returned FALSE for $actionName! (Verify canPerformGestures XML flag and active binding)", "InputPipeline")
            onFinish?.invoke()
        }
    }

    fun injectClick(normX: Float, normY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            val absX = normX * width
            val absY = normY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3. CONVERSION] Screen: ${width}x${height} -> Converted norm ($normX, $normY) to absolute ($absX, $absY)", "InputPipeline")
            
            val path = android.graphics.Path().apply { moveTo(absX, absY) }
            val builder = GestureDescription.Builder()
            builder.addStroke(GestureDescription.StrokeDescription(path, 0, 50))
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4. GESTURE] Created single-stroke CLICK gesture (duration: 50ms at $absX, $absY)", "InputPipeline")
            dispatchWithCallback(builder.build(), "CLICK")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectClick: ${e.message}", "InputPipeline")
        }
    }

    fun injectDoubleClick(normX: Float, normY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            val absX = normX * width
            val absY = normY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3. CONVERSION] Converted double-click norm ($normX, $normY) to absolute ($absX, $absY)", "InputPipeline")
            
            val path1 = android.graphics.Path().apply { moveTo(absX, absY) }
            val path2 = android.graphics.Path().apply { moveTo(absX, absY) }
            val builder = GestureDescription.Builder()
            builder.addStroke(GestureDescription.StrokeDescription(path1, 0, 40))
            builder.addStroke(GestureDescription.StrokeDescription(path2, 100, 40))
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4. GESTURE] Created dual-stroke DOUBLE_CLICK gesture", "InputPipeline")
            dispatchWithCallback(builder.build(), "DOUBLE_CLICK")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectDoubleClick: ${e.message}", "InputPipeline")
        }
    }

    fun injectLongPress(normX: Float, normY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            val absX = normX * width
            val absY = normY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3. CONVERSION] Converted long-press norm ($normX, $normY) to absolute ($absX, $absY)", "InputPipeline")
            
            val path = android.graphics.Path().apply { moveTo(absX, absY) }
            val builder = GestureDescription.Builder()
            builder.addStroke(GestureDescription.StrokeDescription(path, 0, 700))
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4. GESTURE] Created LONG_PRESS gesture (duration: 700ms)", "InputPipeline")
            dispatchWithCallback(builder.build(), "LONG_PRESS")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectLongPress: ${e.message}", "InputPipeline")
        }
    }

    fun injectSwipe(normStartX: Float, normStartY: Float, normEndX: Float, normEndY: Float, duration: Long) {
        try {
            val (width, height) = getScreenDimensions()
            val absStartX = normStartX * width
            val absStartY = normStartY * height
            val absEndX = normEndX * width
            val absEndY = normEndY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3. CONVERSION] Converted SWIPE/DRAG from ($absStartX, $absStartY) to ($absEndX, $absEndY)", "InputPipeline")
            
            val path = android.graphics.Path().apply {
                moveTo(absStartX, absStartY)
                lineTo(absEndX, absEndY)
            }
            val builder = GestureDescription.Builder()
            val validDuration = if (duration <= 0) 300L else duration
            builder.addStroke(GestureDescription.StrokeDescription(path, 0, validDuration))
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4. GESTURE] Created SWIPE/DRAG gesture (duration: ${validDuration}ms)", "InputPipeline")
            dispatchWithCallback(builder.build(), "SWIPE_DRAG")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectSwipe: ${e.message}", "InputPipeline")
        }
    }

    fun injectScroll(normX: Float, normY: Float, deltaX: Float, deltaY: Float) {
        try {
            if (isGestureExecuting) {
                pendingScrollDeltaX += deltaX
                pendingScrollDeltaY += deltaY
                lastScrollNormX = normX
                lastScrollNormY = normY
                com.linkos.core.logging.LinkOSLogger.debug("[InputPipeline] Scroll queued: accumulated delta ($pendingScrollDeltaX, $pendingScrollDeltaY)", "InputPipeline")
                return
            }
            executeScrollStroke(normX, normY, deltaX, deltaY)
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectScroll: ${e.message}", "InputPipeline")
        }
    }

    private fun executeScrollStroke(normX: Float, normY: Float, deltaX: Float, deltaY: Float) {
        val (width, height) = getScreenDimensions()
        val absX = normX * width
        val absY = normY * height
        val endX = (absX + (deltaX * 5f)).coerceIn(0f, width - 1f)
        val endY = (absY + (deltaY * 5f)).coerceIn(0f, height - 1f)
        com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3. CONVERSION] Converted SCROLL delta ($deltaX, $deltaY) to stroke from ($absX, $absY) to ($endX, $endY)", "InputPipeline")
        
        val path = android.graphics.Path().apply {
            moveTo(absX, absY)
            lineTo(endX, endY)
        }
        val builder = GestureDescription.Builder()
        builder.addStroke(GestureDescription.StrokeDescription(path, 0, 50))
        com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4. GESTURE] Created SCROLL gesture (duration: 50ms)", "InputPipeline")
        isGestureExecuting = true
        dispatchWithCallback(builder.build(), "SCROLL") {
            isGestureExecuting = false
            if (kotlin.math.abs(pendingScrollDeltaX) > 0.01f || kotlin.math.abs(pendingScrollDeltaY) > 0.01f) {
                val nextDeltaX = pendingScrollDeltaX
                val nextDeltaY = pendingScrollDeltaY
                pendingScrollDeltaX = 0f
                pendingScrollDeltaY = 0f
                executeScrollStroke(lastScrollNormX, lastScrollNormY, nextDeltaX, nextDeltaY)
            }
        }
    }

    private var activeStroke: GestureDescription.StrokeDescription? = null
    private var lastStrokeEndX: Float = 0f
    private var lastStrokeEndY: Float = 0f

    fun injectGestureStream(
        type: String, phase: String, normX: Float, normY: Float,
        deltaX: Float, deltaY: Float, velocity: Float, momentum: Boolean,
        pressure: Float, scale: Float, rotation: Float, timestamp: Long
    ) {
        try {
            if (type == "PINCH") {
                val (width, height) = getScreenDimensions()
                val cx = normX * width
                val cy = normY * height
                val offset = (50f * scale).coerceIn(20f, width / 3f)
                injectMultiTouch( (cx - offset) / width, cy / height, (cx + offset) / width, cy / height )
                return
            }
            if (type == "SCROLL" || type == "SWIPE") {
                if (isGestureExecuting && phase != "BEGAN") {
                    pendingScrollDeltaX += deltaX
                    pendingScrollDeltaY += deltaY
                    lastScrollNormX = normX
                    lastScrollNormY = normY
                    return
                }
                executeContinuousScrollStroke(type, phase, normX, normY, deltaX, deltaY, momentum)
            }
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectGestureStream: ${e.message}", "InputPipeline")
        }
    }

    private fun executeContinuousScrollStroke(
        type: String, phase: String, normX: Float, normY: Float, deltaX: Float, deltaY: Float, momentum: Boolean
    ) {
        resetScrollTimeout()
        val (width, height) = getScreenDimensions()
        val startX = if (activeStroke != null && phase != "BEGAN") lastStrokeEndX else normX * width
        val startY = if (activeStroke != null && phase != "BEGAN") lastStrokeEndY else normY * height
        
        val multiplier = if (momentum) 8f else 5f
        val endX = (startX + (deltaX * multiplier)).coerceIn(0f, width - 1f)
        val endY = (startY + (deltaY * multiplier)).coerceIn(0f, height - 1f)
        
        lastStrokeEndX = endX
        lastStrokeEndY = endY
        
        val path = android.graphics.Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }
        
        val willContinue = (phase != "ENDED" && phase != "CANCELLED")
        val duration: Long = if (momentum) 100L else 80L
        
        val stroke = if (activeStroke != null && android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O && phase != "BEGAN") {
            try {
                activeStroke!!.continueStroke(path, 0, duration, willContinue)
            } catch (e: Exception) {
                GestureDescription.StrokeDescription(path, 0, duration, willContinue)
            }
        } else if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            GestureDescription.StrokeDescription(path, 0, duration, willContinue)
        } else {
            GestureDescription.StrokeDescription(path, 0, duration)
        }
        
        activeStroke = if (willContinue) stroke else null
        
        val builder = GestureDescription.Builder()
        builder.addStroke(stroke)
        isGestureExecuting = true
        
        dispatchWithCallback(builder.build(), "$type-$phase") {
            isGestureExecuting = false
            if ((kotlin.math.abs(pendingScrollDeltaX) > 0.001f || kotlin.math.abs(pendingScrollDeltaY) > 0.001f) && willContinue) {
                val nextDeltaX = pendingScrollDeltaX
                val nextDeltaY = pendingScrollDeltaY
                pendingScrollDeltaX = 0f
                pendingScrollDeltaY = 0f
                executeContinuousScrollStroke(type, "CHANGED", lastScrollNormX, lastScrollNormY, nextDeltaX, nextDeltaY, momentum)
            } else if (!willContinue) {
                activeStroke = null
            }
        }
    }

    private var activeTouchX = 0f
    private var activeTouchY = 0f

    fun injectTouchDown(normX: Float, normY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            activeTouchX = normX * width
            activeTouchY = normY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3 & 4. TOUCH DOWN] Recorded start at ($activeTouchX, $activeTouchY)", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectTouchDown: ${e.message}", "InputPipeline")
        }
    }

    fun injectTouchMove(normX: Float, normY: Float, normStartX: Float, normStartY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            activeTouchX = normX * width
            activeTouchY = normY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3 & 4. TOUCH MOVE] Current touch at ($activeTouchX, $activeTouchY)", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectTouchMove: ${e.message}", "InputPipeline")
        }
    }

    fun injectTouchUp(normX: Float, normY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            val upX = normX * width
            val upY = normY * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3 & 4. TOUCH UP] Touch ended at ($upX, $upY)", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectTouchUp: ${e.message}", "InputPipeline")
        }
    }

    fun injectHover(normX: Float, normY: Float) {
        try {
            val (width, height) = getScreenDimensions()
            val absX = normX * width
            val absY = normY * height
            com.linkos.core.logging.LinkOSLogger.debug("[InputPipeline] Hover coordinates at ($absX, $absY)", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectHover: ${e.message}", "InputPipeline")
        }
    }

    fun injectMultiTouch(normX1: Float, normY1: Float, normX2: Float, normY2: Float) {
        try {
            val (width, height) = getScreenDimensions()
            val absX1 = normX1 * width; val absY1 = normY1 * height
            val absX2 = normX2 * width; val absY2 = normY2 * height
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [3. CONVERSION] Multi-touch points: ($absX1, $absY1) and ($absX2, $absY2)", "InputPipeline")
            
            val path1 = android.graphics.Path().apply { moveTo(absX1, absY1); lineTo(absX1 + 20f, absY1 + 20f) }
            val path2 = android.graphics.Path().apply { moveTo(absX2, absY2); lineTo(absX2 - 20f, absY2 - 20f) }
            val builder = GestureDescription.Builder()
            builder.addStroke(GestureDescription.StrokeDescription(path1, 0, 250))
            builder.addStroke(GestureDescription.StrokeDescription(path2, 0, 250))
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4. GESTURE] Created dual-stroke MULTI_TOUCH gesture", "InputPipeline")
            dispatchWithCallback(builder.build(), "MULTI_TOUCH")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectMultiTouch: ${e.message}", "InputPipeline")
        }
    }

    fun injectText(text: String) {
        try {
            val rootNode = rootInActiveWindow ?: run {
                com.linkos.core.logging.LinkOSLogger.error("[InputPipeline] [FAIL] injectText: rootInActiveWindow is null!", "InputPipeline")
                return
            }
            val focusedNode = rootNode.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: run {
                com.linkos.core.logging.LinkOSLogger.error("[InputPipeline] [FAIL] injectText: No input focused node found!", "InputPipeline")
                return
            }
            val currentText = focusedNode.text?.toString() ?: ""
            val selStart = focusedNode.textSelectionStart.coerceIn(0, currentText.length)
            val selEnd = focusedNode.textSelectionEnd.coerceIn(0, currentText.length)
            val start = minOf(selStart, selEnd)
            val end = maxOf(selStart, selEnd)
            
            val newText = if (start >= 0 && end >= 0 && start <= currentText.length && end <= currentText.length) {
                currentText.substring(0, start) + text + currentText.substring(end)
            } else {
                currentText + text
            }
            
            val arguments = android.os.Bundle()
            arguments.putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
            val result = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
            
            val newCursorPos = (if (start >= 0) start else currentText.length) + text.length
            val selArgs = android.os.Bundle()
            selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newCursorPos)
            selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newCursorPos)
            focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
            
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4 & 5. TEXT] Inserted ('$text') at [$start, $end], new text len=${newText.length}, result: $result", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectText: ${e.message}", "InputPipeline")
        }
    }

    fun injectBackspace() {
        try {
            val rootNode = rootInActiveWindow ?: run {
                com.linkos.core.logging.LinkOSLogger.error("[InputPipeline] [FAIL] injectBackspace: rootInActiveWindow is null!", "InputPipeline")
                return
            }
            val focusedNode = rootNode.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: run {
                com.linkos.core.logging.LinkOSLogger.error("[InputPipeline] [FAIL] injectBackspace: No input focused node found!", "InputPipeline")
                return
            }
            val currentText = focusedNode.text?.toString() ?: ""
            if (currentText.isNotEmpty()) {
                val selStart = focusedNode.textSelectionStart.coerceIn(0, currentText.length)
                val selEnd = focusedNode.textSelectionEnd.coerceIn(0, currentText.length)
                val start = minOf(selStart, selEnd)
                val end = maxOf(selStart, selEnd)
                
                val newText: String
                val newCursorPos: Int
                if (start != end) {
                    newText = currentText.substring(0, start) + currentText.substring(end)
                    newCursorPos = start
                } else if (start > 0) {
                    newText = currentText.substring(0, start - 1) + currentText.substring(start)
                    newCursorPos = start - 1
                } else {
                    return
                }
                
                val arguments = android.os.Bundle()
                arguments.putCharSequence(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
                val result = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
                
                val selArgs = android.os.Bundle()
                selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, newCursorPos)
                selArgs.putInt(android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, newCursorPos)
                focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_SET_SELECTION, selArgs)
                
                com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4 & 5. BACKSPACE] Backspace at [$start, $end], new cursorPos=$newCursorPos, result: $result", "InputPipeline")
            }
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectBackspace: ${e.message}", "InputPipeline")
        }
    }

    fun injectCopy() {
        try {
            val rootNode = rootInActiveWindow ?: return
            val focusedNode = rootNode.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: return
            val result = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_COPY)
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4 & 5. COPY] Executed ACTION_COPY with result: $result", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectCopy: ${e.message}", "InputPipeline")
        }
    }

    fun injectPaste() {
        try {
            val rootNode = rootInActiveWindow ?: return
            val focusedNode = rootNode.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: return
            val result = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_PASTE)
            com.linkos.core.logging.LinkOSLogger.info("[InputPipeline] [4 & 5. PASTE] Executed ACTION_PASTE with result: $result", "InputPipeline")
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to injectPaste: ${e.message}", "InputPipeline")
        }
    }

    // setForcedRotation has been removed in favor of native system orientation pipeline.
}
