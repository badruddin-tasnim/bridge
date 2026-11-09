package com.link.clipboardsync

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

class BridgeNotificationListenerService : NotificationListenerService() {

    companion object {
        private const val TAG = "BridgeNotifListener"

        @Volatile
        var instance: BridgeNotificationListenerService? = null
            private set

        fun isListening(): Boolean = instance != null

        // Cache active actions: normalizedKey -> map(actionIndex -> ActionHolder)
        private val actionCache = ConcurrentHashMap<String, ConcurrentHashMap<Int, ActionHolder>>()
        private val rawKeyMap = ConcurrentHashMap<String, String>()

        // Cache app icons to avoid re-encoding every time (pkg -> base64)
        private val iconCache = ConcurrentHashMap<String, String>()

        // Cache recent posted notifications to prevent rapid-fire duplicate events
        private val recentPosted = ConcurrentHashMap<String, Long>()
        private val lastSeenTextByNormKey = ConcurrentHashMap<String, String>()
        private val messageHistoryByNormKey = ConcurrentHashMap<String, MutableList<BridgeMessageItem>>()

        fun normalizeKey(raw: String): String =
            raw.replace("\r", "").replace("\n", "").trim()

        fun extractBaseKey(key: String): String {
            return when {
                key.contains("|msg_") -> key.substringBefore("|msg_")
                key.contains("|line_") -> key.substringBefore("|line_")
                key.contains("|upd_") -> key.substringBefore("|upd_")
                else -> key
            }
        }

        data class ActionHolder(
            val action: Notification.Action,
            val remoteInputs: Array<RemoteInput>?
        )
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "Bridge Notification Listener connected.")
        syncActiveNotifications()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        instance = null
        actionCache.clear()
        rawKeyMap.clear()
        lastSeenTextByNormKey.clear()
        messageHistoryByNormKey.clear()
        Log.i(TAG, "Bridge Notification Listener disconnected.")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        processNotificationPosted(sbn, isFullSync = false)
    }

    private fun processNotificationPosted(sbn: StatusBarNotification?, isFullSync: Boolean) {
        if (sbn == null) return
        if (!BridgePrefs.isNotificationSyncEnabled(this)) return

        val pkg = sbn.packageName ?: return
        if (pkg == packageName) return // Don't mirror Bridge's own notifications

        if (BridgePrefs.isAppBlacklisted(this, pkg)) {
            Log.d(TAG, "Skipping notification from blacklisted app: $pkg")
            return
        }

        val notif = sbn.notification ?: return
        val rawKey = sbn.key ?: return
        val normKey = normalizeKey(rawKey)
        rawKeyMap[normKey] = rawKey

        // Filter out group summary notifications to prevent duplicate summary cards on Mac
        val isGroupSummary = (notif.flags and Notification.FLAG_GROUP_SUMMARY) != 0
        if (isGroupSummary) {
            Log.d(TAG, "Ignoring group summary notification: $normKey ($pkg)")
            return
        }

        // Filter out persistent / foreground service ongoing banners (unless active call or chat message)
        val isOngoing = (notif.flags and Notification.FLAG_ONGOING_EVENT) != 0 ||
                (notif.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0 ||
                (notif.flags and Notification.FLAG_NO_CLEAR) != 0

        val category = notif.category
        val isCallOrMsg = category == Notification.CATEGORY_CALL ||
                category == Notification.CATEGORY_MESSAGE ||
                category == Notification.CATEGORY_EVENT

        if (isOngoing && !isCallOrMsg) {
            return
        }

        val extras = notif.extras ?: Bundle()
        val defaultTitle = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString()
            ?: ""

        val defaultText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()
            ?: ""

        val appLabel = try {
            val pm = packageManager
            val info = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(info).toString()
        } catch (e: Exception) {
            pkg
        }

        val iconBase64 = getOrEncodeAppIcon(pkg)

        // Parse notification actions
        val actionsList = ArrayList<BridgeNotificationAction>()
        val actionsMap = ConcurrentHashMap<Int, ActionHolder>()

        val notifActions = notif.actions
        if (notifActions != null) {
            for (i in notifActions.indices) {
                val action = notifActions[i] ?: continue
                val actionTitle = action.title?.toString() ?: ""
                if (actionTitle.isBlank()) continue

                val remoteInputs = action.remoteInputs
                val hasInput = remoteInputs != null && remoteInputs.isNotEmpty()
                val placeholder = if (hasInput) remoteInputs?.firstOrNull()?.label?.toString() else null

                actionsList.add(
                    BridgeNotificationAction(
                        id = i,
                        title = actionTitle,
                        hasInput = hasInput,
                        placeholder = placeholder
                    )
                )
                actionsMap[i] = ActionHolder(action, remoteInputs)
            }
        }

        actionCache[normKey] = actionsMap

        // 1. Check for MessagingStyle (WhatsApp, Messenger, Telegram, Messages, Signal, Slack, etc.)
        val messagingStyle = try {
            NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(notif)
        } catch (e: Exception) {
            null
        }

        if (messagingStyle != null && messagingStyle.messages.isNotEmpty()) {
            val conversationTitle = messagingStyle.conversationTitle?.toString()
            val isGroup = messagingStyle.isGroupConversation || !conversationTitle.isNullOrBlank()
            val messages = messagingStyle.messages
            val messageItems = ArrayList<BridgeMessageItem>()

            for (msg in messages) {
                var msgText = msg.text?.toString() ?: ""
                if (msgText.isBlank()) {
                    if (msg.dataMimeType != null) {
                        msgText = "[Attachment]"
                    } else {
                        continue
                    }
                }

                val senderPerson = msg.person
                val senderName = senderPerson?.name?.toString() ?: msg.sender?.toString()
                val msgTime = if (msg.timestamp > 0) msg.timestamp else sbn.postTime
                messageItems.add(BridgeMessageItem(text = msgText, timestamp = msgTime, sender = senderName))
            }

            if (messageItems.isNotEmpty()) {
                val cardTitle = when {
                    !conversationTitle.isNullOrBlank() -> conversationTitle
                    !messageItems.last().sender.isNullOrBlank() -> messageItems.last().sender!!
                    defaultTitle.isNotBlank() -> defaultTitle
                    else -> appLabel
                }

                val combinedText = messageItems.joinToString("\n") { item ->
                    if (isGroup && !item.sender.isNullOrBlank()) {
                        "${item.sender}: ${item.text}"
                    } else {
                        item.text
                    }
                }

                if (!isFullSync) {
                    val dedupeKey = "$normKey|$cardTitle|$combinedText"
                    val now = System.currentTimeMillis()
                    val last = recentPosted[dedupeKey] ?: 0L
                    if (now - last < 2500) {
                        Log.d(TAG, "Deduplicating duplicate notification event: $dedupeKey")
                        return
                    }
                    recentPosted[dedupeKey] = now
                    if (recentPosted.size > 100) {
                        val cutoff = now - 15000
                        recentPosted.entries.removeIf { it.value < cutoff }
                    }
                }

                val lastMsgTime = messageItems.last().timestamp
                val bridgeNotif = BridgeNotification(
                    id = normKey,
                    source = "android",
                    pkg = pkg,
                    app = appLabel,
                    title = cardTitle,
                    text = combinedText,
                    icon = iconBase64,
                    timestamp = lastMsgTime,
                    actions = actionsList,
                    isSilent = isFullSync,
                    messages = messageItems
                )
                BridgeNotificationManager.postToMac(bridgeNotif)
                return
            }
        }

        // 2. Check for InboxStyle (Gmail, Samsung Email, etc. with multiple text lines)
        val textLines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
        if (textLines != null && textLines.isNotEmpty()) {
            val messageItems = ArrayList<BridgeMessageItem>()
            for (line in textLines) {
                val lineStr = line?.toString() ?: continue
                if (lineStr.isBlank()) continue
                messageItems.add(BridgeMessageItem(text = lineStr, timestamp = sbn.postTime))
            }

            if (messageItems.isNotEmpty()) {
                val cardTitle = if (defaultTitle.isNotBlank()) defaultTitle else appLabel
                val combinedText = messageItems.joinToString("\n") { it.text }

                if (!isFullSync) {
                    val dedupeKey = "$normKey|$cardTitle|$combinedText"
                    val now = System.currentTimeMillis()
                    val last = recentPosted[dedupeKey] ?: 0L
                    if (now - last < 2500) {
                        Log.d(TAG, "Deduplicating duplicate notification event: $dedupeKey")
                        return
                    }
                    recentPosted[dedupeKey] = now
                    if (recentPosted.size > 100) {
                        val cutoff = now - 15000
                        recentPosted.entries.removeIf { it.value < cutoff }
                    }
                }

                val bridgeNotif = BridgeNotification(
                    id = normKey,
                    source = "android",
                    pkg = pkg,
                    app = appLabel,
                    title = cardTitle,
                    text = combinedText,
                    icon = iconBase64,
                    timestamp = sbn.postTime,
                    actions = actionsList,
                    isSilent = isFullSync,
                    messages = messageItems
                )
                BridgeNotificationManager.postToMac(bridgeNotif)
                return
            }
        }

        // 3. Standard Notification / Non-MessagingStyle Updates
        if (defaultTitle.isBlank() && defaultText.isBlank()) return

        val isProgress = extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0) > 0 ||
                extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE, false) ||
                category == Notification.CATEGORY_PROGRESS

        val history = messageHistoryByNormKey.computeIfAbsent(normKey) { ArrayList() }
        var messagesToSend: List<BridgeMessageItem>? = null
        var textToSend = defaultText

        if (!isProgress && defaultText.isNotBlank()) {
            synchronized(history) {
                if (history.isEmpty() || history.last().text != defaultText) {
                    history.add(BridgeMessageItem(text = defaultText, timestamp = sbn.postTime))
                    if (history.size > 20) {
                        history.removeAt(0)
                    }
                }
                if (history.size > 1) {
                    messagesToSend = ArrayList(history)
                    textToSend = history.joinToString("\n") { it.text }
                }
            }
        }

        val cardTitle = if (defaultTitle.isNotBlank()) defaultTitle else appLabel

        if (!isFullSync) {
            val dedupeKey = "$normKey|$cardTitle|$textToSend"
            val now = System.currentTimeMillis()
            val last = recentPosted[dedupeKey] ?: 0L
            if (now - last < 2500) {
                Log.d(TAG, "Deduplicating duplicate notification event: $dedupeKey")
                return
            }
            recentPosted[dedupeKey] = now
            if (recentPosted.size > 100) {
                val cutoff = now - 15000
                recentPosted.entries.removeIf { it.value < cutoff }
            }
        }

        val bridgeNotif = BridgeNotification(
            id = normKey,
            source = "android",
            pkg = pkg,
            app = appLabel,
            title = cardTitle,
            text = textToSend,
            icon = iconBase64,
            timestamp = sbn.postTime,
            actions = actionsList,
            isSilent = isFullSync,
            messages = messagesToSend
        )

        BridgeNotificationManager.postToMac(bridgeNotif)
    }

    private val recentRemovals = ConcurrentHashMap<String, Long>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val reconcileRunnable = Runnable {
        BridgeNotificationManager.syncActiveIdsToMac(getActiveNormalizedKeys())
    }

    private fun isMirrorableNotification(sbn: StatusBarNotification): Boolean {
        val pkg = sbn.packageName ?: return false
        if (pkg == packageName) return false
        if (BridgePrefs.isAppBlacklisted(this, pkg)) return false
        val notif = sbn.notification ?: return false
        if ((notif.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return false
        val isOngoing = (notif.flags and Notification.FLAG_ONGOING_EVENT) != 0 ||
                (notif.flags and Notification.FLAG_FOREGROUND_SERVICE) != 0 ||
                (notif.flags and Notification.FLAG_NO_CLEAR) != 0
        val category = notif.category
        val isCallOrMsg = category == Notification.CATEGORY_CALL ||
                category == Notification.CATEGORY_MESSAGE ||
                category == Notification.CATEGORY_EVENT
        if (isOngoing && !isCallOrMsg) return false
        return true
    }

    private fun getActiveNormalizedKeys(excludingKey: String? = null): List<String> {
        return try {
            val sbns = activeNotifications ?: return emptyList()
            val result = ArrayList<String>()
            for (item in sbns) {
                val k = item.key ?: continue
                val norm = normalizeKey(k)
                if (norm == excludingKey) continue
                if (!isMirrorableNotification(item)) continue
                result.add(norm)
            }
            result
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun handleNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val rawKey = sbn.key ?: return
        val normKey = normalizeKey(rawKey)
        val now = System.currentTimeMillis()
        val last = recentRemovals[normKey] ?: 0L
        if (now - last < 400) {
            return
        }
        recentRemovals[normKey] = now
        if (recentRemovals.size > 100) {
            val cutoff = now - 5000
            recentRemovals.entries.removeIf { it.value < cutoff }
        }

        val pkg = sbn.packageName ?: ""
        val extras = sbn.notification?.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()
            ?: extras?.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString()
            ?: ""
        val text = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()
            ?: ""

        Log.d(TAG, "Notification removed on device: $normKey ($pkg)")
        actionCache.remove(normKey)
        rawKeyMap.remove(normKey)
        lastSeenTextByNormKey.remove(normKey)
        messageHistoryByNormKey.remove(normKey)
        val remainingActive = getActiveNormalizedKeys(excludingKey = normKey)
        BridgeNotificationManager.removeFromMac(
            key = normKey,
            pkg = pkg,
            title = title,
            text = text,
            activeIds = remainingActive
        )
        mainHandler.removeCallbacks(reconcileRunnable)
        mainHandler.postDelayed(reconcileRunnable, 400)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        handleNotificationRemoved(sbn)
    }

    override fun onNotificationRemoved(
        sbn: StatusBarNotification?,
        rankingMap: RankingMap?,
        reason: Int
    ) {
        super.onNotificationRemoved(sbn, rankingMap, reason)
        handleNotificationRemoved(sbn)
    }

    fun syncActiveIdsOnly() {
        if (!BridgePrefs.isNotificationSyncEnabled(this)) return
        try {
            val activeKeys = getActiveNormalizedKeys()
            BridgeNotificationManager.syncActiveIdsToMac(activeKeys)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to sync active notification IDs: ${e.message}")
        }
    }

    fun syncActiveNotifications() {
        if (!BridgePrefs.isNotificationSyncEnabled(this)) return
        try {
            val activeSBNS = activeNotifications ?: return
            val activeKeys = getActiveNormalizedKeys()
            BridgeNotificationManager.syncActiveIdsToMac(activeKeys)
            Log.d(TAG, "Syncing active notifications: count=${activeSBNS.size}")
            for (sbn in activeSBNS) {
                processNotificationPosted(sbn, isFullSync = true)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to sync active notifications: ${e.message}")
        }
    }

    fun executeAction(key: String, actionId: Int, replyText: String?): Boolean {
        val normKey = normalizeKey(key)
        val baseKey = extractBaseKey(normKey)
        val actionsMap = actionCache[baseKey] ?: actionCache[normKey] ?: actionCache[key] ?: return false
        val holder = actionsMap[actionId] ?: return false

        return try {
            if (!replyText.isNullOrBlank() && holder.remoteInputs != null) {
                val intent = Intent()
                val bundle = Bundle()
                for (input in holder.remoteInputs) {
                    bundle.putCharSequence(input.resultKey, replyText)
                }
                RemoteInput.addResultsToIntent(holder.remoteInputs, intent, bundle)
                holder.action.actionIntent.send(this, 0, intent)
                Log.d(TAG, "Sent reply text for notification: $baseKey (action $actionId)")
            } else {
                holder.action.actionIntent.send()
                Log.d(TAG, "Triggered action click for notification: $baseKey (action $actionId)")
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to execute action on $baseKey: ${e.message}", e)
            false
        }
    }

    fun dismissNotification(key: String) {
        val normKey = normalizeKey(key)
        val baseKey = extractBaseKey(normKey)
        val targetRawKey = rawKeyMap[baseKey] ?: rawKeyMap[normKey] ?: key
        try {
            cancelNotification(targetRawKey)
            actionCache.remove(baseKey)
            actionCache.remove(normKey)
            rawKeyMap.remove(baseKey)
            rawKeyMap.remove(normKey)
            lastSeenTextByNormKey.remove(baseKey)
            lastSeenTextByNormKey.remove(normKey)
            Log.d(TAG, "Canceled notification: $baseKey (targetRawKey=$targetRawKey)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cancel notification $baseKey: ${e.message}")
        }
    }

    private fun getOrEncodeAppIcon(packageName: String): String? {
        iconCache[packageName]?.let { return it }

        return try {
            val drawable = packageManager.getApplicationIcon(packageName)
            val bitmap = drawableToBitmap(drawable) ?: return null
            val scaled = Bitmap.createScaledBitmap(bitmap, 72, 72, true)
            val stream = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.PNG, 85, stream)
            val base64 = Base64.encodeToString(stream.toByteArray(), Base64.NO_WRAP)
            iconCache[packageName] = base64
            base64
        } catch (e: Exception) {
            null
        }
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap? {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return drawable.bitmap
        }
        val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 72
        val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 72
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
