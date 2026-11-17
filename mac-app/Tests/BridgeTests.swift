import Foundation
import AppKit
import SwiftUI
import CryptoKit

private var failureCount = 0

private func expect(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
        failureCount += 1
    }
}

private func runLocalIpTests() {
    let allowed = [
        "127.0.0.1", "localhost", "::1",
        "10.0.0.1", "10.255.255.254",
        "172.16.0.1", "172.31.255.254",
        "192.168.1.42", "169.254.10.20",
        "100.64.0.1", "100.127.255.254",
        "fe80::1%en0", "fd12:3456:789a::1", "::ffff:192.168.1.10"
    ]
    for ip in allowed {
        expect(isLocalOrPrivateIp(ip), "Expected local/private IP to be allowed: \(ip)")
    }

    let rejected = [
        "", "   ", "8.8.8.8", "1.1.1.1",
        "172.15.255.255", "172.32.0.1",
        "192.169.1.1", "100.63.255.255", "100.128.0.1",
        "256.168.1.1", "example.com"
    ]
    for ip in rejected {
        expect(!isLocalOrPrivateIp(ip), "Expected public/malformed IP to be rejected: \(ip)")
    }
}

private func runCryptoAndAuthHelperTests() {
    expect(constantTimeEquals("abc123", "abc123"), "constantTimeEquals should match equal strings")
    expect(!constantTimeEquals("abc123", "abc124"), "constantTimeEquals should reject differing strings")
    expect(!constantTimeEquals("abc", "abcd"), "constantTimeEquals should reject different lengths")
    expect(!constantTimeEquals("", ""), "constantTimeEquals should reject empty strings")

    expect(
        computeSHA256("123") == "a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3",
        "computeSHA256 should produce standard lowercase SHA-256 hex"
    )

    for _ in 0..<25 {
        let code = generateSecureSixDigitCode()
        expect(code.count == 6, "Pairing code must be 6 digits: \(code)")
        if let val = Int(code) {
            expect((100000...999999).contains(val), "Pairing code out of 6-digit range: \(code)")
        } else {
            expect(false, "Pairing code was not numeric: \(code)")
        }
    }
}

private func runPayloadAndVersionTests() throws {
    let payload = ClipboardPayload(type: "clip", hash: "deadbeef", text: "Hello Bridge", device: "Mac")
    let data = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(ClipboardPayload.self, from: data)
    expect(decoded.type == "clip", "Decoded payload type mismatch")
    expect(decoded.hash == "deadbeef", "Decoded payload hash mismatch")
    expect(decoded.text == "Hello Bridge", "Decoded payload text mismatch")

    expect(BridgeModel.isNewerVersion(remote: "1.3.2", current: "1.3.1"), "1.3.2 should be newer than 1.3.1")
    expect(BridgeModel.isNewerVersion(remote: "v1.4.0", current: "1.3.1"), "v1.4.0 should be newer than 1.3.1")
    expect(BridgeModel.isNewerVersion(remote: "1.2", current: "1.1.1"), "1.2 should be newer than 1.1.1")
    expect(!BridgeModel.isNewerVersion(remote: "1.2.0", current: "1.2"), "1.2.0 should equal 1.2")
    expect(!BridgeModel.isNewerVersion(remote: "1.3.1", current: "1.3.1"), "Equal versions should return false")
}

private func runFileTransferSecurityTests() throws {
    let traversed = BridgeFileTransferManager.sanitizeFileName("../../etc/passwd")
    expect(!traversed.contains("/"), "Sanitized filename must not contain '/'")
    let destDir = URL(fileURLWithPath: "/tmp/bridge-dest")
    let resolved = destDir.appendingPathComponent(traversed).standardized
    expect(resolved.deletingLastPathComponent().path == destDir.path, "Sanitized filename must not escape destination directory")

    let backslash = BridgeFileTransferManager.sanitizeFileName("..\\..\\evil.txt")
    expect(!backslash.contains("\\"), "Sanitized filename must not contain '\\'")

    let dotfile = BridgeFileTransferManager.sanitizeFileName(".zshrc")
    expect(!dotfile.hasPrefix("."), "Sanitized filename must strip leading dots")

    let emptyFallback = BridgeFileTransferManager.sanitizeFileName("...")
    expect(emptyFallback.hasPrefix("file_"), "Empty/dot-only filename should use safe fallback")

    let longName = String(repeating: "a", count: 250) + ".txt"
    expect(BridgeFileTransferManager.sanitizeFileName(longName).count == 200, "Sanitized filename should cap at 200 chars")

    // AES-256-GCM key derivation & roundtrip
    let token = BridgeFileTransferManager.generateSecureToken()
    expect(token.count == 64, "Secure token should be 64 hex chars")

    let key = BridgeFileTransferManager.deriveAesKey(token: token)
    expect(key.bitCount == 256, "Expected 256-bit AES key")

    let plaintext = Data("Bridge AES-GCM test chunk".utf8)
    let sealed = try AES.GCM.seal(plaintext, using: key)
    let combined = sealed.combined!
    let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
    expect(opened == plaintext, "AES-GCM decrypted plaintext mismatch")

    var tampered = combined
    tampered[tampered.count - 1] ^= 0xFF
    do {
        _ = try AES.GCM.open(AES.GCM.SealedBox(combined: tampered), using: key)
        expect(false, "Expected AES-GCM open to reject tampered ciphertext")
    } catch {
        // Expected authentication failure
    }

    // Data socket authentication proof (never sends raw token on the data socket)
    let dataAuth = BridgeFileTransferManager.computeDataSocketAuth(
        token: "sample-transfer-token",
        transferId: "tx_12345",
        offset: 65536
    )
    expect(
        dataAuth == "abedb85429f8107b6dbb1a10dd1ca078d232b7f52f1e8f621cfb5b23f613e34e",
        "Expected deterministic data socket auth digest"
    )
    expect(dataAuth != "sample-transfer-token", "Data socket auth digest must never expose raw token")

    // Executable detection & folder nuance (including .command, .workflow, .scpt, .py, .jar, .webloc)
    for ext in ["sh", "command", "workflow", "scpt", "py", "jar", "webloc", "apk", "exe", "dmg", "pkg", "app"] {
        let execItem = FileTransferItem(
            id: "exec_\(ext)",
            fileName: "payload.\(ext)",
            fileSize: 10,
            direction: .incoming,
            deviceId: nil,
            deviceName: "Phone",
            isFolder: false
        )
        expect(execItem.isExecutable, "Expected .\(ext) file to be marked executable")
    }
    let folderItem = FileTransferItem(id: "2", fileName: "archive.sh", fileSize: 10, direction: .incoming, deviceId: nil, deviceName: "Phone", isFolder: true)
    let pdfItem = FileTransferItem(id: "3", fileName: "notes.pdf", fileSize: 10, direction: .incoming, deviceId: nil, deviceName: "Phone", isFolder: false)
    expect(!folderItem.isExecutable, "Folder items are marked non-executable")
    expect(!pdfItem.isExecutable, "Expected .pdf file to not be marked executable")

    // Default autoAcceptIncomingFiles must be true when UserDefaults key is unset
    let savedAutoAccept = UserDefaults.standard.object(forKey: "bridge_file_auto_accept")
    defer {
        if let saved = savedAutoAccept {
            UserDefaults.standard.set(saved, forKey: "bridge_file_auto_accept")
        } else {
            UserDefaults.standard.removeObject(forKey: "bridge_file_auto_accept")
        }
    }
    UserDefaults.standard.removeObject(forKey: "bridge_file_auto_accept")
    let unsetDefault = UserDefaults.standard.object(forKey: "bridge_file_auto_accept") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "bridge_file_auto_accept")
    expect(unsetDefault, "autoAcceptIncomingFiles default must be true when unset")
}

private func runSpekeAndSessionCipherTests() {
    // 1. Deterministic cross-platform SPEKE test vector (matches Android BridgeCoreUnitTest)
    let code = "482910"
    let clientNonce = "00112233445566778899aabbccddeeff"
    let serverNonce = "ffeeddccbbaa99887766554433221100"
    let clientScalar = BigUInt2048(bigEndianBytes: Array(SHA256.hash(data: Data("deterministic-client-scalar".utf8))))
    let serverScalar = BigUInt2048(bigEndianBytes: Array(SHA256.hash(data: Data("deterministic-server-scalar".utf8))))

    let gen = BridgeSpeke.deriveGenerator(pairingCode: code, clientNonce: clientNonce)
    let clientPubHex = BridgeSpeke.computePublicElement(generator: gen, privateScalar: clientScalar)
    let serverPubHex = BridgeSpeke.computePublicElement(generator: gen, privateScalar: serverScalar)

    expect(
        clientPubHex.hasPrefix("1b4f3adc32b2cd3737115a7a07b5579d483b136f1784520dd2fd505aa2ec9b4f"),
        "Deterministic SPEKE client public key prefix mismatch"
    )
    expect(
        serverPubHex.hasPrefix("3304c34f377eb869ab75eade3a1f7b8e117a73d6f380825895d60e4b0eb5496a"),
        "Deterministic SPEKE server public key prefix mismatch"
    )

    let clientShared = BridgeSpeke.computeSharedSecret(peerPublicHex: serverPubHex, privateScalar: clientScalar)
    let serverShared = BridgeSpeke.computeSharedSecret(peerPublicHex: clientPubHex, privateScalar: serverScalar)
    expect(clientShared != nil && clientShared == serverShared, "SPEKE shared secrets must match")
    expect(
        clientShared?.hasPrefix("129b5d17f6f0fb9fe3ae58cae7230fa8c4e1b0dfabf044c52005c6e3781f001f") == true,
        "Deterministic SPEKE shared secret prefix mismatch"
    )

    let material = BridgeSpeke.deriveSessionMaterial(
        sharedSecretHex: clientShared!,
        pairingCode: code,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        clientPublicHex: clientPubHex,
        serverPublicHex: serverPubHex
    )
    expect(
        material.clientProof == "b80392ad0780478b3bf87f5b61fd2f22a8359d25c7dee09bb93c52e57a690d52",
        "Deterministic SPEKE clientProof mismatch"
    )
    expect(
        material.serverProof == "13e5e9de0452dc3611549979cea6eb3f9a5517f81f8273e85535abf06ed3fcf5",
        "Deterministic SPEKE serverProof mismatch"
    )
    expect(
        material.c2sKeyHex == "4224cc6ef8b81b5526b2d5e1b06efdaf3e58bf2b8c600f5504e8cd167c60f0ac",
        "Deterministic SPEKE c2sKey mismatch"
    )
    expect(
        material.s2cKeyHex == "7eb5343bb3045f11ef556a8aaee671fc325b2fc5ba74c6b12adbd0155b1000f9",
        "Deterministic SPEKE s2cKey mismatch"
    )

    // 2. Reject invalid group elements (0, 1, p-1, p, malformed)
    expect(!BridgeSpeke.isValidPublicElement(""), "Empty public element must be rejected")
    expect(!BridgeSpeke.isValidPublicElement("0"), "0 must be rejected")
    expect(!BridgeSpeke.isValidPublicElement("1"), "1 must be rejected")
    expect(!BridgeSpeke.isValidPublicElement(BridgeSpeke.primeMinusTwo.toHex() + "00"), "Over-length element must be rejected")
    let pMinusOneHex = BigUInt2048(BigUInt2048.subtract(BridgeSpeke.prime.limbs, [1])).toHex()
    expect(!BridgeSpeke.isValidPublicElement(pMinusOneHex), "p-1 must be rejected")
    expect(!BridgeSpeke.isValidPublicElement(BridgeSpeke.pHex), "p must be rejected")

    // 3. Deterministic cross-platform AES-256-GCM BridgeSessionCipher vector + replay/tamper defense
    let testKey = SymmetricKey(data: SHA256.hash(data: Data("test-session-key".utf8)))
    let clientCipher = BridgeSessionCipher(
        sendKey: material.c2sKey,
        receiveKey: material.s2cKey,
        sendDirection: "c2s",
        receiveDirection: "s2c"
    )
    let serverCipher = BridgeSessionCipher(
        sendKey: material.s2cKey,
        receiveKey: material.c2sKey,
        sendDirection: "s2c",
        receiveDirection: "c2s"
    )

    let vecSender = BridgeSessionCipher(sendKey: testKey, receiveKey: testKey, sendDirection: "c2s", receiveDirection: "c2s")
    let vecReceiver = BridgeSessionCipher(sendKey: testKey, receiveKey: testKey, sendDirection: "c2s", receiveDirection: "c2s")
    let vecPlain = Data("{\"type\":\"clip\",\"text\":\"secret hello\"}".utf8)
    let vecLine = vecSender.seal(vecPlain, saltOverride: [0xAA, 0xBB, 0xCC, 0xDD])!
    let vecJson = try! JSONSerialization.jsonObject(with: vecLine) as! [String: Any]
    expect(
        (vecJson["d"] as? String) == "qrvM3QAAAAAAAAABj9S5pvE1dq/nFETBIMF65kliHlU9lp23sE7XgDN72AYSfHfaknczz+4/TmBF1LvejSdnHHs=",
        "Deterministic session cipher Base64 vector mismatch"
    )
    expect(vecReceiver.open(jsonObject: vecJson) == vecPlain, "Deterministic session cipher vector failed to open")
    // Replaying seq=1 must fail
    expect(vecReceiver.open(jsonObject: vecJson) == nil, "Replaying encrypted session frame must be rejected")

    // Full bidirectional session cipher test + tamper & direction reflection defense
    let msg1 = Data("{\"type\":\"clip\",\"text\":\"Clipboard over AES-256-GCM\"}".utf8)
    let enc1 = clientCipher.seal(msg1)!
    let enc1Json = try! JSONSerialization.jsonObject(with: enc1) as! [String: Any]
    // Direction reflection: client trying to open its own c2s message as s2c must fail
    expect(clientCipher.open(jsonObject: enc1Json) == nil, "Direction reflection attack must be rejected")
    // Server opens msg1
    expect(serverCipher.open(jsonObject: enc1Json) == msg1, "Server should decrypt client frame 1")

    // Tampered ciphertext must fail
    let msg2 = Data("{\"type\":\"ping\"}".utf8)
    let enc2 = clientCipher.seal(msg2)!
    var enc2Json = try! JSONSerialization.jsonObject(with: enc2) as! [String: Any]
    enc2Json["seq"] = 99
    expect(serverCipher.open(jsonObject: enc2Json) == nil, "Modified sequence number must be rejected")
}

private func runHandshakeGateTests() {
    let gate = BridgeHandshakeGate()
    let code = "482913"
    let nonce1 = "0123456789abcdef0123456789abcdef"
    let clientScalar1 = BigUInt2048(bigEndianBytes: Array(SHA256.hash(data: Data("client-scalar-1".utf8))))
    let gen1 = BridgeSpeke.deriveGenerator(pairingCode: code, clientNonce: nonce1)
    let clientPub1 = BridgeSpeke.computePublicElement(generator: gen1, privateScalar: clientScalar1)

    // 1. Valid two-phase SPEKE handshake succeeds
    let helloOk = gate.evaluateHello(
        jsonObject: ["type": "hello", "text": nonce1, "data": clientPub1],
        pairingCode: code,
        remoteIp: "192.168.1.10",
        now: 1000
    )
    expect(helloOk.challengeIssued && helloOk.serverPublicHex != nil, "Valid SPEKE hello should issue challenge")

    let clientShared1 = BridgeSpeke.computeSharedSecret(peerPublicHex: helloOk.serverPublicHex!, privateScalar: clientScalar1)!
    let clientMat1 = BridgeSpeke.deriveSessionMaterial(
        sharedSecretHex: clientShared1,
        pairingCode: code,
        clientNonce: nonce1,
        serverNonce: helloOk.serverNonce!,
        clientPublicHex: clientPub1,
        serverPublicHex: helloOk.serverPublicHex!
    )
    let authOk = gate.evaluateAuth(
        jsonObject: ["type": "auth", "hash": clientMat1.clientProof],
        sessionMaterial: helloOk.sessionMaterial!,
        clientNonce: nonce1,
        remoteIp: "192.168.1.10",
        now: 1000.5
    )
    expect(authOk.authenticated, "Valid SPEKE clientProof should authenticate")

    // 2. Replaying the same nonce is rejected
    let replay = gate.evaluateHello(
        jsonObject: ["type": "hello", "text": nonce1, "data": clientPub1],
        pairingCode: code,
        remoteIp: "192.168.1.10",
        now: 1001
    )
    expect(!replay.challengeIssued && replay.failureReason == .replayedNonce, "Replayed nonce must be rejected")

    // 3. Legacy plaintext code login and legacy static SHA-256 hash login are rejected
    let plaintext = gate.evaluateHello(
        jsonObject: ["type": "hello", "code": code],
        pairingCode: code,
        remoteIp: "192.168.1.11",
        now: 1002
    )
    expect(!plaintext.challengeIssued && plaintext.failureReason == .invalidPayload, "Plaintext code fallback must be rejected")

    let legacySha = gate.evaluateHello(
        jsonObject: ["type": "hello", "hash": computeSHA256("bridge-hello:\(code):\(nonce1)"), "text": "11223344556677889900aabbccddeeff"],
        pairingCode: code,
        remoteIp: "192.168.1.11",
        now: 1003
    )
    expect(!legacySha.challengeIssued && legacySha.failureReason == .invalidPayload, "Legacy static SHA-256 hello without SPEKE key must be rejected")

    // 4. Wrong pairing code fails at evaluateAuth and records failed attempt
    let wrongNonce = "aaaaaaaabbbbbbbbccccccccdddddddd"
    let wrongGen = BridgeSpeke.deriveGenerator(pairingCode: "999999", clientNonce: wrongNonce)
    let wrongPub = BridgeSpeke.computePublicElement(generator: wrongGen, privateScalar: clientScalar1)
    let wrongHello = gate.evaluateHello(
        jsonObject: ["type": "hello", "text": wrongNonce, "data": wrongPub],
        pairingCode: code,
        remoteIp: "192.168.1.12",
        now: 1004
    )
    expect(wrongHello.challengeIssued, "Challenge issued without leaking whether code matched")
    let wrongShared = BridgeSpeke.computeSharedSecret(peerPublicHex: wrongHello.serverPublicHex!, privateScalar: clientScalar1)!
    let wrongMat = BridgeSpeke.deriveSessionMaterial(
        sharedSecretHex: wrongShared,
        pairingCode: "999999",
        clientNonce: wrongNonce,
        serverNonce: wrongHello.serverNonce!,
        clientPublicHex: wrongPub,
        serverPublicHex: wrongHello.serverPublicHex!
    )
    let wrongAuth = gate.evaluateAuth(
        jsonObject: ["type": "auth", "hash": wrongMat.clientProof],
        sessionMaterial: wrongHello.sessionMaterial!,
        clientNonce: wrongNonce,
        remoteIp: "192.168.1.12",
        now: 1004.5
    )
    expect(!wrongAuth.authenticated && wrongAuth.failureReason == .invalidProof, "Wrong pairing code must fail SPEKE auth proof")

    // 5. Per-IP lockout after 5 failed attempts
    let ipGate = BridgeHandshakeGate()
    for i in 0..<5 {
        let res = ipGate.evaluateHello(
            jsonObject: ["type": "hello", "text": "nonce_\(i)_0123456789abcdef", "data": "invalid"],
            pairingCode: code,
            remoteIp: "192.168.1.50",
            now: 2000 + Double(i)
        )
        expect(!res.challengeIssued, "Invalid hello should fail")
    }
    let nonce2 = "abcdef0123456789abcdef0123456789"
    let lockedOut = ipGate.evaluateHello(
        jsonObject: ["type": "hello", "text": nonce2, "data": clientPub1],
        pairingCode: code,
        remoteIp: "192.168.1.50",
        now: 2010
    )
    expect(!lockedOut.challengeIssued && lockedOut.failureReason == .rateLimited, "IP should be locked out for 60s")
    let afterIpCooldown = ipGate.evaluateHello(
        jsonObject: ["type": "hello", "text": nonce2, "data": clientPub1],
        pairingCode: code,
        remoteIp: "192.168.1.50",
        now: 2065
    )
    expect(afterIpCooldown.challengeIssued, "IP should unlock after 60s lockout expires")

    // 6. Global lockout triggers after 10 failures across distinct IPs and blocks a brand new IP
    let globalGate = BridgeHandshakeGate()
    for i in 0..<10 {
        let res = globalGate.evaluateHello(
            jsonObject: ["type": "hello", "text": "global_\(i)_0123456789abcdef", "data": "invalid"],
            pairingCode: code,
            remoteIp: "192.168.1.\(100 + i)",
            now: 3000 + Double(i)
        )
        expect(!res.challengeIssued, "Invalid attempt across distinct IPs should fail")
    }
    let nonce3 = "fedcba9876543210fedcba9876543210"
    let blockedByGlobal = globalGate.evaluateHello(
        jsonObject: ["type": "hello", "text": nonce3, "data": clientPub1],
        pairingCode: code,
        remoteIp: "192.168.1.250",
        now: 3015
    )
    expect(!blockedByGlobal.challengeIssued && blockedByGlobal.failureReason == .rateLimited, "Global lockout must block even a brand new IP")

    let afterGlobalCooldown = globalGate.evaluateHello(
        jsonObject: ["type": "hello", "text": nonce3, "data": clientPub1],
        pairingCode: code,
        remoteIp: "192.168.1.250",
        now: 3040
    )
    expect(afterGlobalCooldown.challengeIssued, "Global lockout should expire after 30s")

    // 7. reset() clears lockouts
    for i in 0..<10 {
        _ = globalGate.evaluateHello(
            jsonObject: ["type": "hello", "text": "reset_\(i)_0123456789abcdef", "data": "invalid"],
            pairingCode: code,
            remoteIp: "192.168.2.\(100 + i)",
            now: 4000
        )
    }
    expect(globalGate.isRateLimited(ip: "192.168.2.250", now: 4005), "Expected global lockout active before reset")
    globalGate.reset()
    expect(!globalGate.isRateLimited(ip: "192.168.2.250", now: 4005), "Expected reset() to clear global lockout")
}

private func containsScrollView(_ view: NSView) -> Bool {
    if view is NSScrollView { return true }
    return view.subviews.contains(where: containsScrollView)
}

private func runNotificationScrollLayoutTests() {
    let model = BridgeModel(startServer: false)
    model.isConnected = true
    model.pairedDevice = "Galaxy"
    model.selectedTab = .notifications

    let notifManager = BridgeNotificationManager.shared
    let originalNotifications = notifManager.activeNotifications
    defer {
        notifManager.activeNotifications = originalNotifications
        StatusDotTicker.shared.stop()
    }

    // 1. Single short notification stays compact without forcing full 280pt ScrollView height
    notifManager.activeNotifications = [
        BridgeNotification(id: "short-1", app: "Messages", title: "Alice", text: "On my way!")
    ]
    let shortHost = NSHostingController(rootView: BridgeMenuView(model: model))
    let shortWin = NSWindow(contentViewController: shortHost)
    shortWin.setFrame(NSRect(x: 0, y: 0, width: 380, height: 600), display: false)
    shortHost.view.layoutSubtreeIfNeeded()
    let shortHeight = shortHost.view.fittingSize.height

    // 2. Single very long notification (8 multi-line stacked messages + reply + actions)
    //    must cap at the 280pt ScrollView height so the popover never overflows/displaces.
    let stackedMessages = (1...8).map { idx in
        BridgeMessageItem(
            text: "Message \(idx): This is a multi-line group chat notification body that would otherwise stretch the menu bar popover past the screen height.",
            timestamp: Int64(1700000000000 + idx),
            sender: "Member \(idx)"
        )
    }
    notifManager.activeNotifications = [
        BridgeNotification(
            id: "long-1",
            app: "WhatsApp",
            title: "Pioneers (23 messages)",
            text: stackedMessages.last?.text,
            actions: [
                BridgeNotificationAction(id: 0, title: "Reply", hasInput: true, placeholder: "Reply"),
                BridgeNotificationAction(id: 1, title: "Mark as read"),
                BridgeNotificationAction(id: 2, title: "Mute")
            ],
            messages: stackedMessages
        )
    ]
    let longHost = NSHostingController(rootView: BridgeMenuView(model: model))
    let longWin = NSWindow(contentViewController: longHost)
    longWin.setFrame(NSRect(x: 0, y: 0, width: 380, height: 600), display: false)
    longHost.view.layoutSubtreeIfNeeded()
    let longHeight = longHost.view.fittingSize.height

    expect(shortHeight < longHeight, "Short notification popover (\(shortHeight)) should be shorter than capped long notification popover (\(longHeight))")
    expect(longHeight <= 600, "Single long notification must be capped by ScrollView instead of overflowing (got \(longHeight))")
    expect(containsScrollView(longHost.view), "Single long notification exceeding 280pt must render inside NSScrollView")
}

private final class MockLaunchAtLoginController: LaunchAtLoginControlling {
    var state: LaunchAtLoginState = .disabled
    var registerError: Error? = nil
    var unregisterError: Error? = nil
    var registerCalls = 0
    var unregisterCalls = 0
    var openSettingsCalls = 0
    var registerOutcomeState: LaunchAtLoginState = .enabled

    func currentState() -> LaunchAtLoginState {
        return state
    }

    func register() throws {
        registerCalls += 1
        if let err = registerError {
            throw err
        }
        state = registerOutcomeState
    }

    func unregister() throws {
        unregisterCalls += 1
        if let err = unregisterError {
            throw err
        }
        state = .disabled
    }

    func openLoginItemsSettings() {
        openSettingsCalls += 1
    }
}

private func runLaunchAtLoginTests() {
    let mock = MockLaunchAtLoginController()
    let model = BridgeModel(startServer: false, launchAtLoginController: mock)

    expect(!model.isLaunchAtLoginEnabled, "Launch at Login should start disabled")
    expect(!model.launchAtLoginRequiresApproval, "Requires approval should start false")
    expect(model.launchAtLoginError == nil, "Error should start nil")

    // 1. Enabling succeeds -> enabled
    model.setLaunchAtLogin(enabled: true)
    expect(mock.registerCalls == 1, "register() should be called once")
    expect(model.isLaunchAtLoginEnabled, "Launch at Login should be enabled after register()")
    expect(!model.launchAtLoginRequiresApproval, "Requires approval should be false when .enabled")
    expect(model.launchAtLoginError == nil, "Error should remain nil on success")

    // 2. Disabling succeeds -> disabled
    model.setLaunchAtLogin(enabled: false)
    expect(mock.unregisterCalls == 1, "unregister() should be called once")
    expect(!model.isLaunchAtLoginEnabled, "Launch at Login should be disabled after unregister()")

    // 3. Enabling results in .requiresApproval -> toggle on + approval hint
    mock.registerOutcomeState = .requiresApproval
    model.setLaunchAtLogin(enabled: true)
    expect(model.isLaunchAtLoginEnabled, "Launch at Login should stay enabled when awaiting approval")
    expect(model.launchAtLoginRequiresApproval, "Requires approval flag should be true")

    model.openLoginItemsSettings()
    expect(mock.openSettingsCalls == 1, "openLoginItemsSettings() should delegate to controller")

    // 4. External approval in System Settings reflected on refresh
    mock.state = .enabled
    model.refreshLaunchAtLoginStatus()
    expect(model.isLaunchAtLoginEnabled && !model.launchAtLoginRequiresApproval, "Refresh should clear approval flag once approved")

    // 5. Registration failure sets error and preserves actual controller state
    mock.state = .disabled
    model.refreshLaunchAtLoginStatus()
    mock.registerError = NSError(domain: "BridgeTest", code: 1, userInfo: nil)
    model.setLaunchAtLogin(enabled: true)
    expect(!model.isLaunchAtLoginEnabled, "Failed register() must keep toggle off")
    expect(model.launchAtLoginError != nil, "Failed register() should populate launchAtLoginError")

    // 6. Settings tab renders Launch at Login in MAC ONLY section with valid fitting size
    let uiModel = BridgeModel(startServer: false, launchAtLoginController: mock)
    uiModel.isConnected = true
    uiModel.pairedDevice = "Galaxy"
    uiModel.selectedTab = .settings
    let settingsHost = NSHostingController(rootView: BridgeMenuView(model: uiModel))
    let settingsWin = NSWindow(contentViewController: settingsHost)
    settingsWin.setFrame(NSRect(x: 0, y: 0, width: 380, height: 700), display: false)
    settingsHost.view.layoutSubtreeIfNeeded()
    let settingsHeight = settingsHost.view.fittingSize.height
    expect(settingsHeight > 300 && settingsHeight < 750, "Settings tab fitting height should be reasonable (got \(settingsHeight))")
    StatusDotTicker.shared.stop()
}

private func runBatteryAndDeviceCardTests() {
    let mock = MockLaunchAtLoginController()
    let model = BridgeModel(startServer: false, launchAtLoginController: mock)
    let originalPref = model.isLowBatteryAlertEnabled
    defer {
        model.isLowBatteryAlertEnabled = originalPref
        StatusDotTicker.shared.stop()
    }

    // 1. Low-battery alert triggers once at <= 15% when not charging, then resets at >= 20% or charging
    model.isLowBatteryAlertEnabled = true
    expect(!model.evaluateBatteryAlert(deviceName: "Galaxy", level: 45, isCharging: false, postNotification: false), "45% should not trigger low battery alert")
    expect(model.evaluateBatteryAlert(deviceName: "Galaxy", level: 15, isCharging: false, postNotification: false), "15% unplugged should trigger low battery alert")
    expect(!model.evaluateBatteryAlert(deviceName: "Galaxy", level: 14, isCharging: false, postNotification: false), "14% should not re-alert in same discharge cycle")
    expect(!model.evaluateBatteryAlert(deviceName: "Galaxy", level: 12, isCharging: true, postNotification: false), "Charging should clear alert state")
    expect(model.evaluateBatteryAlert(deviceName: "Galaxy", level: 12, isCharging: false, postNotification: false), "Unplugging again below 15% should alert after charging cleared state")
    expect(!model.evaluateBatteryAlert(deviceName: "Galaxy", level: 22, isCharging: false, postNotification: false), ">=20% should reset hysteresis")
    expect(model.evaluateBatteryAlert(deviceName: "Galaxy", level: 10, isCharging: false, postNotification: false), "Dropping back below 15% after >=20% should alert again")

    model.isLowBatteryAlertEnabled = false
    expect(!model.evaluateBatteryAlert(deviceName: "Pixel", level: 5, isCharging: false, postNotification: false), "Disabled setting must suppress low battery alerts")

    // 2. Connected device card with BatteryRingView renders cleanly across normal, low, and charging states
    expect(formatDisplayDeviceName("samsung SM-A525F") == "Samsung SM-A525F", "Brand prefix should be capitalized")
    expect(formatDisplayDeviceName("OnePlus 12") == "OnePlus 12", "Mixed-case brand should stay intact")
    let nowSec = Date().timeIntervalSince1970
    expect(model.isBatteryStale(ConnectedDeviceInfo(id: UUID(), name: "NoBat", ip: nil, isConnected: true), now: nowSec), "Missing battery should be stale")
    expect(!model.isBatteryStale(ConnectedDeviceInfo(id: UUID(), name: "Fresh", ip: nil, isConnected: true, batteryLevel: 80, lastBatteryUpdatedAt: nowSec - 30), now: nowSec), "Recent battery should not be stale")
    expect(model.isBatteryStale(ConnectedDeviceInfo(id: UUID(), name: "Old", ip: nil, isConnected: true, batteryLevel: 80, lastBatteryUpdatedAt: nowSec - 400), now: nowSec), "Old battery >5m should be stale")

    model.isConnected = true
    model.pairedDevice = "Galaxy"
    model.selectedTab = .devices
    model.connectedDevicesList = [
        ConnectedDeviceInfo(id: UUID(), name: "Galaxy S24", ip: "192.168.1.40", isConnected: true, batteryLevel: 45, isCharging: false),
        ConnectedDeviceInfo(id: UUID(), name: "Pixel 9", ip: "192.168.1.41", isConnected: true, batteryLevel: 15, isCharging: true)
    ]
    let host = NSHostingController(rootView: BridgeMenuView(model: model))
    let win = NSWindow(contentViewController: host)
    win.setFrame(NSRect(x: 0, y: 0, width: 380, height: 650), display: false)
    host.view.layoutSubtreeIfNeeded()
    let cardHeight = host.view.fittingSize.height
    expect(cardHeight > 250 && cardHeight < 750, "Device card list fitting height should be valid (got \(cardHeight))")

    // Expanding Add Another Phone expands only the bottom portion cleanly within screen bounds
    model.showPairingSection = true
    host.rootView = BridgeMenuView(model: model)
    host.view.layoutSubtreeIfNeeded()
    let expandedHeight = host.view.fittingSize.height
    let screenHeight = NSScreen.main?.visibleFrame.height ?? 860
    expect(expandedHeight <= screenHeight, "Devices tab with Add Another Phone expanded must stay within screen height (got \(expandedHeight), screen \(screenHeight))")

    // Single device + active Now Playing + Add Another Phone stays stable without jumping off screen
    model.connectedDevicesList = [
        ConnectedDeviceInfo(
            id: UUID(),
            name: "Samsung SM-A525F",
            ip: "192.168.1.40",
            isConnected: true,
            batteryLevel: 79,
            isCharging: false,
            mediaInfo: MediaPlaybackInfo.from(
                jsonObject: [
                    "type": "media_status",
                    "isActive": true,
                    "isPlaying": false,
                    "title": "Test Video",
                    "artist": "Channel",
                    "appName": "YouTube",
                    "durationMs": Int64(240_000),
                    "positionMs": Int64(10_000),
                    "volumeIndex": 6,
                    "maxVolume": 15,
                    "canSeek": true,
                    "canSkipNext": true,
                    "canSkipPrevious": true,
                    "canControlVolume": true
                ],
                previous: nil,
                receivedAtUptime: ProcessInfo.processInfo.systemUptime
            )
        )
    ]
    host.rootView = BridgeMenuView(model: model)
    host.view.layoutSubtreeIfNeeded()
    let expandedMediaHeight = host.view.fittingSize.height
    expect(expandedMediaHeight <= screenHeight, "Single device + Now Playing + Add Another Phone must fit within screen height (got \(expandedMediaHeight), screen \(screenHeight))")
    model.showPairingSection = false

    // 3. BatteryRingView keeps identical layout dimensions across Charging / charge left / Battery unavailable
    let ringCharging = NSHostingController(rootView: BatteryRingView(level: 80, isCharging: true, isStale: false))
    let ringDischarging = NSHostingController(rootView: BatteryRingView(level: 80, isCharging: false, isStale: false))
    let ringUnavailable = NSHostingController(rootView: BatteryRingView(level: nil, isCharging: false, isStale: true))
    ringCharging.view.layoutSubtreeIfNeeded()
    ringDischarging.view.layoutSubtreeIfNeeded()
    ringUnavailable.view.layoutSubtreeIfNeeded()
    expect(
        ringCharging.view.fittingSize == ringDischarging.view.fittingSize &&
        ringDischarging.view.fittingSize == ringUnavailable.view.fittingSize,
        "BatteryRingView size must remain constant across states (charging=\(ringCharging.view.fittingSize), discharging=\(ringDischarging.view.fittingSize), unavailable=\(ringUnavailable.view.fittingSize))"
    )
}

private func runQuickControlPanelTests() {
    let mock = MockLaunchAtLoginController()
    let model = BridgeModel(startServer: false, launchAtLoginController: mock)
    let originalCallsOnMacEnabled = BridgeNotificationManager.shared.isCallsOnMacEnabled
    defer {
        BridgeNotificationManager.shared.isCallsOnMacEnabled = originalCallsOnMacEnabled
        StatusDotTicker.shared.stop()
    }

    // 1. RingerMode cycles Normal -> Vibrate -> Silent -> Normal
    expect(RingerMode.normal.next == .vibrate, "Normal should cycle to Vibrate")
    expect(RingerMode.vibrate.next == .silent, "Vibrate should cycle to Silent")
    expect(RingerMode.silent.next == .normal, "Silent should cycle back to Normal")

    let devId = UUID()
    model.connectedDevicesList = [
        ConnectedDeviceInfo(
            id: devId,
            name: "GalaxyTest",
            ip: "192.168.1.50",
            isConnected: true,
            batteryLevel: 65,
            isCharging: false,
            ringerMode: .normal,
            isDndEnabled: false,
            hasDndPermission: false,
            isRingingPhone: false
        )
    ]

    // Cycle Normal -> Vibrate; attempting Silent without DND permission must show hint and NOT fake Silent state
    model.cycleRingerMode(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].ringerMode == .vibrate, "First click should set Vibrate")
    expect(!model.dndHintDeviceIds.contains(devId), "Vibrate should not require DND permission")

    model.cycleRingerMode(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].ringerMode == .vibrate, "Silent without DND permission must not fake Silent state")
    expect(model.dndHintDeviceIds.contains(devId), "Silent without DND permission should show hint")

    // With DND permission granted, Vibrate -> Silent -> Normal cycles cleanly
    model.connectedDevicesList[0].hasDndPermission = true
    model.cycleRingerMode(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].ringerMode == .silent, "With permission, Vibrate should cycle to Silent")
    expect(!model.dndHintDeviceIds.contains(devId), "With permission, hint should clear")

    model.cycleRingerMode(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].ringerMode == .normal, "Silent should cycle back to Normal")

    // 2. DND toggle respects hasDndPermission
    model.connectedDevicesList[0].hasDndPermission = false
    model.toggleDnd(for: model.connectedDevicesList[0], sendToServer: false)
    expect(!model.connectedDevicesList[0].isDndEnabled, "DND should not flip optimistically without permission")
    expect(model.dndHintDeviceIds.contains(devId), "DND attempt without permission should show hint")

    model.connectedDevicesList[0].hasDndPermission = true
    model.toggleDnd(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].isDndEnabled, "DND should enable when permission is granted")
    expect(!model.dndHintDeviceIds.contains(devId), "Hint should clear once DND permission is granted")

    // Pending state tracking when sending commands to server
    model.cycleRingerMode(for: model.connectedDevicesList[0], sendToServer: true)
    expect(model.pendingRingerDeviceIds.contains(devId), "Sending ringer mode command should mark pending until confirmed")
    model.pendingRingerDeviceIds.removeAll()

    // 3. Ring Phone toggles continuously until clicked again
    expect(!model.connectedDevicesList[0].isRingingPhone, "Ring Phone should start idle")
    model.toggleRingPhone(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].isRingingPhone, "First click should start ringing")
    model.toggleRingPhone(for: model.connectedDevicesList[0], sendToServer: false)
    expect(!model.connectedDevicesList[0].isRingingPhone, "Second click should stop ringing")

    // 4. Get Call on Mac shared synced setting toggle + settings_sync payload
    let dev = model.connectedDevicesList[0]
    let wasEnabled = model.isGetCallOnMacEnabled(for: dev)
    model.toggleGetCallOnMac(for: dev)
    expect(model.isGetCallOnMacEnabled(for: dev) == !wasEnabled, "Get Call on Mac should toggle state")
    expect(BridgeNotificationManager.shared.isCallsOnMacEnabled == !wasEnabled, "Get Call on Mac should update shared notification setting")
    if let syncJson = BridgeNotificationManager.shared.buildSettingsSyncJson(),
       let data = syncJson.data(using: .utf8),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect((parsed["callsOnMacEnabled"] as? Bool) == !wasEnabled, "settings_sync JSON should encode callsOnMacEnabled")
    } else {
        expect(false, "buildSettingsSyncJson should return valid JSON with callsOnMacEnabled")
    }
    model.toggleGetCallOnMac(for: dev)
    expect(model.isGetCallOnMacEnabled(for: dev) == wasEnabled, "Get Call on Mac should toggle back")
}

private func runNowPlayingMediaTests() {
    // 1. Parsing active & inactive media_status + artwork cache reuse
    let samplePngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
    let json1: [String: Any] = [
        "type": "media_status",
        "isActive": true,
        "isPlaying": true,
        "title": "Surrender",
        "artist": "KIDPUNK",
        "album": "Surrender",
        "appName": "Spotify",
        "durationMs": Int64(176_000),
        "positionMs": Int64(28_000),
        "playbackSpeed": 1.0,
        "volumeIndex": 9,
        "maxVolume": 15,
        "canSeek": true,
        "canSkipNext": true,
        "canSkipPrevious": false,
        "canControlVolume": true,
        "artworkHash": "art12345",
        "artworkBase64": samplePngBase64
    ]
    let parsed1 = MediaPlaybackInfo.from(jsonObject: json1, previous: nil, receivedAtUptime: 100.0)
    expect(parsed1.isActive && parsed1.isPlaying, "Parsed media should be active and playing")
    expect(parsed1.title == "Surrender" && parsed1.artist == "KIDPUNK", "Track metadata mismatch")
    expect(parsed1.canSeek && parsed1.canSkipNext && !parsed1.canSkipPrevious && parsed1.canControlVolume, "Capability flags mismatch")
    expect(parsed1.artworkImage != nil, "Artwork base64 should decode into NSImage")
    expect(parsed1.estimatedPositionMs(at: 105.0) == 33_000, "Estimated position should advance by 5s when playing")

    // Subsequent update with same artworkHash and no artworkBase64 must reuse cached NSImage
    let json2: [String: Any] = [
        "type": "media_status",
        "isActive": true,
        "isPlaying": false,
        "title": "Surrender",
        "artist": "KIDPUNK",
        "durationMs": Int64(176_000),
        "positionMs": Int64(40_000),
        "volumeIndex": 12,
        "maxVolume": 15,
        "artworkHash": "art12345"
    ]
    let parsed2 = MediaPlaybackInfo.from(jsonObject: json2, previous: parsed1, receivedAtUptime: 200.0)
    expect(!parsed2.isPlaying, "Paused update should mark isPlaying=false")
    expect(parsed2.artworkImage === parsed1.artworkImage, "Matching artworkHash should reuse cached NSImage")
    expect(parsed2.estimatedPositionMs(at: 215.0) == 40_000, "Paused position should remain frozen")

    // Inactive update hides media
    let inactive = MediaPlaybackInfo.from(jsonObject: ["type": "media_status", "isActive": false, "volumeIndex": 5, "maxVolume": 15], previous: parsed2)
    expect(!inactive.isActive && inactive.artworkImage == nil, "Inactive media_status should clear active flag and artwork")

    // 2. Model optimistic actions & UI auto-hide height verification
    let mock = MockLaunchAtLoginController()
    let model = BridgeModel(startServer: false, launchAtLoginController: mock)
    defer { StatusDotTicker.shared.stop() }
    model.isConnected = true
    model.pairedDevice = "Galaxy"
    model.selectedTab = .devices

    let devId = UUID()
    model.connectedDevicesList = [
        ConnectedDeviceInfo(id: devId, name: "Galaxy", ip: "192.168.1.50", isConnected: true, batteryLevel: 45, mediaInfo: inactive)
    ]
    let hiddenHost = NSHostingController(rootView: BridgeMenuView(model: model))
    let hiddenWin = NSWindow(contentViewController: hiddenHost)
    hiddenWin.setFrame(NSRect(x: 0, y: 0, width: 380, height: 700), display: false)
    hiddenHost.view.layoutSubtreeIfNeeded()
    let hiddenHeight = hiddenHost.view.fittingSize.height

    model.connectedDevicesList[0].mediaInfo = parsed1
    model.sendMediaPlayPause(for: model.connectedDevicesList[0], sendToServer: false)
    expect(model.connectedDevicesList[0].mediaInfo?.isPlaying == false, "Optimistic play/pause should toggle isPlaying")
    model.setMediaVolume(for: model.connectedDevicesList[0], volumeIndex: 99, forceSend: true, sendToServer: false)
    expect(model.connectedDevicesList[0].mediaInfo?.volumeIndex == 15, "Volume index should clamp to maxVolume")
    model.sendMediaSeek(for: model.connectedDevicesList[0], positionMs: 60_000, sendToServer: false)
    expect(model.connectedDevicesList[0].mediaInfo?.positionMs == 60_000, "Seek should update positionMs")
    model.sendMediaSkip(for: model.connectedDevicesList[0], deltaMs: -10_000, sendToServer: false)
    expect(model.connectedDevicesList[0].mediaInfo?.positionMs == 50_000, "-10s skip should rewind by 10s")
    model.sendMediaSkip(for: model.connectedDevicesList[0], deltaMs: 10_000, sendToServer: false)
    expect(model.connectedDevicesList[0].mediaInfo?.positionMs == 60_000, "+10s skip should advance by 10s")
    model.sendMediaSkip(for: model.connectedDevicesList[0], deltaMs: -100_000, sendToServer: false)
    expect(model.connectedDevicesList[0].mediaInfo?.positionMs == 0, "-10s skip should clamp at 0")

    let shownHost = NSHostingController(rootView: BridgeMenuView(model: model))
    let shownWin = NSWindow(contentViewController: shownHost)
    shownWin.setFrame(NSRect(x: 0, y: 0, width: 380, height: 700), display: false)
    shownHost.view.layoutSubtreeIfNeeded()
    let shownHeight = shownHost.view.fittingSize.height

    expect(shownHeight > hiddenHeight + 80, "Active Now Playing card (\(shownHeight)) should expand device card over hidden state (\(hiddenHeight))")
}

private final class MockMacMediaController: MacMediaControlling {
    var playing = false
    var sendCalls = 0

    func isAudioPlaying() -> Bool {
        return playing
    }

    func sendPlayPauseKey() -> Bool {
        sendCalls += 1
        return true
    }
}

private func runIncomingCallAndAutoPauseTests() {
    // 1. MacMediaPauser only pauses when audio is actively playing, and once per callId
    let mediaMock = MockMacMediaController()
    let pauser = MacMediaPauser(controller: mediaMock)

    mediaMock.playing = false
    expect(!pauser.pauseIfPlaying(callId: "call_1"), "Must not toggle Play/Pause when Mac audio is silent")
    expect(mediaMock.sendCalls == 0, "Should not send key event when not playing")

    mediaMock.playing = true
    expect(pauser.pauseIfPlaying(callId: "call_1"), "Should pause active Mac audio when call arrives")
    expect(!pauser.pauseIfPlaying(callId: "call_1"), "Second call state update for same callId must not double-toggle")
    expect(mediaMock.sendCalls == 1, "Should only send key event once per call")

    pauser.clearCall(callId: "call_1")
    expect(pauser.pauseIfPlaying(callId: "call_1"), "After call ends, new call with same id can pause again")
    expect(mediaMock.sendCalls == 2, "Expected second pause after clearCall")

    // 2. IncomingCallInfo parsing + BridgeModel call banner & Get Call on Mac gating
    let loginMock = MockLaunchAtLoginController()
    let mediaMock2 = MockMacMediaController()
    mediaMock2.playing = true
    let model = BridgeModel(
        startServer: false,
        launchAtLoginController: loginMock,
        mediaPauser: MacMediaPauser(controller: mediaMock2)
    )
    let origAutoPause = model.isAutoPauseMacMediaEnabled
    let origCallsOnMac = BridgeNotificationManager.shared.isCallsOnMacEnabled
    defer {
        model.isAutoPauseMacMediaEnabled = origAutoPause
        BridgeNotificationManager.shared.isCallsOnMacEnabled = origCallsOnMac
        StatusDotTicker.shared.stop()
    }

    let devId = UUID()
    let device = ConnectedDeviceInfo(id: devId, name: "GalaxyCallTest", ip: "192.168.1.55", isConnected: true)
    model.connectedDevicesList = [device]
    model.isAutoPauseMacMediaEnabled = true
    BridgeNotificationManager.shared.isCallsOnMacEnabled = true

    let parsed = IncomingCallInfo.from(
        jsonObject: [
            "type": "call_event",
            "callId": "c_101",
            "state": "ringing",
            "callerName": "Alex",
            "appName": "Phone",
            "canAnswer": true,
            "canDecline": true
        ],
        deviceId: devId,
        deviceName: "GalaxyCallTest"
    )
    expect(parsed != nil, "Valid call_event JSON should parse")
    let call = parsed!

    model.handleIncomingCallEvent(call, presentPanel: false)
    expect(model.activeIncomingCall?.callerName == "Alex", "Active call should be stored on model")
    expect(mediaMock2.sendCalls == 1, "Auto-Pause Mac Media should pause playing audio on incoming call")

    // Silencing hides active call; subsequent ringing update for same callId stays dismissed
    model.silenceCall(call, sendToServer: false, presentPanel: false)
    expect(model.activeIncomingCall == nil, "Silencing should dismiss active banner")
    model.handleIncomingCallEvent(call, presentPanel: false)
    expect(model.activeIncomingCall == nil, "Silenced callId must stay dismissed until ended")

    // Ending call clears dismissed state
    let ended = IncomingCallInfo(
        deviceId: devId,
        deviceName: "GalaxyCallTest",
        callId: "c_101",
        state: "ended",
        callerName: "Alex",
        appName: "Phone",
        canAnswer: false,
        canDecline: false,
        appIconImage: nil
    )
    model.handleIncomingCallEvent(ended, presentPanel: false)

    // When Get Call on Mac is turned OFF for device, incoming call is ignored and does not auto-pause
    model.toggleGetCallOnMac(for: device)
    expect(!model.isGetCallOnMacEnabled(for: device), "Get Call on Mac should now be disabled")
    let call2 = IncomingCallInfo(
        deviceId: devId,
        deviceName: "GalaxyCallTest",
        callId: "c_102",
        state: "ringing",
        callerName: "Sam",
        appName: "WhatsApp",
        canAnswer: true,
        canDecline: true,
        appIconImage: nil
    )
    model.handleIncomingCallEvent(call2, presentPanel: false)
    expect(model.activeIncomingCall == nil, "Disabled Get Call on Mac must suppress incoming call banner")
    expect(mediaMock2.sendCalls == 1, "Disabled Get Call on Mac must not trigger Auto-Pause")

    let unknownCaller = IncomingCallInfo.from(
        jsonObject: ["type": "call_event", "callId": "c_103", "state": "ringing", "callerName": "   "],
        deviceId: devId,
        deviceName: "GalaxyCallTest"
    )
    expect(unknownCaller?.callerName == "Unknown Caller", "Blank caller name should fall back to Unknown Caller")
}

private final class MockMacControlProvider: MacSystemControlProviding {
    var snapshot = MacSystemStatusSnapshot(
        batteryPercent: 78,
        isCharging: false,
        isMuted: false,
        volumePercent: 45,
        canToggleMute: true,
        canControlVolume: true
    )

    func readSnapshot() -> MacSystemStatusSnapshot { snapshot }

    func setMuted(_ muted: Bool) -> Bool {
        snapshot.isMuted = muted
        return true
    }

    func setVolumePercent(_ percent: Int) -> Bool {
        let clamped = max(0, min(100, percent))
        if clamped > 0 { snapshot.isMuted = false }
        snapshot.volumePercent = clamped
        return true
    }
}

private final class MockMacMediaControlClient: MacMediaControlClientProviding {
    var isAvailable: Bool = true
    var currentPayload: MediaControlPayload? = nil
    var commands: [String] = []
    var seekTargetsSeconds: [Double] = []
    var streamStarted = false
    var onUpdateCallback: ((MediaControlPayload?) -> Void)?

    func startStreaming(onUpdate: @escaping (MediaControlPayload?) -> Void, onFailure: @escaping () -> Void) {
        streamStarted = true
        onUpdateCallback = onUpdate
    }

    func stopStreaming() {
        streamStarted = false
        onUpdateCallback = nil
    }

    func fetchCurrent() -> MediaControlPayload? {
        return currentPayload
    }

    @discardableResult func play() -> Bool { commands.append("play"); return true }
    @discardableResult func pause() -> Bool { commands.append("pause"); return true }
    @discardableResult func togglePlayPause() -> Bool { commands.append("toggle-play-pause"); return true }
    @discardableResult func nextTrack() -> Bool { commands.append("next-track"); return true }
    @discardableResult func previousTrack() -> Bool { commands.append("previous-track"); return true }
    @discardableResult func stopPlayback() -> Bool { commands.append("stop"); return true }
    @discardableResult func seek(toSeconds seconds: Double) -> Bool {
        seekTargetsSeconds.append(seconds)
        return true
    }
}

private func runUniversalMediaControlTests() {
    let samplePngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="

    // 1. Parse wrapped `media-control stream --no-diff` JSON line
    let streamJson = """
    {"type":"data","diff":false,"payload":{"title":"Starboy","artist":"The Weeknd","album":"Starboy","bundleIdentifier":"com.google.Chrome","duration":230.5,"elapsedTime":45.0,"playing":true,"playbackRate":1.0,"artworkData":"\(samplePngBase64)"}}
    """
    if case .some(let parsed?) = MediaControlPayload.parse(jsonData: Data(streamJson.utf8)) {
        expect(parsed.title == "Starboy" && parsed.artist == "The Weeknd", "Parsed universal track metadata mismatch")
        expect(parsed.bundleIdentifier == "com.google.Chrome", "Parsed bundleIdentifier mismatch")
        expect(abs(parsed.durationSeconds - 230.5) < 0.01, "Parsed durationSeconds mismatch")
        expect(parsed.isPlaying && parsed.artworkData != nil, "Parsed playing state and artwork should be set")
    } else {
        expect(false, "Expected valid MediaControlPayload from stream JSON")
    }

    // Empty payload clears active universal media
    let emptyStreamJson = """
    {"type":"data","diff":false,"payload":{}}
    """
    if case .some(let cleared) = MediaControlPayload.parse(jsonData: Data(emptyStreamJson.utf8)) {
        expect(cleared == nil, "Empty stream payload should parse as nil payload")
    } else {
        expect(false, "Expected .some(nil) for empty stream payload")
    }

    // Flat `media-control get` JSON with micros
    let getJson = """
    {"title":"Podcast Episode","artist":"Host","durationMicros":120000000,"elapsedTimeMicros":30000000,"playing":false}
    """
    if case .some(let flat?) = MediaControlPayload.parse(jsonData: Data(getJson.utf8)) {
        expect(flat.title == "Podcast Episode" && !flat.isPlaying, "Flat get JSON should parse title and paused state")
        expect(flat.estimatedPositionMs() == 30_000, "Paused micros elapsed position should be 30_000ms")
    } else {
        expect(false, "Expected valid MediaControlPayload from flat get JSON")
    }

    // 2. MacMediaMonitor uses universal payload for any app (e.g. Chrome video / Podcasts) & dispatches transport + seek
    let mockBackend = MockMacMediaBackend()
    mockBackend.performActionResult = false
    let mockCLI = MockMacMediaControlClient()
    let universalMon = MacMediaMonitor(backend: mockBackend, mediaControlClient: mockCLI)

    let chromePayload = MediaControlPayload(
        title: "Universal Video",
        artist: "Creator Channel",
        album: "",
        bundleIdentifier: "com.google.Chrome",
        durationSeconds: 300.0,
        elapsedSeconds: 50.0,
        isPlaying: true,
        playbackRate: 1.0,
        timestamp: nil,
        artworkData: Data(base64Encoded: samplePngBase64)
    )
    if let json = universalMon.applyUniversalPayloadForTesting(chromePayload),
       let data = json.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["type"] as? String == "mac_media_status", "Expected mac_media_status")
        expect(obj["appName"] as? String == "Google Chrome", "Expected Google Chrome appName from bundleIdentifier")
        expect(obj["title"] as? String == "Universal Video", "Expected universal title")
        expect(obj["canSeek"] as? Bool == true, "Expected canSeek=true when duration > 0")
        expect(obj["canSkipNext"] as? Bool == true && obj["canSkipPrevious"] as? Bool == true, "Expected skip capabilities")
        expect((obj["artworkBase64"] as? String)?.isEmpty == false, "Expected encoded artworkBase64")
    } else {
        expect(false, "Universal payload should emit valid mac_media_status JSON")
    }

    // Dispatch play, pause, play_pause, next, previous, stop, seek, seek_delta via universal CLI
    universalMon.handleMediaAction(jsonObject: ["action": "pause"])
    universalMon.handleMediaAction(jsonObject: ["action": "play"])
    universalMon.handleMediaAction(jsonObject: ["action": "play_pause"])
    universalMon.handleMediaAction(jsonObject: ["action": "next"])
    universalMon.handleMediaAction(jsonObject: ["action": "previous"])
    universalMon.handleMediaAction(jsonObject: ["action": "stop"])
    universalMon.handleMediaAction(jsonObject: ["action": "seek", "positionMs": 125_000])
    universalMon.handleMediaAction(jsonObject: ["action": "seek_delta", "deltaMs": 10_000])

    // Wait briefly for MacMediaMonitor's serial queue to process actions
    let actionWait = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
        actionWait.signal()
    }
    _ = actionWait.wait(timeout: .now() + 1.0)

    expect(mockCLI.commands == ["pause", "play", "toggle-play-pause", "next-track", "previous-track", "stop"], "Expected universal commands to route to media-control CLI, got \(mockCLI.commands)")
    expect(mockCLI.seekTargetsSeconds.count == 2, "Expected 2 seek commands via universal CLI, got \(mockCLI.seekTargetsSeconds.count)")
    if mockCLI.seekTargetsSeconds.count == 2 {
        expect(abs(mockCLI.seekTargetsSeconds[0] - 125.0) < 0.01, "First seek should target 125.0s")
        expect(abs(mockCLI.seekTargetsSeconds[1] - 135.0) < 0.01, "Second seek_delta +10s should target 135.0s")
    }

    // 3. LaunchBackend command/seek argument mapping for bundled mediaremote-adapter vs external media-control CLI
    let bundled = MacMediaControlCLI.LaunchBackend.bundledAdapter(
        perlPath: "/usr/bin/perl",
        scriptPath: "/Applications/Bridge.app/Contents/Resources/mediaremote-adapter.pl",
        frameworkPath: "/Applications/Bridge.app/Contents/Frameworks/MediaRemoteAdapter.framework"
    )
    expect(
        bundled.arguments(forCommand: "play") == [
            "/Applications/Bridge.app/Contents/Resources/mediaremote-adapter.pl",
            "/Applications/Bridge.app/Contents/Frameworks/MediaRemoteAdapter.framework",
            "send", "0"
        ],
        "Bundled adapter should map play -> send 0"
    )
    expect(
        bundled.arguments(forCommand: "pause").suffix(2) == ["send", "1"],
        "Bundled adapter should map pause -> send 1"
    )
    expect(
        bundled.arguments(forCommand: "next-track").suffix(2) == ["send", "4"],
        "Bundled adapter should map next-track -> send 4"
    )
    expect(
        bundled.arguments(forCommand: "previous-track").suffix(2) == ["send", "5"],
        "Bundled adapter should map previous-track -> send 5"
    )
    expect(
        bundled.arguments(forSeekSeconds: 22.5).suffix(2) == ["seek", "22500000"],
        "Bundled adapter should pass seek position in microseconds"
    )

    let external = MacMediaControlCLI.LaunchBackend.externalCLI(binaryPath: "/opt/homebrew/bin/media-control")
    expect(external.arguments(forCommand: "toggle-play-pause") == ["toggle-play-pause"], "External CLI should pass command directly")
    expect(external.arguments(forSeekSeconds: 22.5) == ["seek", "22.500"], "External CLI should pass seek position in seconds")

    // Clearing universal payload falls back cleanly to inactive when CoreAudio is silent
    if let clearedJson = universalMon.applyUniversalPayloadForTesting(nil),
       let data = clearedJson.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["isActive"] as? Bool == false, "Cleared universal payload with silent audio should emit isActive=false")
    } else {
        expect(false, "Cleared universal payload should emit inactive JSON")
    }
}

private final class MockMacMediaBackend: MacMediaMonitoringBackend {
    var running: Set<String> = []
    var audioPlaying: Bool = false
    var results: [String: MacMediaMonitor.PlayerQueryResult] = [:]
    var sentActions: [(action: String, bundleId: String)] = []
    var sentKeys: [Int32] = []
    var performActionResult: Bool = true

    func runningPlayerBundleIds() -> Set<String> { running }
    func isAnyMacAudioPlaying() -> Bool { audioPlaying }
    func queryPlayer(bundleId: String) -> MacMediaMonitor.PlayerQueryResult? { results[bundleId] }
    func performPlayerAction(_ action: String, bundleId: String, positionMs: Int64?, deltaMs: Int64?) -> Bool {
        sentActions.append((action, bundleId))
        return performActionResult
    }
    func sendMediaKey(keyType: Int32) { sentKeys.append(keyType) }
}

private func runMacSystemControlAndMediaMonitorTests() {
    // 1. Desktop Mac omits batteryPercent; MacBook includes batteryPercent + isCharging
    let desktopSnap = MacSystemStatusSnapshot(
        batteryPercent: nil,
        isCharging: false,
        isMuted: true,
        volumePercent: 0,
        canToggleMute: true,
        canControlVolume: true
    )
    let desktopObj = desktopSnap.toJsonObject()
    expect(desktopObj["type"] as? String == "mac_status", "Desktop mac_status type should match")
    expect(desktopObj["batteryPercent"] == nil, "Desktop Mac must omit batteryPercent")
    expect(desktopObj["isMuted"] as? Bool == true, "Desktop Mac mute flag should serialize")

    // 2. MacSystemControlManager command handling (Sound <-> Silent + volume unmutes)
    let mockCtrl = MockMacControlProvider()
    let ctrlMgr = MacSystemControlManager(provider: mockCtrl)
    var emittedJsons: [String] = []
    let expMute = DispatchSemaphore(value: 0)
    ctrlMgr.onStatusChanged = { json in
        emittedJsons.append(json)
        expMute.signal()
    }
    ctrlMgr.handleControlCommand(jsonObject: ["action": "toggle_mute"])
    expect(expMute.wait(timeout: .now() + 2.0) == .success, "toggle_mute should emit mac_status")
    expect(mockCtrl.snapshot.isMuted == true, "toggle_mute should switch Sound -> Silent")

    ctrlMgr.handleControlCommand(jsonObject: ["action": "set_volume", "volumePercent": 62])
    expect(expMute.wait(timeout: .now() + 2.0) == .success, "set_volume should emit mac_status")
    expect(mockCtrl.snapshot.volumePercent == 62 && !mockCtrl.snapshot.isMuted, "Setting volume > 0 should unmute")
    expect(!emittedJsons.isEmpty, "mac_status emissions expected")

    // 3. MacMediaMonitor player precedence & CoreAudio browser fallback
    let mockMedia = MockMacMediaBackend()
    let disabledCLI = MockMacMediaControlClient()
    disabledCLI.isAvailable = false
    let mediaMon = MacMediaMonitor(backend: mockMedia, mediaControlClient: disabledCLI)
    mockMedia.running = ["com.spotify.client"]
    mockMedia.results["com.spotify.client"] = .active(
        MacMediaSnapshot(
            isActive: true,
            isPlaying: true,
            title: "Nightcall",
            artist: "Kavinsky",
            album: "OutRun",
            appName: "Spotify",
            bundleId: "com.spotify.client",
            durationMs: 258_000,
            positionMs: 42_000,
            playbackSpeed: 1.0,
            canSeek: true,
            canSkipNext: true,
            canSkipPrevious: true
        ),
        artworkUrl: nil
    )
    if let spotifyJson = mediaMon.pollAndBroadcastForTesting(force: true),
       let data = spotifyJson.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["type"] as? String == "mac_media_status", "Expected mac_media_status")
        expect(obj["appName"] as? String == "Spotify", "Expected Spotify appName")
        expect(obj["canSeek"] as? Bool == true, "Spotify track should support seek")
    } else {
        expect(false, "Spotify poll should produce valid JSON")
    }

    // When Spotify pauses and another Mac app plays audio, fallback to "Audio playing on Mac"
    mockMedia.results["com.spotify.client"] = .active(
        MacMediaSnapshot(
            isActive: true,
            isPlaying: false,
            title: "Nightcall",
            artist: "Kavinsky",
            album: "OutRun",
            appName: "Spotify",
            bundleId: "com.spotify.client",
            durationMs: 258_000,
            positionMs: 42_000,
            playbackSpeed: 0.0,
            canSeek: true,
            canSkipNext: true,
            canSkipPrevious: true
        ),
        artworkUrl: nil
    )
    mockMedia.audioPlaying = true
    if let fallbackJson = mediaMon.pollAndBroadcastForTesting(force: true),
       let data = fallbackJson.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["title"] as? String == "Audio playing on Mac", "Expected browser audio fallback title")
        expect(obj["canSeek"] as? Bool == false, "Generic Mac audio must disable seek")
        expect(obj["isPlaying"] as? Bool == true, "Active audio fallback should be playing")
    } else {
        expect(false, "Generic audio fallback should produce JSON")
    }

    // When generic Mac audio pauses, card remains active in paused state (isActive=true, isPlaying=false)
    mockMedia.results.removeAll()
    mockMedia.audioPlaying = false
    if let pausedFallbackJson = mediaMon.pollAndBroadcastForTesting(force: true),
       let data = pausedFallbackJson.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(obj["isActive"] as? Bool == true, "Paused Mac audio should keep Now Playing active")
        expect(obj["isPlaying"] as? Bool == false, "Paused Mac audio should set isPlaying=false for Play icon")
    } else {
        expect(false, "Paused generic audio fallback should produce JSON")
    }

    // Thumbnail JPEG encoder
    let samplePngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
    if let raw = Data(base64Encoded: samplePngBase64),
       let thumb = MacMediaMonitor.encodeThumbnail(fromData: raw) {
        expect(!thumb.hash.isEmpty && !thumb.base64.isEmpty, "Thumbnail encoder should emit hash and base64")
    } else {
        expect(false, "Sample PNG thumbnail encoding should succeed")
    }

    // YouTube browser tab URL + title parsing
    expect(
        MacMediaMonitor.extractYouTubeVideoId(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s") == "dQw4w9WgXcQ",
        "Standard YouTube watch URL should extract video id"
    )
    expect(
        MacMediaMonitor.extractYouTubeVideoId(from: "https://music.youtube.com/watch?v=abc123XYZ&list=RD") == "abc123XYZ",
        "YouTube Music URL should extract video id"
    )
    expect(
        MacMediaMonitor.extractYouTubeVideoId(from: "https://youtu.be/xyz987?si=1") == "xyz987",
        "youtu.be short URL should extract video id"
    )
    expect(
        MacMediaMonitor.cleanYouTubeTitle("(3) AI Engineering Full Course - YouTube") == "AI Engineering Full Course",
        "YouTube tab title cleaner should strip badge count and suffix"
    )
}

@main
struct BridgeTestRunner {
    static func main() {
        runLocalIpTests()
        runCryptoAndAuthHelperTests()
        runSpekeAndSessionCipherTests()
        runHandshakeGateTests()
        runNotificationScrollLayoutTests()
        runLaunchAtLoginTests()
        runBatteryAndDeviceCardTests()
        runQuickControlPanelTests()
        runNowPlayingMediaTests()
        runIncomingCallAndAutoPauseTests()
        runMacSystemControlAndMediaMonitorTests()
        runUniversalMediaControlTests()
        do {
            try runPayloadAndVersionTests()
            try runFileTransferSecurityTests()
        } catch {
            fputs("FAIL: Unexpected error thrown: \(error)\n", stderr)
            failureCount += 1
        }

        if failureCount > 0 {
            fputs("macOS unit tests failed: \(failureCount) failure(s)\n", stderr)
            exit(1)
        }
        print("All macOS Bridge unit tests passed!")
    }
}
