package com.link.clipboardsync

import android.content.ComponentName
import android.content.Context
import android.database.ContentObserver
import android.graphics.Bitmap
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Observes active Android media sessions (via NotificationListener authorization)
 * and STREAM_MUSIC volume, syncing Now Playing metadata + transport/volume controls
 * with the connected Mac over the encrypted :8765 channel.
 */
object PhoneMediaManager {
    private const val TAG = "PhoneMediaManager"
    private const val MAX_ARTWORK_DIM = 160

    data class MediaSnapshot(
        val isActive: Boolean,
        val isPlaying: Boolean = false,
        val title: String = "",
        val artist: String = "",
        val album: String = "",
        val appName: String = "",
        val durationMs: Long = 0L,
        val positionMs: Long = 0L,
        val playbackSpeed: Float = 1.0f,
        val volumeIndex: Int = 0,
        val maxVolume: Int = 15,
        val canSeek: Boolean = false,
        val canSkipNext: Boolean = false,
        val canSkipPrevious: Boolean = false,
        val canControlVolume: Boolean = true,
        val artworkHash: String = "",
        val artworkBase64: String? = null
    )

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val lock = Any()
    private val appNameCache = ConcurrentHashMap<String, String>()

    @Volatile private var isObserving = false
    private val observedControllers = LinkedHashMap<MediaSession.Token, MediaController>()
    private val controllerCallbacks = HashMap<MediaSession.Token, MediaController.Callback>()
    private var sessionsListener: MediaSessionManager.OnActiveSessionsChangedListener? = null
    private var volumeObserver: ContentObserver? = null
    private var lastSentSignature: String? = null
    private var lastSentArtworkHash: String = ""
    private var cachedArtworkHash: String = ""
    private var cachedArtworkBase64: String? = null

    fun startObserving(context: Context) {
        val appCtx = context.applicationContext
        mainHandler.post {
            synchronized(lock) {
                if (isObserving) {
                    refreshSessionsAndPush(appCtx, forceArtwork = true)
                    return@post
                }
                isObserving = true

                val msm = appCtx.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
                val component = ComponentName(appCtx, BridgeNotificationListenerService::class.java)

                val listener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
                    bindAllControllersLocked(appCtx, controllers ?: emptyList())
                    pushCurrentState(appCtx, forceArtwork = false)
                }
                sessionsListener = listener
                try {
                    msm?.addOnActiveSessionsChangedListener(listener, component, mainHandler)
                    val initial = msm?.getActiveSessions(component) ?: emptyList()
                    bindAllControllersLocked(appCtx, initial)
                } catch (se: SecurityException) {
                    Log.w(TAG, "Notification access missing for MediaSessionManager: ${se.message}")
                } catch (e: Exception) {
                    Log.w(TAG, "Failed starting MediaSession observation: ${e.message}")
                }

                val volObs = object : ContentObserver(mainHandler) {
                    override fun onChange(selfChange: Boolean) {
                        super.onChange(selfChange)
                        pushCurrentState(appCtx, forceArtwork = false)
                    }
                }
                volumeObserver = volObs
                try {
                    appCtx.contentResolver.registerContentObserver(
                        Settings.System.CONTENT_URI,
                        true,
                        volObs
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "Failed registering volume ContentObserver: ${e.message}")
                }
            }
            pushCurrentState(appCtx, forceArtwork = true)
        }
    }

    fun stopObserving(context: Context) {
        val appCtx = context.applicationContext
        mainHandler.post {
            synchronized(lock) {
                isObserving = false
                unregisterAllControllersLocked()

                sessionsListener?.let { listener ->
                    try {
                        val msm = appCtx.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
                        msm?.removeOnActiveSessionsChangedListener(listener)
                    } catch (_: Exception) {}
                }
                sessionsListener = null

                volumeObserver?.let { obs ->
                    try {
                        appCtx.contentResolver.unregisterContentObserver(obs)
                    } catch (_: Exception) {}
                }
                volumeObserver = null
                lastSentSignature = null
                lastSentArtworkHash = ""
            }
        }
    }

    fun sendCurrentStatus(context: Context, forceArtwork: Boolean = true) {
        val appCtx = context.applicationContext
        mainHandler.post {
            refreshSessionsAndPush(appCtx, forceArtwork = forceArtwork)
        }
    }

    fun handleMediaAction(context: Context, jsonObj: JSONObject) {
        val appCtx = context.applicationContext
        val action = jsonObj.optString("action")
        mainHandler.post {
            when (action) {
                "set_volume" -> {
                    val am = appCtx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                    if (am != null) {
                        val maxVol = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                        val target = if (jsonObj.has("volumeIndex")) {
                            jsonObj.optInt("volumeIndex", 0).coerceIn(0, maxVol)
                        } else {
                            val pct = jsonObj.optInt("volumePercent", 0).coerceIn(0, 100)
                            ((pct / 100.0) * maxVol).toInt().coerceIn(0, maxVol)
                        }
                        try {
                            am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed setting STREAM_MUSIC volume: ${e.message}")
                        }
                        pushCurrentState(appCtx, forceArtwork = false, forceSend = true)
                    }
                }
                "play_pause", "next", "previous", "seek" -> {
                    val controller = findPrimaryController(appCtx) ?: return@post
                    val controls = controller.transportControls
                    when (action) {
                        "play_pause" -> {
                            val state = controller.playbackState?.state
                            if (state == PlaybackState.STATE_PLAYING || state == PlaybackState.STATE_BUFFERING) {
                                controls.pause()
                            } else {
                                controls.play()
                            }
                        }
                        "next" -> controls.skipToNext()
                        "previous" -> controls.skipToPrevious()
                        "seek" -> {
                            val posMs = jsonObj.optLong("positionMs", 0L).coerceAtLeast(0L)
                            controls.seekTo(posMs)
                        }
                    }
                }
                else -> Log.d(TAG, "Unknown media_action: $action")
            }
        }
    }

    private fun refreshSessionsAndPush(appCtx: Context, forceArtwork: Boolean) {
        val msm = appCtx.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
        val component = ComponentName(appCtx, BridgeNotificationListenerService::class.java)
        try {
            val sessions = msm?.getActiveSessions(component) ?: emptyList()
            synchronized(lock) {
                bindAllControllersLocked(appCtx, sessions)
            }
        } catch (se: SecurityException) {
            Log.w(TAG, "Missing notification access for getActiveSessions: ${se.message}")
            synchronized(lock) {
                unregisterAllControllersLocked()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error querying active media sessions: ${e.message}")
        }
        pushCurrentState(appCtx, forceArtwork = forceArtwork, forceSend = forceArtwork)
    }

    private fun bindAllControllersLocked(appCtx: Context, controllers: List<MediaController>) {
        val candidates = controllers.filter { it.packageName != appCtx.packageName }
        val newTokens = candidates.map { it.sessionToken }.toSet()

        val removedTokens = observedControllers.keys.filter { it !in newTokens }
        for (token in removedTokens) {
            val oldCtrl = observedControllers.remove(token)
            val oldCb = controllerCallbacks.remove(token)
            if (oldCtrl != null && oldCb != null) {
                try {
                    oldCtrl.unregisterCallback(oldCb)
                } catch (_: Exception) {}
            }
        }

        // Preserve MediaSessionManager priority order in LinkedHashMap
        val reordered = LinkedHashMap<MediaSession.Token, MediaController>()
        for (ctrl in candidates) {
            val token = ctrl.sessionToken
            val existingCtrl = observedControllers[token]
            if (existingCtrl != null) {
                reordered[token] = existingCtrl
            } else {
                val cb = object : MediaController.Callback() {
                    override fun onPlaybackStateChanged(state: PlaybackState?) {
                        pushCurrentState(appCtx, forceArtwork = false)
                    }

                    override fun onMetadataChanged(metadata: MediaMetadata?) {
                        pushCurrentState(appCtx, forceArtwork = false)
                    }

                    override fun onSessionDestroyed() {
                        refreshSessionsAndPush(appCtx, forceArtwork = false)
                    }
                }
                try {
                    ctrl.registerCallback(cb, mainHandler)
                    reordered[token] = ctrl
                    controllerCallbacks[token] = cb
                } catch (e: Exception) {
                    Log.w(TAG, "Failed registering callback for ${ctrl.packageName}: ${e.message}")
                }
            }
        }
        observedControllers.clear()
        observedControllers.putAll(reordered)
        Log.d(TAG, "Bound ${observedControllers.size} active media session(s)")
    }

    private fun unregisterAllControllersLocked() {
        for ((token, ctrl) in observedControllers) {
            val cb = controllerCallbacks[token]
            if (cb != null) {
                try {
                    ctrl.unregisterCallback(cb)
                } catch (_: Exception) {}
            }
        }
        observedControllers.clear()
        controllerCallbacks.clear()
    }

    private fun findPrimaryController(appCtx: Context): MediaController? {
        val list = synchronized(lock) {
            observedControllers.values.toList()
        }
        val chosen = list.firstOrNull { isPlayingState(it.playbackState?.state) && !extractTitle(it.metadata).isNullOrBlank() }
            ?: list.firstOrNull { isActiveOrPausedState(it.playbackState?.state) && !extractTitle(it.metadata).isNullOrBlank() }
        if (chosen != null) return chosen

        // Fallback fresh query if list was empty
        val msm = appCtx.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager ?: return null
        val component = ComponentName(appCtx, BridgeNotificationListenerService::class.java)
        return try {
            val sessions = msm.getActiveSessions(component)
            synchronized(lock) {
                bindAllControllersLocked(appCtx, sessions)
                observedControllers.values.firstOrNull {
                    isPlayingState(it.playbackState?.state) && !extractTitle(it.metadata).isNullOrBlank()
                } ?: observedControllers.values.firstOrNull {
                    isActiveOrPausedState(it.playbackState?.state) && !extractTitle(it.metadata).isNullOrBlank()
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun isPlayingState(state: Int?): Boolean {
        return state == PlaybackState.STATE_PLAYING || state == PlaybackState.STATE_BUFFERING
    }

    private fun isActiveOrPausedState(state: Int?): Boolean {
        return isPlayingState(state) || state == PlaybackState.STATE_PAUSED
    }

    private fun extractTitle(metadata: MediaMetadata?): String? {
        if (metadata == null) return null
        val raw = metadata.getText(MediaMetadata.METADATA_KEY_DISPLAY_TITLE)?.toString()
            ?: metadata.getText(MediaMetadata.METADATA_KEY_TITLE)?.toString()
            ?: metadata.description.title?.toString()
        return raw?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun extractArtist(metadata: MediaMetadata?): String {
        if (metadata == null) return ""
        return (metadata.getText(MediaMetadata.METADATA_KEY_ARTIST)?.toString()
            ?: metadata.getText(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)?.toString()
            ?: metadata.getText(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE)?.toString()
            ?: metadata.description.subtitle?.toString()
            ?: "").trim()
    }

    private fun pushCurrentState(appCtx: Context, forceArtwork: Boolean, forceSend: Boolean = false) {
        val client = ClipboardSyncManager.networkClient ?: return
        if (!client.isConnected()) return

        val snapshot = buildSnapshot(appCtx, includeArtwork = forceArtwork)
        val signature = listOf(
            snapshot.isActive,
            snapshot.isPlaying,
            snapshot.title,
            snapshot.artist,
            snapshot.album,
            snapshot.appName,
            snapshot.durationMs,
            snapshot.positionMs,
            snapshot.playbackSpeed,
            snapshot.volumeIndex,
            snapshot.maxVolume,
            snapshot.canSeek,
            snapshot.canSkipNext,
            snapshot.canSkipPrevious,
            snapshot.canControlVolume,
            snapshot.artworkHash
        ).joinToString("|")

        if (!forceSend && !forceArtwork && signature == lastSentSignature) {
            return
        }
        lastSentSignature = signature
        if (!snapshot.artworkBase64.isNullOrEmpty()) {
            lastSentArtworkHash = snapshot.artworkHash
        }
        Log.d(
            TAG,
            "Sending media_status (active=${snapshot.isActive}, playing=${snapshot.isPlaying}, app=${snapshot.appName}, vol=${snapshot.volumeIndex}/${snapshot.maxVolume})"
        )
        client.sendRawJson(buildMediaStatusJson(snapshot))
    }

    private fun buildSnapshot(appCtx: Context, includeArtwork: Boolean): MediaSnapshot {
        val am = appCtx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val volumeIndex = am?.getStreamVolume(AudioManager.STREAM_MUSIC) ?: 0
        val maxVolume = (am?.getStreamMaxVolume(AudioManager.STREAM_MUSIC) ?: 15).coerceAtLeast(1)
        val canControlVolume = !(am?.isVolumeFixed ?: false)

        val candidates = synchronized(lock) { observedControllers.values.toList() }
        val controller = candidates.firstOrNull {
            isPlayingState(it.playbackState?.state) && !extractTitle(it.metadata).isNullOrBlank()
        } ?: candidates.firstOrNull {
            isActiveOrPausedState(it.playbackState?.state) && !extractTitle(it.metadata).isNullOrBlank()
        }

        val pbState = controller?.playbackState
        val metadata = controller?.metadata
        val title = extractTitle(metadata)

        if (controller == null || metadata == null || title.isNullOrEmpty() || !isActiveOrPausedState(pbState?.state)) {
            return MediaSnapshot(
                isActive = false,
                volumeIndex = volumeIndex,
                maxVolume = maxVolume,
                canControlVolume = canControlVolume
            )
        }

        val artist = extractArtist(metadata)
        val album = (metadata.getText(MediaMetadata.METADATA_KEY_ALBUM)?.toString() ?: "").trim()
        val durationMs = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION).coerceAtLeast(0L)
        val positionMs = (pbState?.position ?: 0L).coerceAtLeast(0L)
        val isPlaying = isPlayingState(pbState?.state)
        val speed = if (isPlaying) (pbState?.playbackSpeed ?: 1.0f).coerceAtLeast(0.1f) else 0f
        val actions = pbState?.actions ?: 0L
        val canSeek = durationMs > 0L && (actions and PlaybackState.ACTION_SEEK_TO) != 0L
        val canSkipNext = (actions and PlaybackState.ACTION_SKIP_TO_NEXT) != 0L
        val canSkipPrevious = (actions and PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0L

        val rawBitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON)

        var artHash = ""
        var artBase64: String? = null
        if (rawBitmap != null) {
            val encoded = encodeArtwork(rawBitmap)
            if (encoded != null) {
                artHash = encoded.first
                if (includeArtwork || artHash != lastSentArtworkHash) {
                    artBase64 = encoded.second
                }
            }
        }

        return MediaSnapshot(
            isActive = true,
            isPlaying = isPlaying,
            title = title,
            artist = artist,
            album = album,
            appName = resolveAppName(appCtx, controller.packageName),
            durationMs = durationMs,
            positionMs = positionMs,
            playbackSpeed = speed,
            volumeIndex = volumeIndex,
            maxVolume = maxVolume,
            canSeek = canSeek,
            canSkipNext = canSkipNext,
            canSkipPrevious = canSkipPrevious,
            canControlVolume = canControlVolume,
            artworkHash = artHash,
            artworkBase64 = artBase64
        )
    }

    private fun resolveAppName(appCtx: Context, pkg: String?): String {
        if (pkg.isNullOrBlank()) return ""
        appNameCache[pkg]?.let { return it }
        val resolved = try {
            val pm = appCtx.packageManager
            val info = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            pkg
        }
        appNameCache[pkg] = resolved
        return resolved
    }

    private fun encodeArtwork(bitmap: Bitmap): Pair<String, String>? {
        return try {
            val w = bitmap.width
            val h = bitmap.height
            if (w <= 0 || h <= 0) return null
            val scale = minOf(1.0f, MAX_ARTWORK_DIM.toFloat() / maxOf(w, h).toFloat())
            val targetW = (w * scale).toInt().coerceAtLeast(1)
            val targetH = (h * scale).toInt().coerceAtLeast(1)
            val scaled = if (scale < 1.0f) {
                Bitmap.createScaledBitmap(bitmap, targetW, targetH, true)
            } else {
                bitmap
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 78, out)
            if (scaled !== bitmap) {
                scaled.recycle()
            }
            val bytes = out.toByteArray()
            if (bytes.isEmpty()) return null
            val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            val hash = digest.take(8).joinToString("") { "%02x".format(it) }
            if (hash == cachedArtworkHash && cachedArtworkBase64 != null) {
                return hash to cachedArtworkBase64!!
            }
            val b64 = Base64.encodeToString(bytes, Base64.NO_WRAP)
            cachedArtworkHash = hash
            cachedArtworkBase64 = b64
            hash to b64
        } catch (e: Exception) {
            Log.w(TAG, "Failed encoding album artwork: ${e.message}")
            null
        }
    }

    fun buildMediaStatusJson(snapshot: MediaSnapshot): String {
        return JSONObject().apply {
            put("type", "media_status")
            put("isActive", snapshot.isActive)
            put("isPlaying", snapshot.isPlaying)
            put("title", snapshot.title)
            put("artist", snapshot.artist)
            put("album", snapshot.album)
            put("appName", snapshot.appName)
            put("durationMs", snapshot.durationMs)
            put("positionMs", snapshot.positionMs)
            put("playbackSpeed", snapshot.playbackSpeed.toDouble())
            put("volumeIndex", snapshot.volumeIndex)
            put("maxVolume", snapshot.maxVolume)
            put("canSeek", snapshot.canSeek)
            put("canSkipNext", snapshot.canSkipNext)
            put("canSkipPrevious", snapshot.canSkipPrevious)
            put("canControlVolume", snapshot.canControlVolume)
            put("artworkHash", snapshot.artworkHash)
            if (!snapshot.artworkBase64.isNullOrEmpty()) {
                put("artworkBase64", snapshot.artworkBase64)
            }
        }.toString()
    }
}
