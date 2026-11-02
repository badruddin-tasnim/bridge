package com.link.clipboardsync

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.util.Log
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

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "Accessibility Service Connected.")

        serviceInfo = AccessibilityServiceInfo().apply {
            eventTypes = AccessibilityEvent.TYPE_VIEW_CLICKED or AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
            feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            notificationTimeout = 20
            flags = AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                    AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }

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
        instance = null
        Log.i(TAG, "Accessibility Service Destroyed.")
    }
}
