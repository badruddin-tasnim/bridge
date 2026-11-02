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
    }

    private var hasRead = false
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overridePendingTransition(0, 0)

        // Safety watchdog: Automatically finish after 250ms
        handler.postDelayed({
            if (!hasRead) {
                readClipboardAndFinish()
            }
        }, 250)
    }

    override fun onResume() {
        super.onResume()
        overridePendingTransition(0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !hasRead) {
            readClipboardAndFinish()
        }
    }

    private fun readClipboardAndFinish() {
        if (hasRead) return
        hasRead = true

        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = cm.primaryClip
            if (clip != null && clip.itemCount > 0) {
                val item = clip.getItemAt(0)
                val text = item.coerceToText(this)?.toString()
                if (!text.isNullOrEmpty()) {
                    Log.d(TAG, "Successfully read clipboard with window focus (${text.length} chars)")
                    ClipboardSyncManager.dispatchTextToMac(applicationContext, text, "ClipboardReaderActivity")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read clipboard in focused activity: ${e.message}")
        } finally {
            finish()
            overridePendingTransition(0, 0)
        }
    }

    override fun onPause() {
        super.onPause()
        overridePendingTransition(0, 0)
    }
}
