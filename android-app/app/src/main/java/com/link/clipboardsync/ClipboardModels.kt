package com.link.clipboardsync

import org.json.JSONObject
import java.security.MessageDigest

/**
 * Clipboard message model exchanged over the TCP wire.
 * Serialized as newline-delimited JSON (NDJSON).
 *
 * Message types:
 *  - "hello"   (Android -> Mac)  pairing handshake, carries [code] + [device]
 *  - "welcome" (Mac -> Android)  handshake accepted, carries Mac [name]
 *  - "denied"  (Mac -> Android)  handshake rejected (wrong pairing code)
 *  - "clip"    (both ways)       clipboard text payload
 *  - "ping"    (both ways)       keep-alive heartbeat
 */
data class ClipboardPayload(
    val type: String = "clip",
    val hash: String = "",
    val text: String = "",
    val timestamp: Long = System.currentTimeMillis(),
    val code: String? = null,
    val device: String? = null,
    val name: String? = null
) {
    fun toJsonString(): String {
        val json = JSONObject()
        json.put("type", type)
        json.put("hash", hash)
        json.put("text", text)
        json.put("timestamp", timestamp)
        code?.let { json.put("code", it) }
        device?.let { json.put("device", it) }
        name?.let { json.put("name", it) }
        return json.toString()
    }

    companion object {
        fun fromJsonString(jsonStr: String): ClipboardPayload? {
            return try {
                val json = JSONObject(jsonStr)
                ClipboardPayload(
                    type = json.optString("type", "clip"),
                    hash = json.optString("hash", ""),
                    text = json.optString("text", ""),
                    timestamp = json.optLong("timestamp", System.currentTimeMillis()),
                    code = json.optString("code").ifEmpty { null },
                    device = json.optString("device").ifEmpty { null },
                    name = json.optString("name").ifEmpty { null }
                )
            } catch (e: Exception) {
                null
            }
        }

        fun computeSHA256(input: String): String {
            val bytes = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}
