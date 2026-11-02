package com.link.clipboardsync

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

class ClipboardReaderActivity : Activity() {

    companion object {
        private const val TAG = "ClipboardReaderActivity"
        private const val MAX_ATTEMPTS = 3
        private const val RETRY_DELAY_MS = 110L
    }

    private var isFinished = false
    private var focusReadStarted = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)

        // Safety watchdog: ensure the invisible activity always closes quickly
        handler.postDelayed({
            if (!isFinished) {
                tryReadClipboard(MAX_ATTEMPTS)
            }
        }, 380)
    }

    override fun onResume() {
        super.onResume()
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !focusReadStarted && !isFinished) {
            focusReadStarted = true
            tryReadClipboard(1)
        }
    }

    private fun tryReadClipboard(attempt: Int) {
        if (isFinished) return

        var dispatched = false
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip != null && clip.itemCount > 0) {
                dispatched = ClipboardSyncManager.extractAndDispatchClipboard(
                    this,
                    clip,
                    "ClipboardReaderActivity#$attempt"
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read clipboard in focused activity (attempt $attempt): ${e.message}")
        }

        if (dispatched || attempt >= MAX_ATTEMPTS) {
            finishSilently()
        } else {
            // Some apps (Chrome, Gallery) write copied images asynchronously ~80-200ms after tapping "Copy image"
            handler.postDelayed({
                tryReadClipboard(attempt + 1)
            }, RETRY_DELAY_MS)
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
