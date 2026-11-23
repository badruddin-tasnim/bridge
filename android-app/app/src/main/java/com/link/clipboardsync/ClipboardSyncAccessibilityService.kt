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

        private val COPY_WORD_REGEX = Regex(
            """(^|[^a-zA-Z])(copy|cut|copied|clipboard)($|[^a-zA-Z])""",
            RegexOption.IGNORE_CASE
        )

        fun isCopyOrCutKeyword(str: String?): Boolean {
            if (str.isNullOrBlank()) return false
            if (str.contains("কপি")) return true
            return COPY_WORD_REGEX.containsMatchIn(str)
        }

        fun isCopyRelatedViewId(viewId: String?): Boolean {
            if (viewId.isNullOrBlank()) return false
            val lower = viewId.lowercase()
            return lower.contains("copy") ||
                lower.contains("cut") ||
                lower.contains("clipboard") ||
                lower.contains("floating_toolbar_menu_item") ||
                lower.contains("action_mode_close_button")
        }

        fun isSystemClipboardOverlayEvent(
            pkg: String?,
            className: String?,
            text: String?,
            contentDesc: String?,
            viewId: String?
        ): Boolean {
            val lowerPkg = pkg?.lowercase() ?: ""
            val lowerClass = className?.lowercase() ?: ""
            val lowerViewId = viewId?.lowercase() ?: ""
            val combinedText = "${text ?: ""} ${contentDesc ?: ""}".trim()
            val lowerText = combinedText.lowercase()

            if (lowerPkg == "com.android.systemui") {
                return lowerClass.contains("clipboard") ||
                    lowerViewId.contains("clipboard") ||
                    lowerViewId.contains("copy_button") ||
                    lowerText.contains("copied") ||
                    lowerText.contains("clipboard")
            }

            if (lowerPkg == "com.samsung.android.honeyboard" ||
                lowerPkg == "com.samsung.android.app.clipboardedge" ||
                lowerPkg == "com.google.android.inputmethod.latin"
            ) {
                if (lowerClass.contains("clipboard") ||
                    lowerViewId.contains("clipboard") ||
                    lowerText.contains("copied") ||
                    lowerText.contains("clipboard")
                ) {
                    return true
                }
            }

            if (lowerText.isEmpty()) return false
            if (lowerText.contains("কপি") ||
                lowerText.contains("copied to clipboard") ||
                lowerText.contains("link copied") ||
                lowerText.contains("text copied") ||
                lowerText.contains("message copied") ||
                lowerText.contains("url copied") ||
                lowerText.contains("address copied") ||
                lowerText.contains("code copied")
            ) {
                return true
            }

            return combinedText.length <= 120 && COPY_WORD_REGEX.containsMatchIn(lowerText) &&
                (lowerText.contains("copied") || lowerText.contains("clipboard"))
        }
    }

    private lateinit var clipboardManager: ClipboardManager
    private var lastFocusReaderLaunch = 0L
    private var lastActiveSelectionAtMs = 0L
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val scheduledFocusReaderRunnable = Runnable { launchFocusReader() }
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
            eventTypes = AccessibilityEvent.TYPE_VIEW_CLICKED or
                    AccessibilityEvent.TYPE_VIEW_LONG_CLICKED or
                    AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED or
                    AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                    AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or
                    AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
                    AccessibilityEvent.TYPE_ANNOUNCEMENT
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
        val eventPkg = event.packageName?.toString()
        // Ignore our own UI and notifications to avoid feedback loops
        if (eventPkg == packageName) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                val fromIdx = event.fromIndex
                val toIdx = event.toIndex
                val now = System.currentTimeMillis()
                if (fromIdx >= 0 && toIdx > fromIdx) {
                    lastActiveSelectionAtMs = now
                } else if (fromIdx >= 0 && fromIdx == toIdx && (now - lastActiveSelectionAtMs) < 4000L) {
                    lastActiveSelectionAtMs = 0L
                    Log.d(TAG, "Text selection collapsed shortly after selection; scheduling clipboard reader.")
                    scheduleFocusReader(40L)
                }
            }

            AccessibilityEvent.TYPE_VIEW_CLICKED -> {
                try {
                    val text = event.text.joinToString(" ")
                    val desc = event.contentDescription?.toString() ?: ""
                    val cls = event.className?.toString() ?: ""
                    val sourceNode = event.source
                    val viewId = sourceNode?.viewIdResourceName ?: ""
                    val tooltip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        sourceNode?.tooltipText?.toString() ?: ""
                    } else {
                        ""
                    }
                    val recentSelection = (System.currentTimeMillis() - lastActiveSelectionAtMs) < 10_000L
                    val isToolbarMenuClick = cls.contains("MenuItem", ignoreCase = true) ||
                            cls.contains("FloatingToolbar", ignoreCase = true) ||
                            cls.contains("ActionMenuItem", ignoreCase = true)
                    val hasExplicitLabel = text.isNotBlank() || desc.isNotBlank() || tooltip.isNotBlank()

                    val isCopy = isCopyOrCutKeyword(text) ||
                            isCopyOrCutKeyword(desc) ||
                            isCopyOrCutKeyword(tooltip) ||
                            isCopyRelatedViewId(viewId) ||
                            hasCopyNodeInNeighborhood(sourceNode) ||
                            (!hasExplicitLabel && (recentSelection || isToolbarMenuClick))

                    @Suppress("DEPRECATION")
                    sourceNode?.recycle()

                    if (isCopy) {
                        lastActiveSelectionAtMs = 0L
                        Log.d(TAG, "Detected copy-related click ($eventPkg / $cls); scheduling clipboard reader.")
                        scheduleFocusReader(35L)
                    }
                } catch (ignored: Exception) {}
            }

            AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_ANNOUNCEMENT -> {
                try {
                    val text = event.text.joinToString(" ")
                    val desc = event.contentDescription?.toString() ?: ""
                    val cls = event.className?.toString() ?: ""
                    val needsSourceId = eventPkg == "com.android.systemui" ||
                            eventPkg == "com.samsung.android.honeyboard" ||
                            eventPkg == "com.samsung.android.app.clipboardedge" ||
                            eventPkg == "com.google.android.inputmethod.latin" ||
                            event.eventType == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
                    val sourceNode = if (needsSourceId) event.source else null
                    val viewId = sourceNode?.viewIdResourceName ?: ""
                    @Suppress("DEPRECATION")
                    sourceNode?.recycle()

                    val isToastFallback = event.eventType == AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED &&
                            (text.contains("copied", ignoreCase = true) ||
                             text.contains("clipboard", ignoreCase = true) ||
                             text.contains("কপি"))

                    if (isToastFallback || isSystemClipboardOverlayEvent(eventPkg, cls, text, desc, viewId)) {
                        Log.d(TAG, "Detected system clipboard overlay/toast/snackbar ($eventPkg): $text")
                        scheduleFocusReader(20L)
                    }
                } catch (ignored: Exception) {}
            }
        }
    }

    private fun matchesCopyKeyword(str: String): Boolean {
        return isCopyOrCutKeyword(str)
    }

    private fun hasCopyNodeInNeighborhood(node: AccessibilityNodeInfo?): Boolean {
        if (node == null) return false
        if (hasCopyChildNode(node, 0)) return true
        try {
            val parent = node.parent ?: return false
            val parentText = parent.text?.toString() ?: ""
            val parentDesc = parent.contentDescription?.toString() ?: ""
            val parentId = parent.viewIdResourceName ?: ""
            val parentTooltip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                parent.tooltipText?.toString() ?: ""
            } else {
                ""
            }
            if (isCopyOrCutKeyword(parentText) ||
                isCopyOrCutKeyword(parentDesc) ||
                isCopyOrCutKeyword(parentTooltip) ||
                isCopyRelatedViewId(parentId)
            ) {
                @Suppress("DEPRECATION")
                parent.recycle()
                return true
            }
            val siblingCount = parent.childCount.coerceAtMost(12)
            for (i in 0 until siblingCount) {
                val sibling = parent.getChild(i) ?: continue
                val matched = isCopyOrCutKeyword(sibling.text?.toString()) ||
                        isCopyOrCutKeyword(sibling.contentDescription?.toString()) ||
                        isCopyRelatedViewId(sibling.viewIdResourceName)
                @Suppress("DEPRECATION")
                sibling.recycle()
                if (matched) {
                    @Suppress("DEPRECATION")
                    parent.recycle()
                    return true
                }
            }
            @Suppress("DEPRECATION")
            parent.recycle()
        } catch (ignored: Exception) {}
        return false
    }

    private fun hasCopyChildNode(node: AccessibilityNodeInfo?, depth: Int): Boolean {
        if (node == null || depth > 3) return false
        try {
            val nodeText = node.text?.toString() ?: ""
            val nodeDesc = node.contentDescription?.toString() ?: ""
            val nodeId = node.viewIdResourceName ?: ""
            val nodeTooltip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                node.tooltipText?.toString() ?: ""
            } else {
                ""
            }
            if (matchesCopyKeyword(nodeText) ||
                matchesCopyKeyword(nodeDesc) ||
                matchesCopyKeyword(nodeTooltip) ||
                isCopyRelatedViewId(nodeId)
            ) {
                return true
            }
            val count = node.childCount.coerceAtMost(16)
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
            if (System.currentTimeMillis() - ClipboardSyncManager.lastInternalMutationAtMs < 400L) {
                return
            }

            val clip = clipboardManager.primaryClip
            if (clip != null && clip.itemCount > 0) {
                if (ClipboardSyncManager.extractAndDispatchClipboard(this, clip, "OnPrimaryClipChanged")) {
                    return
                }
            }
            scheduleFocusReader(15L)
        } catch (e: Exception) {
            Log.e(TAG, "Error handling clipboard change: ${e.message}", e)
        }
    }

    private fun scheduleFocusReader(delayMs: Long) {
        if (!BridgePrefs.isPaired(this)) return
        mainHandler.removeCallbacks(scheduledFocusReaderRunnable)
        mainHandler.postDelayed(scheduledFocusReaderRunnable, delayMs)
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
                            "copy" -> {
                                val selected = extractSelectedText(ic.getSurroundingText(4096, 4096, 0))
                                if (!selected.isNullOrEmpty()) {
                                    ClipboardSyncManager.dispatchTextToMac(this, selected, "MirrorCmdC")
                                }
                                ic.performContextMenuAction(android.R.id.copy)
                                scheduleFocusReader(45L)
                                return@post
                            }
                            "cut" -> {
                                val selected = extractSelectedText(ic.getSurroundingText(4096, 4096, 0))
                                if (!selected.isNullOrEmpty()) {
                                    ClipboardSyncManager.dispatchTextToMac(this, selected, "MirrorCmdX")
                                }
                                ic.performContextMenuAction(android.R.id.cut)
                                scheduleFocusReader(45L)
                                return@post
                            }
                            "select_all" -> {
                                ic.performContextMenuAction(android.R.id.selectAll)
                                val now = SystemClock.uptimeMillis()
                                ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0, KeyEvent.META_CTRL_ON))
                                ic.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_A, 0, KeyEvent.META_CTRL_ON))
                                return@post
                            }
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "IME keyAction '$keyAction' failed, falling back: ${e.message}")
                    }
                }
            }

            val node = findFocusedEditableNode() ?: findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY) ?: return@post
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
                    "copy" -> {
                        val start = node.textSelectionStart
                        val end = node.textSelectionEnd
                        val text = node.text?.toString()
                        if (!text.isNullOrEmpty() && start >= 0 && end > start && end <= text.length) {
                            ClipboardSyncManager.dispatchTextToMac(this, text.substring(start, end), "MirrorNodeCmdC")
                        }
                        node.performAction(AccessibilityNodeInfo.ACTION_COPY)
                        scheduleFocusReader(45L)
                    }
                    "cut" -> {
                        val start = node.textSelectionStart
                        val end = node.textSelectionEnd
                        val text = node.text?.toString()
                        if (!text.isNullOrEmpty() && start >= 0 && end > start && end <= text.length) {
                            ClipboardSyncManager.dispatchTextToMac(this, text.substring(start, end), "MirrorNodeCmdX")
                        }
                        node.performAction(AccessibilityNodeInfo.ACTION_CUT)
                        scheduleFocusReader(45L)
                    }
                    "select_all" -> {
                        val textLen = node.text?.length ?: 0
                        if (textLen > 0) {
                            val args = Bundle().apply {
                                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
                                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, textLen)
                            }
                            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed performing key action '$keyAction': ${e.message}")
            }
        }
    }

    private fun extractSelectedText(surrounding: android.view.inputmethod.SurroundingText?): String? {
        if (surrounding == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val text = surrounding.text ?: return null
        val start = minOf(surrounding.selectionStart, surrounding.selectionEnd)
        val end = maxOf(surrounding.selectionStart, surrounding.selectionEnd)
        if (start < 0 || end <= start || end > text.length) return null
        return text.subSequence(start, end).toString()
    }

    // MARK: - Live Call UI Inspection & Fallback Node Actions

    fun findActiveCallCallerName(pkg: String): String? {
        return try {
            val roots = collectCallInspectionRoots(pkg, includeSystemUi = false)
            if (roots.isEmpty()) return null
            val prioritized = ArrayList<String>()
            val secondary = ArrayList<String>()

            for (root in roots) {
                val queue = ArrayDeque<AccessibilityNodeInfo>()
                queue.add(root)
                var visited = 0
                while (queue.isNotEmpty() && visited < 200) {
                    val node = queue.removeFirst()
                    visited++
                    val viewId = node.viewIdResourceName?.lowercase() ?: ""
                    val className = node.className?.toString() ?: ""
                    val isTimer = className.contains("Chronometer", ignoreCase = true)
                    val isPriorityId = viewId.contains("name") ||
                        viewId.contains("caller") ||
                        viewId.contains("contact") ||
                        viewId.contains("number") ||
                        viewId.contains("title")

                    if (!isTimer) {
                        val txt = node.text?.toString()?.trim()
                        if (!txt.isNullOrEmpty()) {
                            if (isPriorityId) prioritized.add(txt) else secondary.add(txt)
                        }
                        val desc = node.contentDescription?.toString()?.trim()
                        if (!desc.isNullOrEmpty()) {
                            if (isPriorityId) prioritized.add(desc) else secondary.add(desc)
                        }
                    }

                    for (i in 0 until node.childCount) {
                        node.getChild(i)?.let { queue.add(it) }
                    }
                }
            }

            val resolved = PhoneCallMonitor.selectBestCallerName(
                candidates = prioritized + secondary,
                appName = "",
                previousCallerName = null,
                fallback = ""
            )
            resolved.ifBlank { null }
        } catch (e: Exception) {
            Log.d(TAG, "findActiveCallCallerName error: ${e.message}")
            null
        }
    }

    fun performCallNodeClick(pkg: String, actionType: String): Boolean {
        return try {
            val roots = collectCallInspectionRoots(pkg, includeSystemUi = true)
            for (root in roots) {
                val queue = ArrayDeque<AccessibilityNodeInfo>()
                queue.add(root)
                var visited = 0
                while (queue.isNotEmpty() && visited < 250) {
                    val node = queue.removeFirst()
                    visited++
                    val viewId = node.viewIdResourceName?.lowercase() ?: ""
                    val text = node.text?.toString()?.trim()?.lowercase() ?: ""
                    val desc = node.contentDescription?.toString()?.trim()?.lowercase() ?: ""

                    if (matchesCallNodeAction(actionType, text, desc, viewId)) {
                        if (clickNodeOrClickableParent(node)) {
                            Log.i(TAG, "Clicked call accessibility node for '$actionType' (id=$viewId, text=$text, desc=$desc)")
                            return true
                        }
                    }

                    for (i in 0 until node.childCount) {
                        node.getChild(i)?.let { queue.add(it) }
                    }
                }
            }
            false
        } catch (e: Exception) {
            Log.d(TAG, "performCallNodeClick error: ${e.message}")
            false
        }
    }

    private fun collectCallInspectionRoots(pkg: String, includeSystemUi: Boolean): List<AccessibilityNodeInfo> {
        val dialerRoots = ArrayList<AccessibilityNodeInfo>()
        val sysUiRoots = ArrayList<AccessibilityNodeInfo>()

        fun matchesCallPkg(nodePkg: String): Boolean {
            if (nodePkg.isEmpty()) return false
            if (pkg.isNotEmpty() && nodePkg == pkg) return true
            val lower = nodePkg.lowercase()
            return lower.contains("incallui") ||
                lower.contains("dialer") ||
                lower.contains("telecom")
        }

        try {
            val windowList = windows
            if (windowList != null) {
                for (w in windowList) {
                    val root = w.root ?: continue
                    val rootPkg = root.packageName?.toString() ?: ""
                    if (matchesCallPkg(rootPkg)) {
                        dialerRoots.add(root)
                    } else if (includeSystemUi && rootPkg == "com.android.systemui") {
                        sysUiRoots.add(root)
                    }
                }
            }
        } catch (_: Exception) {}

        try {
            val active = rootInActiveWindow
            val activePkg = active?.packageName?.toString() ?: ""
            if (active != null) {
                if (matchesCallPkg(activePkg)) {
                    dialerRoots.add(active)
                } else if (includeSystemUi && activePkg == "com.android.systemui") {
                    sysUiRoots.add(active)
                }
            }
        } catch (_: Exception) {}

        return if (includeSystemUi) dialerRoots + sysUiRoots else dialerRoots
    }

    private fun matchesCallNodeAction(actionType: String, text: String, desc: String, viewId: String): Boolean {
        val combined = "$text $desc".trim()
        return when (actionType) {
            "answer" -> {
                combined.contains("answer") ||
                    combined.contains("accept") ||
                    combined.contains("pick up") ||
                    text == "join" ||
                    desc == "join" ||
                    combined.contains("join call") ||
                    viewId.contains("answer") ||
                    viewId.contains("accept") ||
                    viewId.contains("join")
            }
            "decline" -> {
                combined.contains("decline") ||
                    combined.contains("reject") ||
                    combined.contains("end call") ||
                    combined.contains("hang up") ||
                    text == "end" ||
                    desc == "end" ||
                    desc == "end call" ||
                    viewId.contains("decline") ||
                    viewId.contains("reject") ||
                    viewId.contains("end_call") ||
                    viewId.contains("endcall") ||
                    viewId.contains("hangup")
            }
            "mute" -> {
                text == "mute" ||
                    desc == "mute" ||
                    text == "unmute" ||
                    desc == "unmute" ||
                    combined.contains("mute call") ||
                    viewId.contains("mute")
            }
            "silence" -> {
                combined.contains("silence") ||
                    viewId.contains("silence")
            }
            else -> false
        }
    }

    private fun clickNodeOrClickableParent(start: AccessibilityNodeInfo): Boolean {
        var curr: AccessibilityNodeInfo? = start
        var depth = 0
        while (curr != null && depth <= 3) {
            if (curr.isClickable && curr.performAction(AccessibilityNodeInfo.ACTION_CLICK)) {
                return true
            }
            curr = curr.parent
            depth++
        }
        return false
    }
}
