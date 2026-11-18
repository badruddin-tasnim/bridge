package com.link.clipboardsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Stops active Phone Mirroring when the user taps Stop in the ongoing notification.
 */
class ScreenMirrorActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == ScreenMirrorForegroundService.ACTION_STOP_MIRRORING) {
            PhoneMirrorController.stopMirroring(context, reason = "user_stopped_notification", notifyMac = true)
        }
    }
}
