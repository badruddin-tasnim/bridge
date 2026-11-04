package com.link.clipboardsync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * connectedDevice foreground service: keeps the socket to the Mac alive while the app
 * is in the background (prevents Samsung FreecessController from freezing the process)
 * and writes incoming Mac clipboard text into the Android clipboard.
 */
class ClipboardSyncForegroundService : Service(), NetworkSyncClient.SyncListener {

    companion object {
        private const val TAG = "ClipboardSyncFGService"
        private const val NOTIFICATION_ID = 101
        private const val CHANNEL_ID = "bridge_connection"

        @Volatile
        var isRunning = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, ClipboardSyncForegroundService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start foreground service: ${e.message}")
            }
        }
    }

    private lateinit var clipboardManager: ClipboardManager
    private var wifiLock: WifiManager.WifiLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        startForegroundWithNotification(initialStatus())

        // High-performance Wi-Fi lock so the radio doesn't drop the idle socket
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Bridge::WifiLock").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not acquire WifiLock: ${e.message}")
        }

        ClipboardSyncManager.init(this)
        ClipboardSyncManager.networkClient?.addListener(this)
        UpdateChecker.startPeriodicChecks(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    private fun initialStatus(): String =
        if (BridgePrefs.isPaired(this)) "Connecting to ${BridgePrefs.macName(this) ?: "Mac"}…"
        else "Not paired — open Bridge to connect your Mac"

    private fun startForegroundWithNotification(statusText: String) {
        createNotificationChannel()
        val notification = buildNotification(statusText)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MANIFEST)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed startForeground: ${e.message}", e)
        }
    }

    private fun updateNotification(statusText: String) {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(statusText))
        } catch (ignored: Exception) {}
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Keeps Bridge connected to your Mac in the background"
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(statusText: String): Notification {
        val pApp = PendingIntent.getActivity(
            this, 20, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Bridge")
            .setContentText(statusText)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(pApp)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
    }

    override fun onConnectionStatusChanged(isConnected: Boolean, host: String?) {
        mainHandler.post {
            val name = BridgePrefs.macName(this) ?: "Mac"
            updateNotification(
                when {
                    !BridgePrefs.isPaired(this) && !isConnected -> initialStatus()
                    isConnected -> "Connected with $name"
                    else -> "Reconnecting to $name…"
                }
            )
        }
    }

    override fun onPairingResult(accepted: Boolean, macName: String?) {
        if (accepted) {
            BridgePrefs.markPaired(this, macName)
            mainHandler.post {
                val name = BridgePrefs.macName(this) ?: "Mac"
                if (ClipboardSyncManager.networkClient?.isConnected() == true) {
                    updateNotification("Connected with $name")
                }
            }
        }
    }

    override fun onRemoteUnpair() {
        mainHandler.post {
            updateNotification(initialStatus())
        }
    }

    override fun onConnectionFailed(consecutiveFailures: Int) {
        if (consecutiveFailures >= 2) {
            mainHandler.post {
                updateNotification("Cannot reach Mac: check that both are on same Wi-Fi")
            }
        }
    }

    override fun onPayloadReceived(payload: ClipboardPayload) {
        when (payload.type) {
            "clip" -> {
                val text = payload.text
                if (text.isEmpty()) return
                val hash = payload.hash.ifEmpty { ClipboardPayload.computeSHA256(text) }

                if (hash == ClipboardSyncManager.lastSentHash || hash == ClipboardSyncManager.lastReceivedHash) {
                    return
                }

                mainHandler.post {
                    try {
                        ClipboardSyncManager.lastReceivedHash = hash
                        ClipboardSyncManager.isInternalMutation = true
                        clipboardManager.setPrimaryClip(ClipData.newPlainText("Bridge", text))
                        ClipboardSyncManager.recordHistory(text, outgoing = false)
                        Log.d(TAG, "Injected remote clipboard into Android (${text.length} chars, hash: ${hash.take(8)})")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to set clipboard: ${e.message}", e)
                        ClipboardSyncManager.isInternalMutation = false
                    }
                }
            }

            "image" -> {
                val base64Data = payload.data ?: return
                if (base64Data.length > 25 * 1024 * 1024) return
                try {
                    val bytes = Base64.decode(base64Data, Base64.DEFAULT)
                    if (bytes.isEmpty()) return
                    val hash = payload.hash.ifEmpty { ClipboardPayload.computeSHA256(bytes) }

                    if (hash == ClipboardSyncManager.lastSentHash || hash == ClipboardSyncManager.lastReceivedHash) {
                        return
                    }

                    val mime = payload.mime ?: "image/jpeg"
                    val imageUri = ClipboardImageProvider.saveImageAndGetUri(this, bytes, mime) ?: return

                    mainHandler.post {
                        try {
                            ClipboardSyncManager.lastReceivedHash = hash
                            ClipboardSyncManager.lastRawImageHash = hash
                            ClipboardSyncManager.isInternalMutation = true
                            val clipData = ClipData.newUri(contentResolver, "Bridge Image", imageUri)
                            clipboardManager.setPrimaryClip(clipData)
                            ClipboardSyncManager.recordHistory("[Image]", outgoing = false)
                            Log.d(TAG, "Injected remote image into Android (${bytes.size / 1024} KB, hash=${hash.take(8)})")
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to set image clipboard: ${e.message}", e)
                            ClipboardSyncManager.isInternalMutation = false
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to decode incoming image payload: ${e.message}", e)
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        isRunning = false
        try { wifiLock?.release() } catch (ignored: Exception) {}
        ClipboardSyncManager.networkClient?.removeListener(this)
    }
}
