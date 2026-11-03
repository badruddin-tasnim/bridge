package com.link.clipboardsync

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class MacAlertDismissReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "MacAlertDismissReceiver"
        const val ACTION_DISMISS_MAC_ALERT = "com.link.clipboardsync.ACTION_DISMISS_MAC_ALERT"
        const val EXTRA_NOTIF_ID = "extra_notif_id"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return
        if (intent.action == ACTION_DISMISS_MAC_ALERT) {
            val notifId = intent.getStringExtra(EXTRA_NOTIF_ID) ?: return
            Log.d(TAG, "User dismissed Mac alert: $notifId. Forwarding dismiss to Mac.")

            // Cancel on phone
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(notifId.hashCode())

            // Notify Mac to close its banner
            val dismissReq = NotificationDismissRequest(id = notifId, target = "mac")
            ClipboardSyncManager.networkClient?.sendRawJson(dismissReq.toJsonString())
        }
    }
}
