package com.link.clipboardsync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class FileTransferActionReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "FileTransferAction"
        const val ACTION_ACCEPT_TRANSFER = "com.link.clipboardsync.ACTION_ACCEPT_TRANSFER"
        const val ACTION_DECLINE_TRANSFER = "com.link.clipboardsync.ACTION_DECLINE_TRANSFER"
        const val EXTRA_TRANSFER_ID = "extra_transfer_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val transferId = intent.getStringExtra(EXTRA_TRANSFER_ID) ?: return
        Log.d(TAG, "Received transfer action: ${intent.action} for id: $transferId")

        BridgeFileTransferManager.dismissPromptNotification(context, transferId)

        when (intent.action) {
            ACTION_ACCEPT_TRANSFER -> {
                BridgeFileTransferManager.acceptIncomingFile(context, transferId)
            }
            ACTION_DECLINE_TRANSFER -> {
                BridgeFileTransferManager.cancelTransfer(transferId, notifyPeer = true)
            }
        }
    }
}
