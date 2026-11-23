package com.link.clipboardsync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.util.concurrent.CopyOnWriteArrayList

object PhoneMirrorController {
    private const val TAG = "PhoneMirrorController"
    private const val CONSENT_CHANNEL_ID = "bridge_mirror_consent"
    private const val CONSENT_NOTIF_ID = 4202
    private const val OFFER_TIMEOUT_MS = 15_000L

    interface StateListener {
        fun onMirrorStateChanged(state: MirrorSessionState)
    }

    data class PendingOffer(
        val macHost: String,
        val offer: MirrorStreamOffer,
        val createdAtMs: Long
    )

    data class PendingConsent(
        val resultCode: Int,
        val data: Intent,
        val createdAtMs: Long
    )

    private val lock = Any()
    private val listeners = CopyOnWriteArrayList<StateListener>()
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    @Volatile
    var currentState: MirrorSessionState = MirrorSessionState.IDLE
        private set

    private var pendingRemoteOffer: PendingOffer? = null
    private var pendingConsent: PendingConsent? = null
    private var offerTimeoutRunnable: Runnable? = null

    fun addListener(listener: StateListener) {
        listeners.addIfAbsent(listener)
    }

    fun removeListener(listener: StateListener) {
        listeners.remove(listener)
    }

    internal fun updateState(newState: MirrorSessionState) {
        currentState = newState
        mainHandler.post {
            for (l in listeners) {
                try {
                    l.onMirrorStateChanged(newState)
                } catch (ignored: Exception) {}
            }
        }
    }

    fun startFromPhone(context: Context) {
        val appCtx = context.applicationContext
        if (ClipboardSyncManager.networkClient?.isConnected() != true) {
            Log.w(TAG, "Cannot start phone mirroring: not connected to Mac")
            return
        }

        if (currentState != MirrorSessionState.IDLE) {
            stopMirroring(appCtx, reason = "stopped_by_phone", notifyMac = true)
            return
        }

        synchronized(lock) {
            pendingRemoteOffer = null
            pendingConsent = null
            cancelOfferTimeoutLocked()
        }
        updateState(MirrorSessionState.WAITING_PERMISSION)
        launchConsentActivity(appCtx)
    }

    fun handleControlMessage(context: Context, jsonObj: JSONObject, macHost: String) {
        val appCtx = context.applicationContext
        val cmd = PhoneMirrorProtocol.parseControlCommand(jsonObj) ?: run {
            Log.d(TAG, "Ignoring unrecognized mirror_control action=${jsonObj.optString("action")}")
            return
        }

        when (cmd) {
            is MirrorControlCommand.RequestStart -> {
                if (!NetworkSyncClient.isPrivateLocalAddress(macHost)) {
                    Log.w(TAG, "Rejected mirror request_start from non-private host $macHost")
                    return
                }
                synchronized(lock) {
                    pendingRemoteOffer = PendingOffer(macHost, cmd.offer, System.currentTimeMillis())
                    pendingConsent = null
                    cancelOfferTimeoutLocked()
                }
                updateState(MirrorSessionState.WAITING_PERMISSION)
                launchConsentActivity(appCtx)
            }

            is MirrorControlCommand.StreamOffer -> {
                if (!NetworkSyncClient.isPrivateLocalAddress(macHost)) {
                    Log.w(TAG, "Rejected mirror stream_offer from non-private host $macHost")
                    return
                }
                val consent = synchronized(lock) {
                    cancelOfferTimeoutLocked()
                    val c = pendingConsent
                    pendingConsent = null
                    c
                }
                if (consent != null && (System.currentTimeMillis() - consent.createdAtMs) <= 30_000L) {
                    updateState(MirrorSessionState.STARTING)
                    ScreenMirrorForegroundService.start(
                        context = appCtx,
                        resultCode = consent.resultCode,
                        resultData = consent.data,
                        macHost = macHost,
                        offer = cmd.offer
                    )
                } else {
                    Log.w(TAG, "Received stream_offer with no valid pending consent")
                    updateState(MirrorSessionState.IDLE)
                    ClipboardSyncManager.networkClient?.sendRawJson(
                        PhoneMirrorProtocol.buildStatusJson("stopped", reason = "consent_expired")
                    )
                }
            }

            is MirrorControlCommand.SetDim -> {
                ClipboardSyncAccessibilityService.instance?.setMirrorScreenDimmed(cmd.dimmed)
            }

            is MirrorControlCommand.Stop -> {
                stopMirroring(appCtx, reason = "stopped_by_mac", notifyMac = false)
            }

            is MirrorControlCommand.RequestKeyframe -> {
                ScreenMirrorForegroundService.activeInstance?.requestKeyframe()
            }
        }
    }

    fun onConsentGranted(context: Context, resultCode: Int, data: Intent) {
        val appCtx = context.applicationContext
        cancelConsentNotification(appCtx)

        val remote = synchronized(lock) {
            val r = pendingRemoteOffer
            pendingRemoteOffer = null
            r
        }

        if (remote != null && (System.currentTimeMillis() - remote.createdAtMs) <= 60_000L) {
            updateState(MirrorSessionState.STARTING)
            ScreenMirrorForegroundService.start(
                context = appCtx,
                resultCode = resultCode,
                resultData = data,
                macHost = remote.macHost,
                offer = remote.offer
            )
            return
        }

        // Initiated locally from Android Quick Control tile: store consent briefly and ask Mac to open listener
        val client = ClipboardSyncManager.networkClient
        if (client?.isConnected() != true) {
            updateState(MirrorSessionState.IDLE)
            return
        }

        synchronized(lock) {
            pendingConsent = PendingConsent(resultCode, data, System.currentTimeMillis())
            cancelOfferTimeoutLocked()
            val timeout = Runnable {
                val timedOut = synchronized(lock) {
                    val had = pendingConsent != null
                    pendingConsent = null
                    had
                }
                if (timedOut) {
                    updateState(MirrorSessionState.IDLE)
                    ClipboardSyncManager.networkClient?.sendRawJson(
                        PhoneMirrorProtocol.buildStatusJson("stopped", reason = "offer_timeout")
                    )
                }
            }
            offerTimeoutRunnable = timeout
            mainHandler.postDelayed(timeout, OFFER_TIMEOUT_MS)
        }

        updateState(MirrorSessionState.STARTING)
        client.sendRawJson(PhoneMirrorProtocol.buildRequestOfferJson())
    }

    fun onConsentDenied(context: Context) {
        val appCtx = context.applicationContext
        cancelConsentNotification(appCtx)
        synchronized(lock) {
            pendingRemoteOffer = null
            pendingConsent = null
            cancelOfferTimeoutLocked()
        }
        updateState(MirrorSessionState.IDLE)
        ClipboardSyncManager.networkClient?.sendRawJson(
            PhoneMirrorProtocol.buildStatusJson("stopped", reason = "permission_denied")
        )
    }

    fun stopMirroring(context: Context, reason: String = "user_stopped", notifyMac: Boolean = true) {
        val appCtx = context.applicationContext
        cancelConsentNotification(appCtx)
        synchronized(lock) {
            pendingRemoteOffer = null
            pendingConsent = null
            cancelOfferTimeoutLocked()
        }
        ScreenMirrorForegroundService.stop(appCtx)
        updateState(MirrorSessionState.IDLE)
        if (notifyMac) {
            ClipboardSyncManager.networkClient?.sendRawJson(
                PhoneMirrorProtocol.buildStatusJson("stopped", reason = reason)
            )
        }
    }

    fun handleServiceStopped(reason: String? = null, notifyMac: Boolean = true) {
        synchronized(lock) {
            pendingRemoteOffer = null
            pendingConsent = null
            cancelOfferTimeoutLocked()
        }
        updateState(MirrorSessionState.IDLE)
        if (notifyMac) {
            ClipboardSyncManager.networkClient?.sendRawJson(
                PhoneMirrorProtocol.buildStatusJson("stopped", reason = reason)
            )
        }
    }

    private fun cancelOfferTimeoutLocked() {
        offerTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        offerTimeoutRunnable = null
    }

    private fun launchConsentActivity(context: Context) {
        val intent = Intent(context, ScreenCaptureConsentActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        }

        // AccessibilityService exemption lets Bridge launch consent dialog even when app is backgrounded on Android 14
        val a11y = ClipboardSyncAccessibilityService.instance
        if (a11y != null) {
            try {
                a11y.startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "A11y consent activity launch failed: ${e.message}")
            }
        }

        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Context consent activity launch blocked, posting prompt notification: ${e.message}")
            postConsentNotification(context, intent)
        }
    }

    private fun postConsentNotification(context: Context, intent: Intent) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = NotificationChannel(
                    CONSENT_CHANNEL_ID,
                    "Phone Mirroring Prompt",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Prompts to allow screen mirroring to your Mac"
                }
                nm.createNotificationChannel(ch)
            }
            val pi = PendingIntent.getActivity(
                context,
                4202,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val macName = BridgePrefs.macName(context) ?: "Mac"
            val notif = NotificationCompat.Builder(context, CONSENT_CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Mirror screen to $macName?")
                .setContentText("Tap to allow screen mirroring from Bridge.")
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setContentIntent(pi)
                .setFullScreenIntent(pi, true)
                .build()
            nm.notify(CONSENT_NOTIF_ID, notif)
        } catch (e: Exception) {
            Log.e(TAG, "Failed posting consent notification: ${e.message}")
        }
    }

    private fun cancelConsentNotification(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(CONSENT_NOTIF_ID)
        } catch (ignored: Exception) {}
    }
}
