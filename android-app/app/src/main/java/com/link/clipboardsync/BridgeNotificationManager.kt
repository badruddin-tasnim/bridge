package com.link.clipboardsync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArraySet

object BridgeNotificationManager {

    private const val TAG = "BridgeNotifManager"
    const val CHANNEL_MAC_ALERTS = "bridge_mac_alerts"
    const val CHANNEL_MAC_ALERTS_SILENT = "bridge_mac_alerts_silent"
    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val postedMacAlertIds = CopyOnWriteArraySet<Int>()

    interface SettingsListener {
        fun onSettingsChanged()
    }

    private val settingsListeners = CopyOnWriteArraySet<SettingsListener>()

    fun addSettingsListener(listener: SettingsListener) {
        settingsListeners.add(listener)
    }

    fun removeSettingsListener(listener: SettingsListener) {
        settingsListeners.remove(listener)
    }

    fun notifySettingsChanged() {
        mainHandler.post {
            for (l in settingsListeners) {
                try {
                    l.onSettingsChanged()
                } catch (ignored: Exception) {}
            }
        }
    }

    fun init(context: Context) {
        appContext = context.applicationContext
        createNotificationChannel(context)
    }

    private fun createNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            val channel = NotificationChannel(
                CHANNEL_MAC_ALERTS,
                "Mac Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifications forwarded from your connected Mac"
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)

            val silentChannel = NotificationChannel(
                CHANNEL_MAC_ALERTS_SILENT,
                "Mac Alerts (Silent)",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Silent notifications forwarded from your connected Mac"
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(silentChannel)
        }
    }

    fun sendSettingsToMac(context: Context) {
        val client = ClipboardSyncManager.networkClient
        if (client != null && client.isConnected()) {
            val json = JSONObject().apply {
                put("type", "settings_sync")
                put("notifMasterEnabled", BridgePrefs.isNotifMasterEnabled(context))
                put("androidNotifEnabled", BridgePrefs.isAndroidNotifEnabled(context))
                put("macNotifEnabled", BridgePrefs.isMacNotifEnabled(context))
                put("updatedAt", BridgePrefs.getSettingsUpdatedAt(context))
            }
            client.sendRawJson(json.toString())
            Log.d(TAG, "Sent settings_sync to Mac: $json")
        }
    }

    fun cancelAllMacAlerts(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            for (id in postedMacAlertIds) {
                nm.cancel(id)
            }
            postedMacAlertIds.clear()
        } catch (ignored: Exception) {}
    }

    fun postToMac(notif: BridgeNotification) {
        val ctx = appContext
        if (ctx != null && !BridgePrefs.isNotificationSyncEnabled(ctx)) {
            return
        }
        val client = ClipboardSyncManager.networkClient
        if (client != null && client.isConnected()) {
            client.sendRawJson(notif.toPostJsonString())
            Log.d(TAG, "Forwarded notification to Mac: [${notif.app}] ${notif.title}")
        }
    }

    fun removeFromMac(key: String) {
        val client = ClipboardSyncManager.networkClient
        if (client != null && client.isConnected()) {
            val json = JSONObject()
            json.put("type", "notif_remove")
            json.put("id", key)
            json.put("timestamp", System.currentTimeMillis())
            client.sendRawJson(json.toString())
            Log.d(TAG, "Sent notification removal to Mac: $key")
        } else {
            Log.w(TAG, "Skipping removal to Mac (not connected): $key")
        }
    }

    private var installedAppCache: Set<String>? = null
    private var lastInstalledCacheTime = 0L

    fun getInstalledAppNames(context: Context): Set<String> {
        val now = System.currentTimeMillis()
        installedAppCache?.let {
            if (now - lastInstalledCacheTime < 60_000) return it
        }
        val names = HashSet<String>()
        try {
            val pm = context.packageManager
            val packages = pm.getInstalledApplications(0)
            for (app in packages) {
                val label = pm.getApplicationLabel(app).toString().trim().lowercase()
                if (label.isNotEmpty()) names.add(label)
                val pkg = app.packageName.trim().lowercase()
                names.add(pkg)
                val clean = label.replace(Regex("[^a-z0-9]"), "")
                if (clean.isNotEmpty()) names.add(clean)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get installed apps", e)
        }
        installedAppCache = names
        lastInstalledCacheTime = now
        return names
    }

    fun isAppInstalledOnDevice(context: Context, appName: String): Boolean {
        if (appName.isBlank()) return false
        val cleanName = appName.trim().lowercase()
        val cleanAlpha = cleanName.replace(Regex("[^a-z0-9]"), "")
        val installed = getInstalledAppNames(context)

        if (installed.contains(cleanName) || installed.contains(cleanAlpha)) {
            return true
        }
        return installed.any { installedName ->
            if (installedName.length >= 4 && cleanName.length >= 4) {
                installedName == cleanName || installedName.contains(cleanName) || cleanName.contains(installedName)
            } else {
                installedName == cleanName
            }
        }
    }

    fun handleIncomingPayload(context: Context, jsonString: String) {
        try {
            val json = JSONObject(jsonString)
            when (json.optString("type")) {
                "settings_sync" -> {
                    val remoteUpdatedAt = json.optLong("updatedAt", 0L)
                    val localUpdatedAt = BridgePrefs.getSettingsUpdatedAt(context)
                    if (remoteUpdatedAt > 0L && localUpdatedAt > remoteUpdatedAt) {
                        // Local Android settings are newer than Mac's handshake; push ours back
                        sendSettingsToMac(context)
                        return
                    }

                    if (json.has("notifMasterEnabled")) {
                        BridgePrefs.setNotifMasterEnabled(
                            context,
                            json.optBoolean("notifMasterEnabled", true),
                            updateTimestamp = false
                        )
                    }
                    if (json.has("androidNotifEnabled")) {
                        BridgePrefs.setAndroidNotifEnabled(
                            context,
                            json.optBoolean("androidNotifEnabled", true),
                            updateTimestamp = false
                        )
                    }
                    if (json.has("macNotifEnabled")) {
                        BridgePrefs.setMacNotifEnabled(
                            context,
                            json.optBoolean("macNotifEnabled", true),
                            updateTimestamp = false
                        )
                    }
                    if (remoteUpdatedAt > 0L) {
                        BridgePrefs.setSettingsUpdatedAt(context, remoteUpdatedAt)
                    }

                    if (!BridgePrefs.isMacAlertsEnabled(context)) {
                        cancelAllMacAlerts(context)
                    }
                    if (BridgePrefs.isNotificationSyncEnabled(context)) {
                        BridgeNotificationListenerService.instance?.syncActiveNotifications()
                    }
                    notifySettingsChanged()
                    Log.d(
                        TAG,
                        "Applied remote settings_sync: master=${BridgePrefs.isNotifMasterEnabled(context)}, android=${BridgePrefs.isAndroidNotifEnabled(context)}, mac=${BridgePrefs.isMacNotifEnabled(context)}"
                    )
                }
                "notif_action" -> {
                    val req = NotificationActionRequest.fromJson(json) ?: return
                    BridgeNotificationListenerService.instance?.executeAction(req.id, req.actionId, req.replyText)
                }
                "notif_dismiss" -> {
                    val req = NotificationDismissRequest.fromJson(json) ?: return
                    if (req.target == "android") {
                        BridgeNotificationListenerService.instance?.dismissNotification(req.id)
                    } else if (req.target == "mac") {
                        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        val nId = req.id.hashCode()
                        nm.cancel(nId)
                        postedMacAlertIds.remove(nId)
                    }
                }
                "notif_post" -> {
                    val notif = BridgeNotification.fromJson(json) ?: return
                    if (notif.source == "mac" && BridgePrefs.isMacAlertsEnabled(context)) {
                        if (isAppInstalledOnDevice(context, notif.app)) {
                            Log.d(TAG, "Dropping Mac alert for '${notif.app}': already installed on phone.")
                            return
                        }
                        showMacAlertNotification(context, notif)
                    }
                }
                "notif_remove" -> {
                    val id = json.optString("id")
                    if (id.isNotEmpty()) {
                        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        val nId = id.hashCode()
                        nm.cancel(nId)
                        postedMacAlertIds.remove(nId)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling incoming notification payload: ${e.message}", e)
        }
    }

    private fun showMacAlertNotification(context: Context, notif: BridgeNotification) {
        if (!BridgePrefs.isMacAlertsEnabled(context)) return

        val notifId = notif.id.hashCode()
        val vibrateEnabled = BridgePrefs.isPhoneVibrateEnabled(context)
        val channelId = if (vibrateEnabled) CHANNEL_MAC_ALERTS else CHANNEL_MAC_ALERTS_SILENT

        val dismissIntent = Intent(context, MacAlertDismissReceiver::class.java).apply {
            action = MacAlertDismissReceiver.ACTION_DISMISS_MAC_ALERT
            putExtra(MacAlertDismissReceiver.EXTRA_NOTIF_ID, notif.id)
        }
        val pDismiss = PendingIntent.getBroadcast(
            context,
            notifId,
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Clean native Android notification UI without square brackets
        val displayTitle = if (notif.title.isNotBlank()) notif.title else notif.app.ifEmpty { "Mac Alert" }
        val displaySubText = if (notif.app.isNotBlank()) notif.app else "Mac"

        var largeIcon: Bitmap? = null
        if (!notif.icon.isNullOrEmpty()) {
            try {
                val bytes = Base64.decode(notif.icon, Base64.DEFAULT)
                largeIcon = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to decode notification large icon: ${e.message}")
            }
        }

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(displayTitle)
            .setContentText(notif.text)
            .setSubText(displaySubText)
            .setStyle(NotificationCompat.BigTextStyle().bigText(notif.text))
            .setPriority(if (vibrateEnabled) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_LOW)
            .setSilent(!vibrateEnabled)
            .setAutoCancel(true)
            .setDeleteIntent(pDismiss)
            .addAction(0, "Dismiss on Mac", pDismiss)

        if (largeIcon != null) {
            builder.setLargeIcon(largeIcon)
        }

        try {
            val nm = NotificationManagerCompat.from(context)
            nm.notify(notifId, builder.build())
            postedMacAlertIds.add(notifId)
            Log.d(TAG, "Displayed Mac alert on phone: [${notif.app}] $displayTitle")
        } catch (e: SecurityException) {
            Log.w(TAG, "POST_NOTIFICATIONS permission not granted: ${e.message}")
        }
    }
}
