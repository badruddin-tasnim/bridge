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
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object BridgeSpeke {
    // RFC 3526 Group 14 (2048-bit MODP Safe Prime p = 2q + 1)
    const val P_HEX =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
        "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" +
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" +
        "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D" +
        "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F" +
        "83655D23DCA3AD961C62F356208552BB9ED529077096966D" +
        "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9" +
        "DE2BCBF6955817183995497CEA956AE515D2261898FA0510" +
        "15728E5A8AACAA68FFFFFFFFFFFFFFFF"

    val PRIME = BigInteger(P_HEX, 16)
    val TWO: BigInteger = BigInteger.valueOf(2)
    val PRIME_MINUS_TWO: BigInteger = PRIME.subtract(TWO)
    val PRIME_MINUS_THREE: BigInteger = PRIME.subtract(BigInteger.valueOf(3))
    private val secureRandom = SecureRandom()
    private val hexRegex = Regex("^[0-9a-fA-F]{1,512}$")

    data class KeyPair(
        val privateScalar: BigInteger,
        val publicHex: String
    )

    data class SessionMaterial(
        val clientProof: String,
        val serverProof: String,
        val c2sKey: SecretKeySpec,
        val s2cKey: SecretKeySpec,
        val c2sKeyHex: String,
        val s2cKeyHex: String
    )

    fun generatePrivateScalar(): BigInteger {
        val bytes = ByteArray(32)
        secureRandom.nextBytes(bytes)
        bytes[0] = (bytes[0].toInt() or 0x80).toByte()
        return BigInteger(1, bytes)
    }

    fun generateKeyPair(
        pairingCode: String,
        clientNonce: String,
        scalarOverride: BigInteger? = null
    ): KeyPair {
        val scalar = scalarOverride ?: generatePrivateScalar()
        val generator = deriveGenerator(pairingCode, clientNonce)
        val publicHex = computePublicElement(generator, scalar)
        return KeyPair(privateScalar = scalar, publicHex = publicHex)
    }

    fun toFixedHex256(value: BigInteger): String {
        val hex = value.toString(16).lowercase()
        return if (hex.length >= 512) hex.takeLast(512) else hex.padStart(512, '0')
    }

    fun deriveGenerator(pairingCode: String, clientNonce: String): BigInteger {
        val cleanCode = pairingCode.replace(" ", "").replace("-", "").trim()
        val blocks = ByteArray(256)
        val md = MessageDigest.getInstance("SHA-256")
        for (i in 0 until 8) {
            val digest = md.digest("bridge-speke-v1:$cleanCode:$clientNonce:$i".toByteArray(Charsets.UTF_8))
            System.arraycopy(digest, 0, blocks, i * 32, 32)
        }
        val rawH = BigInteger(1, blocks)
        val h = rawH.mod(PRIME_MINUS_THREE).add(TWO)
        return h.modPow(TWO, PRIME)
    }

    fun computePublicElement(generator: BigInteger, privateScalar: BigInteger): String {
        return toFixedHex256(generator.modPow(privateScalar, PRIME))
    }

    fun isValidPublicElement(hex: String?): Boolean {
        if (hex.isNullOrBlank()) return false
        val clean = hex.trim()
        if (!hexRegex.matches(clean)) return false
        return try {
            val v = BigInteger(clean, 16)
            v >= TWO && v <= PRIME_MINUS_TWO
        } catch (_: Exception) {
            false
        }
    }

    fun computeSharedSecret(peerPublicHex: String?, privateScalar: BigInteger): String? {
        if (!isValidPublicElement(peerPublicHex)) return null
        val peerPub = BigInteger(peerPublicHex!!.trim(), 16)
        val shared = peerPub.modPow(privateScalar, PRIME)
        if (shared < TWO || shared > PRIME_MINUS_TWO) return null
        return toFixedHex256(shared)
    }

    fun deriveSessionMaterial(
        sharedSecretHex: String,
        pairingCode: String,
        clientNonce: String,
        serverNonce: String,
        clientPublicHex: String,
        serverPublicHex: String
    ): SessionMaterial {
        val cleanCode = pairingCode.replace(" ", "").replace("-", "").trim()
        val normSecret = BigInteger(sharedSecretHex.trim(), 16).let { toFixedHex256(it) }
        val normClientPub = BigInteger(clientPublicHex.trim(), 16).let { toFixedHex256(it) }
        val normServerPub = BigInteger(serverPublicHex.trim(), 16).let { toFixedHex256(it) }

        val transcript = "bridge-speke-transcript-v1:$clientNonce:$serverNonce:$normClientPub:$normServerPub"
        val rootHex = ClipboardPayload.computeSHA256("$normSecret:$cleanCode:$transcript")
        val clientProof = ClipboardPayload.computeSHA256("bridge-client-confirm:$rootHex:$transcript")
        val serverProof = ClipboardPayload.computeSHA256("bridge-server-confirm:$rootHex:$transcript")

        val md = MessageDigest.getInstance("SHA-256")
        val c2sBytes = md.digest("bridge-c2s-key:$rootHex:$transcript".toByteArray(Charsets.UTF_8))
        val s2cBytes = md.digest("bridge-s2c-key:$rootHex:$transcript".toByteArray(Charsets.UTF_8))
        val c2sHex = c2sBytes.joinToString("") { "%02x".format(it) }
        val s2cHex = s2cBytes.joinToString("") { "%02x".format(it) }

        return SessionMaterial(
            clientProof = clientProof,
            serverProof = serverProof,
            c2sKey = SecretKeySpec(c2sBytes, "AES"),
            s2cKey = SecretKeySpec(s2cBytes, "AES"),
            c2sKeyHex = c2sHex,
            s2cKeyHex = s2cHex
        )
    }
}

class BridgeSessionCipher(
    private val sendKey: SecretKeySpec,
    private val receiveKey: SecretKeySpec,
    private val sendDirection: String,
    private val receiveDirection: String
) {
    private val secureRandom = SecureRandom()
    private var sendSeq: Long = 0L
    private var expectedReceiveSeq: Long = 1L

    @Synchronized
    fun seal(plaintextJson: String, saltOverride: ByteArray? = null): String {
        return seal(plaintextJson.toByteArray(Charsets.UTF_8), saltOverride)
    }

    @Synchronized
    fun seal(plaintext: ByteArray, saltOverride: ByteArray? = null): String {
        sendSeq += 1L
        val seq = sendSeq

        val iv = ByteArray(12)
        if (saltOverride != null && saltOverride.size == 4) {
            System.arraycopy(saltOverride, 0, iv, 0, 4)
        } else {
            val prefix = ByteArray(4)
            secureRandom.nextBytes(prefix)
            System.arraycopy(prefix, 0, iv, 0, 4)
        }
        ByteBuffer.wrap(iv, 4, 8).putLong(seq)

        val aad = "bridge-v1:$sendDirection:$seq".toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, sendKey, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        val ciphertextWithTag = cipher.doFinal(plaintext)

        val combined = ByteArray(12 + ciphertextWithTag.size)
        System.arraycopy(iv, 0, combined, 0, 12)
        System.arraycopy(ciphertextWithTag, 0, combined, 12, ciphertextWithTag.size)

        val b64 = Base64.getEncoder().encodeToString(combined)
        return """{"type":"enc","seq":$seq,"d":"$b64"}"""
    }

    @Synchronized
    fun open(jsonObject: JSONObject): String? {
        return try {
            if (jsonObject.optString("type") != "enc") return null
            val seq = jsonObject.optLong("seq", -1L)
            if (seq <= 0L || seq != expectedReceiveSeq) return null

            val b64 = jsonObject.optString("d", "")
            if (b64.isEmpty()) return null
            val combined = Base64.getDecoder().decode(b64)
            if (combined.size <= 28) return null

            val embeddedSeq = ByteBuffer.wrap(combined, 4, 8).long
            if (embeddedSeq != seq) return null

            val aad = "bridge-v1:$receiveDirection:$seq".toByteArray(Charsets.UTF_8)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, receiveKey, GCMParameterSpec(128, combined, 0, 12))
            cipher.updateAAD(aad)
            val plaintext = cipher.doFinal(combined, 12, combined.size - 12)

            expectedReceiveSeq += 1L
            String(plaintext, Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }
}

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
    @Volatile private var sessionCipher: BridgeSessionCipher? = null
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

    fun isConnected(): Boolean = authenticated && sessionCipher != null && socket?.isClosed == false
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
                writeEncrypted(ClipboardPayload(type = signalType))
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

                if (isConnected()) {
                    writeEncrypted(payload)
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
                    writeEncrypted(jsonString)
                }
            } catch (e: Exception) {
                log("Error sending raw json: ${e.message}")
            }
        }
    }

    private fun writePlaintext(payload: ClipboardPayload) {
        synchronized(this) {
            writer?.println(payload.toJsonString())
            writer?.flush()
        }
    }

    private fun writeEncrypted(payload: ClipboardPayload) {
        writeEncrypted(payload.toJsonString())
    }

    private fun writeEncrypted(jsonString: String) {
        synchronized(this) {
            val out = writer ?: return
            val cipher = sessionCipher ?: return
            val encryptedLine = cipher.seal(jsonString)
            out.println(encryptedLine)
            out.flush()
        }
    }

    private var heartbeatTick = 0

    private fun startHeartbeat() {
        stopHeartbeat()
        heartbeatTick = 0
        heartbeatTask = heartbeatExecutor.scheduleWithFixedDelay({
            if (isRunning.get() && isConnected()) {
                try {
                    writeEncrypted(ClipboardPayload(type = "ping"))
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
                        sessionCipher = null
                        authenticated = false
                    }

                    val activeCode = (pairCode ?: "").replace(" ", "").trim()
                    val clientNonce = generateSecureNonce()
                    val clientKeyPair = BridgeSpeke.generateKeyPair(
                        pairingCode = activeCode,
                        clientNonce = clientNonce
                    )
                    var pendingMaterial: BridgeSpeke.SessionMaterial? = null

                    // Step 1 of SPEKE PAKE handshake: send client nonce + ephemeral public key (no password hash on the wire)
                    writePlaintext(
                        ClipboardPayload(
                            type = "hello",
                            text = clientNonce,
                            data = clientKeyPair.publicHex,
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
                                // Strict pre-authentication gate: only "challenge", "welcome", or "denied" allowed before auth
                                val payload = ClipboardPayload.fromJsonString(trimmed)
                                when (payload?.type) {
                                    "challenge" -> {
                                        if (pendingMaterial != null) {
                                            throw SecurityException("Duplicate challenge message from server")
                                        }
                                        val serverNonce = payload.text?.trim() ?: ""
                                        val serverPublicHex = payload.data?.trim()?.lowercase() ?: ""
                                        if (serverNonce.length !in 16..128) {
                                            throw SecurityException("Invalid server nonce in challenge")
                                        }
                                        val sharedSecretHex = BridgeSpeke.computeSharedSecret(
                                            peerPublicHex = serverPublicHex,
                                            privateScalar = clientKeyPair.privateScalar
                                        ) ?: throw SecurityException("Invalid SPEKE public key from server")

                                        val material = BridgeSpeke.deriveSessionMaterial(
                                            sharedSecretHex = sharedSecretHex,
                                            pairingCode = activeCode,
                                            clientNonce = clientNonce,
                                            serverNonce = serverNonce,
                                            clientPublicHex = clientKeyPair.publicHex,
                                            serverPublicHex = serverPublicHex
                                        )
                                        pendingMaterial = material
                                        writePlaintext(
                                            ClipboardPayload(
                                                type = "auth",
                                                hash = material.clientProof
                                            )
                                        )
                                    }
                                    "welcome" -> {
                                        val material = pendingMaterial
                                            ?: throw SecurityException("Received welcome before SPEKE challenge")
                                        if (!constantTimeEquals(payload.hash.lowercase(), material.serverProof.lowercase())) {
                                            log("Security: Rejected unverified 'welcome' from $host (failed mutual SPEKE auth proof)")
                                            throw SecurityException("Server failed mutual SPEKE authentication proof")
                                        }
                                        synchronized(this) {
                                            sessionCipher = BridgeSessionCipher(
                                                sendKey = material.c2sKey,
                                                receiveKey = material.s2cKey,
                                                sendDirection = "c2s",
                                                receiveDirection = "s2c"
                                            )
                                            authenticated = true
                                        }
                                        failedAttempts = 0
                                        macName = (payload.name ?: "Mac").take(64)
                                        BridgePrefs.saveHost(context, host, currentPort)
                                        BridgePrefs.markPaired(context, macName)
                                        log("Paired with ${payload.name} at $host:$currentPort (SPEKE + AES-256-GCM)")
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
                            } else {
                                if (type != "enc" || jsonObj == null) {
                                    log("Security: Rejected unencrypted post-handshake frame from $host")
                                    throw SecurityException("Post-handshake message must be encrypted")
                                }
                                val decryptedJsonString = sessionCipher?.open(jsonObj)
                                    ?: throw SecurityException("Failed to decrypt or authenticate session frame from server")
                                val innerObj = try { JSONObject(decryptedJsonString) } catch (e: Exception) { null }
                                val innerType = innerObj?.optString("type")

                                if (innerType != null && (innerType.startsWith("notif_") || innerType == "settings_sync")) {
                                    notifyNotificationPayloadReceived(decryptedJsonString)
                                } else if (innerType != null && innerType.startsWith("file_") && innerObj != null) {
                                    BridgeFileTransferManager.handleControlMessage(context, innerObj, host)
                                } else {
                                    val payload = ClipboardPayload.fromJsonString(decryptedJsonString)
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
                                            // Acknowledge ping over encrypted channel
                                            writeEncrypted(ClipboardPayload(type = "pong"))
                                        }
                                        "pong" -> {
                                            // Keepalive ack received
                                        }
                                        else -> { /* unknown */ }
                                    }
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
            sessionCipher = null
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
