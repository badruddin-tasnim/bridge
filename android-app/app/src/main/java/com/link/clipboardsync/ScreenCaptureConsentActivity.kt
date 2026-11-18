package com.link.clipboardsync

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import android.util.Log

/**
 * Transparent 0-ms trampoline activity that presents the system MediaProjection
 * consent dialog and forwards the result token directly to [PhoneMirrorController].
 */
class ScreenCaptureConsentActivity : Activity() {

    companion object {
        private const val TAG = "ScreenConsentActivity"
        private const val REQ_MEDIA_PROJECTION = 5101
    }

    private var dispatchedResult = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (projectionManager == null) {
            Log.e(TAG, "MediaProjectionManager unavailable")
            dispatchedResult = true
            PhoneMirrorController.onConsentDenied(this)
            finish()
            return
        }

        try {
            @Suppress("DEPRECATION")
            startActivityForResult(projectionManager.createScreenCaptureIntent(), REQ_MEDIA_PROJECTION)
        } catch (e: Exception) {
            Log.e(TAG, "Failed launching screen capture consent intent: ${e.message}")
            dispatchedResult = true
            PhoneMirrorController.onConsentDenied(this)
            finish()
        }
    }

    @Deprecated("Required for MediaProjection result without ComponentActivity bloat on translucent Activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_MEDIA_PROJECTION) return
        dispatchedResult = true
        if (resultCode == RESULT_OK && data != null) {
            PhoneMirrorController.onConsentGranted(this, resultCode, data)
        } else {
            PhoneMirrorController.onConsentDenied(this)
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        super.onDestroy()
        if (!dispatchedResult && isFinishing) {
            PhoneMirrorController.onConsentDenied(this)
        }
    }
}
