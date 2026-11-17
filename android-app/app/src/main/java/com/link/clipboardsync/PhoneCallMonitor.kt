package com.link.clipboardsync

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Detects live incoming/active calls via NotificationListenerService (CATEGORY_CALL / CallStyle),
 * emits encrypted call_event frames to Mac, and executes Answer / Decline / Silence actions.
 */
object PhoneCallMonitor {
    private const val TAG = "PhoneCallMonitor"

    private data class TrackedCall(
        val callId: String,
        val pkg: String,
        val appName: String,
        val callerName: String,
        val state: String,
        val answerIntent: PendingIntent?,
        val declineIntent: PendingIntent?,
        val silenceIntent: PendingIntent?
    )

    private val activeCalls = ConcurrentHashMap<String, TrackedCall>()
    private val silencedCallIds = ConcurrentHashMap.newKeySet<String>()
    private val appIconCache = ConcurrentHashMap<String, String>()

    fun isCallNotification(sbn: StatusBarNotification?): Boolean {
        val notif = sbn?.notification ?: return false
        if (notif.category == Notification.CATEGORY_CALL) return true
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

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            @Suppress("DEPRECATION")
            answerIntent = extras.getParcelable(Notification.EXTRA_ANSWER_INTENT)
            @Suppress("DEPRECATION")
            declineIntent = extras.getParcelable(Notification.EXTRA_DECLINE_INTENT)
                ?: extras.getParcelable(Notification.EXTRA_HANG_UP_INTENT)
        }

        val notifActions = notif.actions
        if (notifActions != null) {
            for (action in notifActions) {
                val title = action.title?.toString()?.trim()?.lowercase() ?: continue
                val pi = action.actionIntent ?: continue
                when {
                    answerIntent == null && (title.contains("answer") || title.contains("accept") || title.contains("pick up")) -> {
                        answerIntent = pi
                    }
                    declineIntent == null && (
                        title.contains("decline") ||
                            title.contains("reject") ||
                            title.contains("dismiss") ||
                            title.contains("hang up") ||
                            title.contains("end")
                        ) -> {
                        declineIntent = pi
                    }
                    silenceIntent == null && (title.contains("silence") || title.contains("mute")) -> {
                        silenceIntent = pi
                    }
                }
            }
        }

        // Ignore post-call / missed-call style notifications that have neither answer nor decline/hang-up
        if (answerIntent == null && declineIntent == null) {
            return false
        }

        val callerName = extractCallerName(extras)
        val pkg = sbn.packageName ?: ""
        val appName = resolveAppName(context, pkg)
        val state = if (answerIntent != null) "ringing" else "active"

        val tracked = TrackedCall(
            callId = callId,
            pkg = pkg,
            appName = appName,
            callerName = callerName.ifBlank { "Incoming Call" },
            state = state,
            answerIntent = answerIntent,
            declineIntent = declineIntent,
            silenceIntent = silenceIntent
        )
        val prev = activeCalls.put(callId, tracked)
        if (prev?.state == tracked.state && prev.callerName == tracked.callerName &&
            (prev.answerIntent != null) == (tracked.answerIntent != null) &&
            (prev.declineIntent != null) == (tracked.declineIntent != null)
        ) {
            return true
        }

        if (state == "ringing" && silencedCallIds.contains(callId)) {
            return true
        }

        if (!BridgePrefs.isCallsOnMacEnabled(context)) {
            return true
        }

        val iconBase64 = getOrEncodeAppIcon(context, pkg)
        val json = buildCallEventJson(
            callId = callId,
            state = state,
            callerName = tracked.callerName,
            appName = appName,
            canAnswer = answerIntent != null,
            canDecline = declineIntent != null,
            iconBase64 = iconBase64
        )
        ClipboardSyncManager.networkClient?.sendRawJson(json)
        return true
    }

    fun handleCallNotificationRemoved(sbn: StatusBarNotification?) {
        val rawKey = sbn?.key ?: return
        val callId = BridgeNotificationListenerService.normalizeKey(rawKey)
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
                iconBase64 = null
            )
            ClipboardSyncManager.networkClient?.sendRawJson(json)
        }
    }

    fun handleCallAction(context: Context, jsonObj: JSONObject) {
        val callId = jsonObj.optString("callId")
        val action = jsonObj.optString("action")
        val tracked = if (callId.isNotEmpty()) activeCalls[callId] else activeCalls.values.firstOrNull()
        if (tracked == null) {
            Log.d(TAG, "No tracked active call for call_action '$action' ($callId)")
            return
        }

        when (action) {
            "answer" -> {
                try {
                    tracked.answerIntent?.send()
                    Log.i(TAG, "Triggered answer PendingIntent for ${tracked.callId}")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed triggering answer intent: ${e.message}")
                }
            }
            "decline" -> {
                try {
                    tracked.declineIntent?.send()
                    Log.i(TAG, "Triggered decline PendingIntent for ${tracked.callId}")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed triggering decline intent: ${e.message}")
                }
            }
            "silence" -> {
                silencedCallIds.add(tracked.callId)
                if (tracked.silenceIntent != null) {
                    try {
                        tracked.silenceIntent.send()
                        Log.i(TAG, "Triggered silence PendingIntent for ${tracked.callId}")
                        return
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed silence PendingIntent: ${e.message}")
                    }
                }
                try {
                    val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                    am?.adjustStreamVolume(AudioManager.STREAM_RING, AudioManager.ADJUST_MUTE, 0)
                } catch (e: SecurityException) {
                    Log.d(TAG, "Could not mute ring stream without DND access: ${e.message}")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed muting ring stream: ${e.message}")
                }
            }
            else -> Log.d(TAG, "Unknown call_action: $action")
        }
    }

    fun clearAll() {
        activeCalls.clear()
        silencedCallIds.clear()
    }

    private fun extractCallerName(extras: Bundle): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            val person = extras.getParcelable<android.app.Person>(Notification.EXTRA_CALL_PERSON)
            val personName = person?.name?.toString()?.trim()
            if (!personName.isNullOrEmpty()) return personName
        }
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
        if (!title.isNullOrEmpty()) return title
        val bigTitle = extras.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString()?.trim()
        if (!bigTitle.isNullOrEmpty()) return bigTitle
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()
        return text ?: ""
    }

    private fun resolveAppName(context: Context, pkg: String): String {
        if (pkg.isBlank()) return "Phone"
        return try {
            val pm = context.applicationContext.packageManager
            val info = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            pkg
        }
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
            if (!iconBase64.isNullOrEmpty()) {
                put("icon", iconBase64)
            }
        }.toString()
    }
}
