package com.link.clipboardsync

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service (`mediaProjection`) that captures the screen into a VirtualDisplay
 * backed by a hardware H.264 MediaCodec encoder and streams framed Annex-B NALUs over TCP to Mac.
 */
class ScreenMirrorForegroundService : Service() {

    companion object {
        private const val TAG = "ScreenMirrorFGService"
        private const val NOTIFICATION_ID = 4201
        private const val CHANNEL_ID = "bridge_screen_mirror"
        const val ACTION_STOP_MIRRORING = "com.link.clipboardsync.ACTION_STOP_MIRRORING"

        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_RESULT_DATA = "result_data"
        private const val EXTRA_MAC_HOST = "mac_host"
        private const val EXTRA_PORT = "mirror_port"
        private const val EXTRA_TOKEN = "mirror_token"
        private const val EXTRA_MAX_DIM = "mirror_max_dim"
        private const val EXTRA_BITRATE = "mirror_bitrate"
        private const val EXTRA_FPS = "mirror_fps"

        @Volatile
        var activeInstance: ScreenMirrorForegroundService? = null
            private set

        fun start(
            context: Context,
            resultCode: Int,
            resultData: Intent,
            macHost: String,
            offer: MirrorStreamOffer
        ) {
            val intent = Intent(context, ScreenMirrorForegroundService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, resultData)
                putExtra(EXTRA_MAC_HOST, macHost)
                putExtra(EXTRA_PORT, offer.port)
                putExtra(EXTRA_TOKEN, offer.token)
                putExtra(EXTRA_MAX_DIM, offer.maxDimension)
                putExtra(EXTRA_BITRATE, offer.bitRate)
                putExtra(EXTRA_FPS, offer.fps)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed starting ScreenMirrorForegroundService: ${e.message}", e)
                PhoneMirrorController.handleServiceStopped("service_start_failed", notifyMac = true)
            }
        }

        fun stop(context: Context) {
            try {
                activeInstance?.stopCaptureAndSelf("user_stopped", notifyMac = false)
                context.stopService(Intent(context, ScreenMirrorForegroundService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping ScreenMirrorForegroundService: ${e.message}")
            }
        }
    }

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val isStreaming = AtomicBoolean(false)
    private val reconfigureRequested = AtomicBoolean(false)

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var mediaCodec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var socket: Socket? = null
    private var workerThread: Thread? = null
    private var displayListener: DisplayManager.DisplayListener? = null

    @Volatile
    private var currentStreamWidth = 720
    @Volatile
    private var currentStreamHeight = 1600
    @Volatile
    private var currentRotation = 0
    @Volatile
    private var maxDimension = 1280
    @Volatile
    private var bitRate = 5_000_000
    @Volatile
    private var targetFps = 60

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundMediaProjection()

        if (intent == null) {
            stopCaptureAndSelf("missing_intent", notifyMac = true)
            return START_NOT_STICKY
        }

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val resultData: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        val macHost = intent.getStringExtra(EXTRA_MAC_HOST) ?: ""
        val mirrorPort = intent.getIntExtra(EXTRA_PORT, -1)
        val token = intent.getStringExtra(EXTRA_TOKEN) ?: ""
        maxDimension = intent.getIntExtra(EXTRA_MAX_DIM, 1280).coerceIn(480, 1920)
        bitRate = intent.getIntExtra(EXTRA_BITRATE, 5_000_000).coerceIn(1_000_000, 16_000_000)
        targetFps = intent.getIntExtra(EXTRA_FPS, 60).coerceIn(15, 60)

        if (resultCode != Activity.RESULT_OK || resultData == null || macHost.isBlank() || mirrorPort !in 1024..65535 || token.length != PhoneMirrorProtocol.TOKEN_HEX_LENGTH) {
            stopCaptureAndSelf("invalid_stream_parameters", notifyMac = true)
            return START_NOT_STICKY
        }

        stopWorkerLocked()

        val projectionManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        val projection = try {
            projectionManager?.getMediaProjection(resultCode, resultData)
        } catch (e: Exception) {
            Log.e(TAG, "getMediaProjection failed: ${e.message}", e)
            null
        }

        if (projection == null) {
            stopCaptureAndSelf("media_projection_null", notifyMac = true)
            return START_NOT_STICKY
        }

        mediaProjection = projection
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "System stopped MediaProjection")
                stopCaptureAndSelf("projection_stopped_by_system", notifyMac = true)
            }
        }, mainHandler)

        val displayGeom = queryDisplayGeometry()
        val (streamW, streamH) = PhoneMirrorProtocol.computeStreamDimensions(
            rawWidth = displayGeom.widthPx,
            rawHeight = displayGeom.heightPx,
            maxDimension = maxDimension
        )
        currentStreamWidth = streamW
        currentStreamHeight = streamH
        currentRotation = displayGeom.rotation

        registerRotationListener()

        isStreaming.set(true)
        val thread = Thread({
            runStreamingLoop(
                macHost = macHost,
                port = mirrorPort,
                tokenHex = token,
                densityDpi = displayGeom.densityDpi
            )
        }, "BridgeMirrorStreamThread")
        workerThread = thread
        thread.start()

        return START_NOT_STICKY
    }

    fun requestKeyframe() {
        val codec = mediaCodec ?: return
        try {
            val params = Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            }
            codec.setParameters(params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed requesting keyframe: ${e.message}")
        }
    }

    private fun startForegroundMediaProjection() {
        createNotificationChannel()
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed: ${e.message}", e)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Phone Mirroring",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shown while mirroring your phone screen to your Mac"
                setShowBadge(false)
            }
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val openAppIntent = PendingIntent.getActivity(
            this,
            4203,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val stopIntent = Intent(this, ScreenMirrorActionReceiver::class.java).apply {
            action = ACTION_STOP_MIRRORING
        }
        val stopPendingIntent = PendingIntent.getBroadcast(
            this,
            4204,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val macName = BridgePrefs.macName(this) ?: "Mac"
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Mirroring screen to $macName")
            .setContentText("Your screen is visible on $macName. Tap Stop to end.")
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(openAppIntent)
            .addAction(0, "Stop", stopPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private data class DisplayGeom(val widthPx: Int, val heightPx: Int, val densityDpi: Int, val rotation: Int)

    private fun queryDisplayGeometry(): DisplayGeom {
        val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        val display = dm?.getDisplay(Display.DEFAULT_DISPLAY)
        val rotation = display?.rotation ?: 0

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            val metrics = wm?.maximumWindowMetrics
            if (metrics != null) {
                val b = metrics.bounds
                val density = resources.displayMetrics.densityDpi.coerceAtLeast(160)
                if (b.width() > 0 && b.height() > 0) {
                    return DisplayGeom(b.width(), b.height(), density, rotation)
                }
            }
        }

        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        display?.getRealMetrics(metrics)
        if (metrics.widthPixels > 0 && metrics.heightPixels > 0) {
            return DisplayGeom(
                metrics.widthPixels,
                metrics.heightPixels,
                metrics.densityDpi.coerceAtLeast(160),
                rotation
            )
        }

        val fallback = resources.displayMetrics
        return DisplayGeom(
            fallback.widthPixels.coerceAtLeast(720),
            fallback.heightPixels.coerceAtLeast(1280),
            fallback.densityDpi.coerceAtLeast(160),
            rotation
        )
    }

    private fun registerRotationListener() {
        unregisterRotationListener()
        val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: return
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}
            override fun onDisplayRemoved(displayId: Int) {}
            override fun onDisplayChanged(displayId: Int) {
                if (displayId != Display.DEFAULT_DISPLAY || !isStreaming.get()) return
                val geom = queryDisplayGeometry()
                val (newW, newH) = PhoneMirrorProtocol.computeStreamDimensions(
                    geom.widthPx,
                    geom.heightPx,
                    maxDimension
                )
                if (newW != currentStreamWidth || newH != currentStreamHeight || geom.rotation != currentRotation) {
                    currentStreamWidth = newW
                    currentStreamHeight = newH
                    currentRotation = geom.rotation
                    reconfigureRequested.set(true)
                }
            }
        }
        displayListener = listener
        dm.registerDisplayListener(listener, mainHandler)
    }

    private fun unregisterRotationListener() {
        val listener = displayListener ?: return
        try {
            val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
            dm?.unregisterDisplayListener(listener)
        } catch (ignored: Exception) {}
        displayListener = null
    }

    private fun createConfiguredEncoder(width: Int, height: Int): Pair<MediaCodec, Surface> {
        fun tryConfigure(fps: Int, includeRepeatFrame: Boolean): Pair<MediaCodec, Surface> {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                if (includeRepeatFrame) {
                    setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
                }
            }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                val surface = codec.createInputSurface()
                codec.start()
                return Pair(codec, surface)
            } catch (e: Exception) {
                try { codec.release() } catch (ignored: Exception) {}
                throw e
            }
        }

        return try {
            tryConfigure(fps = targetFps, includeRepeatFrame = true)
        } catch (primaryError: Exception) {
            Log.w(TAG, "Primary H.264 encoder config failed (${primaryError.message}), falling back to minimal profile")
            tryConfigure(fps = 30, includeRepeatFrame = false)
        }
    }

    private fun configureEncoderAndVirtualDisplay(width: Int, height: Int, densityDpi: Int) {
        releaseEncoderOnly()

        val (codec, surface) = createConfiguredEncoder(width, height)

        mediaCodec = codec
        inputSurface = surface

        val existingVd = virtualDisplay
        if (existingVd == null) {
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                "BridgePhoneMirror",
                width,
                height,
                densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                surface,
                null,
                null
            )
        } else {
            existingVd.resize(width, height, densityDpi)
            existingVd.surface = surface
        }
    }

    private fun runStreamingLoop(
        macHost: String,
        port: Int,
        tokenHex: String,
        densityDpi: Int
    ) {
        var stopReason: String? = "stream_ended"
        try {
            val s = Socket()
            s.connect(InetSocketAddress(macHost, port), 5000)
            s.tcpNoDelay = true
            s.sendBufferSize = 512 * 1024
            socket = s

            val out = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 65536))

            // 1. Send authenticated 69-byte handshake
            val w0 = currentStreamWidth
            val h0 = currentStreamHeight
            val rot0 = currentRotation
            val handshake = PhoneMirrorProtocol.buildHandshake(tokenHex, w0, h0, rot0)
            out.write(handshake)
            out.flush()

            // 2. Start hardware H.264 encoder & VirtualDisplay
            configureEncoderAndVirtualDisplay(w0, h0, densityDpi)
            ClipboardSyncAccessibilityService.instance?.onMirrorSessionStarted(dimScreen = true)
            PhoneMirrorController.updateState(MirrorSessionState.STREAMING)
            ClipboardSyncManager.networkClient?.sendRawJson(
                PhoneMirrorProtocol.buildStatusJson("streaming", width = w0, height = h0)
            )

            val bufferInfo = MediaCodec.BufferInfo()

            while (isStreaming.get()) {
                if (reconfigureRequested.compareAndSet(true, false)) {
                    val newW = currentStreamWidth
                    val newH = currentStreamHeight
                    val newRot = currentRotation
                    val geomPayload = PhoneMirrorProtocol.buildGeometryPayload(newW, newH, newRot)
                    val geomHeader = PhoneMirrorProtocol.buildPacketHeader(
                        type = PhoneMirrorProtocol.PACKET_TYPE_GEOMETRY,
                        flags = PhoneMirrorProtocol.FLAG_NONE,
                        ptsUs = 0L,
                        payloadLength = geomPayload.size
                    )
                    out.write(geomHeader)
                    out.write(geomPayload)
                    out.flush()

                    configureEncoderAndVirtualDisplay(newW, newH, densityDpi)
                    ClipboardSyncManager.networkClient?.sendRawJson(
                        PhoneMirrorProtocol.buildStatusJson("streaming", width = newW, height = newH)
                    )
                    continue
                }

                val codec = mediaCodec ?: break
                val outIndex = codec.dequeueOutputBuffer(bufferInfo, 16_000L)
                when {
                    outIndex >= 0 -> {
                        val encodedBuffer = codec.getOutputBuffer(outIndex)
                        if (encodedBuffer != null && bufferInfo.size > 0) {
                            val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                            val isEos = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            if (!isEos) {
                                encodedBuffer.position(bufferInfo.offset)
                                encodedBuffer.limit(bufferInfo.offset + bufferInfo.size)
                                val bytes = ByteArray(bufferInfo.size)
                                encodedBuffer.get(bytes)

                                val packetType = if (isConfig) {
                                    PhoneMirrorProtocol.PACKET_TYPE_CONFIG
                                } else {
                                    PhoneMirrorProtocol.PACKET_TYPE_FRAME
                                }
                                val isKey = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                                val flags = if (isKey) PhoneMirrorProtocol.FLAG_KEYFRAME else PhoneMirrorProtocol.FLAG_NONE
                                val header = PhoneMirrorProtocol.buildPacketHeader(
                                    type = packetType,
                                    flags = flags,
                                    ptsUs = bufferInfo.presentationTimeUs,
                                    payloadLength = bytes.size
                                )
                                out.write(header)
                                out.write(bytes)
                                out.flush()
                            }
                        }
                        codec.releaseOutputBuffer(outIndex, false)
                    }
                    outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        // Extract csd-0 / csd-1 if encoder emits format change before Annex-B config buffer
                        try {
                            val newFormat = codec.outputFormat
                            val csd0 = newFormat.getByteBuffer("csd-0")
                            val csd1 = newFormat.getByteBuffer("csd-1")
                            if (csd0 != null) {
                                val b0 = ByteArray(csd0.remaining()).also { csd0.duplicate().get(it) }
                                val b1 = if (csd1 != null) ByteArray(csd1.remaining()).also { csd1.duplicate().get(it) } else ByteArray(0)
                                val combined = b0 + b1
                                if (combined.isNotEmpty()) {
                                    val header = PhoneMirrorProtocol.buildPacketHeader(
                                        type = PhoneMirrorProtocol.PACKET_TYPE_CONFIG,
                                        flags = PhoneMirrorProtocol.FLAG_NONE,
                                        ptsUs = 0L,
                                        payloadLength = combined.size
                                    )
                                    out.write(header)
                                    out.write(combined)
                                    out.flush()
                                }
                            }
                        } catch (ignored: Exception) {}
                    }
                }
            }
            stopReason = null
        } catch (io: IOException) {
            Log.i(TAG, "Mirror stream socket closed: ${io.message}")
            stopReason = "connection_closed"
        } catch (e: Exception) {
            Log.e(TAG, "Mirror stream error: ${e.message}", e)
            stopReason = e.message ?: "encoder_error"
        } finally {
            val wasExpectedStop = !isStreaming.get()
            stopCaptureInternal()
            if (!wasExpectedStop) {
                PhoneMirrorController.handleServiceStopped(reason = stopReason, notifyMac = true)
            }
            mainHandler.post { stopSelf() }
        }
    }

    private fun releaseEncoderOnly() {
        try {
            mediaCodec?.stop()
        } catch (ignored: Exception) {}
        try {
            mediaCodec?.release()
        } catch (ignored: Exception) {}
        mediaCodec = null
        try {
            inputSurface?.release()
        } catch (ignored: Exception) {}
        inputSurface = null
    }

    private fun stopCaptureInternal() {
        isStreaming.set(false)
        ClipboardSyncAccessibilityService.instance?.onMirrorSessionStopped()
        unregisterRotationListener()
        releaseEncoderOnly()
        try {
            virtualDisplay?.release()
        } catch (ignored: Exception) {}
        virtualDisplay = null
        try {
            mediaProjection?.stop()
        } catch (ignored: Exception) {}
        mediaProjection = null
        try {
            socket?.close()
        } catch (ignored: Exception) {}
        socket = null
    }

    private fun stopWorkerLocked() {
        isStreaming.set(false)
        try {
            socket?.close()
        } catch (ignored: Exception) {}
        try {
            workerThread?.join(500)
        } catch (ignored: Exception) {}
        workerThread = null
    }

    private fun stopCaptureAndSelf(reason: String, notifyMac: Boolean) {
        stopCaptureInternal()
        PhoneMirrorController.handleServiceStopped(reason = reason, notifyMac = notifyMac)
        mainHandler.post { stopSelf() }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopWorkerLocked()
        stopCaptureInternal()
        if (activeInstance === this) {
            activeInstance = null
        }
    }
}
