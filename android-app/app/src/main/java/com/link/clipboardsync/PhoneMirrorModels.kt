package com.link.clipboardsync

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

enum class MirrorSessionState {
    IDLE,
    WAITING_PERMISSION,
    STARTING,
    STREAMING
}

sealed class MirrorControlCommand {
    data class RequestStart(val offer: MirrorStreamOffer) : MirrorControlCommand()
    data class StreamOffer(val offer: MirrorStreamOffer) : MirrorControlCommand()
    data class SetDim(val dimmed: Boolean) : MirrorControlCommand()
    object Stop : MirrorControlCommand()
    object RequestKeyframe : MirrorControlCommand()
}

data class MirrorStreamOffer(
    val port: Int,
    val token: String,
    val maxDimension: Int,
    val bitRate: Int,
    val fps: Int
)

sealed class MirrorInputCommand {
    data class Tap(val xNorm: Float, val yNorm: Float) : MirrorInputCommand()
    data class LongPress(val xNorm: Float, val yNorm: Float) : MirrorInputCommand()
    data class Swipe(
        val startXNorm: Float,
        val startYNorm: Float,
        val endXNorm: Float,
        val endYNorm: Float,
        val durationMs: Long
    ) : MirrorInputCommand()
    data class GlobalAction(val action: String) : MirrorInputCommand()
    data class TextInput(val text: String) : MirrorInputCommand()
    data class KeyAction(val keyAction: String) : MirrorInputCommand()
}

object PhoneMirrorProtocol {
    const val PACKET_TYPE_CONFIG: Byte = 0x01
    const val PACKET_TYPE_FRAME: Byte = 0x02
    const val PACKET_TYPE_GEOMETRY: Byte = 0x03

    const val FLAG_NONE: Byte = 0x00
    const val FLAG_KEYFRAME: Byte = 0x01

    const val TOKEN_HEX_LENGTH = 64
    const val HANDSHAKE_BYTES = 69
    const val HEADER_BYTES = 14
    const val GEOMETRY_PAYLOAD_BYTES = 5

    fun computeStreamAuthProof(tokenHex: String, width: Int, height: Int, rotation: Int): String {
        val normalizedToken = tokenHex.trim().lowercase()
        require(normalizedToken.length == TOKEN_HEX_LENGTH) {
            "Mirror token must be $TOKEN_HEX_LENGTH hex chars, got ${normalizedToken.length}"
        }
        val safeW = width.coerceIn(1, 65535)
        val safeH = height.coerceIn(1, 65535)
        val safeRot = rotation and 0xFF
        val message = "bridge-mirror-auth-v1:$normalizedToken:$safeW:$safeH:$safeRot"
        val digest = MessageDigest.getInstance("SHA-256").digest(message.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    fun buildHandshake(tokenHex: String, width: Int, height: Int, rotation: Int): ByteArray {
        val safeW = width.coerceIn(1, 65535)
        val safeH = height.coerceIn(1, 65535)
        val safeRot = rotation and 0xFF
        val authProof = computeStreamAuthProof(tokenHex, safeW, safeH, safeRot)
        val authBytes = authProof.toByteArray(Charsets.US_ASCII)
        val buf = ByteBuffer.allocate(HANDSHAKE_BYTES).order(ByteOrder.BIG_ENDIAN)
        buf.put(authBytes)
        buf.putShort(safeW.toShort())
        buf.putShort(safeH.toShort())
        buf.put(safeRot.toByte())
        return buf.array()
    }

    fun buildPacketHeader(type: Byte, flags: Byte, ptsUs: Long, payloadLength: Int): ByteArray {
        val buf = ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        buf.put(type)
        buf.put(flags)
        buf.putLong(ptsUs)
        buf.putInt(max(0, payloadLength))
        return buf.array()
    }

    fun buildGeometryPayload(width: Int, height: Int, rotation: Int): ByteArray {
        val buf = ByteBuffer.allocate(GEOMETRY_PAYLOAD_BYTES).order(ByteOrder.BIG_ENDIAN)
        buf.putShort(width.coerceIn(1, 65535).toShort())
        buf.putShort(height.coerceIn(1, 65535).toShort())
        buf.put((rotation and 0xFF).toByte())
        return buf.array()
    }

    fun denormalizePoint(
        xNorm: Float,
        yNorm: Float,
        screenWidth: Int,
        screenHeight: Int
    ): Pair<Float, Float> {
        val w = max(1, screenWidth)
        val h = max(1, screenHeight)
        val clampedX = if (xNorm.isNaN()) 0f else xNorm.coerceIn(0f, 1f)
        val clampedY = if (yNorm.isNaN()) 0f else yNorm.coerceIn(0f, 1f)
        val px = clampedX * (w - 1).toFloat()
        val py = clampedY * (h - 1).toFloat()
        return Pair(px, py)
    }

    fun computeStreamDimensions(
        rawWidth: Int,
        rawHeight: Int,
        maxDimension: Int = 1280
    ): Pair<Int, Int> {
        val safeW = max(16, rawWidth)
        val safeH = max(16, rawHeight)
        val cap = max(256, maxDimension)
        val longest = max(safeW, safeH)
        val scale = if (longest > cap) cap.toDouble() / longest.toDouble() else 1.0

        val scaledW = max(256, (safeW * scale).roundToInt())
        val scaledH = max(256, (safeH * scale).roundToInt())

        // Align down/nearest to multiple of 16 for hardware MediaCodec compatibility
        val alignedW = max(256, ((scaledW + 8) / 16) * 16)
        val alignedH = max(256, ((scaledH + 8) / 16) * 16)
        return Pair(alignedW, alignedH)
    }

    fun buildStatusJson(
        state: String,
        reason: String? = null,
        width: Int? = null,
        height: Int? = null
    ): String {
        val obj = JSONObject()
            .put("type", "mirror_control")
            .put("action", "status")
            .put("state", state)
        if (!reason.isNullOrBlank()) {
            obj.put("reason", reason)
        }
        if (width != null && width > 0) {
            obj.put("width", width)
        }
        if (height != null && height > 0) {
            obj.put("height", height)
        }
        return obj.toString()
    }

    fun buildRequestOfferJson(): String {
        return JSONObject()
            .put("type", "mirror_control")
            .put("action", "request_offer")
            .toString()
    }

    fun parseControlCommand(json: JSONObject): MirrorControlCommand? {
        val action = json.optString("action").trim().lowercase()
        return when (action) {
            "request_start", "stream_offer" -> {
                val port = json.optInt("port", -1)
                val token = json.optString("token", "").trim().lowercase()
                if (port !in 1024..65535 || token.length != TOKEN_HEX_LENGTH || !token.all { it in '0'..'9' || it in 'a'..'f' }) {
                    return null
                }
                val maxDimension = json.optInt("maxDimension", 1280).coerceIn(480, 1920)
                val bitRate = json.optInt("bitRate", 5_000_000).coerceIn(1_000_000, 16_000_000)
                val fps = json.optInt("fps", 60).coerceIn(15, 60)
                val offer = MirrorStreamOffer(
                    port = port,
                    token = token,
                    maxDimension = maxDimension,
                    bitRate = bitRate,
                    fps = fps
                )
                if (action == "request_start") {
                    MirrorControlCommand.RequestStart(offer)
                } else {
                    MirrorControlCommand.StreamOffer(offer)
                }
            }
            "set_dim" -> MirrorControlCommand.SetDim(json.optBoolean("dimmed", true))
            "stop" -> MirrorControlCommand.Stop
            "request_keyframe" -> MirrorControlCommand.RequestKeyframe
            else -> null
        }
    }

    fun parseInputCommand(json: JSONObject): MirrorInputCommand? {
        val action = json.optString("action").trim().lowercase()
        return when (action) {
            "tap" -> {
                val x = json.optDouble("xNorm", Double.NaN).toFloat()
                val y = json.optDouble("yNorm", Double.NaN).toFloat()
                if (x.isNaN() || y.isNaN()) null else MirrorInputCommand.Tap(x.coerceIn(0f, 1f), y.coerceIn(0f, 1f))
            }
            "long_press" -> {
                val x = json.optDouble("xNorm", Double.NaN).toFloat()
                val y = json.optDouble("yNorm", Double.NaN).toFloat()
                if (x.isNaN() || y.isNaN()) null else MirrorInputCommand.LongPress(x.coerceIn(0f, 1f), y.coerceIn(0f, 1f))
            }
            "swipe" -> {
                val sx = json.optDouble("startXNorm", Double.NaN).toFloat()
                val sy = json.optDouble("startYNorm", Double.NaN).toFloat()
                val ex = json.optDouble("endXNorm", Double.NaN).toFloat()
                val ey = json.optDouble("endYNorm", Double.NaN).toFloat()
                val dur = json.optLong("durationMs", 220L).coerceIn(60L, 1200L)
                if (sx.isNaN() || sy.isNaN() || ex.isNaN() || ey.isNaN()) {
                    null
                } else {
                    MirrorInputCommand.Swipe(
                        startXNorm = sx.coerceIn(0f, 1f),
                        startYNorm = sy.coerceIn(0f, 1f),
                        endXNorm = ex.coerceIn(0f, 1f),
                        endYNorm = ey.coerceIn(0f, 1f),
                        durationMs = dur
                    )
                }
            }
            "global" -> {
                val globalAction = json.optString("globalAction", "").trim().lowercase()
                if (globalAction.isEmpty()) null else MirrorInputCommand.GlobalAction(globalAction)
            }
            "text" -> {
                val text = json.optString("text", "")
                if (text.isEmpty()) null else MirrorInputCommand.TextInput(text)
            }
            "key" -> {
                val keyAction = json.optString("keyAction", "").trim().lowercase()
                if (keyAction.isEmpty()) null else MirrorInputCommand.KeyAction(keyAction)
            }
            else -> null
        }
    }
}

/**
 * Per-packet AES-256-GCM cipher for the Phone Mirroring TCP video stream.
 * Derives key from `SHA-256("<token>:bridge-mirror-encryption")`, uses a 12-byte IV
 * (`4-byte random salt + 8-byte big-endian monotonic seq`), and binds header metadata via AAD.
 */
class PhoneMirrorStreamCipher(tokenHex: String) {
    private val keySpec: SecretKeySpec
    private val sendSalt = ByteArray(4).also { SecureRandom().nextBytes(it) }
    private var sendSeq: Long = 0L
    private var receiveSeq: Long = 0L

    init {
        val normalized = tokenHex.trim().lowercase()
        require(normalized.length == PhoneMirrorProtocol.TOKEN_HEX_LENGTH) {
            "Mirror token must be ${PhoneMirrorProtocol.TOKEN_HEX_LENGTH} hex chars"
        }
        val keyMaterial = MessageDigest.getInstance("SHA-256")
            .digest("$normalized:bridge-mirror-encryption".toByteArray(Charsets.UTF_8))
        keySpec = SecretKeySpec(keyMaterial, "AES")
    }

    @Synchronized
    fun seal(type: Byte, flags: Byte, ptsUs: Long, plaintext: ByteArray): ByteArray {
        val seq = sendSeq
        val iv = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN).apply {
            put(sendSalt)
            putLong(seq)
        }.array()
        val aad = buildAad(type, flags, ptsUs, seq)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keySpec, GCMParameterSpec(128, iv))
        cipher.updateAAD(aad)
        val cipherAndTag = cipher.doFinal(plaintext)
        sendSeq = seq + 1L
        return iv + cipherAndTag
    }

    @Synchronized
    fun open(type: Byte, flags: Byte, ptsUs: Long, encryptedPayload: ByteArray): ByteArray? {
        if (encryptedPayload.size < 28) return null
        val seq = receiveSeq
        val iv = encryptedPayload.copyOfRange(0, 12)
        val expectedSeqBytes = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN).putLong(seq).array()
        for (i in 0 until 8) {
            if (iv[4 + i] != expectedSeqBytes[i]) return null
        }
        val cipherAndTag = encryptedPayload.copyOfRange(12, encryptedPayload.size)
        val aad = buildAad(type, flags, ptsUs, seq)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, keySpec, GCMParameterSpec(128, iv))
            cipher.updateAAD(aad)
            val plain = cipher.doFinal(cipherAndTag)
            receiveSeq = seq + 1L
            plain
        } catch (_: Exception) {
            null
        }
    }

    private fun buildAad(type: Byte, flags: Byte, ptsUs: Long, seq: Long): ByteArray {
        val t = type.toInt() and 0xFF
        val f = flags.toInt() and 0xFF
        return "bridge-mirror-pkt-v1:$t:$f:$ptsUs:$seq".toByteArray(Charsets.UTF_8)
    }
}
