package com.link.clipboardsync

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec

class BridgeCoreUnitTest {

    @Test
    fun isPrivateLocalAddress_acceptsPrivateAndLoopback_rejectsPublicAndMalformed() {
        val allowed = listOf(
            "127.0.0.1",
            "localhost",
            "::1",
            "10.0.0.1",
            "10.255.255.254",
            "172.16.0.1",
            "172.31.255.254",
            "192.168.1.42",
            "169.254.10.20",
            "100.64.0.1",
            "100.127.255.254",
            "fe80::1%en0",
            "fd12:3456:789a::1",
            "::ffff:192.168.1.10"
        )
        for (addr in allowed) {
            assertTrue("Expected local/private address to be allowed: $addr", NetworkSyncClient.isPrivateLocalAddress(addr))
        }

        val rejected = listOf(
            null,
            "",
            "   ",
            "8.8.8.8",
            "1.1.1.1",
            "172.15.255.255",
            "172.32.0.1",
            "192.169.1.1",
            "100.63.255.255",
            "100.128.0.1",
            "256.168.1.1",
            "example.com"
        )
        for (addr in rejected) {
            assertFalse("Expected non-private/invalid address to be rejected: $addr", NetworkSyncClient.isPrivateLocalAddress(addr))
        }
    }

    @Test
    fun constantTimeEquals_and_generateSecureNonce_behaveCorrectly() {
        assertTrue(NetworkSyncClient.constantTimeEquals("abc123", "abc123"))
        assertFalse(NetworkSyncClient.constantTimeEquals("abc123", "abc124"))
        assertFalse(NetworkSyncClient.constantTimeEquals("abc", "abcd"))
        assertFalse(NetworkSyncClient.constantTimeEquals("", ""))
        assertFalse(NetworkSyncClient.constantTimeEquals(null, "abc"))

        val n1 = NetworkSyncClient.generateSecureNonce()
        val n2 = NetworkSyncClient.generateSecureNonce()
        assertEquals(32, n1.length)
        assertTrue(n1.matches(Regex("^[0-9a-f]{32}$")))
        assertNotEquals(n1, n2)
    }

    @Test
    fun clipboardPayload_roundTrip_and_sha256() {
        val original = ClipboardPayload(
            type = "clip",
            hash = ClipboardPayload.computeSHA256("hello bridge"),
            text = "hello bridge",
            timestamp = 1700000000000L,
            device = "Pixel 8"
        )
        val parsed = ClipboardPayload.fromJsonString(original.toJsonString())
        assertNotNull(parsed)
        assertEquals("clip", parsed!!.type)
        assertEquals(original.hash, parsed.hash)
        assertEquals("hello bridge", parsed.text)
        assertEquals("Pixel 8", parsed.device)

        assertNull(ClipboardPayload.fromJsonString("not-valid-json"))

        // Deterministic handshake digest vector matching macOS server
        assertEquals(
            "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3",
            ClipboardPayload.computeSHA256("123")
        )
    }

    @Test
    fun sanitizeFileName_blocksTraversalAndInvalidNames() {
        assertEquals("passwd", BridgeFileTransferManager.sanitizeFileName("../../../../etc/passwd"))
        assertEquals("TransferredFile", BridgeFileTransferManager.sanitizeFileName(".."))
        assertEquals("TransferredFile", BridgeFileTransferManager.sanitizeFileName("."))
        assertEquals("TransferredFile", BridgeFileTransferManager.sanitizeFileName("   "))
        assertEquals("_hidden", BridgeFileTransferManager.sanitizeFileName(".hidden"))
        assertEquals("report.pdf", BridgeFileTransferManager.sanitizeFileName("report\u0000.pdf"))
        assertFalse(BridgeFileTransferManager.sanitizeFileName("..\\..\\evil.txt").contains("\\"))
    }

    @Test
    fun deriveAesKey_and_aesGcmRoundTrip_detectsTampering() {
        val key = BridgeFileTransferManager.deriveAesKey("sample-transfer-token")
        assertEquals("AES", key.algorithm)
        assertEquals(32, key.encoded.size) // 256-bit AES key

        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val plaintext = "Bridge encrypted file chunk payload".toByteArray(Charsets.UTF_8)

        val encCipher = Cipher.getInstance("AES/GCM/NoPadding")
        encCipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        val ciphertext = encCipher.doFinal(plaintext)

        val decCipher = Cipher.getInstance("AES/GCM/NoPadding")
        decCipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        assertArrayEquals(plaintext, decCipher.doFinal(ciphertext))

        // Flip a byte in ciphertext and ensure GCM tag verification rejects it
        val tampered = ciphertext.copyOf()
        tampered[0] = (tampered[0].toInt() xor 0xFF).toByte()
        val badCipher = Cipher.getInstance("AES/GCM/NoPadding")
        badCipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        var threw = false
        try {
            badCipher.doFinal(tampered)
        } catch (_: AEADBadTagException) {
            threw = true
        }
        assertTrue("Expected AEADBadTagException on tampered ciphertext", threw)
    }

    @Test
    fun fileTransferHelpers_detectExecutablesAndOsMetadata() {
        assertTrue(BridgeFileTransferManager.isExecutable("app.APK"))
        assertTrue(BridgeFileTransferManager.isExecutable("run.sh"))
        assertTrue(BridgeFileTransferManager.isExecutable("setup.exe"))
        assertFalse(BridgeFileTransferManager.isExecutable("photo.jpg"))
        assertFalse(BridgeFileTransferManager.isExecutable("notes.pdf"))

        assertTrue(BridgeFileTransferManager.isIgnoredMetadata(".DS_Store"))
        assertTrue(BridgeFileTransferManager.isIgnoredMetadata("__MACOSX"))
        assertTrue(BridgeFileTransferManager.isIgnoredMetadata("._document.pdf"))
        assertFalse(BridgeFileTransferManager.isIgnoredMetadata("document.pdf"))
    }

    @Test
    fun updateChecker_isNewerVersion_handlesSemVer() {
        assertTrue(UpdateChecker.isNewerVersion("1.3.2", "1.3.1"))
        assertTrue(UpdateChecker.isNewerVersion("v1.4.0", "1.3.1"))
        assertTrue(UpdateChecker.isNewerVersion("1.2", "1.1.1"))
        assertFalse(UpdateChecker.isNewerVersion("1.2.0", "1.2"))
        assertFalse(UpdateChecker.isNewerVersion("1.3.1", "1.3.1"))
        assertFalse(UpdateChecker.isNewerVersion("1.3.0", "1.3.1"))
    }

    @Test
    fun notificationModels_validateAndRoundTrip() {
        val notif = BridgeNotification(
            id = "notif_1",
            pkg = "com.example.chat",
            app = "Chat",
            title = "Alex",
            text = "Ping",
            actions = listOf(BridgeNotificationAction(id = 1, title = "Reply", hasInput = true))
        )
        val parsed = BridgeNotification.fromJson(JSONObject(notif.toPostJsonString()))
        assertNotNull(parsed)
        assertEquals("notif_1", parsed!!.id)
        assertEquals(1, parsed.actions.size)

        assertNull(NotificationActionRequest.fromJson(JSONObject("""{"id":"","actionId":0}""")))
        assertNull(NotificationDismissRequest.fromJson(JSONObject("""{"id":""}""")))
    }
}
