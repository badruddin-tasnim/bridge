package com.link.clipboardsync

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.media.RingtoneManager
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.sin
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import org.json.JSONObject

/**
 * Executes remote phone controls from the paired Mac:
 * - Ringer mode (normal / vibrate / silent)
 * - Native Android Do Not Disturb toggle
 * - Find My Phone continuous alarm-stream ringing
 */
object PhoneControlManager {
    private const val TAG = "PhoneControlManager"
    const val ACTION_STOP_RING_PHONE = "com.link.clipboardsync.ACTION_STOP_RING_PHONE"
    private const val FIND_PHONE_CHANNEL_ID = "bridge_find_phone"
    private const val FIND_PHONE_NOTIF_ID = 4101
    private const val DND_PROMPT_CHANNEL_ID = "bridge_dnd_permission"
    private const val DND_PROMPT_NOTIF_ID = 4102

    @Volatile
    var isRinging: Boolean = false
        private set

    private val ringLock = Any()
    private var beaconTrack: AudioTrack? = null
    private var mediaPlayer: MediaPlayer? = null
    private var previousAlarmVolume: Int? = null

    fun hasDndPermission(context: Context): Boolean {
        val nm = context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        return nm.isNotificationPolicyAccessGranted
    }

    fun getRingerModeString(context: Context): String {
        val am = context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return "normal"
        return when (am.ringerMode) {
            AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
            AudioManager.RINGER_MODE_SILENT -> "silent"
            else -> "normal"
        }
    }

    fun isDndEnabled(context: Context): Boolean {
        val nm = context.applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return false
        return when (nm.currentInterruptionFilter) {
            NotificationManager.INTERRUPTION_FILTER_PRIORITY,
            NotificationManager.INTERRUPTION_FILTER_NONE,
            NotificationManager.INTERRUPTION_FILTER_ALARMS -> true
            else -> false
        }
    }

    fun handleControlCommand(context: Context, jsonObj: JSONObject) {
        val action = jsonObj.optString("action")
        when (action) {
            "set_ringer_mode" -> {
                val mode = jsonObj.optString("mode")
                setRingerMode(context, mode)
            }
            "set_dnd" -> {
                val enabled = jsonObj.optBoolean("enabled", false)
                setDndEnabled(context, enabled)
            }
            "ring_phone" -> {
                val ringing = jsonObj.optBoolean("ringing", false)
                if (ringing) {
                    startRinging(context)
                } else {
                    stopRinging(context)
                }
            }
            else -> Log.d(TAG, "Ignoring unknown device_control action: $action")
        }
    }

    fun setRingerMode(context: Context, mode: String) {
        val appCtx = context.applicationContext
        val am = appCtx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        val targetMode = when (mode) {
            "vibrate" -> AudioManager.RINGER_MODE_VIBRATE
            "silent" -> AudioManager.RINGER_MODE_SILENT
            else -> AudioManager.RINGER_MODE_NORMAL
        }

        if ((targetMode == AudioManager.RINGER_MODE_SILENT || am.ringerMode == AudioManager.RINGER_MODE_SILENT) &&
            !hasDndPermission(appCtx)
        ) {
            Log.w(TAG, "Missing Do Not Disturb access for silent ringer transition")
            showDndPermissionPromptNotification(appCtx)
            DeviceStatusMonitor.sendCurrentStatus(appCtx, force = true)
            return
        }

        try {
            am.ringerMode = targetMode
        } catch (se: SecurityException) {
            Log.w(TAG, "SecurityException setting ringer mode '$mode': ${se.message}")
            showDndPermissionPromptNotification(appCtx)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set ringer mode '$mode': ${e.message}")
        }
        DeviceStatusMonitor.sendCurrentStatus(appCtx, force = true)
    }

    fun setDndEnabled(context: Context, enabled: Boolean) {
        val appCtx = context.applicationContext
        val nm = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

        if (!nm.isNotificationPolicyAccessGranted) {
            Log.w(TAG, "Cannot toggle DND: Notification Policy access not granted")
            showDndPermissionPromptNotification(appCtx)
            DeviceStatusMonitor.sendCurrentStatus(appCtx, force = true)
            return
        }

        try {
            val filter = if (enabled) {
                NotificationManager.INTERRUPTION_FILTER_PRIORITY
            } else {
                NotificationManager.INTERRUPTION_FILTER_ALL
            }
            nm.setInterruptionFilter(filter)
        } catch (se: SecurityException) {
            Log.w(TAG, "SecurityException setting DND: ${se.message}")
            showDndPermissionPromptNotification(appCtx)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to set DND ($enabled): ${e.message}")
        }
        DeviceStatusMonitor.sendCurrentStatus(appCtx, force = true)
    }

    fun startRinging(context: Context) {
        val appCtx = context.applicationContext
        synchronized(ringLock) {
            stopMediaAndVibrationLocked(appCtx)

            val am = appCtx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            if (am != null) {
                try {
                    val current = am.getStreamVolume(AudioManager.STREAM_ALARM)
                    val max = am.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                    val target = (max * 0.85f).toInt().coerceAtLeast(1)
                    if (current < target) {
                        previousAlarmVolume = current
                        am.setStreamVolume(AudioManager.STREAM_ALARM, target, 0)
                    } else {
                        previousAlarmVolume = null
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Could not adjust alarm volume: ${e.message}")
                }
            }

            val startedBeacon = startBeaconTone()
            if (!startedBeacon) {
                val fallbackUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)

                if (fallbackUri != null) {
                    try {
                        val player = MediaPlayer().apply {
                            setAudioAttributes(
                                AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_ALARM)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                    .build()
                            )
                            setDataSource(appCtx, fallbackUri)
                            isLooping = true
                            prepare()
                            start()
                        }
                        mediaPlayer = player
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to start fallback MediaPlayer for Find My Phone: ${e.message}")
                    }
                }
            }

            startAlarmVibration(appCtx)
            isRinging = true
            showFindPhoneNotification(appCtx)
        }
        DeviceStatusMonitor.sendCurrentStatus(appCtx, force = true)
    }

    fun generateFindPhoneBeaconPcm(sampleRate: Int = 24000): ShortArray {
        val totalSamples = (sampleRate * 1.25).toInt()
        val samples = ShortArray(totalSamples)
        val maxAmp = Short.MAX_VALUE * 0.78

        fun addTone(startSec: Double, durationSec: Double, freqHz: Double) {
            val startIdx = (startSec * sampleRate).toInt().coerceIn(0, totalSamples)
            val endIdx = ((startSec + durationSec) * sampleRate).toInt().coerceIn(startIdx, totalSamples)
            val attackSec = 0.008
            for (i in startIdx until endIdx) {
                val t = (i - startIdx).toDouble() / sampleRate
                val attack = if (t < attackSec) (t / attackSec) else 1.0
                val decay = exp(-10.5 * t)
                val wave = 0.82 * sin(2.0 * PI * freqHz * t) + 0.18 * sin(2.0 * PI * (freqHz * 2.0) * t)
                val value = (wave * attack * decay * maxAmp).toInt()
                val mixed = (samples[i].toInt() + value).coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                samples[i] = mixed.toShort()
            }
        }

        // Crisp two-note sonar chime (A5 -> D6), then clean pause
        addTone(startSec = 0.00, durationSec = 0.18, freqHz = 880.0)
        addTone(startSec = 0.20, durationSec = 0.22, freqHz = 1174.66)
        return samples
    }

    private fun startBeaconTone(): Boolean {
        return try {
            val sampleRate = 24000
            val pcm = generateFindPhoneBeaconPcm(sampleRate)
            val bufferBytes = pcm.size * 2
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(bufferBytes)
                .build()

            val written = track.write(pcm, 0, pcm.size)
            if (written <= 0) {
                track.release()
                return false
            }
            track.setLoopPoints(0, pcm.size, -1)
            track.play()
            beaconTrack = track
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed starting AudioTrack beacon: ${e.message}")
            false
        }
    }

    fun stopRinging(context: Context) {
        val appCtx = context.applicationContext
        val wasRinging: Boolean
        synchronized(ringLock) {
            wasRinging = isRinging || beaconTrack != null || mediaPlayer != null
            stopMediaAndVibrationLocked(appCtx)
            isRinging = false
            cancelFindPhoneNotification(appCtx)
        }
        if (wasRinging) {
            DeviceStatusMonitor.sendCurrentStatus(appCtx, force = true)
        }
    }

    private fun stopMediaAndVibrationLocked(appCtx: Context) {
        try {
            beaconTrack?.let { track ->
                if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    track.stop()
                }
                track.release()
            }
        } catch (_: Exception) {}
        beaconTrack = null

        try {
            mediaPlayer?.let { player ->
                if (player.isPlaying) {
                    player.stop()
                }
                player.release()
            }
        } catch (_: Exception) {}
        mediaPlayer = null

        previousAlarmVolume?.let { savedVol ->
            try {
                val am = appCtx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                am?.setStreamVolume(AudioManager.STREAM_ALARM, savedVol, 0)
            } catch (_: Exception) {}
        }
        previousAlarmVolume = null

        stopVibration(appCtx)
    }

    private fun getVibrator(appCtx: Context): Vibrator? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vm = appCtx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            vm?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            appCtx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private fun startAlarmVibration(appCtx: Context) {
        val vibrator = getVibrator(appCtx) ?: return
        if (!vibrator.hasVibrator()) return
        try {
            val pattern = longArrayOf(0, 600, 400)
            val effect = VibrationEffect.createWaveform(pattern, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val attrs = android.os.VibrationAttributes.createForUsage(android.os.VibrationAttributes.USAGE_ALARM)
                vibrator.vibrate(effect, attrs)
            } else {
                @Suppress("DEPRECATION")
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                @Suppress("DEPRECATION")
                vibrator.vibrate(effect, attrs)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not start alarm vibration: ${e.message}")
        }
    }

    private fun stopVibration(appCtx: Context) {
        try {
            getVibrator(appCtx)?.cancel()
        } catch (_: Exception) {}
    }

    private fun showFindPhoneNotification(appCtx: Context) {
        val nm = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                FIND_PHONE_CHANNEL_ID,
                "Find My Phone",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Alert displayed while ringing your phone from Mac"
                setSound(null, null)
                enableVibration(false)
            }
            nm.createNotificationChannel(ch)
        }

        val stopIntent = Intent(appCtx, PhoneFinderActionReceiver::class.java).apply {
            action = ACTION_STOP_RING_PHONE
        }
        val stopPending = PendingIntent.getBroadcast(
            appCtx,
            FIND_PHONE_NOTIF_ID,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notif = NotificationCompat.Builder(appCtx, FIND_PHONE_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Ringing from Mac")
            .setContentText("Tap Stop Ringing to silence this alert.")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(stopPending)
            .addAction(0, "Stop Ringing", stopPending)
            .build()

        try {
            nm.notify(FIND_PHONE_NOTIF_ID, notif)
        } catch (e: SecurityException) {
            Log.w(TAG, "Cannot post Find My Phone notification: ${e.message}")
        }
    }

    private fun cancelFindPhoneNotification(appCtx: Context) {
        try {
            val nm = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(FIND_PHONE_NOTIF_ID)
        } catch (_: Exception) {}
    }

    private fun showDndPermissionPromptNotification(appCtx: Context) {
        val nm = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                DND_PROMPT_CHANNEL_ID,
                "Permissions",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Prompts when Mac requests Do Not Disturb or Silent mode control"
            }
            nm.createNotificationChannel(ch)
        }

        val settingsIntent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        val pending = PendingIntent.getActivity(
            appCtx,
            DND_PROMPT_NOTIF_ID,
            settingsIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val notif = NotificationCompat.Builder(appCtx, DND_PROMPT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Do Not Disturb access needed")
            .setContentText("Tap to allow Bridge to toggle Silent mode and Do Not Disturb from your Mac.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()

        try {
            nm.notify(DND_PROMPT_NOTIF_ID, notif)
        } catch (_: SecurityException) {}
    }
}
