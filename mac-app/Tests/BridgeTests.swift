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

    // Default autoAcceptIncomingFiles must be false when UserDefaults key is unset
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
        ? false
        : UserDefaults.standard.bool(forKey: "bridge_file_auto_accept")
    expect(!unsetDefault, "autoAcceptIncomingFiles default must be false when unset")
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

@main
struct BridgeTestRunner {
    static func main() {
        runLocalIpTests()
        runCryptoAndAuthHelperTests()
        runSpekeAndSessionCipherTests()
        runHandshakeGateTests()
        runNotificationScrollLayoutTests()
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
