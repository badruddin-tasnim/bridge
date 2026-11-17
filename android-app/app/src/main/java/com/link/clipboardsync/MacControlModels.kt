package com.link.clipboardsync

import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

/**
 * Live Mac hardware telemetry (MacBook battery + Sound/Silent mute + volume) received from Mac over `mac_status`.
 */
data class MacSystemStatus(
    val batteryPercent: Int? = null,
    val isCharging: Boolean = false,
    val isMuted: Boolean = false,
    val volumePercent: Int = 0,
    val canToggleMute: Boolean = true,
    val canControlVolume: Boolean = true
) {
    companion object {
        fun fromJson(json: JSONObject): MacSystemStatus {
            val battery = if (json.has("batteryPercent") && !json.isNull("batteryPercent")) {
                json.optInt("batteryPercent", -1).takeIf { it in 0..100 }
            } else {
                null
            }
            return MacSystemStatus(
                batteryPercent = battery,
                isCharging = json.optBoolean("isCharging", false),
                isMuted = json.optBoolean("isMuted", false),
                volumePercent = json.optInt("volumePercent", 0).coerceIn(0, 100),
                canToggleMute = json.optBoolean("canToggleMute", true),
                canControlVolume = json.optBoolean("canControlVolume", true)
            )
        }

        fun buildMacControlJson(action: String, muted: Boolean? = null, volumePercent: Int? = null): String {
            return JSONObject().apply {
                put("type", "mac_control")
                put("action", action)
                if (muted != null) put("muted", muted)
                if (volumePercent != null) put("volumePercent", volumePercent.coerceIn(0, 100))
            }.toString()
        }
    }
}

/**
 * Live Mac media playback snapshot received from Mac over `mac_media_status`.
 */
data class MacMediaStatus(
    val isActive: Boolean = false,
    val isPlaying: Boolean = false,
    val title: String = "",
    val artist: String = "",
    val album: String = "",
    val appName: String = "",
    val durationMs: Long = 0L,
    val positionMs: Long = 0L,
    val playbackSpeed: Double = 1.0,
    val canSeek: Boolean = false,
    val canSkipNext: Boolean = false,
    val canSkipPrevious: Boolean = false,
    val artworkHash: String? = null,
    val artworkBase64: String? = null,
    val receivedAtElapsedMs: Long = 0L
) {
    fun estimatedPositionMs(nowElapsedMs: Long): Long {
        if (!isActive) return 0L
        val base = if (!isPlaying) {
            positionMs
        } else {
            val elapsed = max(0L, nowElapsedMs - receivedAtElapsedMs)
            val speed = if (playbackSpeed > 0.0) playbackSpeed else 1.0
            positionMs + (elapsed * speed).toLong()
        }
        return if (durationMs > 0L) base.coerceIn(0L, durationMs) else max(0L, base)
    }

    companion object {
        fun fromJson(
            json: JSONObject,
            previous: MacMediaStatus?,
            receivedAtElapsedMs: Long
        ): MacMediaStatus {
            val isActive = json.optBoolean("isActive", false)
            if (!isActive) {
                return MacMediaStatus(isActive = false, isPlaying = false, receivedAtElapsedMs = receivedAtElapsedMs)
            }
            val rawHash = json.optString("artworkHash", "").takeIf { it.isNotEmpty() }
            val rawB64 = json.optString("artworkBase64", "").takeIf { it.isNotEmpty() }
            val resolvedB64 = rawB64 ?: if (rawHash != null && rawHash == previous?.artworkHash) {
                previous.artworkBase64
            } else {
                null
            }
            return MacMediaStatus(
                isActive = true,
                isPlaying = json.optBoolean("isPlaying", false),
                title = json.optString("title", "").ifBlank { "Playing on Mac" },
                artist = json.optString("artist", ""),
                album = json.optString("album", ""),
                appName = json.optString("appName", ""),
                durationMs = max(0L, json.optLong("durationMs", 0L)),
                positionMs = max(0L, json.optLong("positionMs", 0L)),
                playbackSpeed = json.optDouble("playbackSpeed", 1.0),
                canSeek = json.optBoolean("canSeek", false),
                canSkipNext = json.optBoolean("canSkipNext", false),
                canSkipPrevious = json.optBoolean("canSkipPrevious", false),
                artworkHash = rawHash,
                artworkBase64 = resolvedB64,
                receivedAtElapsedMs = receivedAtElapsedMs
            )
        }

        fun buildMediaActionJson(
            action: String,
            positionMs: Long? = null,
            deltaMs: Long? = null,
            volumePercent: Int? = null
        ): String {
            return JSONObject().apply {
                put("type", "mac_media_action")
                put("action", action)
                if (positionMs != null) put("positionMs", max(0L, positionMs))
                if (deltaMs != null) put("deltaMs", deltaMs)
                if (volumePercent != null) put("volumePercent", min(100, max(0, volumePercent)))
            }.toString()
        }

        fun formatTimeMs(ms: Long): String {
            val totalSeconds = max(0L, ms / 1000L)
            val hours = totalSeconds / 3600L
            val minutes = (totalSeconds % 3600L) / 60L
            val seconds = totalSeconds % 60L
            return if (hours > 0L) {
                String.format("%d:%02d:%02d", hours, minutes, seconds)
            } else {
                String.format("%d:%02d", minutes, seconds)
            }
        }
    }
}
