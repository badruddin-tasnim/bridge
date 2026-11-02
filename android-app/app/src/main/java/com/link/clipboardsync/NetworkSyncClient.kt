package com.link.clipboardsync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.net.InetSocketAddress
import java.net.Socket
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
    }

    interface SyncListener {
        fun onConnectionStatusChanged(isConnected: Boolean, host: String?) {}
        fun onPayloadReceived(payload: ClipboardPayload) {}
        fun onLog(message: String) {}
        fun onPairingResult(accepted: Boolean, macName: String?) {}
        fun onRemoteUnpair() {}
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
        pairCode = code
        currentPort = port
        currentHost = host
        failedAttempts = 0
        isRunning.set(true)
        disconnectSocket()

        if (host.isNullOrBlank()) {
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

    fun sendUnpairAndStop() {
        isRunning.set(false)
        pairCode = null
        stopDiscovery()
        stopHeartbeat()
        Thread {
            try {
                writeRaw(ClipboardPayload(type = "unpair"))
            } catch (ignored: Exception) {}
            disconnectSocket()
            readThread?.interrupt()
            readThread = null
            notifyConnectionStatusChanged(false, null)
        }.start()
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

    private fun writeRaw(payload: ClipboardPayload) {
        synchronized(this) {
            writer?.println(payload.toJsonString())
            writer?.flush()
        }
    }

    private fun startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = heartbeatExecutor.scheduleWithFixedDelay({
            if (isRunning.get() && isConnected()) {
                try {
                    writeRaw(ClipboardPayload(type = "ping"))
                } catch (e: Exception) {
                    Log.w(TAG, "Heartbeat ping failed: ${e.message}")
                }
            }
        }, 10, 10, TimeUnit.SECONDS)
    }

    private fun stopHeartbeat() {
        heartbeatTask?.cancel(true)
        heartbeatTask = null
    }

    private fun connectLoop() {
        if (readThread?.isAlive == true) return
        val t = Thread({
            while (isRunning.get()) {
                val host = currentHost
                if (host.isNullOrBlank()) {
                    if (!isDiscovering) startDiscovery()
                    try {
                        Thread.sleep(1500)
                    } catch (ignored: InterruptedException) {
                        break
                    }
                    continue
                }

                try {
                    log("Connecting to Mac at $host:$currentPort...")
                    val s = Socket()
                    s.connect(InetSocketAddress(host, currentPort), 3500)
                    s.tcpNoDelay = true
                    s.keepAlive = true
                    s.soTimeout = 20000 // Detect dropped / sleeping host within 20s

                    val out = PrintWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8), true)
                    val reader = BufferedReader(InputStreamReader(s.getInputStream(), Charsets.UTF_8))

                    synchronized(this) {
                        socket = s
                        writer = out
                        authenticated = false
                    }

                    // Pairing handshake
                    writeRaw(
                        ClipboardPayload(
                            type = "hello",
                            code = pairCode,
                            device = "${Build.MANUFACTURER} ${Build.MODEL}"
                        )
                    )

                    var line: String? = reader.readLine()
                    while (line != null && isRunning.get()) {
                        if (line.isNotBlank()) {
                            val payload = ClipboardPayload.fromJsonString(line.trim())
                            when (payload?.type) {
                                "welcome" -> {
                                    authenticated = true
                                    failedAttempts = 0
                                    macName = payload.name ?: "Mac"
                                    BridgePrefs.markPaired(context, macName)
                                    log("Paired with ${payload.name} at $host:$currentPort")
                                    notifyPairingResult(true, macName)
                                    notifyConnectionStatusChanged(true, host)
                                    startHeartbeat()
                                }
                                "denied" -> {
                                    log("Mac rejected the pairing code.")
                                    isRunning.set(false)
                                    notifyPairingResult(false, null)
                                }
                                "unpair" -> {
                                    log("Mac initiated unpair.")
                                    pairCode = null
                                    BridgePrefs.clear(context)
                                    isRunning.set(false)
                                    notifyRemoteUnpair()
                                    notifyConnectionStatusChanged(false, null)
                                    break
                                }
                                "sleep" -> {
                                    log("Mac lid closed / entering sleep.")
                                    break // Immediately terminate read loop & prepare for reconnect
                                }
                                "clip", "image" -> if (authenticated) notifyPayloadReceived(payload)
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
                        line = reader.readLine()
                    }
                    if (line == null) {
                        log("Connection closed by Mac (lid closed or asleep).")
                    }
                } catch (e: Exception) {
                    log("Connection dropped or failed: ${e.message}")
                    failedAttempts++
                } finally {
                    stopHeartbeat()
                    disconnectSocket()
                    notifyConnectionStatusChanged(false, host)
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
                            if (!host.isNullOrBlank() && !host.contains(":")) {
                                log("Found Mac at $host")
                                currentHost = host
                                currentPort = port
                                failedAttempts = 0
                                BridgePrefs.saveHost(context, host, port)
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
