package com.link.clipboardsync

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityOptions
import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.service.notification.StatusBarNotification
import android.telecom.TelecomManager
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Chronometer
import android.widget.FrameLayout
import android.widget.RemoteViews
import android.widget.TextView
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

/**
 * Detects live incoming/active calls via NotificationListenerService (CATEGORY_CALL / CallStyle /
 * Samsung InCallUI RemoteViews), emits encrypted call_event frames to Mac, and executes
 * Answer / Decline / Silence / Mute actions.
 */
object PhoneCallMonitor {
    private const val TAG = "PhoneCallMonitor"

    private val KNOWN_DIALER_PACKAGES = setOf(
        "com.samsung.android.incallui",
        "com.samsung.android.dialer",
        "com.google.android.dialer",
        "com.android.incallui",
        "com.android.dialer",
        "com.android.phone",
        "com.android.server.telecom"
    )

    private val GENERIC_CALL_LABELS = setOf(
        "call", "calls", "phone", "phone call",
        "incoming call", "incoming voice call", "incoming video call",
        "incoming hd call", "incoming wi-fi call", "incoming wifi call",
        "ongoing call", "ongoing voice call", "ongoing video call",
        "active call", "current call", "call in progress",
        "voice call", "video call", "hd call", "wi-fi call", "wifi call",
        "volte", "dialing", "calling", "ringing", "connected", "connecting",
        "on hold", "hold", "answer", "accept", "pick up",
        "decline", "reject", "dismiss", "end", "end call", "hang up",
        "mute", "unmute", "silence", "speaker", "keypad", "bluetooth",
        "add call", "record", "sim 1", "sim 2", "sim1", "sim2",
        "return to call", "tap to return to call", "calling via wi-fi",
        "wifi calling", "wi-fi calling", "unknown", "private number"
    )

    private val TIMER_REGEX = Regex("""^\d{1,2}:\d{2}(:\d{2})?$""")

    private val CALLER_PREFIXES = listOf(
        "incoming voice call from ",
        "incoming video call from ",
        "incoming call from ",
        "ongoing call with ",
        "call from ",
        "calling "
    )

    private data class TrackedCall(
        val callId: String,
        val pkg: String,
        val appName: String,
        val callerName: String,
        val state: String,
        val isMuted: Boolean,
        val connectedAtEpochMs: Long?,
        val answerIntent: PendingIntent?,
        val declineIntent: PendingIntent?,
        val silenceIntent: PendingIntent?,
        val muteIntent: PendingIntent?,
        val answerView: View?,
        val declineView: View?,
        val muteView: View?,
        val silenceView: View?
    )

    private data class RemoteViewsInspection(
        val priorityTexts: List<String> = emptyList(),
        val secondaryTexts: List<String> = emptyList(),
        val allLowerTexts: String = "",
        val answerIntent: PendingIntent? = null,
        val declineIntent: PendingIntent? = null,
        val silenceIntent: PendingIntent? = null,
        val muteIntent: PendingIntent? = null,
        val answerView: View? = null,
        val declineView: View? = null,
        val silenceView: View? = null,
        val muteView: View? = null
    )

    private val activeCalls = ConcurrentHashMap<String, TrackedCall>()
    private val silencedCallIds = ConcurrentHashMap.newKeySet<String>()
    private val appIconCache = ConcurrentHashMap<String, String>()
    private val pendingRequeryRunnables = ConcurrentHashMap<String, MutableList<Runnable>>()
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    fun normalizeCallAppName(pkg: String, rawAppLabel: String): String {
        val trimmed = rawAppLabel.trim()
        if (pkg.lowercase(Locale.ROOT) in KNOWN_DIALER_PACKAGES ||
            trimmed.equals("call", ignoreCase = true)
        ) {
            return "Phone"
        }
        return trimmed.ifBlank { "Phone" }
    }

    fun cleanCallerCandidate(raw: String?): String {
        if (raw == null) return ""
        var text = raw.replace('\n', ' ').replace('\r', ' ').trim()
        if (text.isEmpty()) return ""
        val lower = text.lowercase(Locale.ROOT)
        for (prefix in CALLER_PREFIXES) {
            if (lower.startsWith(prefix) && text.length > prefix.length) {
                text = text.substring(prefix.length).trim()
                break
            }
        }
        return text
    }

    fun isGenericCallLabel(raw: String?, appName: String = ""): Boolean {
        val trimmed = raw?.trim()?.trimEnd('.', '…')?.trim() ?: return true
        if (trimmed.isEmpty()) return true
        if (appName.isNotBlank() && trimmed.equals(appName.trim(), ignoreCase = true)) {
            return true
        }
        if (TIMER_REGEX.matches(trimmed)) {
            return true
        }
        val lower = trimmed.lowercase(Locale.ROOT)
        if (lower in GENERIC_CALL_LABELS) return true
        if ((lower.startsWith("incoming ") || lower.startsWith("ongoing ") || lower.startsWith("active ")) &&
            lower.endsWith(" call")
        ) {
            return true
        }
        return false
    }

    fun selectBestCallerName(
        candidates: List<String?>,
        appName: String,
        previousCallerName: String? = null,
        fallback: String = "Incoming Call"
    ): String {
        for (candidate in candidates) {
            val cleaned = cleanCallerCandidate(candidate)
            if (!isGenericCallLabel(cleaned, appName)) {
                return cleaned
            }
        }
        val prevCleaned = cleanCallerCandidate(previousCallerName)
        if (!isGenericCallLabel(prevCleaned, appName)) {
            return prevCleaned
        }
        return fallback
    }

    fun isCallNotification(sbn: StatusBarNotification?): Boolean {
        val notif = sbn?.notification ?: return false
        if (notif.category == Notification.CATEGORY_CALL) return true
        val pkg = sbn.packageName?.lowercase(Locale.ROOT) ?: ""
        if (pkg.contains("incallui") || pkg == "com.android.server.telecom") {
            return true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val extras = notif.extras ?: return false
            if (extras.containsKey(Notification.EXTRA_ANSWER_INTENT) ||
                extras.containsKey(Notification.EXTRA_DECLINE_INTENT) ||
                extras.containsKey(Notification.EXTRA_HANG_UP_INTENT)
            ) {
                return true
            }
        }
        return false
    }

    fun handleCallNotificationPosted(context: Context, sbn: StatusBarNotification): Boolean {
        if (!isCallNotification(sbn)) return false
        val notif = sbn.notification ?: return false
        val rawKey = sbn.key ?: return false
        val callId = BridgeNotificationListenerService.normalizeKey(rawKey)

        val extras = notif.extras ?: Bundle()
        var answerIntent: PendingIntent? = null
        var declineIntent: PendingIntent? = null
        var silenceIntent: PendingIntent? = null
        var muteIntent: PendingIntent? = null

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            @Suppress("DEPRECATION")
            answerIntent = extras.getParcelable(Notification.EXTRA_ANSWER_INTENT)
            @Suppress("DEPRECATION")
            declineIntent = extras.getParcelable(Notification.EXTRA_DECLINE_INTENT)
                ?: extras.getParcelable(Notification.EXTRA_HANG_UP_INTENT)
        }

        val extrasCallTypeHint = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            extras.getInt("android.callType", 0)
        } else {
            0
        }

        val actionTexts = ArrayList<String>()
        val actionPairs = ArrayList<Pair<String, PendingIntent>>()
        val notifActions = notif.actions
        if (notifActions != null) {
            for (action in notifActions) {
                val rawTitle = action.title?.toString()?.trim() ?: ""
                val title = rawTitle.lowercase(Locale.ROOT)
                if (title.isNotEmpty()) {
                    actionTexts.add(title)
                }
                val pi = action.actionIntent ?: continue
                actionPairs.add(title to pi)
                when {
                    muteIntent == null && matchesActionLabel(title, "mute") -> {
                        muteIntent = pi
                    }
                    silenceIntent == null && matchesActionLabel(title, "silence") -> {
                        silenceIntent = pi
                    }
                    declineIntent == null && matchesActionLabel(title, "decline") -> {
                        declineIntent = pi
                    }
                    answerIntent == null && matchesActionLabel(title, "answer") -> {
                        answerIntent = pi
                    }
                }
            }

            // Positional fallback for non-standard/localized call action labels (e.g. Telegram/Messenger/localized apps)
            fun isAudioRouteOrMuteAction(t: String): Boolean {
                return t.contains("mute") || t.contains("speaker") || t.contains("bluetooth") ||
                    t.contains("hold") || t.contains("keypad") || t.contains("silence")
            }

            if (actionPairs.size == 2 && extrasCallTypeHint != 2) {
                val first = actionPairs[0]
                val second = actionPairs[1]
                if (declineIntent != null && answerIntent == null) {
                    val other = actionPairs.firstOrNull { it.second != declineIntent && !isAudioRouteOrMuteAction(it.first) }
                    if (other != null) answerIntent = other.second
                } else if (answerIntent != null && declineIntent == null) {
                    val other = actionPairs.firstOrNull { it.second != answerIntent && !isAudioRouteOrMuteAction(it.first) }
                    if (other != null) declineIntent = other.second
                } else if (answerIntent == null && declineIntent == null &&
                    !isAudioRouteOrMuteAction(first.first) && !isAudioRouteOrMuteAction(second.first)
                ) {
                    declineIntent = first.second
                    answerIntent = second.second
                }
            } else if (actionPairs.size == 1 && extrasCallTypeHint != 1 && answerIntent == null && declineIntent == null) {
                if (!isAudioRouteOrMuteAction(actionPairs[0].first)) {
                    declineIntent = actionPairs[0].second
                }
            }
        }

        val pkg = sbn.packageName ?: ""
        val rvInspection = inspectRemoteViews(context, pkg, notif)
        if (answerIntent == null) answerIntent = rvInspection.answerIntent
        if (declineIntent == null) declineIntent = rvInspection.declineIntent
        if (silenceIntent == null) silenceIntent = rvInspection.silenceIntent
        if (muteIntent == null) muteIntent = rvInspection.muteIntent

        val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val audioMode = am?.mode ?: AudioManager.MODE_NORMAL
        val isOngoing = (notif.flags and Notification.FLAG_ONGOING_EVENT) != 0

        val combinedText = buildString {
            append(extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: "")
            append(' ')
            append(extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: "")
            append(' ')
            append(extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: "")
            append(' ')
            append(extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: "")
            append(' ')
            append(rvInspection.allLowerTexts)
            append(' ')
            append(actionTexts.joinToString(" "))
        }.lowercase(Locale.ROOT)

        val hasAnyActionControl = answerIntent != null ||
            declineIntent != null ||
            rvInspection.answerView != null ||
            rvInspection.declineView != null

        // Ignore post-call / missed-call notifications so normal notification sync handles them
        if (combinedText.contains("missed call") || combinedText.contains("missed")) {
            return false
        }
        if (!hasAnyActionControl &&
            audioMode == AudioManager.MODE_NORMAL &&
            !isOngoing &&
            notif.fullScreenIntent == null
        ) {
            return false
        }

        val extrasCallType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            extras.getInt("android.callType", 0)
        } else {
            0
        }

        val hasAnswerControl = answerIntent != null || rvInspection.answerView != null
        val isRinging = extrasCallType == 1 ||
            audioMode == AudioManager.MODE_RINGTONE ||
            hasAnswerControl ||
            combinedText.contains("incoming") ||
            combinedText.contains("ringing") ||
            combinedText.contains("is calling")

        val state = if (isRinging && extrasCallType != 2) "ringing" else "active"

        val appName = resolveAppName(context, pkg)
        val previous = activeCalls[callId]

        val candidates = ArrayList<String?>()
        extractExtrasCallerCandidates(extras, candidates)
        candidates.addAll(rvInspection.priorityTexts)
        candidates.addAll(rvInspection.secondaryTexts)
        if (candidates.none { !isGenericCallLabel(cleanCallerCandidate(it), appName) }) {
            ClipboardSyncAccessibilityService.instance?.findActiveCallCallerName(pkg)?.let {
                candidates.add(it)
            }
        }

        val defaultFallback = if (state == "ringing") "Incoming Call" else "Active Call"
        val callerName = selectBestCallerName(
            candidates = candidates,
            appName = appName,
            previousCallerName = previous?.callerName,
            fallback = defaultFallback
        )

        val currentMuted = if (state == "active") {
            am?.isMicrophoneMute ?: previous?.isMuted ?: false
        } else {
            false
        }

        val nowMs = System.currentTimeMillis()
        val connectedAtEpochMs: Long? = if (state == "active") {
            when {
                previous?.state == "active" && previous.connectedAtEpochMs != null -> previous.connectedAtEpochMs
                previous?.state == "ringing" -> nowMs
                extras.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER, false) &&
                    notif.`when` in (nowMs - 12L * 3600L * 1000L)..nowMs -> notif.`when`
                else -> nowMs
            }
        } else {
            null
        }

        val tracked = TrackedCall(
            callId = callId,
            pkg = pkg,
            appName = appName,
            callerName = callerName,
            state = state,
            isMuted = currentMuted,
            connectedAtEpochMs = connectedAtEpochMs,
            answerIntent = answerIntent,
            declineIntent = declineIntent,
            silenceIntent = silenceIntent,
            muteIntent = muteIntent,
            answerView = rvInspection.answerView,
            declineView = rvInspection.declineView,
            muteView = rvInspection.muteView,
            silenceView = rvInspection.silenceView
        )
        val prev = activeCalls.put(callId, tracked)

        if (isGenericCallLabel(callerName, appName)) {
            scheduleCallerNameRequery(context.applicationContext, callId, pkg, appName)
        } else {
            cancelRequeryRunnables(callId)
        }

        if (prev?.state == tracked.state &&
            prev.callerName == tracked.callerName &&
            prev.isMuted == tracked.isMuted
        ) {
            return true
        }

        if (state == "ringing" && silencedCallIds.contains(callId)) {
            return true
        }

        if (!BridgePrefs.isCallsOnMacEnabled(context)) {
            return true
        }

        emitCallEvent(context, tracked)
        return true
    }

    private fun emitCallEvent(context: Context, tracked: TrackedCall) {
        val iconBase64 = getOrEncodeAppIcon(context, tracked.pkg)
        val isRinging = tracked.state == "ringing"
        val elapsedSeconds: Int? = if (!isRinging && tracked.connectedAtEpochMs != null) {
            ((System.currentTimeMillis() - tracked.connectedAtEpochMs) / 1000L).coerceAtLeast(0L).toInt()
        } else {
            null
        }
        val json = buildCallEventJson(
            callId = tracked.callId,
            state = tracked.state,
            callerName = tracked.callerName,
            appName = tracked.appName,
            canAnswer = isRinging,
            canDecline = true,
            isMuted = tracked.isMuted,
            elapsedSeconds = elapsedSeconds,
            iconBase64 = iconBase64
        )
        ClipboardSyncManager.networkClient?.sendRawJson(json)
    }

    private fun scheduleCallerNameRequery(
        appContext: Context,
        callId: String,
        pkg: String,
        appName: String
    ) {
        cancelRequeryRunnables(callId)
        val delaysMs = listOf(400L, 1200L)
        val runnables = ArrayList<Runnable>()
        for (delay in delaysMs) {
            val r = Runnable {
                val current = activeCalls[callId] ?: return@Runnable
                if (!isGenericCallLabel(current.callerName, appName)) return@Runnable
                val resolved = findCallerNameFromLiveWindowsAndNotifications(appContext, pkg, appName)
                if (resolved != null && !isGenericCallLabel(resolved, appName) && resolved != current.callerName) {
                    val updated = current.copy(callerName = resolved)
                    activeCalls[callId] = updated
                    if (BridgePrefs.isCallsOnMacEnabled(appContext) &&
                        !(updated.state == "ringing" && silencedCallIds.contains(callId))
                    ) {
                        emitCallEvent(appContext, updated)
                    }
                    cancelRequeryRunnables(callId)
                }
            }
            runnables.add(r)
            mainHandler.postDelayed(r, delay)
        }
        pendingRequeryRunnables[callId] = runnables
    }

    private fun cancelRequeryRunnables(callId: String) {
        pendingRequeryRunnables.remove(callId)?.forEach { mainHandler.removeCallbacks(it) }
    }

    private fun findCallerNameFromLiveWindowsAndNotifications(
        context: Context,
        pkg: String,
        appName: String
    ): String? {
        ClipboardSyncAccessibilityService.instance?.findActiveCallCallerName(pkg)?.let {
            if (!isGenericCallLabel(it, appName)) return it
        }
        try {
            val activeSbns = BridgeNotificationListenerService.instance?.activeNotifications
            if (activeSbns != null) {
                for (sbn in activeSbns) {
                    if (!isCallNotification(sbn)) continue
                    val extras = sbn.notification?.extras ?: continue
                    val candidates = ArrayList<String?>()
                    extractExtrasCallerCandidates(extras, candidates)
                    val rv = inspectRemoteViews(context, sbn.packageName ?: pkg, sbn.notification)
                    candidates.addAll(rv.priorityTexts)
                    candidates.addAll(rv.secondaryTexts)
                    val best = selectBestCallerName(candidates, appName, null, "")
                    if (best.isNotBlank()) return best
                }
            }
        } catch (_: Exception) {}
        return null
    }

    fun handleCallNotificationRemoved(sbn: StatusBarNotification?) {
        val rawKey = sbn?.key ?: return
        val callId = BridgeNotificationListenerService.normalizeKey(rawKey)
        cancelRequeryRunnables(callId)
        val removed = activeCalls.remove(callId)
        silencedCallIds.remove(callId)
        if (removed != null) {
            val json = buildCallEventJson(
                callId = callId,
                state = "ended",
                callerName = removed.callerName,
                appName = removed.appName,
                canAnswer = false,
                canDecline = false,
                isMuted = false,
                iconBase64 = null
            )
            ClipboardSyncManager.networkClient?.sendRawJson(json)
        }
    }

    fun handleCallAction(context: Context, jsonObj: JSONObject) {
        val callId = jsonObj.optString("callId")
        val action = jsonObj.optString("action")
        val tracked = (if (callId.isNotEmpty()) activeCalls[callId] else null) ?: activeCalls.values.firstOrNull()
        if (tracked == null) {
            Log.d(TAG, "No tracked active call for call_action '$action' ($callId)")
            return
        }

        when (action) {
            "answer" -> executeAnswer(context, tracked)
            "decline" -> executeDecline(context, tracked)
            "silence" -> executeSilence(context, tracked)
            "mute" -> {
                if (tracked.state == "ringing") {
                    executeSilence(context, tracked)
                } else {
                    executeMuteToggle(context, tracked)
                }
            }
            else -> Log.d(TAG, "Unknown call_action: $action")
        }
    }

    private fun executeAnswer(context: Context, tracked: TrackedCall) {
        wakeScreenBriefly(context)
        val isDialer = tracked.pkg.lowercase(Locale.ROOT) in KNOWN_DIALER_PACKAGES
        var handled = false

        if (isDialer && tryTelecomAccept(context)) {
            handled = true
        }
        if (sendPendingIntentWithBal(context, tracked.answerIntent, "answer")) {
            handled = true
        }
        if (tracked.answerView != null) {
            tryPerformViewClick(tracked.answerView, "answer")
        }
        if (!handled || tracked.answerIntent == null) {
            if (ClipboardSyncAccessibilityService.instance?.performCallNodeClick(tracked.pkg, "answer") == true) {
                handled = true
            }
            if (!handled && tryTelecomAccept(context)) {
                handled = true
            }
        }
        if (!handled) {
            dispatchHeadsetOrCallKey(context, KeyEvent.KEYCODE_HEADSETHOOK)
        }
    }

    private fun executeDecline(context: Context, tracked: TrackedCall) {
        val isDialer = tracked.pkg.lowercase(Locale.ROOT) in KNOWN_DIALER_PACKAGES
        var handled = false

        if (isDialer && tryTelecomEndCall(context)) {
            handled = true
        }
        if (sendPendingIntentWithBal(context, tracked.declineIntent, "decline")) {
            handled = true
        }
        if (tracked.declineView != null) {
            tryPerformViewClick(tracked.declineView, "decline")
        }
        if (!handled || tracked.declineIntent == null) {
            if (ClipboardSyncAccessibilityService.instance?.performCallNodeClick(tracked.pkg, "decline") == true) {
                handled = true
            }
            if (!handled && tryTelecomEndCall(context)) {
                handled = true
            }
        }
        if (!handled) {
            dispatchHeadsetOrCallKey(context, KeyEvent.KEYCODE_ENDCALL)
        }
    }

    @SuppressLint("MissingPermission")
    private fun executeSilence(context: Context, tracked: TrackedCall) {
        silencedCallIds.add(tracked.callId)
        if (sendPendingIntentWithBal(context, tracked.silenceIntent, "silence")) return
        tryPerformViewClick(tracked.silenceView, "silence")
        if (ClipboardSyncAccessibilityService.instance?.performCallNodeClick(tracked.pkg, "silence") == true) return
        try {
            val tm = context.applicationContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
            @Suppress("DEPRECATION")
            tm?.silenceRinger()
        } catch (_: Exception) {}
        try {
            val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            am?.adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_MUTE, 0)
        } catch (e: SecurityException) {
            Log.d(TAG, "Could not mute ring stream without DND access: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "Failed muting ring stream: ${e.message}")
        }
    }

    private fun executeMuteToggle(context: Context, tracked: TrackedCall) {
        val newMuted = !tracked.isMuted
        var toggled = false

        try {
            val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (am != null) {
                am.isMicrophoneMute = newMuted
                toggled = true
                Log.i(TAG, "Set AudioManager.isMicrophoneMute=$newMuted for ${tracked.callId}")
            }
        } catch (e: Exception) {
            Log.w(TAG, "AudioManager.isMicrophoneMute failed: ${e.message}")
        }

        if (!sendPendingIntentWithBal(context, tracked.muteIntent, "mute")) {
            tryPerformViewClick(tracked.muteView, "mute")
            if (tracked.muteIntent == null) {
                ClipboardSyncAccessibilityService.instance?.performCallNodeClick(tracked.pkg, "mute")
            }
        }

        if (toggled || tracked.muteIntent != null || tracked.muteView != null) {
            val updated = tracked.copy(isMuted = newMuted)
            activeCalls[tracked.callId] = updated
            if (BridgePrefs.isCallsOnMacEnabled(context)) {
                emitCallEvent(context, updated)
            }
        }
    }

    fun sendPendingIntentWithBal(
        context: Context,
        pi: PendingIntent?,
        label: String,
        fillInIntent: Intent? = null
    ): Boolean {
        if (pi == null) return false
        return try {
            val options = ActivityOptions.makeBasic()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                options.setPendingIntentBackgroundActivityStartMode(
                    ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                @Suppress("DEPRECATION")
                options.setPendingIntentBackgroundActivityLaunchAllowed(true)
            }
            pi.send(context, 0, fillInIntent, null, null, null, options.toBundle())
            Log.i(TAG, "Triggered $label PendingIntent (with BAL allowance)")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed triggering $label PendingIntent: ${e.message}")
            false
        }
    }

    private fun wakeScreenBriefly(context: Context) {
        try {
            val pm = context.applicationContext.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            if (!pm.isInteractive) {
                @Suppress("DEPRECATION")
                val wl = pm.newWakeLock(
                    PowerManager.FULL_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                    "Bridge::CallAnswerWake"
                )
                wl.acquire(3000L)
            }
        } catch (_: Exception) {}
    }

    private fun tryPerformViewClick(view: View?, label: String): Boolean {
        if (view == null) return false
        mainHandler.post {
            try {
                view.performClick()
                Log.i(TAG, "Clicked inflated RemoteViews $label view")
            } catch (e: Exception) {
                Log.w(TAG, "Failed clicking inflated RemoteViews $label view: ${e.message}")
            }
        }
        return true
    }

    @SuppressLint("MissingPermission")
    private fun tryTelecomAccept(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ANSWER_PHONE_CALLS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return try {
            val tm = context.applicationContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return false
            @Suppress("DEPRECATION")
            tm.acceptRingingCall()
            Log.i(TAG, "Accepted ringing call via TelecomManager")
            true
        } catch (e: Exception) {
            Log.w(TAG, "TelecomManager.acceptRingingCall failed: ${e.message}")
            false
        }
    }

    @SuppressLint("MissingPermission")
    private fun tryTelecomEndCall(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ANSWER_PHONE_CALLS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return try {
            val tm = context.applicationContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                ?: return false
            @Suppress("DEPRECATION")
            val result = tm.endCall()
            if (result) Log.i(TAG, "Ended call via TelecomManager")
            result
        } catch (e: Exception) {
            Log.w(TAG, "TelecomManager.endCall failed: ${e.message}")
            false
        }
    }

    private fun dispatchHeadsetOrCallKey(context: Context, keyCode: Int) {
        try {
            val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                ?: return
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, keyCode))
            Log.i(TAG, "Dispatched media keyEvent keyCode=$keyCode")
        } catch (e: Exception) {
            Log.w(TAG, "Failed dispatching keyCode=$keyCode: ${e.message}")
        }
    }

    fun clearAll() {
        for (id in pendingRequeryRunnables.keys.toList()) {
            cancelRequeryRunnables(id)
        }
        activeCalls.clear()
        silencedCallIds.clear()
    }

    private fun extractExtrasCallerCandidates(extras: Bundle, out: MutableList<String?>) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            val person = extras.getParcelable<android.app.Person>(Notification.EXTRA_CALL_PERSON)
            out.add(person?.name?.toString())
            @Suppress("DEPRECATION")
            val peopleList = extras.getParcelableArrayList<android.app.Person>(Notification.EXTRA_PEOPLE_LIST)
            peopleList?.forEach { out.add(it?.name?.toString()) }
        }
        val keys = listOf(
            Notification.EXTRA_TITLE_BIG,
            Notification.EXTRA_TITLE,
            Notification.EXTRA_SUB_TEXT,
            Notification.EXTRA_TEXT,
            Notification.EXTRA_BIG_TEXT,
            Notification.EXTRA_INFO_TEXT,
            Notification.EXTRA_SUMMARY_TEXT
        )
        for (k in keys) {
            val raw = extras.getCharSequence(k)?.toString() ?: continue
            if (raw.contains('\n')) {
                raw.lines().forEach { out.add(it) }
            }
            out.add(raw)
        }
        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
        lines?.forEach { line ->
            val str = line?.toString()
            if (!str.isNullOrBlank()) out.add(str)
        }
    }

    @Suppress("DEPRECATION")
    private fun inspectRemoteViews(context: Context, pkg: String, notif: Notification): RemoteViewsInspection {
        val viewsToInspect = listOfNotNull(
            notif.headsUpContentView,
            notif.bigContentView,
            notif.contentView
        ).distinct()

        if (viewsToInspect.isEmpty()) return RemoteViewsInspection()

        val priorityTexts = ArrayList<String>()
        val secondaryTexts = ArrayList<String>()
        val allLowerTexts = StringBuilder()

        var answerIntent: PendingIntent? = null
        var declineIntent: PendingIntent? = null
        var silenceIntent: PendingIntent? = null
        var muteIntent: PendingIntent? = null

        var answerView: View? = null
        var declineView: View? = null
        var silenceView: View? = null
        var muteView: View? = null

        val pkgContext = try {
            if (pkg.isNotBlank()) context.createPackageContext(pkg, Context.CONTEXT_IGNORE_SECURITY) else context
        } catch (_: Exception) {
            context
        }
        val pkgRes = try { pkgContext.resources } catch (_: Exception) { null }

        for (rv in viewsToInspect) {
            // 1. Reflect RemoteViews.mActions (fast and works without needing full theme inflation)
            val viewLabelsById = HashMap<Int, String>()
            try {
                val actionsField = RemoteViews::class.java.getDeclaredField("mActions").apply {
                    isAccessible = true
                }
                val actions = actionsField.get(rv) as? List<*>
                if (actions != null) {
                    val pendingIntents = ArrayList<Pair<Int, PendingIntent>>()
                    for (actionObj in actions) {
                        if (actionObj == null) continue
                        val cls = actionObj.javaClass
                        val viewId = readIntField(actionObj, "viewId") ?: continue
                        val entryName = try {
                            if (viewId != View.NO_ID) pkgRes?.getResourceEntryName(viewId)?.lowercase(Locale.ROOT) ?: "" else ""
                        } catch (_: Exception) { "" }

                        val simpleName = cls.simpleName
                        if (simpleName.contains("ReflectionAction")) {
                            val methodName = readStringField(actionObj, "methodName") ?: ""
                            if (methodName == "setText" || methodName == "setContentDescription") {
                                val valObj = readAnyField(actionObj, "value")?.toString()?.trim()
                                if (!valObj.isNullOrEmpty()) {
                                    allLowerTexts.append(valObj.lowercase(Locale.ROOT)).append(' ')
                                    viewLabelsById[viewId] = ((viewLabelsById[viewId] ?: "") + " " + valObj).trim()
                                    if (isPriorityCallerViewName(entryName)) {
                                        priorityTexts.add(valObj)
                                    } else {
                                        secondaryTexts.add(valObj)
                                    }
                                }
                            }
                        } else if (simpleName.contains("SetOnClickPendingIntent")) {
                            val pi = readAnyField(actionObj, "pendingIntent") as? PendingIntent
                            if (pi != null) pendingIntents.add(viewId to pi)
                        } else if (simpleName.contains("SetOnClickResponse")) {
                            val resp = readAnyField(actionObj, "mResponse")
                            val pi = resp?.let { readAnyField(it, "mPendingIntent") as? PendingIntent }
                            if (pi != null) pendingIntents.add(viewId to pi)
                        }
                    }

                    for ((viewId, pi) in pendingIntents) {
                        val entryName = try {
                            if (viewId != View.NO_ID) pkgRes?.getResourceEntryName(viewId)?.lowercase(Locale.ROOT) ?: "" else ""
                        } catch (_: Exception) { "" }
                        val textHint = (viewLabelsById[viewId] ?: "").lowercase(Locale.ROOT)
                        val hint = "$entryName $textHint".trim()
                        when {
                            answerIntent == null && matchesActionHint(hint, "answer") -> answerIntent = pi
                            declineIntent == null && matchesActionHint(hint, "decline") -> declineIntent = pi
                            silenceIntent == null && matchesActionHint(hint, "silence") -> silenceIntent = pi
                            muteIntent == null && matchesActionHint(hint, "mute") -> muteIntent = pi
                        }
                    }
                }
            } catch (_: Exception) {
                // Hidden API restrictions on some devices block mActions; inflation fallback handles below
            }

            // 2. Inflate RemoteViews into an offscreen container to read TextViews & clickable buttons
            try {
                val root = rv.apply(pkgContext, FrameLayout(pkgContext))
                val queue = ArrayDeque<View>()
                queue.add(root)
                var visited = 0
                while (queue.isNotEmpty() && visited < 200) {
                    val v = queue.removeFirst()
                    visited++
                    val entryName = try {
                        if (v.id != View.NO_ID) pkgRes?.getResourceEntryName(v.id)?.lowercase(Locale.ROOT) ?: "" else ""
                    } catch (_: Exception) { "" }

                    if (v is TextView && v !is Chronometer) {
                        val txt = v.text?.toString()?.trim()
                        if (!txt.isNullOrEmpty()) {
                            allLowerTexts.append(txt.lowercase(Locale.ROOT)).append(' ')
                            if (txt.contains('\n')) {
                                txt.lines().map { it.trim() }.filter { it.isNotEmpty() }.forEach { line ->
                                    if (isPriorityCallerViewName(entryName)) priorityTexts.add(line) else secondaryTexts.add(line)
                                }
                            } else if (isPriorityCallerViewName(entryName)) {
                                priorityTexts.add(txt)
                            } else {
                                secondaryTexts.add(txt)
                            }
                        }
                    }

                    val cd = v.contentDescription?.toString()?.trim()
                    if (!cd.isNullOrEmpty()) {
                        allLowerTexts.append(cd.lowercase(Locale.ROOT)).append(' ')
                        if (isPriorityCallerViewName(entryName)) {
                            priorityTexts.add(cd)
                        } else {
                            secondaryTexts.add(cd)
                        }
                    }

                    val textHint = ((v as? TextView)?.text?.toString() ?: "").lowercase(Locale.ROOT)
                    val descHint = (cd ?: "").lowercase(Locale.ROOT)
                    val hint = "$entryName $textHint $descHint".trim()
                    if (v.isClickable || v.hasOnClickListeners()) {
                        when {
                            answerView == null && matchesActionHint(hint, "answer") -> answerView = v
                            declineView == null && matchesActionHint(hint, "decline") -> declineView = v
                            silenceView == null && matchesActionHint(hint, "silence") -> silenceView = v
                            muteView == null && matchesActionHint(hint, "mute") -> muteView = v
                        }
                    }

                    if (v is ViewGroup) {
                        for (i in 0 until v.childCount) {
                            v.getChildAt(i)?.let { queue.add(it) }
                        }
                    }
                }
            } catch (_: Exception) {}
        }

        return RemoteViewsInspection(
            priorityTexts = priorityTexts.distinct(),
            secondaryTexts = secondaryTexts.distinct(),
            allLowerTexts = allLowerTexts.toString(),
            answerIntent = answerIntent,
            declineIntent = declineIntent,
            silenceIntent = silenceIntent,
            muteIntent = muteIntent,
            answerView = answerView,
            declineView = declineView,
            silenceView = silenceView,
            muteView = muteView
        )
    }

    private fun isPriorityCallerViewName(entryName: String): Boolean {
        if (entryName.isEmpty()) return false
        return entryName.contains("name") ||
            entryName.contains("caller") ||
            entryName.contains("contact") ||
            entryName.contains("number") ||
            entryName.contains("title")
    }

    private fun matchesActionLabel(lowerLabel: String, actionType: String): Boolean {
        return when (actionType) {
            "answer" -> lowerLabel.contains("answer") || lowerLabel.contains("accept") ||
                lowerLabel.contains("pick up") || lowerLabel.contains("join") ||
                lowerLabel.contains("connect") || lowerLabel.contains("receive") ||
                lowerLabel == "audio" || lowerLabel == "video"
            "decline" -> lowerLabel.contains("decline") || lowerLabel.contains("reject") ||
                lowerLabel.contains("dismiss") || lowerLabel.contains("hang up") ||
                lowerLabel.contains("end") || lowerLabel.contains("ignore") ||
                lowerLabel.contains("cancel") || lowerLabel.contains("leave") ||
                lowerLabel.contains("disconnect")
            "silence" -> lowerLabel.contains("silence")
            "mute" -> lowerLabel.contains("mute")
            else -> false
        }
    }

    private fun matchesActionHint(lowerHint: String, actionType: String): Boolean {
        if (lowerHint.isEmpty()) return false
        return when (actionType) {
            "answer" -> lowerHint.contains("answer") || lowerHint.contains("accept") || lowerHint.contains("pick up")
            "decline" -> lowerHint.contains("decline") || lowerHint.contains("reject") ||
                lowerHint.contains("end_call") || lowerHint.contains("endcall") ||
                lowerHint.contains("hangup") || lowerHint.contains("hang up") ||
                lowerHint.contains("end call") || lowerHint == "end"
            "silence" -> lowerHint.contains("silence")
            "mute" -> lowerHint.contains("mute")
            else -> false
        }
    }

    private fun readAnyField(target: Any, fieldName: String): Any? {
        var cls: Class<*>? = target.javaClass
        while (cls != null) {
            try {
                val f = cls.getDeclaredField(fieldName)
                f.isAccessible = true
                return f.get(target)
            } catch (_: NoSuchFieldException) {
                cls = cls.superclass
            } catch (_: Exception) {
                return null
            }
        }
        return null
    }

    private fun readIntField(target: Any, fieldName: String): Int? = readAnyField(target, fieldName) as? Int
    private fun readStringField(target: Any, fieldName: String): String? = readAnyField(target, fieldName) as? String

    private fun resolveAppName(context: Context, pkg: String): String {
        if (pkg.isBlank()) return "Phone"
        val rawLabel = try {
            val pm = context.applicationContext.packageManager
            val info = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            pkg
        }
        return normalizeCallAppName(pkg, rawLabel)
    }

    private fun getOrEncodeAppIcon(context: Context, pkg: String): String? {
        if (pkg.isBlank()) return null
        appIconCache[pkg]?.let { return it }
        return try {
            val drawable: Drawable = context.applicationContext.packageManager.getApplicationIcon(pkg)
            val size = 64
            val bmp = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
            } else {
                val created = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(created)
                drawable.setBounds(0, 0, size, size)
                drawable.draw(canvas)
                created
            }
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 90, out)
            val b64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            appIconCache[pkg] = b64
            b64
        } catch (_: Exception) {
            null
        }
    }

    fun buildCallEventJson(
        callId: String,
        state: String,
        callerName: String,
        appName: String,
        canAnswer: Boolean,
        canDecline: Boolean,
        isMuted: Boolean = false,
        elapsedSeconds: Int? = null,
        iconBase64: String?
    ): String {
        return JSONObject().apply {
            put("type", "call_event")
            put("callId", callId)
            put("state", state)
            put("callerName", callerName)
            put("appName", appName)
            put("canAnswer", canAnswer)
            put("canDecline", canDecline)
            put("isMuted", isMuted)
            if (elapsedSeconds != null && elapsedSeconds >= 0) {
                put("elapsedSeconds", elapsedSeconds)
            }
            if (!iconBase64.isNullOrEmpty()) {
                put("icon", iconBase64)
            }
        }.toString()
    }
}
