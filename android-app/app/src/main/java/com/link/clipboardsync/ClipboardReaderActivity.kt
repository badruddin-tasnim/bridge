package com.link.clipboardsync

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

class ClipboardReaderActivity : Activity() {

    companion object {
        private const val TAG = "ClipboardReaderActivity"
        private val RETRY_DELAYS_MS = longArrayOf(0L, 80L, 180L, 300L, 450L)
        private const val WATCHDOG_TIMEOUT_MS = 650L
    }

    private var isFinished = false
    private var focusReadStarted = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)
        scheduleWatchdogAndResumeFallback()
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        overridePendingTransition(0, 0)
        handler.removeCallbacksAndMessages(null)
        isFinished = false
        focusReadStarted = false
        scheduleWatchdogAndResumeFallback()
        tryReadClipboard(0)
    }

    override fun onResume() {
        super.onResume()
        overridePendingTransition(0, 0)
        handler.postDelayed({
            if (!focusReadStarted && !isFinished) {
                focusReadStarted = true
                tryReadClipboard(0)
            }
        }, 70L)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !focusReadStarted && !isFinished) {
            focusReadStarted = true
            tryReadClipboard(0)
        }
    }

    private fun scheduleWatchdogAndResumeFallback() {
        handler.postDelayed({
            if (!isFinished) {
                tryReadClipboard(RETRY_DELAYS_MS.size - 1)
                finishSilently()
            }
        }, WATCHDOG_TIMEOUT_MS)
    }

    private fun tryReadClipboard(attemptIdx: Int) {
        if (isFinished) return

        var dispatched = false
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip != null && clip.itemCount > 0) {
                dispatched = ClipboardSyncManager.extractAndDispatchClipboard(
                    this,
                    clip,
                    "ClipboardReaderActivity#${attemptIdx + 1}"
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read clipboard in focused activity (attempt ${attemptIdx + 1}): ${e.message}")
        }

        if (dispatched || attemptIdx >= RETRY_DELAYS_MS.size - 1) {
            finishSilently()
        } else {
            val nextIdx = attemptIdx + 1
            val delay = (RETRY_DELAYS_MS[nextIdx] - RETRY_DELAYS_MS[attemptIdx]).coerceAtLeast(40L)
            handler.postDelayed({
                tryReadClipboard(nextIdx)
            }, delay)
        }
    }

    private fun finishSilently() {
        if (isFinished) return
        isFinished = true
        handler.removeCallbacksAndMessages(null)
        finish()
        overridePendingTransition(0, 0)
    }

    override fun onPause() {
        super.onPause()
        overridePendingTransition(0, 0)
    }
}
