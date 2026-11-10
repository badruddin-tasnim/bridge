package com.link.clipboardsync

import android.content.ClipData
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

object ClipboardSyncManager {
    private const val TAG = "ClipboardSyncManager"
    private const val MAX_HISTORY = 20
    private const val MAX_IMAGE_DIMENSION = 2560
    private const val MAX_RAW_IMAGE_BYTES = 30 * 1024 * 1024

    data class HistoryItem(val text: String, val outgoing: Boolean, val timestamp: Long)

    interface HistoryListener {
        fun onHistoryChanged()
    }

    @Volatile
    var networkClient: NetworkSyncClient? = null

    @Volatile
    var lastSentHash: String = ""

    @Volatile
    var lastReceivedHash: String = ""

    @Volatile
    var lastRawImageHash: String = ""

    @Volatile
    var isInternalMutation: Boolean = false

    private val imageExecutor = Executors.newSingleThreadExecutor()

    val history = CopyOnWriteArrayList<HistoryItem>()
    private val historyListeners = CopyOnWriteArrayList<HistoryListener>()

    fun addHistoryListener(l: HistoryListener) { historyListeners.addIfAbsent(l) }
    fun removeHistoryListener(l: HistoryListener) { historyListeners.remove(l) }

    fun recordHistory(text: String, outgoing: Boolean) {
        history.add(0, HistoryItem(text, outgoing, System.currentTimeMillis()))
        while (history.size > MAX_HISTORY) history.removeAt(history.size - 1)
        historyListeners.forEach { try { it.onHistoryChanged() } catch (ignored: Exception) {} }
    }

    /** Creates the shared client and connects if this phone is already paired. */
    fun init(context: Context) {
        if (networkClient == null) {
            synchronized(this) {
                if (networkClient == null) {
                    val client = NetworkSyncClient(context.applicationContext)
                    networkClient = client
                    if (BridgePrefs.isPaired(context)) {
                        client.start(BridgePrefs.host(context), BridgePrefs.port(context), BridgePrefs.code(context))
                    }
                    Log.i(TAG, "ClipboardSyncManager initialized (paired=${BridgePrefs.isPaired(context)})")
                }
            }
        }
    }

    /** Attempts to pair with a Mac. Result is delivered via SyncListener.onPairingResult. */
    fun pair(context: Context, host: String?, port: Int, code: String) {
        init(context)
        BridgePrefs.saveCandidate(context, host, port, code)
        networkClient?.start(host, port, code)
    }

    /** Disconnects from the currently paired Mac without removing pairing credentials. */
    fun disconnect(context: Context) {
        networkClient?.sendDisconnectAndStop()
        BridgeNotificationManager.cancelAllMacAlerts(context)
    }

    /** Reconnects to the saved paired Mac using stored pairing credentials. */
    fun reconnect(context: Context) {
        if (!BridgePrefs.isPaired(context)) return
        init(context)
        networkClient?.start(BridgePrefs.host(context), BridgePrefs.port(context), BridgePrefs.code(context))
    }

    fun unpair(context: Context) {
        BridgePrefs.clearPairing(context)
        networkClient?.sendUnpairAndStop()
        BridgeNotificationManager.cancelAllMacAlerts(context)
        history.clear()
        historyListeners.forEach { try { it.onHistoryChanged() } catch (ignored: Exception) {} }
    }

    /**
     * Inspects a [ClipData] for either a copied image URI or copied text and dispatches it to Mac.
     * Must be called while the app holds window focus if reading a `content://` URI on Android 10+.
     *
     * @return `true` if a new clipboard item was found and dispatched (or was our own internal clip),
     *         `false` if the clipboard was empty or unchanged.
     */
    fun extractAndDispatchClipboard(context: Context, clip: ClipData, source: String): Boolean {
        if (clip.itemCount == 0) return false

        val item = clip.getItemAt(0)
        val desc = clip.description
        val uri = item.uri

        // 1. Check for local content:// or file:// image URI first
        if (uri != null && (uri.scheme == "content" || uri.scheme == "file")) {
            // Ignore images placed onto the Android clipboard by Bridge itself
            if (uri.authority == ClipboardImageProvider.AUTHORITY) {
                Log.d(TAG, "[$source] Ignoring Bridge's own ClipboardImageProvider URI")
                return true
            }

            val resolver = context.contentResolver
            val resolvedMime = try { resolver.getType(uri) } catch (e: Exception) { null }
            val descMime = if (desc != null && desc.mimeTypeCount > 0) desc.getMimeType(0) else null
            val mime = resolvedMime ?: descMime ?: ""

            val uriStr = uri.toString()
            val isImage = mime.startsWith("image/", ignoreCase = true) ||
                    (desc?.hasMimeType("image/*") == true) ||
                    uriStr.contains("image", ignoreCase = true) ||
                    uriStr.contains("photo", ignoreCase = true) ||
                    uriStr.contains("screenshot", ignoreCase = true) ||
                    uriStr.contains("media", ignoreCase = true) ||
                    uriStr.contains("clipboard", ignoreCase = true)

            if (isImage) {
                try {
                    val rawBytes = resolver.openInputStream(uri)?.use { input ->
                        val out = ByteArrayOutputStream()
                        val buf = ByteArray(16384)
                        var total = 0
                        var read: Int
                        while (input.read(buf).also { read = it } != -1) {
                            total += read
                            if (total > MAX_RAW_IMAGE_BYTES) {
                                Log.w(TAG, "[$source] Clipboard image exceeds max allowed size")
                                return false
                            }
                            out.write(buf, 0, read)
                        }
                        out.toByteArray()
                    }
                    if (rawBytes != null && rawBytes.isNotEmpty()) {
                        val rawHash = ClipboardPayload.computeSHA256(rawBytes)
                        if (rawHash == lastRawImageHash || rawHash == lastReceivedHash || rawHash == lastSentHash) {
                            Log.d(TAG, "[$source] Suppressed duplicate/unchanged clipboard image (${rawHash.take(8)})")
                            return false
                        }
                        lastRawImageHash = rawHash
                        Log.d(TAG, "[$source] Read ${rawBytes.size / 1024} KB image from clipboard, encoding...")
                        dispatchRawImageBytesToMac(context.applicationContext, rawBytes, source)
                        return true
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "[$source] Failed reading clipboard image stream: ${e.message}")
                }
            }

            // Never coerce a content:// or file:// URI into a literal "content://..." text string
            if (item.text == null) {
                return false
            }
        }

        // 2. Plain text / web link sync
        val text = item.text?.toString() ?: item.coerceToText(context)?.toString()
        if (!text.isNullOrEmpty()) {
            val hash = ClipboardPayload.computeSHA256(text)
            if (hash == lastReceivedHash || hash == lastSentHash) {
                return false
            }
            dispatchTextToMac(context.applicationContext, text, source)
            return true
        }

        return false
    }

    fun dispatchTextToMac(context: Context, text: String, source: String) {
        if (text.isEmpty()) return

        val hash = ClipboardPayload.computeSHA256(text)
        Log.d(TAG, "[$source] dispatchTextToMac (${text.length} chars, hash: ${hash.take(8)})")

        // Loopback echo & deduplication check
        if (hash == lastReceivedHash || hash == lastSentHash) {
            Log.d(TAG, "Suppressed duplicate/echo: Matches last received or sent hash")
            return
        }

        lastSentHash = hash
        init(context)

        val client = networkClient
        if (client != null) {
            client.sendPayload(ClipboardPayload(type = "clip", hash = hash, text = text))
            recordHistory(text, outgoing = true)
        } else {
            Log.e(TAG, "NetworkSyncClient is null, cannot dispatch!")
        }
    }

    private fun dispatchRawImageBytesToMac(context: Context, rawBytes: ByteArray, source: String) {
        imageExecutor.execute {
            try {
                val bitmap = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size)
                if (bitmap == null) {
                    Log.w(TAG, "[$source] Could not decode image bytes into Bitmap")
                    return@execute
                }

                val width = bitmap.width
                val height = bitmap.height
                val maxDim = maxOf(width, height)
                val scaled = if (maxDim > MAX_IMAGE_DIMENSION) {
                    val scale = MAX_IMAGE_DIMENSION.toFloat() / maxDim.toFloat()
                    val newW = (width * scale).toInt().coerceAtLeast(1)
                    val newH = (height * scale).toInt().coerceAtLeast(1)
                    Bitmap.createScaledBitmap(bitmap, newW, newH, true)
                } else {
                    bitmap
                }

                val usePng = scaled.hasAlpha() && (scaled.width * scaled.height <= 1_000_000)
                val outMime = if (usePng) "image/png" else "image/jpeg"
                val outStream = ByteArrayOutputStream()
                if (usePng) {
                    scaled.compress(Bitmap.CompressFormat.PNG, 100, outStream)
                } else {
                    scaled.compress(Bitmap.CompressFormat.JPEG, 88, outStream)
                }

                if (scaled !== bitmap) {
                    scaled.recycle()
                }
                bitmap.recycle()

                val encodedBytes = outStream.toByteArray()
                val hash = ClipboardPayload.computeSHA256(encodedBytes)
                if (hash == lastReceivedHash || hash == lastSentHash) {
                    Log.d(TAG, "[$source] Suppressed duplicate encoded image hash (${hash.take(8)})")
                    return@execute
                }

                lastSentHash = hash
                val base64Data = Base64.encodeToString(encodedBytes, Base64.NO_WRAP)

                init(context)
                val client = networkClient
                if (client != null) {
                    Log.d(TAG, "[$source] Dispatching image to Mac (${encodedBytes.size / 1024} KB, $outMime, hash: ${hash.take(8)})")
                    client.sendPayload(
                        ClipboardPayload(
                            type = "image",
                            hash = hash,
                            text = "[Image]",
                            data = base64Data,
                            mime = outMime
                        )
                    )
                    recordHistory("[Image]", outgoing = true)
                }
            } catch (e: Exception) {
                Log.e(TAG, "[$source] Error encoding/dispatching image: ${e.message}", e)
            }
        }
    }
}
