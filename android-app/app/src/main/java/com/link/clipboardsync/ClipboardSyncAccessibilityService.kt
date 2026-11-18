package com.link.clipboardsync

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Detects copy actions anywhere on the device (taps on "Copy"/"Copy image"/"Cut" and the system
 * "Copied to clipboard" toast) and briefly launches [ClipboardReaderActivity], which
 * gains window focus for a few ms so Android 10+ allows reading text and image URIs from the clipboard.
 */
class ClipboardSyncAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "ClipboardSyncService"

        @Volatile
        var instance: ClipboardSyncAccessibilityService? = null
            private set

        fun isServiceRunning(): Boolean = instance != null
    }

    private lateinit var clipboardManager: ClipboardManager
    private var lastFocusReaderLaunch = 0L
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private var isGestureInFlight = false
    private var gestureInFlightUntilMs = 0L
    private var pendingSwipe: (() -> Unit)? = null
    private var mirrorKeepAwakeView: View? = null
    private var isMirrorDimmed: Boolean = true

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "Accessibility Service Connected.")

        val updatedInfo = (serviceInfo ?: AccessibilityServiceInfo()).apply {
            eventTypes = AccessibilityEvent.TYPE_VIEW_CLICKED or AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 20
            flags = flags or
                    AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                    AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                    AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                    (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR else 0)
        }
        serviceInfo = updatedInfo

        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        // Keep sockets and process alive 24/7
        ClipboardSyncForegroundService.start(this)

        clipboardManager.addPrimaryClipChangedListener {
            handleLocalClipboardChange()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        // Ignore our own UI and notifications to avoid feedback loops
        if (event.packageName?.toString() == packageName) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                try {
                    val text = event.text.joinToString(" ")
                    val desc = event.contentDescription?.toString() ?: ""
                    val sourceNode = event.source
                    val viewId = sourceNode?.viewIdResourceName ?: ""

                    val isCopy = matchesCopyKeyword(text) ||
                            matchesCopyKeyword(desc) ||
                            viewId.contains("copy", ignoreCase = true) ||
                            viewId.contains("cut", ignoreCase = true) ||
                            hasCopyChildNode(sourceNode, 0)

                    @Suppress("DEPRECATION")
                    sourceNode?.recycle()

                    if (isCopy) {
                        Log.d(TAG, "Detected 'Copy' tap via Accessibility Event. Launching reader...")
                        launchFocusReader()
                    }
                } catch (ignored: Exception) {}
            }

            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED -> {
                try {
                    val text = event.text.joinToString(" ")
                    if (text.contains("copied", ignoreCase = true) ||
                        text.contains("clipboard", ignoreCase = true) ||
                        text.contains("কপি")
                    ) {
                        Log.d(TAG, "Detected copy toast via Accessibility Notification")
                        launchFocusReader()
                    }
                } catch (ignored: Exception) {}
            }
        }
    }

    private fun matchesCopyKeyword(str: String): Boolean {
        if (str.isEmpty()) return false
        return str.contains("Copy", ignoreCase = true) ||
                str.contains("Cut", ignoreCase = true) ||
                str.contains("কপি")
    }

    private fun hasCopyChildNode(node: AccessibilityNodeInfo?, depth: Int): Boolean {
        if (node == null || depth > 2) return false
        try {
            val nodeText = node.text?.toString() ?: ""
            val nodeDesc = node.contentDescription?.toString() ?: ""
            if (matchesCopyKeyword(nodeText) || matchesCopyKeyword(nodeDesc)) {
                return true
            }
            val count = node.childCount
            for (i in 0 until count) {
                val child = node.getChild(i) ?: continue
                val found = hasCopyChildNode(child, depth + 1)
                @Suppress("DEPRECATION")
                child.recycle()
                if (found) return true
            }
        } catch (ignored: Exception) {}
        return false
    }

    private fun handleLocalClipboardChange() {
        try {
            if (ClipboardSyncManager.isInternalMutation) {
                ClipboardSyncManager.isInternalMutation = false
                return
            }

            val clip = clipboardManager.primaryClip
            if (clip != null && clip.itemCount > 0) {
                if (ClipboardSyncManager.extractAndDispatchClipboard(this, clip, "OnPrimaryClipChanged")) {
                    return
                }
            }
            launchFocusReader()
        } catch (e: Exception) {
            Log.e(TAG, "Error handling clipboard change: ${e.message}", e)
        }
    }

    private fun launchFocusReader() {
        if (!BridgePrefs.isPaired(this)) return
        val now = System.currentTimeMillis()
        if (now - lastFocusReaderLaunch < 350) return
        lastFocusReaderLaunch = now

        try {
            val intent = Intent(this, ClipboardReaderActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch focus reader: ${e.message}")
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "Accessibility Service Interrupted.")
    }

    override fun onDestroy() {
        super.onDestroy()
        removeMirrorOverlaySync()
        try {
            softKeyboardController.showMode = SHOW_MODE_AUTO
        } catch (ignored: Exception) {}
        instance = null
        Log.i(TAG, "Accessibility Service Destroyed.")
    }

    // MARK: - Mirror Session Keyboard Auto-Hide & Hardware Screen Dimming

    fun onMirrorSessionStarted(dimScreen: Boolean = true) {
        mainHandler.post {
            isMirrorDimmed = dimScreen
            try {
                softKeyboardController.showMode = SHOW_MODE_HIDDEN
            } catch (e: Exception) {
                Log.w(TAG, "Could not hide soft keyboard: ${e.message}")
            }
            attachOrUpdateMirrorOverlayLocked(dimmed = dimScreen)
        }
    }

    fun setMirrorScreenDimmed(dimmed: Boolean) {
        mainHandler.post {
            isMirrorDimmed = dimmed
            attachOrUpdateMirrorOverlayLocked(dimmed = dimmed)
        }
    }

    fun onMirrorSessionStopped() {
        mainHandler.post {
            try {
                softKeyboardController.showMode = SHOW_MODE_AUTO
            } catch (e: Exception) {
                Log.w(TAG, "Could not restore soft keyboard: ${e.message}")
            }
            removeMirrorOverlaySync()
        }
    }

    private fun attachOrUpdateMirrorOverlayLocked(dimmed: Boolean) {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val existing = mirrorKeepAwakeView
        val brightness = if (dimmed) 0.0f else WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE

        if (existing != null) {
            try {
                val lp = (existing.layoutParams as? WindowManager.LayoutParams) ?: return
                lp.screenBrightness = brightness
                wm.updateViewLayout(existing, lp)
            } catch (e: Exception) {
                Log.w(TAG, "Failed updating mirror overlay brightness: ${e.message}")
            }
            return
        }

        try {
            val view = View(this).apply {
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
            }
            val lp = WindowManager.LayoutParams(
                1,
                1,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                PixelFormat.TRANSLUCENT
            ).apply {
                gravity = Gravity.TOP or Gravity.START
                x = 0
                y = 0
                screenBrightness = brightness
            }
            wm.addView(view, lp)
            mirrorKeepAwakeView = view
        } catch (e: Exception) {
            Log.w(TAG, "Failed attaching mirror keep-awake/dim overlay: ${e.message}")
        }
    }

    private fun removeMirrorOverlaySync() {
        val view = mirrorKeepAwakeView ?: return
        mirrorKeepAwakeView = null
        try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            wm?.removeViewImmediate(view)
        } catch (ignored: Exception) {}
    }

    // MARK: - Phone Mirroring Remote Input Injection

    private fun currentScreenPixelBounds(): Pair<Int, Int> {
        val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        val display = dm?.getDisplay(Display.DEFAULT_DISPLAY)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            val bounds = wm?.maximumWindowMetrics?.bounds
            if (bounds != null && bounds.width() > 0 && bounds.height() > 0) {
                return Pair(bounds.width(), bounds.height())
            }
        }
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display?.getRealMetrics(metrics)
        if (metrics.widthPixels > 0 && metrics.heightPixels > 0) {
            return Pair(metrics.widthPixels, metrics.heightPixels)
        }
        val fallback = resources.displayMetrics
        return Pair(fallback.widthPixels.coerceAtLeast(1), fallback.heightPixels.coerceAtLeast(1))
    }

    fun performMirrorTap(xNorm: Float, yNorm: Float) {
        val (w, h) = currentScreenPixelBounds()
        val (x, y) = PhoneMirrorProtocol.denormalizePoint(xNorm, yNorm, w, h)
        mainHandler.post {
            val path = Path().apply { moveTo(x, y) }
            val stroke = GestureDescription.StrokeDescription(path, 0L, 45L)
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            dispatchGesture(gesture, null, null)
        }
    }

    fun performMirrorLongPress(xNorm: Float, yNorm: Float) {
        val (w, h) = currentScreenPixelBounds()
        val (x, y) = PhoneMirrorProtocol.denormalizePoint(xNorm, yNorm, w, h)
        mainHandler.post {
            val path = Path().apply { moveTo(x, y) }
            val stroke = GestureDescription.StrokeDescription(path, 0L, 580L)
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            dispatchGesture(gesture, null, null)
        }
    }

    fun performMirrorSwipe(
        startXNorm: Float,
        startYNorm: Float,
        endXNorm: Float,
        endYNorm: Float,
        durationMs: Long
    ) {
        val (w, h) = currentScreenPixelBounds()
        val (sx, sy) = PhoneMirrorProtocol.denormalizePoint(startXNorm, startYNorm, w, h)
        val (ex, ey) = PhoneMirrorProtocol.denormalizePoint(endXNorm, endYNorm, w, h)
        val clampedDuration = durationMs.coerceIn(100L, 400L)
        mainHandler.post {
            val runSwipe = {
                val path = Path().apply {
                    moveTo(sx, sy)
                    lineTo(ex, ey)
                }
                val stroke = GestureDescription.StrokeDescription(path, 0L, clampedDuration)
                val gesture = GestureDescription.Builder().addStroke(stroke).build()
                isGestureInFlight = true
                gestureInFlightUntilMs = SystemClock.uptimeMillis() + clampedDuration + 250L
                val dispatched = dispatchGesture(gesture, object : GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription?) {
                        isGestureInFlight = false
                        val next = pendingSwipe
                        pendingSwipe = null
                        next?.invoke()
                    }

                    override fun onCancelled(gestureDescription: GestureDescription?) {
                        isGestureInFlight = false
                        val next = pendingSwipe
                        pendingSwipe = null
                        next?.invoke()
                    }
                }, mainHandler)
                if (!dispatched) {
                    isGestureInFlight = false
                    pendingSwipe = null
                }
            }

            if (isGestureInFlight && SystemClock.uptimeMillis() < gestureInFlightUntilMs) {
                pendingSwipe = runSwipe
            } else {
                pendingSwipe = null
                runSwipe()
            }
        }
    }

    fun performMirrorGlobalAction(actionName: String) {
        mainHandler.post {
            val code = when (actionName) {
                "back" -> GLOBAL_ACTION_BACK
                "home" -> GLOBAL_ACTION_HOME
                "recents" -> GLOBAL_ACTION_RECENTS
                "notifications" -> GLOBAL_ACTION_NOTIFICATIONS
                "quick_settings" -> GLOBAL_ACTION_QUICK_SETTINGS
                "lock_screen" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) GLOBAL_ACTION_LOCK_SCREEN else -1
                else -> -1
            }
            if (code != -1) {
                performGlobalAction(code)
            }
        }
    }

    private fun findFocusedEditableNode(): AccessibilityNodeInfo? {
        val directFocus = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (directFocus != null && directFocus.isEditable) {
            return directFocus
        }
        @Suppress("DEPRECATION")
        directFocus?.recycle()

        val root = rootInActiveWindow ?: return null
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)
        var fallbackEditable: AccessibilityNodeInfo? = null
        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            if (node.isEditable && node.isFocused) {
                fallbackEditable = node
                break
            }
            if (fallbackEditable == null && node.isEditable && node.isVisibleToUser) {
                fallbackEditable = node
            }
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.add(it) }
            }
        }
        return fallbackEditable
    }

    fun performMirrorTextInput(textToAppend: String) {
        if (textToAppend.isEmpty()) return
        mainHandler.post {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val ic = inputMethod?.currentInputConnection
                if (ic != null) {
                    try {
                        ic.commitText(textToAppend, 1, null)
                        return@post
                    } catch (e: Exception) {
                        Log.w(TAG, "IME commitText failed, falling back to AccessibilityNodeInfo: ${e.message}")
                    }
                }
            }

            val node = findFocusedEditableNode() ?: return@post
            try {
                // Note: hint text on empty EditText may appear in node.text on some OEM skins if isShowingHintText is true
                val existing = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && node.isShowingHintText) {
                    ""
                } else {
                    node.text?.toString() ?: ""
                }
                val updated = existing + textToAppend
                val args = Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, updated)
                }
                node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            } catch (e: Exception) {
                Log.w(TAG, "Failed performing text input: ${e.message}")
            }
        }
    }

    fun performMirrorKeyAction(keyAction: String) {
        mainHandler.post {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val ic = inputMethod?.currentInputConnection
                if (ic != null) {
                    try {
                        when (keyAction) {
                            "backspace" -> {
                                val surrounding = ic.getSurroundingText(1, 0, 0)
                                if (surrounding?.text?.isNotEmpty() == true) {
                                    ic.deleteSurroundingText(1, 0)
                                } else {
                                    val now = SystemClock.uptimeMillis()
                                    ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL, 0))
                                    ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL, 0))
                                }
                                return@post
                            }
                            "enter" -> {
                                val now = SystemClock.uptimeMillis()
                                ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0))
                                ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0))
                                return@post
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "IME keyAction '$keyAction' failed, falling back: ${e.message}")
                    }
                }
            }

            val node = findFocusedEditableNode() ?: return@post
            try {
                when (keyAction) {
                    "backspace" -> {
                        val existing = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && node.isShowingHintText) {
                            ""
                        } else {
                            node.text?.toString() ?: ""
                        }
                        if (existing.isNotEmpty()) {
                            val updated = existing.dropLast(1)
                            val args = Bundle().apply {
                                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, updated)
                            }
                            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                        }
                    }
                    "enter" -> {
                        val handled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                        } else {
                            false
                        }
                        if (!handled) {
                            node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed performing key action '$keyAction': ${e.message}")
            }
        }
    }
}
