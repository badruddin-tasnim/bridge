package com.link.clipboardsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Stops Find My Phone ringing when the user taps the notification or its Stop action.
 */
class PhoneFinderActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == PhoneControlManager.ACTION_STOP_RING_PHONE) {
            PhoneControlManager.stopRinging(context)
        }
    }
}
