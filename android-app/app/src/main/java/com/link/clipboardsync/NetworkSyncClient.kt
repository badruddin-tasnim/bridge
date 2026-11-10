package com.link.clipboardsync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Persistent TCP client to the Bridge macOS daemon.
 *
 * - Newline-delimited JSON framing
 * - Pairing handshake ("hello" with pairing code -> "welcome"/"denied")
 * - Dedicated reader thread + send executor (no head-of-line deadlock)
 * - 15s heartbeat to keep NAT/router state alive
 * - Bonjour (_clipboardsync._tcp) discovery when the Mac IP is unknown or changed
 */
class NetworkSyncClient(private val context: Context) {

    companion object {
        private const val TAG = "NetworkSyncClient"
        const val DEFAULT_PORT = 8765
        const val SERVICE_TYPE = "_clipboardsync._tcp."
        private const val MAX_UNAUTH_LINE_CHARS = 8192
        private const val MAX_AUTH_LINE_CHARS = 25 * 1024 * 1024
        private val secureRandom = SecureRandom()

        fun generateSecureNonce(): String {
            val bytes = ByteArray(16)
            secureRandom.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }

        fun constantTimeEquals(a: String?, b: String?): Boolean {
            if (a.isNullOrEmpty() || b.isNullOrEmpty()) return false
            val aBytes = a.toByteArray(Charsets.UTF_8)
            val bBytes = b.toByteArray(Charsets.UTF_8)
            return MessageDigest.isEqual(aBytes, bBytes)
        }

        fun isPrivateLocalAddress(rawHost: String?): Boolean {
            if (rawHost.isNullOrBlank()) return false
            val clean = rawHost.substringBefore("%").trim().removeSurrounding("[", "]").lowercase()
            if (clean == "localhost" || clean == "::1" || clean == "127.0.0.1") return true
            if (clean.startsWith("fe80:") || clean.startsWith("fc") || clean.startsWith("fd")) return true

            val ipv4 = if (clean.startsWith("::ffff:")) clean.removePrefix("::ffff:") else clean
            val parts = ipv4.split(".")
            if (parts.size != 4) return false
            val octets = parts.map { it.toIntOrNull() ?: return false }
            if (octets.any { it !in 0..255 }) return false

            return when (octets[0]) {
                10, 127 -> true
                192 -> octets[1] == 168
                172 -> octets[1] in 16..31
                169 -> octets[1] == 254
                100 -> octets[1] in 64..127
                else -> false
            }
        }
    }

    interface SyncListener {
        fun onConnectionStatusChanged(isConnected: Boolean, host: String?) {}
        fun onPayloadReceived(payload: ClipboardPayload) {}
        fun onNotificationPayloadReceived(jsonString: String) {}
        fun onLog(message: String) {}
        fun onPairingResult(accepted: Boolean, macName: String?) {}
        fun onRemoteUnpair() {}
        fun onConnectionFailed(consecutiveFailures: Int) {}
    }

    private val listeners = CopyOnWriteArrayList<SyncListener>()
    private val sendExecutor = Executors.newSingleThreadExecutor()
    private val heartbeatExecutor = Executors.newSingleThreadScheduledExecutor()
    private var heartbeatTask: ScheduledFuture<*>? = null
    private var readThread: Thread? = null
    private val isRunning = AtomicBoolean(false)

    @Volatile private var socket: Socket? = null
    @Volatile private var writer: PrintWriter? = null
    @Volatile private var authenticated = false
    @Volatile private var currentHost: String? = null
    @Volatile private var currentPort: Int = DEFAULT_PORT
    @Volatile private var pairCode: String? = null
    @Volatile var macName: String? = null
        private set
    private var failedAttempts: Int = 0

    // mDNS Discovery
    private var nsdManager: NsdManager? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    @Volatile private var isDiscovering = false

    fun isConnected(): Boolean = authenticated && socket?.isClosed == false
    fun isActivelyConnecting(): Boolean = isRunning.get()
    fun getCurrentHost(): String? = currentHost

    fun addListener(l: SyncListener) {
        if (!listeners.contains(l)) {
            listeners.add(l)
            l.onConnectionStatusChanged(isConnected(), currentHost)
        }
    }

    fun removeListener(l: SyncListener) {
        listeners.remove(l)
    }

    /**
     * Starts (or restarts) the connection using a pairing code.
     * If [host] is null the Mac is located via Bonjour.
     */
    fun start(host: String?, port: Int, code: String?) {
        if (code.isNullOrBlank()) {
            log("Not paired yet - waiting for pairing.")
            return
        }
        val cleanCode = code.replace(" ", "").replace("-", "").trim()
        if (cleanCode.length != 6 || !cleanCode.all { it.isDigit() }) {
            log("Invalid pairing code format.")
            notifyPairingResult(false, null)
            return
        }
        pairCode = cleanCode
        currentPort = if (port in 1024..65535) port else DEFAULT_PORT
        currentHost = if (!host.isNullOrBlank() && isPrivateLocalAddress(host)) host.trim() else null
        failedAttempts = 0
        isRunning.set(true)
        disconnectSocket()

        if (currentHost.isNullOrBlank()) {
            startDiscovery()
        } else {
            stopDiscovery()
        }
        connectLoop()
    }

    fun stop() {
        isRunning.set(false)
        pairCode = null
        stopDiscovery()
        stopHeartbeat()
        disconnectSocket()
        readThread?.interrupt()
        readThread = null
        notifyConnectionStatusChanged(false, null)
    }

    private fun stopWithSignal(signalType: String, clearPairingCode: Boolean, hostOnNotify: String?) {
        isRunning.set(false)
        if (clearPairingCode) {
            pairCode = null
        }
        stopDiscovery()
        stopHeartbeat()
        val oldThread = readThread
        readThread = null
        Thread {
            try {
                writeRaw(ClipboardPayload(type = signalType))
                Thread.sleep(100)
            } catch (ignored: Exception) {}
            disconnectSocket()
            oldThread?.interrupt()
            notifyConnectionStatusChanged(false, hostOnNotify)
        }.start()
    }

    fun sendDisconnectAndStop() {
        stopWithSignal(signalType = "disconnect", clearPairingCode = false, hostOnNotify = currentHost)
    }

    fun sendUnpairAndStop() {
        stopWithSignal(signalType = "unpair", clearPairingCode = true, hostOnNotify = null)
    }

    fun sendPayload(payload: ClipboardPayload) {
        sendExecutor.execute {
            try {
                // Wait up to 3 seconds if the socket is still connecting / handshaking
                var attempts = 0
                while (!isConnected() && attempts < 15) {
                    try {
                        Thread.sleep(200)
                    } catch (ignored: InterruptedException) {
                        break
                    }
                    attempts++
                }

                val out = writer
                if (out != null && isConnected()) {
                    synchronized(this) {
                        out.println(payload.toJsonString())
                        out.flush()
                    }
                    log("Dispatched to Mac: ${payload.hash.take(8)}")
                } else {
                    log("Send skipped: not connected to Mac")
                }
            } catch (e: Exception) {
                log("Error sending payload: ${e.message}")
            }
        }
    }

    fun sendRawJson(jsonString: String) {
        sendExecutor.execute {
            try {
                var attempts = 0
                while (!isConnected() && attempts < 15) {
                    try {
                        Thread.sleep(200)
                    } catch (ignored: InterruptedException) {
                        break
                    }
                    attempts++
                }
                if (isConnected()) {
                    synchronized(this) {
                        val out = writer ?: return@execute
                        out.println(jsonString)
                        out.flush()
                    }
                }
            } catch (e: Exception) {
                log("Error sending raw json: ${e.message}")
            }
        }
    }

    private fun writeRaw(payload: ClipboardPayload) {
        synchronized(this) {
            writer?.println(payload.toJsonString())
            writer?.flush()
        }
    }

    private var heartbeatTick = 0

    private fun startHeartbeat() {
        stopHeartbeat()
        heartbeatTick = 0
        heartbeatTask = heartbeatExecutor.scheduleWithFixedDelay({
            if (isRunning.get() && isConnected()) {
                try {
                    writeRaw(ClipboardPayload(type = "ping"))
                    heartbeatTick++
                    if (heartbeatTick % 3 == 0) {
                        BridgeNotificationListenerService.instance?.syncActiveIdsOnly()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Heartbeat ping failed: ${e.message}")
                    disconnectSocket()
                    notifyConnectionStatusChanged(false, currentHost)
                }
            }
        }, 3, 3, TimeUnit.SECONDS)
    }

    private fun stopHeartbeat() {
        heartbeatTask?.cancel(true)
        heartbeatTask = null
    }

    private fun readBoundedLine(reader: BufferedReader, maxChars: Int): String? {
        val sb = StringBuilder()
        while (true) {
            val ch = reader.read()
            if (ch == -1) {
                return if (sb.isNotEmpty()) sb.toString() else null
            }
            if (ch == '\n'.code) {
                return sb.toString()
            }
            if (ch != '\r'.code) {
                if (sb.length >= maxChars) {
                    throw IOException("Incoming payload exceeded maximum allowed line length ($maxChars)")
                }
                sb.append(ch.toChar())
            }
        }
    }

    private fun connectLoop() {
        if (readThread?.isAlive == true) return
        val t = Thread({
            var discoveryWaitCount = 0
            while (isRunning.get()) {
                val host = currentHost
                if (host.isNullOrBlank() || !isPrivateLocalAddress(host)) {
                    if (!host.isNullOrBlank()) {
                        log("Security: Refusing connection to non-private host $host")
                        currentHost = null
                    }
                    if (!isDiscovering) startDiscovery()
                    discoveryWaitCount++
                    if (discoveryWaitCount % 2 == 0) {
                        failedAttempts++
                        notifyConnectionFailed(failedAttempts)
                    }
                    try {
                        Thread.sleep(1500)
                    } catch (ignored: InterruptedException) {
                        break
                    }
                    continue
                }
                discoveryWaitCount = 0

                try {
                    log("Connecting to Mac at $host:$currentPort...")
                    val s = Socket()
                    s.connect(InetSocketAddress(host, currentPort), 3500)
                    s.tcpNoDelay = true
                    s.keepAlive = true
                    s.soTimeout = 7500 // Detect dropped / sleeping host within 7.5s

                    val out = PrintWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8), true)
                    val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.UTF_8))

                    synchronized(this) {
                        socket = s
                        writer = out
                        authenticated = false
                    }

                    val activeCode = (pairCode ?: "").replace(" ", "").trim()
                    val clientNonce = generateSecureNonce()
                    val helloHash = ClipboardPayload.computeSHA256("bridge-hello:$activeCode:$clientNonce")
                    val expectedWelcomeHash = ClipboardPayload.computeSHA256("bridge-welcome:$activeCode:$clientNonce")

                    // Zero-knowledge pairing handshake: send salted SHA-256 proof instead of plaintext code
                    writeRaw(
                        ClipboardPayload(
                            type = "hello",
                            hash = helloHash,
                            text = clientNonce,
                            device = "${Build.MANUFACTURER} ${Build.MODEL}"
                        )
                    )

                    var line: String? = readBoundedLine(reader, MAX_UNAUTH_LINE_CHARS)
                    while (line != null && isRunning.get()) {
                        if (line.isNotBlank()) {
                            val trimmed = line.trim()
                            val jsonObj = try { JSONObject(trimmed) } catch (e: Exception) { null }
                            val type = jsonObj?.optString("type")

                            if (!authenticated) {
                                // Strict pre-authentication gate: only "welcome" or "denied" allowed before auth
                                val payload = ClipboardPayload.fromJsonString(trimmed)
                                when (payload?.type) {
                                    "welcome" -> {
                                        if (!constantTimeEquals(payload.hash.lowercase(), expectedWelcomeHash.lowercase())) {
                                            log("Security: Rejected unverified 'welcome' from $host (failed mutual auth proof)")
                                            throw SecurityException("Server failed mutual authentication proof")
                                        }
                                        authenticated = true
                                        failedAttempts = 0
                                        macName = (payload.name ?: "Mac").take(64)
                                        BridgePrefs.saveHost(context, host, currentPort)
                                        BridgePrefs.markPaired(context, macName)
                                        log("Paired with ${payload.name} at $host:$currentPort")
                                        notifyPairingResult(true, macName)
                                        notifyConnectionStatusChanged(true, host)
                                        startHeartbeat()
                                        BridgeNotificationListenerService.instance?.syncActiveNotifications()
                                    }
                                    "denied" -> {
                                        log("Mac rejected the pairing code.")
                                        isRunning.set(false)
                                        notifyPairingResult(false, null)
                                        break
                                    }
                                    else -> {
                                        log("Security: Rejected unauthenticated message type '${payload?.type ?: type}' from $host")
                                        throw SecurityException("Unexpected unauthenticated message from server")
                                    }
                                }
                            } else if (type != null && (type.startsWith("notif_") || type == "settings_sync")) {
                                notifyNotificationPayloadReceived(trimmed)
                            } else if (type != null && type.startsWith("file_") && jsonObj != null) {
                                BridgeFileTransferManager.handleControlMessage(context, jsonObj, host)
                            } else {
                                val payload = ClipboardPayload.fromJsonString(trimmed)
                                when (payload?.type) {
                                    "unpair" -> {
                                        log("Mac initiated unpair.")
                                        pairCode = null
                                        BridgePrefs.clearPairing(context)
                                        BridgeNotificationManager.cancelAllMacAlerts(context)
                                        isRunning.set(false)
                                        notifyRemoteUnpair()
                                        notifyConnectionStatusChanged(false, null)
                                        break
                                    }
                                    "sleep" -> {
                                        log("Mac lid closed / entering sleep.")
                                        break // Immediately terminate read loop & prepare for reconnect
                                    }
                                    "clip", "image" -> notifyPayloadReceived(payload)
                                    "ping" -> {
                                        // Acknowledge ping
                                        writeRaw(ClipboardPayload(type = "pong"))
                                    }
                                    "pong" -> {
                                        // Keepalive ack received
                                    }
                                    else -> { /* unknown */ }
                                }
                            }
                        }
                        line = readBoundedLine(
                            reader,
                            if (authenticated) MAX_AUTH_LINE_CHARS else MAX_UNAUTH_LINE_CHARS
                        )
                    }
                    if (line == null && isRunning.get()) {
                        log("Connection closed by Mac (lid closed or asleep).")
                    }
                } catch (e: Exception) {
                    if (isRunning.get()) {
                        log("Connection dropped or failed: ${e.message}")
                        failedAttempts++
                        notifyConnectionFailed(failedAttempts)
                    }
                } finally {
                    stopHeartbeat()
                    disconnectSocket()
                    notifyConnectionStatusChanged(false, if (BridgePrefs.isPaired(context)) host else null)
                }

                if (isRunning.get()) {
                    if (!isDiscovering) {
                        startDiscovery()
                    }
                    try {
                        Thread.sleep(1500)
                    } catch (ignored: InterruptedException) {
                        break
                    }
                }
            }
        }, "SocketReaderThread")
        readThread = t
        t.start()
    }

    private fun disconnectSocket() {
        synchronized(this) {
            authenticated = false
            try {
                writer?.close()
                socket?.close()
            } catch (ignored: Exception) {}
            writer = null
            socket = null
        }
    }

    private fun notifyConnectionStatusChanged(isConnected: Boolean, host: String?) {
        for (l in listeners) {
            try { l.onConnectionStatusChanged(isConnected, host) } catch (ignored: Exception) {}
        }
    }

    private fun notifyPayloadReceived(payload: ClipboardPayload) {
        for (l in listeners) {
            try { l.onPayloadReceived(payload) } catch (ignored: Exception) {}
        }
    }

    private fun notifyNotificationPayloadReceived(jsonString: String) {
        for (l in listeners) {
            try { l.onNotificationPayloadReceived(jsonString) } catch (ignored: Exception) {}
        }
    }

    private fun notifyPairingResult(accepted: Boolean, name: String?) {
        for (l in listeners) {
            try { l.onPairingResult(accepted, name) } catch (ignored: Exception) {}
        }
    }

    private fun notifyRemoteUnpair() {
        for (l in listeners) {
            try { l.onRemoteUnpair() } catch (ignored: Exception) {}
        }
    }

    private fun notifyConnectionFailed(failures: Int) {
        for (l in listeners) {
            try { l.onConnectionFailed(failures) } catch (ignored: Exception) {}
        }
    }

    // MARK: - Bonjour / mDNS Discovery

    fun startDiscovery() {
        if (isDiscovering) return
        try {
            nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
            discoveryListener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(regType: String) {
                    isDiscovering = true
                    log("Searching for Mac on Wi-Fi...")
                }

                override fun onServiceFound(service: NsdServiceInfo) {
                    if (!service.serviceType.contains("_clipboardsync")) return
                    nsdManager?.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                            log("Resolve failed: error code $errorCode")
                        }

                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            val host = serviceInfo.host?.hostAddress
                            val port = serviceInfo.port
                            if (!host.isNullOrBlank() && !host.contains(":") && isPrivateLocalAddress(host) && port in 1024..65535) {
                                log("Found Mac candidate at $host:$port")
                                currentHost = host
                                currentPort = port
                                failedAttempts = 0
                                stopDiscovery()
                                if (!pairCode.isNullOrBlank()) {
                                    connectLoop()
                                }
                            }
                        }
                    })
                }

                override fun onServiceLost(service: NsdServiceInfo) {
                    log("Mac Bonjour service offline (sleeping or lid closed).")
                }

                override fun onDiscoveryStopped(serviceType: String) {
                    isDiscovering = false
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    log("Bonjour discovery failed: $errorCode")
                    isDiscovering = false
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    isDiscovering = false
                }
            }

            nsdManager?.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (e: Exception) {
            log("Failed to start Bonjour discovery: ${e.message}")
        }
    }

    private fun stopDiscovery() {
        val l = discoveryListener ?: return
        try {
            nsdManager?.stopServiceDiscovery(l)
        } catch (ignored: Exception) {}
        discoveryListener = null
        isDiscovering = false
    }

    private fun log(msg: String) {
        Log.d(TAG, msg)
        for (l in listeners) {
            try { l.onLog(msg) } catch (ignored: Exception) {}
        }
    }
}
