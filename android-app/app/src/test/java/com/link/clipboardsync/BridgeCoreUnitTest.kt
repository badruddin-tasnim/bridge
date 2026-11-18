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
import java.math.BigInteger
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

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
        assertTrue(BridgeFileTransferManager.isExecutable("autorun.command"))
        assertTrue(BridgeFileTransferManager.isExecutable("payload.workflow"))
        assertTrue(BridgeFileTransferManager.isExecutable("script.scpt"))
        assertTrue(BridgeFileTransferManager.isExecutable("agent.py"))
        assertTrue(BridgeFileTransferManager.isExecutable("launcher.jar"))
        assertTrue(BridgeFileTransferManager.isExecutable("phish.webloc"))
        assertFalse(BridgeFileTransferManager.isExecutable("photo.jpg"))
        assertFalse(BridgeFileTransferManager.isExecutable("notes.pdf"))

        assertTrue(BridgeFileTransferManager.isIgnoredMetadata(".DS_Store"))
        assertTrue(BridgeFileTransferManager.isIgnoredMetadata("__MACOSX"))
        assertTrue(BridgeFileTransferManager.isIgnoredMetadata("._document.pdf"))
        assertFalse(BridgeFileTransferManager.isIgnoredMetadata("document.pdf"))

        assertEquals(
            "abedb85429f8107b6dbb1a10dd1ca078d232b7f52f1e8f621cfb5b23f613e34e",
            BridgeFileTransferManager.computeDataSocketAuth("sample-transfer-token", "tx_12345", 65536L)
        )
    }

    @Test
    fun bridgeSpeke_deterministicVectorMatchesMacOS_andRejectsInvalidGroupElements() {
        val code = "482910"
        val clientNonce = "00112233445566778899aabbccddeeff"
        val serverNonce = "ffeeddccbbaa99887766554433221100"

        val md = MessageDigest.getInstance("SHA-256")
        val clientScalar = BigInteger(1, md.digest("deterministic-client-scalar".toByteArray(Charsets.UTF_8)))
        val serverScalar = BigInteger(1, md.digest("deterministic-server-scalar".toByteArray(Charsets.UTF_8)))

        val clientKP = BridgeSpeke.generateKeyPair(code, clientNonce, clientScalar)
        val serverKP = BridgeSpeke.generateKeyPair(code, clientNonce, serverScalar)

        assertTrue(clientKP.publicHex.startsWith("1b4f3adc32b2cd3737115a7a07b5579d483b136f1784520dd2fd505aa2ec9b4f"))
        assertTrue(serverKP.publicHex.startsWith("3304c34f377eb869ab75eade3a1f7b8e117a73d6f380825895d60e4b0eb5496a"))

        val clientShared = BridgeSpeke.computeSharedSecret(serverKP.publicHex, clientKP.privateScalar)
        val serverShared = BridgeSpeke.computeSharedSecret(clientKP.publicHex, serverKP.privateScalar)
        assertNotNull(clientShared)
        assertEquals(clientShared, serverShared)
        assertTrue(clientShared!!.startsWith("129b5d17f6f0fb9fe3ae58cae7230fa8c4e1b0dfabf044c52005c6e3781f001f"))

        val material = BridgeSpeke.deriveSessionMaterial(
            sharedSecretHex = clientShared,
            pairingCode = code,
            clientNonce = clientNonce,
            serverNonce = serverNonce,
            clientPublicHex = clientKP.publicHex,
            serverPublicHex = serverKP.publicHex
        )
        assertEquals("b80392ad0780478b3bf87f5b61fd2f22a8359d25c7dee09bb93c52e57a690d52", material.clientProof)
        assertEquals("13e5e9de0452dc3611549979cea6eb3f9a5517f81f8273e85535abf06ed3fcf5", material.serverProof)

        // Wrong pairing code produces different proofs
        val wrongKP = BridgeSpeke.generateKeyPair("999999", clientNonce, clientScalar)
        val wrongShared = BridgeSpeke.computeSharedSecret(serverKP.publicHex, wrongKP.privateScalar)!!
        val wrongMaterial = BridgeSpeke.deriveSessionMaterial(
            sharedSecretHex = wrongShared,
            pairingCode = "999999",
            clientNonce = clientNonce,
            serverNonce = serverNonce,
            clientPublicHex = wrongKP.publicHex,
            serverPublicHex = serverKP.publicHex
        )
        assertNotEquals(material.clientProof, wrongMaterial.clientProof)

        // Reject trivial / invalid group elements (0, 1, p-1)
        assertNull(BridgeSpeke.computeSharedSecret("0".repeat(512), clientKP.privateScalar))
        assertNull(BridgeSpeke.computeSharedSecret("0".repeat(511) + "1", clientKP.privateScalar))
    }

    @Test
    fun bridgeSessionCipher_deterministicVectorMatchesMacOS_andEnforcesSeqAndAad() {
        val md = MessageDigest.getInstance("SHA-256")
        val testKey = SecretKeySpec(md.digest("test-session-key".toByteArray(Charsets.UTF_8)), "AES")
        val c2sKey = SecretKeySpec(md.digest("c2s-key".toByteArray(Charsets.UTF_8)), "AES")
        val s2cKey = SecretKeySpec(md.digest("s2c-key".toByteArray(Charsets.UTF_8)), "AES")

        val vecCipher = BridgeSessionCipher(
            sendKey = testKey,
            receiveKey = testKey,
            sendDirection = "c2s",
            receiveDirection = "c2s"
        )
        val salt = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte())
        val sealedVec = vecCipher.seal("""{"type":"clip","text":"secret hello"}""", saltOverride = salt)
        val vecObj = JSONObject(sealedVec)
        assertEquals(
            "qrvM3QAAAAAAAAABj9S5pvE1dq/nFETBIMF65kliHlU9lp23sE7XgDN72AYSfHfaknczz+4/TmBF1LvejSdnHHs=",
            vecObj.optString("d")
        )
        assertEquals("""{"type":"clip","text":"secret hello"}""", vecCipher.open(vecObj))

        val clientCipher = BridgeSessionCipher(c2sKey, s2cKey, "c2s", "s2c")
        val serverCipher = BridgeSessionCipher(s2cKey, c2sKey, "s2c", "c2s")

        val frame1 = clientCipher.seal("""{"type":"clip","text":"one"}""")
        val frame2 = clientCipher.seal("""{"type":"clip","text":"two"}""")
        val obj1 = JSONObject(frame1)
        val obj2 = JSONObject(frame2)

        // Out-of-order frame (seq 2 before seq 1) must be rejected
        assertNull(serverCipher.open(obj2))
        // Expected seq 1 succeeds, then seq 2 succeeds
        assertEquals("""{"type":"clip","text":"one"}""", serverCipher.open(obj1))
        assertEquals("""{"type":"clip","text":"two"}""", serverCipher.open(obj2))
        // Replay of seq 1 must be rejected
        assertNull(serverCipher.open(obj1))
        // Reflection attack (feeding client's c2s frame back into client's s2c receiver) must fail
        val clientMirror = BridgeSessionCipher(c2sKey, c2sKey, "c2s", "s2c")
        assertNull(clientMirror.open(obj1))
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

    @Test
    fun deviceStatusMonitor_buildsBatteryStatusJson() {
        val json = JSONObject(
            DeviceStatusMonitor.buildDeviceStatusJson(
                DeviceStatusMonitor.BatterySnapshot(level = 45, isCharging = false)
            )
        )
        assertEquals("device_status", json.getString("type"))
        assertEquals(45, json.getInt("batteryLevel"))
        assertFalse(json.getBoolean("isCharging"))

        val chargingJson = JSONObject(
            DeviceStatusMonitor.buildDeviceStatusJson(
                DeviceStatusMonitor.BatterySnapshot(level = 20, isCharging = true)
            )
        )
        assertEquals(20, chargingJson.getInt("batteryLevel"))
        assertTrue(chargingJson.getBoolean("isCharging"))

        val fullJson = JSONObject(
            DeviceStatusMonitor.buildDeviceStatusJson(
                DeviceStatusMonitor.DeviceSnapshot(
                    batteryLevel = 72,
                    isCharging = false,
                    ringerMode = "vibrate",
                    isDndEnabled = true,
                    hasDndPermission = true,
                    isRingingPhone = true
                )
            )
        )
        assertEquals("device_status", fullJson.getString("type"))
        assertEquals(72, fullJson.getInt("batteryLevel"))
        assertFalse(fullJson.getBoolean("isCharging"))
        assertEquals("vibrate", fullJson.getString("ringerMode"))
        assertTrue(fullJson.getBoolean("isDndEnabled"))
        assertTrue(fullJson.getBoolean("hasDndPermission"))
        assertTrue(fullJson.getBoolean("isRingingPhone"))
    }

    @Test
    fun phoneMediaManager_buildsMediaStatusJson() {
        val activeJson = JSONObject(
            PhoneMediaManager.buildMediaStatusJson(
                PhoneMediaManager.MediaSnapshot(
                    isActive = true,
                    isPlaying = true,
                    title = "Surrender",
                    artist = "KIDPUNK",
                    album = "Surrender",
                    appName = "Spotify",
                    durationMs = 176000L,
                    positionMs = 28000L,
                    playbackSpeed = 1.0f,
                    volumeIndex = 10,
                    maxVolume = 15,
                    canSeek = true,
                    canSkipNext = true,
                    canSkipPrevious = false,
                    canControlVolume = true,
                    artworkHash = "abc123",
                    artworkBase64 = "ZmFrZQ=="
                )
            )
        )
        assertEquals("media_status", activeJson.getString("type"))
        assertTrue(activeJson.getBoolean("isActive"))
        assertTrue(activeJson.getBoolean("isPlaying"))
        assertEquals("Surrender", activeJson.getString("title"))
        assertEquals("KIDPUNK", activeJson.getString("artist"))
        assertEquals("Spotify", activeJson.getString("appName"))
        assertEquals(176000L, activeJson.getLong("durationMs"))
        assertEquals(28000L, activeJson.getLong("positionMs"))
        assertEquals(10, activeJson.getInt("volumeIndex"))
        assertEquals(15, activeJson.getInt("maxVolume"))
        assertTrue(activeJson.getBoolean("canSeek"))
        assertTrue(activeJson.getBoolean("canSkipNext"))
        assertFalse(activeJson.getBoolean("canSkipPrevious"))
        assertTrue(activeJson.getBoolean("canControlVolume"))
        assertEquals("ZmFrZQ==", activeJson.getString("artworkBase64"))

        val inactiveJson = JSONObject(
            PhoneMediaManager.buildMediaStatusJson(
                PhoneMediaManager.MediaSnapshot(
                    isActive = false,
                    volumeIndex = 4,
                    maxVolume = 15
                )
            )
        )
        assertFalse(inactiveJson.getBoolean("isActive"))
        assertFalse(inactiveJson.has("artworkBase64"))
        assertEquals(4, inactiveJson.getInt("volumeIndex"))
    }

    @Test
    fun phoneCallMonitor_buildsCallEventJson() {
        val ringingJson = JSONObject(
            PhoneCallMonitor.buildCallEventJson(
                callId = "call_key_1",
                state = "ringing",
                callerName = "Alex",
                appName = "Phone",
                canAnswer = true,
                canDecline = true,
                iconBase64 = "aWNvbg=="
            )
        )
        assertEquals("call_event", ringingJson.getString("type"))
        assertEquals("call_key_1", ringingJson.getString("callId"))
        assertEquals("ringing", ringingJson.getString("state"))
        assertEquals("Alex", ringingJson.getString("callerName"))
        assertEquals("Phone", ringingJson.getString("appName"))
        assertTrue(ringingJson.getBoolean("canAnswer"))
        assertTrue(ringingJson.getBoolean("canDecline"))
        assertEquals("aWNvbg==", ringingJson.getString("icon"))

        val endedJson = JSONObject(
            PhoneCallMonitor.buildCallEventJson(
                callId = "call_key_1",
                state = "ended",
                callerName = "Alex",
                appName = "Phone",
                canAnswer = false,
                canDecline = false,
                iconBase64 = null
            )
        )
        assertEquals("ended", endedJson.getString("state"))
        assertFalse(endedJson.has("icon"))
    }

    @Test
    fun phoneControlManager_generatesFindPhoneBeaconPcm() {
        val pcm = PhoneControlManager.generateFindPhoneBeaconPcm(sampleRate = 24000)
        assertEquals(30000, pcm.size)
        assertTrue(pcm.any { it.toInt() != 0 })
        assertEquals(0, pcm.last().toInt())
    }

    @Test
    fun macSystemStatus_parsesMacBookAndDesktopBatteriesAndBuildsControlJson() {
        val macBook = MacSystemStatus.fromJson(
            JSONObject()
                .put("type", "mac_status")
                .put("batteryPercent", 84)
                .put("isCharging", true)
                .put("isMuted", false)
                .put("volumePercent", 65)
                .put("canToggleMute", true)
                .put("canControlVolume", true)
        )
        assertEquals(84, macBook.batteryPercent)
        assertTrue(macBook.isCharging)
        assertFalse(macBook.isMuted)
        assertEquals(65, macBook.volumePercent)

        val desktopMac = MacSystemStatus.fromJson(
            JSONObject()
                .put("type", "mac_status")
                .put("isCharging", false)
                .put("isMuted", true)
                .put("volumePercent", 0)
        )
        assertNull(desktopMac.batteryPercent)
        assertTrue(desktopMac.isMuted)

        val toggleCmd = JSONObject(MacSystemStatus.buildMacControlJson(action = "toggle_mute"))
        assertEquals("mac_control", toggleCmd.getString("type"))
        assertEquals("toggle_mute", toggleCmd.getString("action"))
    }

    @Test
    fun macMediaStatus_parsesReusesArtworkInterpolatesAndBuildsActionJson() {
        val first = MacMediaStatus.fromJson(
            JSONObject()
                .put("type", "mac_media_status")
                .put("isActive", true)
                .put("isPlaying", true)
                .put("title", "Midnight City")
                .put("artist", "M83")
                .put("appName", "Spotify")
                .put("durationMs", 243000L)
                .put("positionMs", 40000L)
                .put("playbackSpeed", 1.0)
                .put("canSeek", true)
                .put("canSkipNext", true)
                .put("canSkipPrevious", true)
                .put("artworkHash", "hash_m83")
                .put("artworkBase64", "AQID"),
            previous = null,
            receivedAtElapsedMs = 1000L
        )
        assertTrue(first.isActive)
        assertEquals("AQID", first.artworkBase64)
        assertEquals(45000L, first.estimatedPositionMs(6000L))
        assertEquals("1:05", MacMediaStatus.formatTimeMs(65000L))

        val followUp = MacMediaStatus.fromJson(
            JSONObject()
                .put("type", "mac_media_status")
                .put("isActive", true)
                .put("isPlaying", false)
                .put("title", "Midnight City")
                .put("appName", "Spotify")
                .put("durationMs", 243000L)
                .put("positionMs", 50000L)
                .put("canSeek", true)
                .put("artworkHash", "hash_m83"),
            previous = first,
            receivedAtElapsedMs = 8000L
        )
        assertEquals("AQID", followUp.artworkBase64)
        assertEquals(50000L, followUp.estimatedPositionMs(20000L))

        val seekCmd = JSONObject(MacMediaStatus.buildMediaActionJson(action = "seek", positionMs = 90000L))
        assertEquals("mac_media_action", seekCmd.getString("type"))
        assertEquals("seek", seekCmd.getString("action"))
        assertEquals(90000L, seekCmd.getLong("positionMs"))
    }

    @Test
    fun phoneMirrorProtocol_handshakeHeadersGeometryAndCoordinates() {
        val token = "ab".repeat(32)
        val hs = PhoneMirrorProtocol.buildHandshake(token, width = 720, height = 1280, rotation = 2)
        assertEquals(PhoneMirrorProtocol.HANDSHAKE_BYTES, hs.size)
        assertEquals(token, String(hs.copyOfRange(0, 64), Charsets.US_ASCII))
        assertEquals(0x02, hs[64].toInt() and 0xFF)
        assertEquals(0xD0, hs[65].toInt() and 0xFF)
        assertEquals(0x05, hs[66].toInt() and 0xFF)
        assertEquals(0x00, hs[67].toInt() and 0xFF)
        assertEquals(0x02, hs[68].toInt() and 0xFF)

        val hdr = PhoneMirrorProtocol.buildPacketHeader(
            type = PhoneMirrorProtocol.PACKET_TYPE_FRAME,
            flags = PhoneMirrorProtocol.FLAG_KEYFRAME,
            ptsUs = 1_000_000L,
            payloadLength = 4096
        )
        assertEquals(PhoneMirrorProtocol.HEADER_BYTES, hdr.size)
        assertEquals(0x02, hdr[0].toInt() and 0xFF)
        assertEquals(0x01, hdr[1].toInt() and 0xFF)
        assertEquals(0x10, hdr[12].toInt() and 0xFF)
        assertEquals(0x00, hdr[13].toInt() and 0xFF)

        val (sw, sh) = PhoneMirrorProtocol.computeStreamDimensions(1080, 2400, maxDimension = 1280)
        assertTrue(sw % 16 == 0 && sh % 16 == 0)
        assertEquals(1280, sh)
        assertEquals(576, sw)

        val (px, py) = PhoneMirrorProtocol.denormalizePoint(1.5f, -0.2f, 1080, 2400)
        assertEquals(1079f, px, 0.01f)
        assertEquals(0f, py, 0.01f)
    }

    @Test
    fun phoneMirrorCommands_parseControlAndInputJson() {
        val validToken = "cd".repeat(32)
        val reqStart = PhoneMirrorProtocol.parseControlCommand(
            JSONObject()
                .put("type", "mirror_control")
                .put("action", "request_start")
                .put("port", 51234)
                .put("token", validToken)
                .put("maxDimension", 1280)
                .put("bitRate", 5_000_000)
                .put("fps", 60)
        )
        assertTrue(reqStart is MirrorControlCommand.RequestStart)
        assertEquals(51234, (reqStart as MirrorControlCommand.RequestStart).offer.port)

        // Reject malformed token or invalid port
        assertNull(
            PhoneMirrorProtocol.parseControlCommand(
                JSONObject().put("action", "request_start").put("port", 80).put("token", validToken)
            )
        )
        assertNull(
            PhoneMirrorProtocol.parseControlCommand(
                JSONObject().put("action", "request_start").put("port", 51234).put("token", "short")
            )
        )

        val swipe = PhoneMirrorProtocol.parseInputCommand(
            JSONObject()
                .put("action", "swipe")
                .put("startXNorm", 0.5)
                .put("startYNorm", 0.8)
                .put("endXNorm", 0.5)
                .put("endYNorm", 0.2)
                .put("durationMs", 250)
        )
        assertTrue(swipe is MirrorInputCommand.Swipe)
        assertEquals(250L, (swipe as MirrorInputCommand.Swipe).durationMs)

        val global = PhoneMirrorProtocol.parseInputCommand(
            JSONObject().put("action", "global").put("globalAction", "home")
        )
        assertEquals(MirrorInputCommand.GlobalAction("home"), global)

        val setDimTrue = PhoneMirrorProtocol.parseControlCommand(
            JSONObject().put("action", "set_dim").put("dimmed", true)
        )
        assertEquals(MirrorControlCommand.SetDim(true), setDimTrue)
        val setDimFalse = PhoneMirrorProtocol.parseControlCommand(
            JSONObject().put("action", "set_dim").put("dimmed", false)
        )
        assertEquals(MirrorControlCommand.SetDim(false), setDimFalse)
    }
}
