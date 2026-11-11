import Foundation
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

    // Executable detection & folder nuance
    let scriptItem = FileTransferItem(id: "1", fileName: "install.sh", fileSize: 10, direction: .incoming, deviceId: nil, deviceName: "Phone", isFolder: false)
    let folderItem = FileTransferItem(id: "2", fileName: "archive.sh", fileSize: 10, direction: .incoming, deviceId: nil, deviceName: "Phone", isFolder: true)
    let pdfItem = FileTransferItem(id: "3", fileName: "notes.pdf", fileSize: 10, direction: .incoming, deviceId: nil, deviceName: "Phone", isFolder: false)
    expect(scriptItem.isExecutable, "Expected .sh file to be marked executable")
    expect(!folderItem.isExecutable, "Folder items are marked non-executable")
    expect(!pdfItem.isExecutable, "Expected .pdf file to not be marked executable")
}

private func runHandshakeGateTests() {
    let gate = BridgeHandshakeGate()
    let code = "482913"
    let nonce1 = "0123456789abcdef0123456789abcdef"
    let validProof1 = computeSHA256("bridge-hello:\(code):\(nonce1)")

    // 1. Valid salted SHA-256 handshake succeeds
    let ok = gate.evaluateHello(
        jsonObject: ["type": "hello", "hash": validProof1, "text": nonce1],
        pairingCode: code,
        remoteIp: "192.168.1.10",
        now: 1000
    )
    expect(ok.authenticated && ok.clientNonce == nonce1, "Valid SHA-256 hello should authenticate")

    // 2. Replaying the same nonce is rejected
    let replay = gate.evaluateHello(
        jsonObject: ["type": "hello", "hash": validProof1, "text": nonce1],
        pairingCode: code,
        remoteIp: "192.168.1.10",
        now: 1001
    )
    expect(!replay.authenticated && replay.failureReason == .replayedNonce, "Replayed nonce must be rejected")

    // 3. Legacy plaintext code login is rejected
    let plaintext = gate.evaluateHello(
        jsonObject: ["type": "hello", "code": code],
        pairingCode: code,
        remoteIp: "192.168.1.11",
        now: 1002
    )
    expect(!plaintext.authenticated && plaintext.failureReason == .invalidPayload, "Plaintext code fallback must be rejected")

    // 4. Per-IP lockout after 5 failed attempts
    let ipGate = BridgeHandshakeGate()
    for i in 0..<5 {
        let res = ipGate.evaluateHello(
            jsonObject: ["type": "hello", "hash": "bad", "text": "nonce_\(i)_0123456789abcdef"],
            pairingCode: code,
            remoteIp: "192.168.1.50",
            now: 2000 + Double(i)
        )
        expect(!res.authenticated, "Bad proof should fail")
    }
    let nonce2 = "abcdef0123456789abcdef0123456789"
    let validProof2 = computeSHA256("bridge-hello:\(code):\(nonce2)")
    let lockedOut = ipGate.evaluateHello(
        jsonObject: ["type": "hello", "hash": validProof2, "text": nonce2],
        pairingCode: code,
        remoteIp: "192.168.1.50",
        now: 2010
    )
    expect(!lockedOut.authenticated && lockedOut.failureReason == .rateLimited, "IP should be locked out for 60s")
    let afterIpCooldown = ipGate.evaluateHello(
        jsonObject: ["type": "hello", "hash": validProof2, "text": nonce2],
        pairingCode: code,
        remoteIp: "192.168.1.50",
        now: 2065
    )
    expect(afterIpCooldown.authenticated, "IP should unlock after 60s lockout expires")

    // 5. Global lockout triggers after 10 failures across distinct IPs and blocks a brand new IP
    let globalGate = BridgeHandshakeGate()
    for i in 0..<10 {
        let res = globalGate.evaluateHello(
            jsonObject: ["type": "hello", "hash": "wrong", "text": "global_\(i)_0123456789abcdef"],
            pairingCode: code,
            remoteIp: "192.168.1.\(100 + i)",
            now: 3000 + Double(i)
        )
        expect(!res.authenticated, "Invalid attempt across distinct IPs should fail")
    }
    let nonce3 = "fedcba9876543210fedcba9876543210"
    let validProof3 = computeSHA256("bridge-hello:\(code):\(nonce3)")
    let blockedByGlobal = globalGate.evaluateHello(
        jsonObject: ["type": "hello", "hash": validProof3, "text": nonce3],
        pairingCode: code,
        remoteIp: "192.168.1.250",
        now: 3015
    )
    expect(!blockedByGlobal.authenticated && blockedByGlobal.failureReason == .rateLimited, "Global lockout must block even a brand new IP")

    let afterGlobalCooldown = globalGate.evaluateHello(
        jsonObject: ["type": "hello", "hash": validProof3, "text": nonce3],
        pairingCode: code,
        remoteIp: "192.168.1.250",
        now: 3040
    )
    expect(afterGlobalCooldown.authenticated, "Global lockout should expire after 30s")

    // 6. reset() clears lockouts
    for i in 0..<10 {
        _ = globalGate.evaluateHello(
            jsonObject: ["type": "hello", "hash": "wrong", "text": "reset_\(i)_0123456789abcdef"],
            pairingCode: code,
            remoteIp: "192.168.2.\(100 + i)",
            now: 4000
        )
    }
    expect(globalGate.isRateLimited(ip: "192.168.2.250", now: 4005), "Expected global lockout active before reset")
    globalGate.reset()
    expect(!globalGate.isRateLimited(ip: "192.168.2.250", now: 4005), "Expected reset() to clear global lockout")
}

@main
struct BridgeTestRunner {
    static func main() {
        runLocalIpTests()
        runCryptoAndAuthHelperTests()
        runHandshakeGateTests()
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
