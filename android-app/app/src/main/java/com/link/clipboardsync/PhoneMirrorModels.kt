package com.link.clipboardsync

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
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

    fun buildHandshake(tokenHex: String, width: Int, height: Int, rotation: Int): ByteArray {
        val normalizedToken = tokenHex.trim().lowercase()
        require(normalizedToken.length == TOKEN_HEX_LENGTH) {
            "Mirror token must be $TOKEN_HEX_LENGTH hex chars, got ${normalizedToken.length}"
        }
        val tokenBytes = normalizedToken.toByteArray(Charsets.US_ASCII)
        val buf = ByteBuffer.allocate(HANDSHAKE_BYTES).order(ByteOrder.BIG_ENDIAN)
        buf.put(tokenBytes)
        buf.putShort(width.coerceIn(1, 65535).toShort())
        buf.putShort(height.coerceIn(1, 65535).toShort())
        buf.put((rotation and 0xFF).toByte())
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
