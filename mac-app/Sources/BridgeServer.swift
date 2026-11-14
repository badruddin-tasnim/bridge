import Foundation
import AppKit
import Network
import CryptoKit

// MARK: - Protocol Models

struct ClipboardPayload: Codable {
    let type: String          // "clip", "image", "ping", "pong", "hello", "welcome", "denied", "sleep", "disconnect", "unpair"
    let hash: String?         // SHA-256 hex string
    let text: String?         // Plain text content
    let data: String?         // Base64-encoded image bytes
    let mime: String?         // Image MIME type ("image/png" or "image/jpeg")
    let timestamp: Int64?     // Milliseconds since epoch
    let code: String?         // Pairing code
    let device: String?       // Device name
    let name: String?         // Server / Host name

    init(
        type: String,
        hash: String? = nil,
        text: String? = nil,
        data: String? = nil,
        mime: String? = nil,
        timestamp: Int64? = Int64(Date().timeIntervalSince1970 * 1000),
        code: String? = nil,
        device: String? = nil,
        name: String? = nil
    ) {
        self.type = type
        self.hash = hash
        self.text = text
        self.data = data
        self.mime = mime
        self.timestamp = timestamp
        self.code = code
        self.device = device
        self.name = name
    }
}

struct ConnectedDeviceInfo: Identifiable, Equatable {
    let id: UUID
    let name: String
    let ip: String?
    let isConnected: Bool
}

// MARK: - Helpers

func computeSHA256(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func computeSHA256(_ string: String) -> String {
    return computeSHA256(Data(string.utf8))
}

func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count && !aBytes.isEmpty else {
        return false
    }
    var diff: UInt8 = 0
    for i in 0..<aBytes.count {
        diff |= (aBytes[i] ^ bBytes[i])
    }
    return diff == 0
}

func generateSecureSixDigitCode() -> String {
    var randomValue: UInt32 = 0
    let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &randomValue)
    if status == errSecSuccess {
        let code = (randomValue % 900000) + 100000
        return String(format: "%06d", code)
    }
    var rng = SystemRandomNumberGenerator()
    let fallback = UInt32.random(in: 100000...999999, using: &rng)
    return String(format: "%06d", fallback)
}

func isLocalOrPrivateIp(_ rawHost: String) -> Bool {
    let clean = rawHost
        .components(separatedBy: "%").first?
        .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n"))
        .lowercased() ?? ""
    if clean.isEmpty { return false }
    if clean == "localhost" || clean == "::1" || clean == "127.0.0.1" {
        return true
    }
    if clean.hasPrefix("fe80:") || clean.hasPrefix("fc") || clean.hasPrefix("fd") {
        return true
    }
    let ipv4Part = clean.hasPrefix("::ffff:") ? String(clean.dropFirst(7)) : clean
    let octets = ipv4Part.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
        return false
    }
    switch octets[0] {
    case 10:
        return true
    case 127:
        return true
    case 192:
        return octets[1] == 168
    case 172:
        return (16...31).contains(octets[1])
    case 169:
        return octets[1] == 254
    case 100:
        return (64...127).contains(octets[1])
    default:
        return false
    }
}

func getPrimaryIPv4Address() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    
    var ptr = firstAddr
    while true {
        let interface = ptr.pointee
        if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name.starts(with: "en") || name.starts(with: "wlan") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, socklen_t(0), NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if !ip.isEmpty && ip != "127.0.0.1" {
                    return ip
                }
            }
        }
        guard let next = ptr.pointee.ifa_next else { break }
        ptr = next
    }
    return nil
}

// MARK: - 2048-Bit Safe-Prime SPEKE & AES-256-GCM Session Transport Security

struct BigUInt2048: Equatable {
    var limbs: [UInt32]

    init(_ limbs: [UInt32]) {
        var trimmed = limbs
        while let last = trimmed.last, last == 0 {
            trimmed.removeLast()
        }
        self.limbs = trimmed
    }

    init(bigEndianBytes: [UInt8]) {
        var words: [UInt32] = []
        var i = bigEndianBytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var word: UInt32 = 0
            for j in start..<i {
                word = (word << 8) | UInt32(bigEndianBytes[j])
            }
            words.append(word)
            i = start
        }
        self.init(words)
    }

    init?(hex: String) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 512 else { return nil }
        let padded = (clean.count % 2 == 0) ? clean : ("0" + clean)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(padded.count / 2)
        var idx = padded.startIndex
        while idx < padded.endIndex {
            let next = padded.index(idx, offsetBy: 2)
            guard let b = UInt8(padded[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bigEndianBytes: bytes)
    }

    func toBigEndianBytes(minLength: Int = 256) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            let w = limbs[i]
            out.append(UInt8((w >> 24) & 0xFF))
            out.append(UInt8((w >> 16) & 0xFF))
            out.append(UInt8((w >> 8) & 0xFF))
            out.append(UInt8(w & 0xFF))
        }
        while out.count > 1 && out.first == 0 {
            out.removeFirst()
        }
        if out.count < minLength {
            out = [UInt8](repeating: 0, count: minLength - out.count) + out
        }
        return out
    }

    func toHex(minByteLength: Int = 256) -> String {
        return toBigEndianBytes(minLength: minByteLength).map { String(format: "%02x", $0) }.joined()
    }

    static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        }
        return 0
    }

    static func add(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let count = max(a.count, b.count)
        var out = [UInt32](repeating: 0, count: count + 1)
        var carry: UInt64 = 0
        for i in 0..<count {
            let av = i < a.count ? UInt64(a[i]) : 0
            let bv = i < b.count ? UInt64(b[i]) : 0
            let sum = av + bv + carry
            out[i] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        out[count] = UInt32(truncatingIfNeeded: carry)
        while let last = out.last, last == 0 { out.removeLast() }
        return out
    }

    static func subtract(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var out = a
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let bv = i < b.count ? Int64(b[i]) : 0
            let diff = Int64(out[i]) - bv - borrow
            if diff < 0 {
                out[i] = UInt32(truncatingIfNeeded: diff + (1 << 32))
                borrow = 1
            } else {
                out[i] = UInt32(truncatingIfNeeded: diff)
                borrow = 0
            }
        }
        while let last = out.last, last == 0 { out.removeLast() }
        return out
    }

    static func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        if a.isEmpty || b.isEmpty { return [] }
        var out = [UInt32](repeating: 0, count: a.count + b.count)
        out.withUnsafeMutableBufferPointer { outBuf in
            a.withUnsafeBufferPointer { aBuf in
                b.withUnsafeBufferPointer { bBuf in
                    for i in 0..<aBuf.count {
                        let ai = UInt64(aBuf[i])
                        var carry: UInt64 = 0
                        for j in 0..<bBuf.count {
                            let prod = ai * UInt64(bBuf[j]) + UInt64(outBuf[i + j]) + carry
                            outBuf[i + j] = UInt32(truncatingIfNeeded: prod)
                            carry = prod >> 32
                        }
                        outBuf[i + bBuf.count] = UInt32(truncatingIfNeeded: carry)
                    }
                }
            }
        }
        while let last = out.last, last == 0 { out.removeLast() }
        return out
    }

    static func mod(_ a: [UInt32], _ m: [UInt32]) -> [UInt32] {
        var r = a
        while let last = r.last, last == 0 { r.removeLast() }
        let n = m.count
        guard n > 0 else { return [] }

        while compare(r, m) >= 0 {
            let shift = r.count - n
            if shift > 0 {
                let topHigh = UInt64(r[r.count - 1])
                let q = max(1, topHigh)
                let wordShift = shift - 1
                r.withUnsafeMutableBufferPointer { rBuf in
                    m.withUnsafeBufferPointer { mBuf in
                        var borrow: Int64 = 0
                        for i in 0..<n {
                            let prod = q * UInt64(mBuf[i])
                            let prodLo = Int64(prod & 0xFFFF_FFFF)
                            let prodHi = Int64(prod >> 32)
                            let cur = Int64(rBuf[i + wordShift]) - prodLo - borrow
                            if cur < 0 {
                                let k = (-cur + 0xFFFF_FFFF) >> 32
                                rBuf[i + wordShift] = UInt32(truncatingIfNeeded: cur + (k << 32))
                                borrow = prodHi + k
                            } else {
                                rBuf[i + wordShift] = UInt32(truncatingIfNeeded: cur)
                                borrow = prodHi
                            }
                        }
                        var idx = n + wordShift
                        while borrow > 0 && idx < rBuf.count {
                            let cur = Int64(rBuf[idx]) - borrow
                            if cur < 0 {
                                rBuf[idx] = UInt32(truncatingIfNeeded: cur + (1 << 32))
                                borrow = 1
                            } else {
                                rBuf[idx] = UInt32(truncatingIfNeeded: cur)
                                borrow = 0
                            }
                            idx += 1
                        }
                    }
                }
                while let last = r.last, last == 0 { r.removeLast() }
            } else {
                r = subtract(r, m)
            }
        }
        return r
    }

    static func modPow(base: BigUInt2048, exponent: BigUInt2048, modulus: BigUInt2048) -> BigUInt2048 {
        let m = modulus.limbs
        let b1 = mod(base.limbs, m)
        if b1.isEmpty { return BigUInt2048([]) }
        if exponent.limbs.isEmpty { return BigUInt2048([1]) }

        var table = [[UInt32]](repeating: [], count: 16)
        table[0] = [1]
        table[1] = b1
        for k in 2..<16 {
            table[k] = mod(multiply(table[k - 1], b1), m)
        }

        var result: [UInt32] = [1]
        let expBytes = exponent.toBigEndianBytes(minLength: 1)
        for byte in expBytes {
            let hi = Int(byte >> 4)
            for _ in 0..<4 { result = mod(multiply(result, result), m) }
            if hi != 0 { result = mod(multiply(result, table[hi]), m) }

            let lo = Int(byte & 0x0F)
            for _ in 0..<4 { result = mod(multiply(result, result), m) }
            if lo != 0 { result = mod(multiply(result, table[lo]), m) }
        }
        return BigUInt2048(result)
    }
}

enum BridgeSpeke {
    // RFC 3526 Group 14 (2048-bit MODP Safe Prime p = 2q + 1)
    static let pHex =
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

    static let prime = BigUInt2048(hex: pHex)!
    static let primeMinusTwo = BigUInt2048(BigUInt2048.subtract(prime.limbs, [2]))
    static let primeMinusThree = BigUInt2048(BigUInt2048.subtract(prime.limbs, [3]))
    static let two = BigUInt2048([2])

    struct SessionMaterial {
        let clientProof: String
        let serverProof: String
        let c2sKey: SymmetricKey
        let s2cKey: SymmetricKey
        let c2sKeyHex: String
        let s2cKeyHex: String
    }

    static func generateNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func generatePrivateScalar() -> BigUInt2048 {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] |= 0x80
        return BigUInt2048(bigEndianBytes: bytes)
    }

    static func deriveGenerator(pairingCode: String, clientNonce: String) -> BigUInt2048 {
        let cleanCode = pairingCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        var blocks: [UInt8] = []
        blocks.reserveCapacity(256)
        for i in 0..<8 {
            let input = Data("bridge-speke-v1:\(cleanCode):\(clientNonce):\(i)".utf8)
            blocks.append(contentsOf: SHA256.hash(data: input))
        }
        let rawH = BigUInt2048(bigEndianBytes: blocks)
        let hMod = BigUInt2048.mod(rawH.limbs, primeMinusThree.limbs)
        let h = BigUInt2048(BigUInt2048.add(hMod, [2]))
        return BigUInt2048.modPow(base: h, exponent: two, modulus: prime)
    }

    static func computePublicElement(generator: BigUInt2048, privateScalar: BigUInt2048) -> String {
        let pub = BigUInt2048.modPow(base: generator, exponent: privateScalar, modulus: prime)
        return pub.toHex(minByteLength: 256)
    }

    static func isValidPublicElement(_ hex: String) -> Bool {
        guard let element = BigUInt2048(hex: hex) else { return false }
        return BigUInt2048.compare(element.limbs, two.limbs) >= 0 &&
               BigUInt2048.compare(element.limbs, primeMinusTwo.limbs) <= 0
    }

    static func computeSharedSecret(peerPublicHex: String, privateScalar: BigUInt2048) -> String? {
        guard isValidPublicElement(peerPublicHex),
              let peerPub = BigUInt2048(hex: peerPublicHex) else {
            return nil
        }
        let shared = BigUInt2048.modPow(base: peerPub, exponent: privateScalar, modulus: prime)
        guard BigUInt2048.compare(shared.limbs, two.limbs) >= 0 &&
              BigUInt2048.compare(shared.limbs, primeMinusTwo.limbs) <= 0 else {
            return nil
        }
        return shared.toHex(minByteLength: 256)
    }

    static func deriveSessionMaterial(
        sharedSecretHex: String,
        pairingCode: String,
        clientNonce: String,
        serverNonce: String,
        clientPublicHex: String,
        serverPublicHex: String
    ) -> SessionMaterial {
        let cleanCode = pairingCode.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let normSecret = sharedSecretHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normClientPub = clientPublicHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normServerPub = serverPublicHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let transcript = "bridge-speke-transcript-v1:\(clientNonce):\(serverNonce):\(normClientPub):\(normServerPub)"
        let rootHex = computeSHA256("\(normSecret):\(cleanCode):\(transcript)")
        let clientProof = computeSHA256("bridge-client-confirm:\(rootHex):\(transcript)")
        let serverProof = computeSHA256("bridge-server-confirm:\(rootHex):\(transcript)")

        let c2sDigest = SHA256.hash(data: Data("bridge-c2s-key:\(rootHex):\(transcript)".utf8))
        let s2cDigest = SHA256.hash(data: Data("bridge-s2c-key:\(rootHex):\(transcript)".utf8))
        let c2sKeyHex = c2sDigest.map { String(format: "%02x", $0) }.joined()
        let s2cKeyHex = s2cDigest.map { String(format: "%02x", $0) }.joined()

        return SessionMaterial(
            clientProof: clientProof,
            serverProof: serverProof,
            c2sKey: SymmetricKey(data: c2sDigest),
            s2cKey: SymmetricKey(data: s2cDigest),
            c2sKeyHex: c2sKeyHex,
            s2cKeyHex: s2cKeyHex
        )
    }
}

final class BridgeSessionCipher {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendDirection: String
    private let receiveDirection: String
    private let lock = NSLock()
    private var sendSeq: UInt64 = 0
    private var expectedReceiveSeq: UInt64 = 1

    init(
        sendKey: SymmetricKey,
        receiveKey: SymmetricKey,
        sendDirection: String,
        receiveDirection: String
    ) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.sendDirection = sendDirection
        self.receiveDirection = receiveDirection
    }

    func seal(_ plaintext: Data, saltOverride: [UInt8]? = nil) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        sendSeq += 1
        let seq = sendSeq

        var iv = Data(capacity: 12)
        if let salt = saltOverride, salt.count == 4 {
            iv.append(contentsOf: salt)
        } else {
            var randomPrefix = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, randomPrefix.count, &randomPrefix)
            iv.append(contentsOf: randomPrefix)
        }
        var seqBig = seq.bigEndian
        withUnsafeBytes(of: &seqBig) { iv.append(contentsOf: $0) }

        let aad = Data("bridge-v1:\(sendDirection):\(seq)".utf8)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let sealed = try? AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad),
              let combined = sealed.combined else {
            return nil
        }

        let b64 = combined.base64EncodedString()
        let envelope = "{\"type\":\"enc\",\"seq\":\(seq),\"d\":\"\(b64)\"}"
        return envelope.data(using: .utf8)
    }

    func open(jsonObject: [String: Any]) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard (jsonObject["type"] as? String) == "enc" else {
            return nil
        }
        let seq: UInt64
        if let num = jsonObject["seq"] as? NSNumber {
            let val = num.int64Value
            guard val > 0 else { return nil }
            seq = UInt64(val)
        } else if let u = jsonObject["seq"] as? UInt64, u > 0 {
            seq = u
        } else if let i = jsonObject["seq"] as? Int, i > 0 {
            seq = UInt64(i)
        } else {
            return nil
        }

        guard seq == expectedReceiveSeq else {
            return nil
        }

        guard let b64 = jsonObject["d"] as? String,
              let combined = Data(base64Encoded: b64),
              combined.count > 28 else {
            return nil
        }

        let embeddedSeq = combined.subdata(in: 4..<12).withUnsafeBytes {
            $0.load(as: UInt64.self).bigEndian
        }
        guard embeddedSeq == seq else {
            return nil
        }

        let aad = Data("bridge-v1:\(receiveDirection):\(seq)".utf8)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(sealedBox, using: receiveKey, authenticating: aad) else {
            return nil
        }

        expectedReceiveSeq += 1
        return plaintext
    }
}

// MARK: - Pairing Security Gate

final class BridgeHandshakeGate {
    enum FailureReason: Equatable {
        case rateLimited
        case invalidPayload
        case replayedNonce
        case invalidProof
    }

    struct EvaluationResult {
        let authenticated: Bool
        let challengeIssued: Bool
        let clientNonce: String?
        let serverNonce: String?
        let serverPublicHex: String?
        let sessionMaterial: BridgeSpeke.SessionMaterial?
        let failureReason: FailureReason?
    }

    static let maxFailedAttemptsPerIp = 5
    static let attemptWindowSeconds: TimeInterval = 60.0
    static let baseLockoutSeconds: TimeInterval = 60.0
    static let maxGlobalFailedAttempts = 10
    static let globalLockoutSeconds: TimeInterval = 30.0
    static let maxNonceHistory = 256

    private var failedHelloTimestampsByIp = [String: [TimeInterval]]()
    private var ipLockoutUntil = [String: TimeInterval]()
    private var ipLockoutCount = [String: Int]()
    private var globalFailedHelloTimestamps = [TimeInterval]()
    private var globalLockoutUntil: TimeInterval = 0
    private var usedHelloNonces = Set<String>()
    private var usedHelloNonceOrder = [String]()

    func isRateLimited(ip: String, now: TimeInterval) -> Bool {
        if now < globalLockoutUntil {
            return true
        }
        if let until = ipLockoutUntil[ip], now < until {
            return true
        }
        return false
    }

    func evaluateHello(
        jsonObject: [String: Any],
        pairingCode: String,
        remoteIp: String,
        now: TimeInterval = Date().timeIntervalSince1970,
        serverNonceOverride: String? = nil,
        serverScalarOverride: BigUInt2048? = nil
    ) -> EvaluationResult {
        if isRateLimited(ip: remoteIp, now: now) {
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .rateLimited
            )
        }

        let targetCode = pairingCode.replacingOccurrences(of: " ", with: "")
        let clientNonce = (jsonObject["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawClientPublicHex = (jsonObject["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        guard clientNonce.count >= 16,
              clientNonce.count <= 128,
              BridgeSpeke.isValidPublicElement(rawClientPublicHex),
              let clientPub = BigUInt2048(hex: rawClientPublicHex) else {
            recordFailedAttempt(for: remoteIp, now: now)
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .invalidPayload
            )
        }

        if usedHelloNonces.contains(clientNonce) {
            recordFailedAttempt(for: remoteIp, now: now)
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .replayedNonce
            )
        }

        let clientPublicHex = clientPub.toHex(minByteLength: 256)
        let serverNonce = serverNonceOverride ?? BridgeSpeke.generateNonce()
        let serverScalar = serverScalarOverride ?? BridgeSpeke.generatePrivateScalar()
        let generator = BridgeSpeke.deriveGenerator(pairingCode: targetCode, clientNonce: clientNonce)
        let serverPublicHex = BridgeSpeke.computePublicElement(generator: generator, privateScalar: serverScalar)

        guard let sharedSecretHex = BridgeSpeke.computeSharedSecret(
            peerPublicHex: clientPublicHex,
            privateScalar: serverScalar
        ) else {
            recordFailedAttempt(for: remoteIp, now: now)
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .invalidPayload
            )
        }

        usedHelloNonces.insert(clientNonce)
        usedHelloNonceOrder.append(clientNonce)
        if usedHelloNonceOrder.count > Self.maxNonceHistory {
            let oldest = usedHelloNonceOrder.removeFirst()
            usedHelloNonces.remove(oldest)
        }

        let material = BridgeSpeke.deriveSessionMaterial(
            sharedSecretHex: sharedSecretHex,
            pairingCode: targetCode,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientPublicHex: clientPublicHex,
            serverPublicHex: serverPublicHex
        )

        return EvaluationResult(
            authenticated: false,
            challengeIssued: true,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            serverPublicHex: serverPublicHex,
            sessionMaterial: material,
            failureReason: nil
        )
    }

    func evaluateAuth(
        jsonObject: [String: Any],
        sessionMaterial: BridgeSpeke.SessionMaterial,
        clientNonce: String,
        remoteIp: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> EvaluationResult {
        if isRateLimited(ip: remoteIp, now: now) {
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .rateLimited
            )
        }

        let incomingProof = (jsonObject["hash"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !incomingProof.isEmpty else {
            recordFailedAttempt(for: remoteIp, now: now)
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .invalidPayload
            )
        }

        guard constantTimeEquals(incomingProof, sessionMaterial.clientProof) else {
            recordFailedAttempt(for: remoteIp, now: now)
            return EvaluationResult(
                authenticated: false,
                challengeIssued: false,
                clientNonce: nil,
                serverNonce: nil,
                serverPublicHex: nil,
                sessionMaterial: nil,
                failureReason: .invalidProof
            )
        }

        clearFailedAttempts(for: remoteIp)
        return EvaluationResult(
            authenticated: true,
            challengeIssued: false,
            clientNonce: clientNonce,
            serverNonce: nil,
            serverPublicHex: nil,
            sessionMaterial: sessionMaterial,
            failureReason: nil
        )
    }

    func recordFailedAttempt(for ip: String, now: TimeInterval) {
        let cutoff = now - Self.attemptWindowSeconds
        var attempts = (failedHelloTimestampsByIp[ip] ?? []).filter { $0 >= cutoff }
        attempts.append(now)
        failedHelloTimestampsByIp[ip] = attempts

        if attempts.count >= Self.maxFailedAttemptsPerIp {
            let lockCount = (ipLockoutCount[ip] ?? 0) + 1
            ipLockoutCount[ip] = lockCount
            let multiplier = min(16.0, pow(2.0, Double(lockCount - 1)))
            let lockoutDuration = Self.baseLockoutSeconds * multiplier
            ipLockoutUntil[ip] = now + lockoutDuration
            failedHelloTimestampsByIp.removeValue(forKey: ip)
            NSLog("[BridgeSecurity] Locked out IP %@ for %.0fs after %d failed pairing attempts", ip, lockoutDuration, attempts.count)
        }

        globalFailedHelloTimestamps = globalFailedHelloTimestamps.filter { $0 >= cutoff }
        globalFailedHelloTimestamps.append(now)
        if globalFailedHelloTimestamps.count >= Self.maxGlobalFailedAttempts {
            globalLockoutUntil = now + Self.globalLockoutSeconds
            globalFailedHelloTimestamps.removeAll()
            NSLog("[BridgeSecurity] Global handshake rate-limit triggered for %.0fs", Self.globalLockoutSeconds)
        }
    }

    func clearFailedAttempts(for ip: String) {
        failedHelloTimestampsByIp.removeValue(forKey: ip)
        ipLockoutUntil.removeValue(forKey: ip)
        ipLockoutCount.removeValue(forKey: ip)
    }

    func reset() {
        failedHelloTimestampsByIp.removeAll()
        ipLockoutUntil.removeAll()
        ipLockoutCount.removeAll()
        globalFailedHelloTimestamps.removeAll()
        globalLockoutUntil = 0
        usedHelloNonces.removeAll()
        usedHelloNonceOrder.removeAll()
    }
}

// MARK: - Bridge Server Engine

class BridgeServer {
    private struct PendingHandshake {
        let clientNonce: String
        let deviceName: String
        let remoteIp: String
        let material: BridgeSpeke.SessionMaterial
    }

    let port: NWEndpoint.Port = 8765
    private var listener: NWListener?
    private var connections = [UUID: NWConnection]()
    private var authenticatedConnections = Set<UUID>()
    private var pendingHandshakes = [UUID: PendingHandshake]()
    private var sessionCiphers = [UUID: BridgeSessionCipher]()
    private var clientDeviceNames = [UUID: String]()
    private var connectionLastSeen = [UUID: TimeInterval]()
    private var connectionCreatedAt = [UUID: TimeInterval]()
    private var connectionRemoteIp = [UUID: String]()
    private let networkQueue = DispatchQueue(label: "com.link.bridge.network")
    private let imageQueue = DispatchQueue(label: "com.link.bridge.image", qos: .userInitiated)
    private let pathMonitor = NWPathMonitor()
    private static let maxImageDimension = 2560
    private static let maxUnauthBufferBytes = 8 * 1024
    private static let maxAuthBufferBytes = 25 * 1024 * 1024
    private static let maxConcurrentConnections = 8
    private static let maxUnauthConnections = 4
    private static let unauthHandshakeTimeoutSeconds: TimeInterval = 8.0
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "bmp", "gif"
    ]

    // Brute-force & replay protection state (accessed on networkQueue)
    private let handshakeGate = BridgeHandshakeGate()
    
    // Pairing state
    private(set) var pairingCode: String = ""
    
    // Pasteboard
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var lastSentHash: String = ""
    private var lastReceivedHash: String = ""
    
    // Timers
    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    
    // Callbacks for UI
    var onStatusChanged: ((_ isConnected: Bool, _ deviceName: String?) -> Void)?
    var onConnectedDevicesChanged: (([ConnectedDeviceInfo]) -> Void)?
    var onClipboardSynced: ((_ text: String, _ outgoing: Bool) -> Void)?
    var onIpChanged: ((_ ip: String) -> Void)?
    var onRemoteUnpair: ((_ deviceId: UUID, _ deviceName: String?, _ remainingCount: Int) -> Void)?
    
    init() {
        loadOrGeneratePairingCode()
        BridgeNotificationManager.shared.sendPayload = { [weak self] jsonString in
            self?.broadcastRawJson(jsonString)
        }
        BridgeFileTransferManager.shared.sendControlMessage = { [weak self] jsonString, targetDeviceId in
            self?.sendRawJson(jsonString, toDeviceId: targetDeviceId)
        }
    }
    
    private func loadOrGeneratePairingCode() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codeFile = home.appendingPathComponent(".bridge_pairing_code")
        
        if let existing = try? String(contentsOf: codeFile, encoding: .utf8) {
            let cleaned = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count == 6 && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: cleaned)) {
                self.pairingCode = cleaned
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codeFile.path)
                return
            }
        }
        
        let newCode = generateSecureSixDigitCode()
        writeSecurePairingCodeFile(newCode, to: codeFile)
        self.pairingCode = newCode
    }

    private func writeSecurePairingCodeFile(_ code: String, to codeFile: URL) {
        try? code.write(to: codeFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codeFile.path)
    }
    
    func start() {
        lastChangeCount = pasteboard.changeCount
        setupPowerStateMonitoring()
        setupNetworkMonitoring()
        startServer()
        startClipboardPolling()
        startHeartbeat()
    }
    
    func stop() {
        pollTimer?.invalidate()
        heartbeatTimer?.invalidate()
        pathMonitor.cancel()
        closeAllConnections()
        listener?.cancel()
        listener = nil
    }
    
    // MARK: - Power & Wake Resilience
    
    private func setupPowerStateMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWillSleep()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleDidWake()
        }
    }
    
    private func handleWillSleep() {
        let sleepPayload = ClipboardPayload(
            type: "sleep",
            name: Host.current().localizedName ?? "Mac"
        )
        broadcastPayload(sleepPayload)
        
        networkQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.closeAllConnections()
            self.listener?.cancel()
            self.listener = nil
        }
    }
    
    private func handleDidWake() {
        lastChangeCount = pasteboard.changeCount
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            self.closeAllConnections()
            self.listener?.cancel()
            self.listener = nil
        }
        
        networkQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            if let ip = getPrimaryIPv4Address() {
                DispatchQueue.main.async { self.onIpChanged?(ip) }
            }
            self.startServer()
            DispatchQueue.main.async {
                self.checkPasteboard()
            }
        }
    }
    
    private func setupNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                if let ip = getPrimaryIPv4Address() {
                    DispatchQueue.main.async { self.onIpChanged?(ip) }
                }
                if self.listener == nil || self.listener?.state != .ready {
                    self.startServer()
                }
            }
        }
        pathMonitor.start(queue: networkQueue)
    }
    
    // MARK: - Server Setup
    
    func startServer() {
        if let existing = listener {
            if existing.state == .ready { return }
            existing.cancel()
            listener = nil
        }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 3
            tcpOptions.keepaliveInterval = 2
            tcpOptions.keepaliveCount = 2
            tcpOptions.connectionDropTime = 6
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
            
            let hostName = Host.current().localizedName ?? "Mac"
            listener?.service = NWListener.Service(name: "Bridge (\(hostName))", type: "_clipboardsync._tcp")
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[Bridge] TCP & Bonjour advertisement ready on port \(self?.port.rawValue ?? 8765)")
                case .failed(_):
                    self?.restartServer()
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }
            
            listener?.start(queue: networkQueue)
        } catch {
            print("[Bridge] Listener error: \(error)")
        }
    }
    
    private func restartServer() {
        listener?.cancel()
        listener = nil
        networkQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.startServer()
        }
    }
    
    private func extractRemoteIp(from conn: NWConnection) -> String {
        switch conn.endpoint {
        case .hostPort(let host, _):
            let raw = "\(host)"
            return raw.components(separatedBy: "%").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n"))
                .lowercased() ?? "unknown"
        default:
            return "local"
        }
    }

    private func handleNewConnection(_ conn: NWConnection) {
        let connectionId = UUID()
        networkQueue.async { [weak self, conn] in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            let remoteIp = self.extractRemoteIp(from: conn)

            // 1. Reject non-private / non-local network connections
            if remoteIp != "local" && !isLocalOrPrivateIp(remoteIp) {
                NSLog("[BridgeSecurity] Rejected connection from non-private IP: %@", remoteIp)
                conn.cancel()
                return
            }

            // 2. Enforce connection limits to prevent socket exhaustion DoS
            let unauthCount = self.connections.count - self.authenticatedConnections.count
            if self.connections.count >= Self.maxConcurrentConnections || unauthCount >= Self.maxUnauthConnections {
                NSLog("[BridgeSecurity] Rejected connection from %@ (concurrent limit reached)", remoteIp)
                conn.cancel()
                return
            }

            self.connections[connectionId] = conn
            self.connectionLastSeen[connectionId] = now
            self.connectionCreatedAt[connectionId] = now
            self.connectionRemoteIp[connectionId] = remoteIp
            
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self = self, let conn = conn else { return }
                switch state {
                case .ready:
                    self.connectionLastSeen[connectionId] = Date().timeIntervalSince1970
                    self.readNextMessage(from: conn, id: connectionId, buffer: Data())
                case .waiting(_), .failed(_), .cancelled:
                    conn.cancel()
                    self.removeConnection(id: connectionId)
                default:
                    break
                }
            }
            conn.start(queue: self.networkQueue)
        }
    }
    
    private func removeConnection(id: UUID) {
        connections.removeValue(forKey: id)
        let wasAuthenticated = authenticatedConnections.remove(id) != nil
        if let abandoned = pendingHandshakes.removeValue(forKey: id), !wasAuthenticated {
            handshakeGate.recordFailedAttempt(for: abandoned.remoteIp, now: Date().timeIntervalSince1970)
        }
        sessionCiphers.removeValue(forKey: id)
        clientDeviceNames.removeValue(forKey: id)
        connectionLastSeen.removeValue(forKey: id)
        connectionCreatedAt.removeValue(forKey: id)
        connectionRemoteIp.removeValue(forKey: id)
        if wasAuthenticated {
            notifyUiStatus()
        }
    }
    
    private func readNextMessage(from conn: NWConnection, id: UUID, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] content, _, isComplete, error in
            guard let self = self, let conn = conn else { return }
            var currentBuffer = buffer
            if let data = content, !data.isEmpty {
                self.connectionLastSeen[id] = Date().timeIntervalSince1970
                currentBuffer.append(data)
                let maxAllowed = self.authenticatedConnections.contains(id) ? Self.maxAuthBufferBytes : Self.maxUnauthBufferBytes
                if currentBuffer.count > maxAllowed {
                    NSLog("[BridgeSecurity] Disconnecting client Exceeded max buffer (%d bytes)", currentBuffer.count)
                    conn.cancel()
                    self.removeConnection(id: id)
                    return
                }
                while let newlineIndex = currentBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = currentBuffer.subdata(in: 0..<newlineIndex)
                    currentBuffer.removeSubrange(0...newlineIndex)
                    if !lineData.isEmpty {
                        self.processPayload(lineData, from: conn, id: id)
                    }
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                self.removeConnection(id: id)
            } else if self.connections[id] != nil {
                self.readNextMessage(from: conn, id: id, buffer: currentBuffer)
            }
        }
    }

    private func denyAndDisconnect(_ conn: NWConnection, id: UUID) {
        pendingHandshakes.removeValue(forKey: id)
        let denied = ClipboardPayload(type: "denied")
        if let data = try? JSONEncoder().encode(denied) {
            var line = data
            line.append(UInt8(ascii: "\n"))
            conn.send(content: line, completion: .contentProcessed({ [weak self, weak conn] _ in
                conn?.cancel()
                self?.removeConnection(id: id)
            }))
        } else {
            conn.cancel()
            self.removeConnection(id: id)
        }
    }
    
    private func processPayload(_ rawLineData: Data, from conn: NWConnection, id: UUID) {
        let isAuth = self.authenticatedConnections.contains(id)

        guard let outerJson = (try? JSONSerialization.jsonObject(with: rawLineData)) as? [String: Any],
              let outerType = outerJson["type"] as? String else {
            if !isAuth {
                NSLog("[BridgeSecurity] Disconnecting unauthenticated client due to malformed JSON")
                conn.cancel()
                self.removeConnection(id: id)
            }
            return
        }

        if !isAuth {
            let now = Date().timeIntervalSince1970
            let remoteIp = self.connectionRemoteIp[id] ?? self.extractRemoteIp(from: conn)

            if outerType == "hello" {
                guard self.pendingHandshakes[id] == nil else {
                    self.handshakeGate.recordFailedAttempt(for: remoteIp, now: now)
                    self.denyAndDisconnect(conn, id: id)
                    return
                }

                let result = self.handshakeGate.evaluateHello(
                    jsonObject: outerJson,
                    pairingCode: self.pairingCode,
                    remoteIp: remoteIp,
                    now: now
                )

                if result.challengeIssued,
                   let clientNonce = result.clientNonce,
                   let serverNonce = result.serverNonce,
                   let serverPublicHex = result.serverPublicHex,
                   let material = result.sessionMaterial {
                    let rawDevice = (outerJson["device"] as? String) ?? "Android Device"
                    let sanitizedDevice = String(
                        rawDevice
                            .components(separatedBy: .controlCharacters).joined()
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .prefix(64)
                    )
                    self.pendingHandshakes[id] = PendingHandshake(
                        clientNonce: clientNonce,
                        deviceName: sanitizedDevice.isEmpty ? "Android Device" : sanitizedDevice,
                        remoteIp: remoteIp,
                        material: material
                    )

                    let challenge = ClipboardPayload(
                        type: "challenge",
                        text: serverNonce,
                        data: serverPublicHex
                    )
                    self.sendPlaintext(payload: challenge, to: conn)
                } else {
                    switch result.failureReason {
                    case .rateLimited:
                        NSLog("[BridgeSecurity] Denied 'hello' due to rate limit from %@", remoteIp)
                    case .replayedNonce:
                        NSLog("[BridgeSecurity] Rejected replayed hello nonce from %@", remoteIp)
                    case .invalidPayload, .invalidProof, .none:
                        NSLog("[BridgeSecurity] Invalid SPEKE hello attempt from %@", remoteIp)
                    }
                    self.denyAndDisconnect(conn, id: id)
                }
                return
            }

            if outerType == "auth" {
                guard let pending = self.pendingHandshakes.removeValue(forKey: id) else {
                    self.handshakeGate.recordFailedAttempt(for: remoteIp, now: now)
                    self.denyAndDisconnect(conn, id: id)
                    return
                }

                let authResult = self.handshakeGate.evaluateAuth(
                    jsonObject: outerJson,
                    sessionMaterial: pending.material,
                    clientNonce: pending.clientNonce,
                    remoteIp: pending.remoteIp,
                    now: now
                )

                if authResult.authenticated {
                    let cipher = BridgeSessionCipher(
                        sendKey: pending.material.s2cKey,
                        receiveKey: pending.material.c2sKey,
                        sendDirection: "s2c",
                        receiveDirection: "c2s"
                    )
                    self.sessionCiphers[id] = cipher
                    self.authenticatedConnections.insert(id)
                    self.clientDeviceNames[id] = pending.deviceName

                    let macName = Host.current().localizedName ?? "Mac"
                    let welcome = ClipboardPayload(
                        type: "welcome",
                        hash: pending.material.serverProof,
                        name: macName
                    )
                    self.sendPlaintext(payload: welcome, to: conn)

                    if let settingsStr = BridgeNotificationManager.shared.buildSettingsSyncJson(),
                       let settingsData = settingsStr.data(using: .utf8) {
                        self.sendEncryptedData(settingsData, to: conn, id: id)
                    }
                    self.notifyUiStatus()
                } else {
                    NSLog("[BridgeSecurity] Invalid SPEKE client auth proof from %@", pending.remoteIp)
                    self.denyAndDisconnect(conn, id: id)
                }
                return
            }

            NSLog("[BridgeSecurity] Rejected unauthenticated message of type '%@' — disconnecting", outerType)
            conn.cancel()
            self.removeConnection(id: id)
            return
        }

        // Authenticated connections MUST use AES-256-GCM encrypted session frames ("type": "enc")
        guard outerType == "enc",
              let cipher = self.sessionCiphers[id],
              let data = cipher.open(jsonObject: outerJson),
              let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = jsonObject["type"] as? String else {
            NSLog("[BridgeSecurity] Disconnecting authenticated client due to unencrypted or tampered frame")
            conn.cancel()
            self.removeConnection(id: id)
            return
        }

        if type.hasPrefix("notif_") || type == "settings_sync" {
            NSLog("[BridgeServer] Routing payload of type '%@' to BridgeNotificationManager", type)
            BridgeNotificationManager.shared.handleIncomingPayload(data: data)
            return
        }

        if type.hasPrefix("file_") {
            let devName = self.clientDeviceNames[id] ?? "Android Device"
            BridgeFileTransferManager.shared.handleControlMessage(jsonObject, fromDeviceId: id, deviceName: devName)
            return
        }
        
        if type == "ping" {
            let pong = ClipboardPayload(type: "pong")
            self.sendEncrypted(payload: pong, to: conn, id: id)
            return
        }

        if type == "pong" {
            return
        }
        
        if type == "disconnect" {
            conn.cancel()
            self.removeConnection(id: id)
            return
        }

        if type == "unpair" {
            let devName = self.clientDeviceNames[id]
            conn.cancel()
            self.removeConnection(id: id)
            let remainingCount = self.authenticatedConnections.count
            if remainingCount == 0 {
                self.resetPairingSecurityState()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if remainingCount == 0 {
                    self.generateNewPairingCode()
                }
                self.onRemoteUnpair?(id, devName, remainingCount)
            }
            return
        }
        
        guard let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) else { return }
        
        if payload.type == "clip", let text = payload.text, !text.isEmpty {
            let verifiedHash = computeSHA256(text)
            if verifiedHash == self.lastSentHash || verifiedHash == self.lastReceivedHash { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastReceivedHash = verifiedHash
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                self.lastChangeCount = self.pasteboard.changeCount
                self.onClipboardSynced?(text, false)
            }
            return
        }

        if payload.type == "image", let base64Data = payload.data {
            guard let imageData = Data(base64Encoded: base64Data, options: .ignoreUnknownCharacters),
                  !imageData.isEmpty,
                  let image = NSImage(data: imageData) else { return }
            let verifiedHash = (payload.hash?.isEmpty == false) ? payload.hash! : computeSHA256(imageData)
            if verifiedHash == self.lastSentHash || verifiedHash == self.lastReceivedHash { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastReceivedHash = verifiedHash
                self.pasteboard.clearContents()
                self.pasteboard.writeObjects([image])
                self.lastChangeCount = self.pasteboard.changeCount
                self.onClipboardSynced?("[Image]", false)
            }
            return
        }
    }
    
    private func notifyUiStatus() {
        let isConnected = !self.authenticatedConnections.isEmpty
        let device = self.clientDeviceNames.values.first
        let devicesList = self.getConnectedDevicesList()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStatusChanged?(isConnected, device)
            self.onConnectedDevicesChanged?(devicesList)
        }
    }

    func getConnectedDevicesList() -> [ConnectedDeviceInfo] {
        return authenticatedConnections.map { id in
            ConnectedDeviceInfo(
                id: id,
                name: clientDeviceNames[id] ?? "Android Device",
                ip: connectionRemoteIp[id],
                isConnected: true
            )
        }
    }

    func disconnectDevice(id: UUID) {
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            let unpairPayload = ClipboardPayload(type: "unpair")
            if let conn = self.connections[id] {
                self.sendEncrypted(payload: unpairPayload, to: conn, id: id)
                self.networkQueue.asyncAfter(deadline: .now() + 0.1) {
                    conn.cancel()
                    self.removeConnection(id: id)
                    if self.authenticatedConnections.isEmpty {
                        self.resetPairingSecurityState()
                        DispatchQueue.main.async {
                            self.generateNewPairingCode()
                        }
                    }
                }
            }
        }
    }
    
    private func sendPlaintext(payload: ClipboardPayload, to conn: NWConnection) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        conn.send(content: line, completion: .contentProcessed({ _ in }))
    }

    private func sendEncrypted(payload: ClipboardPayload, to conn: NWConnection, id: UUID) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        sendEncryptedData(data, to: conn, id: id)
    }

    private func sendEncryptedData(
        _ plainData: Data,
        to conn: NWConnection,
        id: UUID,
        onError: ((NWError?) -> Void)? = nil
    ) {
        guard let cipher = sessionCiphers[id],
              var encryptedLine = cipher.seal(plainData) else {
            return
        }
        encryptedLine.append(UInt8(ascii: "\n"))
        conn.send(content: encryptedLine, completion: .contentProcessed({ error in
            onError?(error)
        }))
    }
    
    private func broadcastPayload(_ payload: ClipboardPayload) {
        guard !authenticatedConnections.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for id in self.authenticatedConnections {
                if let conn = self.connections[id] {
                    self.sendEncryptedData(data, to: conn, id: id)
                }
            }
        }
    }

    func broadcastRawJson(_ jsonString: String) {
        guard !authenticatedConnections.isEmpty else { return }
        guard let data = jsonString.data(using: .utf8) else { return }
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for id in self.authenticatedConnections {
                if let conn = self.connections[id] {
                    self.sendEncryptedData(data, to: conn, id: id)
                }
            }
        }
    }

    func sendRawJson(_ jsonString: String, toDeviceId: UUID?) {
        guard let data = jsonString.data(using: .utf8) else { return }
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            if let targetId = toDeviceId {
                if self.authenticatedConnections.contains(targetId), let conn = self.connections[targetId] {
                    self.sendEncryptedData(data, to: conn, id: targetId)
                } else if let firstId = self.authenticatedConnections.first, let conn = self.connections[firstId] {
                    self.sendEncryptedData(data, to: conn, id: firstId)
                }
            } else {
                for id in self.authenticatedConnections {
                    if let conn = self.connections[id] {
                        self.sendEncryptedData(data, to: conn, id: id)
                    }
                }
            }
        }
    }
    
    private func startClipboardPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }
    
    private func checkPasteboard() {
        let count = pasteboard.changeCount
        if count == lastChangeCount { return }
        lastChangeCount = count
        
        let types = pasteboard.types ?? []

        // 1. Check if the user copied a file in Finder (.fileURL)
        if types.contains(.fileURL) {
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               let firstURL = urls.first,
               firstURL.isFileURL {
                let ext = firstURL.pathExtension.lowercased()
                if Self.supportedImageExtensions.contains(ext),
                   let image = NSImage(contentsOf: firstURL) {
                    dispatchImageToAndroid(image)
                    return
                }
            }
            // Non-image file copied in Finder: do not sync Finder's file icon as a photo
            return
        }

        // 2. Check if the user copied an image or screenshot (.png / .tiff before .string)
        let imageTypeIndex = types.firstIndex(where: { $0 == .png || $0 == .tiff })
        let stringTypeIndex = types.firstIndex(of: .string)

        if let imgIdx = imageTypeIndex, (stringTypeIndex == nil || imgIdx < stringTypeIndex!) {
            if let image = NSImage(pasteboard: pasteboard) {
                dispatchImageToAndroid(image)
                return
            }
        }

        // 3. Standard plain text copy
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let hash = computeSHA256(text)
        if hash == lastReceivedHash || hash == lastSentHash { return }
        lastSentHash = hash
        
        let payload = ClipboardPayload(
            type: "clip",
            hash: hash,
            text: text
        )
        broadcastPayload(payload)
        DispatchQueue.main.async { [weak self] in
            self?.onClipboardSynced?(text, true)
        }
    }

    private func dispatchImageToAndroid(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        imageQueue.async { [weak self] in
            guard let self = self else { return }
            guard let (encodedData, mime) = Self.encodeCGImageForSync(cgImage) else { return }

            let hash = computeSHA256(encodedData)
            if hash == self.lastReceivedHash || hash == self.lastSentHash { return }
            self.lastSentHash = hash

            let base64String = encodedData.base64EncodedString()
            let payload = ClipboardPayload(
                type: "image",
                hash: hash,
                text: "[Image]",
                data: base64String,
                mime: mime
            )
            self.broadcastPayload(payload)
            DispatchQueue.main.async { [weak self] in
                self?.onClipboardSynced?("[Image]", true)
            }
        }
    }

    private static func encodeCGImageForSync(_ cgImage: CGImage) -> (Data, String)? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0 && height > 0 else { return nil }

        let maxDim = max(width, height)
        let finalCGImage: CGImage

        if maxDim > maxImageDimension {
            let scale = Double(maxImageDimension) / Double(maxDim)
            let newW = max(1, Int(Double(width) * scale))
            let newH = max(1, Int(Double(height) * scale))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

            if let ctx = CGContext(
                data: nil,
                width: newW,
                height: newH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                finalCGImage = ctx.makeImage() ?? cgImage
            } else {
                finalCGImage = cgImage
            }
        } else {
            finalCGImage = cgImage
        }

        let bitmapRep = NSBitmapImageRep(cgImage: finalCGImage)
        let usePng = bitmapRep.hasAlpha && (finalCGImage.width * finalCGImage.height <= 1_000_000)

        if usePng, let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return (pngData, "image/png")
        }

        if let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) {
            return (jpegData, "image/jpeg")
        }

        if let pngFallback = bitmapRep.representation(using: .png, properties: [:]) {
            return (pngFallback, "image/png")
        }

        return nil
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.checkConnectionsAndSendPing()
        }
    }
    
    private func checkConnectionsAndSendPing() {
        let ping = ClipboardPayload(type: "ping")
        guard let data = try? JSONEncoder().encode(ping) else { return }
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            var staleIds = [UUID]()
            
            // 1. Kick unauthenticated connections that exceed handshake timeout
            for id in self.connections.keys where !self.authenticatedConnections.contains(id) {
                let createdAt = self.connectionCreatedAt[id] ?? 0
                if now - createdAt > Self.unauthHandshakeTimeoutSeconds {
                    NSLog("[BridgeSecurity] Closing timed-out unauthenticated connection")
                    staleIds.append(id)
                }
            }

            // 2. Heartbeat authenticated connections
            for id in self.authenticatedConnections {
                let lastSeen = self.connectionLastSeen[id] ?? 0
                if now - lastSeen > 6.5 {
                    staleIds.append(id)
                } else if let conn = self.connections[id] {
                    self.sendEncryptedData(data, to: conn, id: id) { [weak self, weak conn] error in
                        if error != nil {
                            conn?.cancel()
                            self?.removeConnection(id: id)
                        }
                    }
                } else {
                    staleIds.append(id)
                }
            }
            
            for id in staleIds {
                self.connections[id]?.cancel()
                self.removeConnection(id: id)
            }
        }
    }
    
    private func closeAllConnections() {
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        authenticatedConnections.removeAll()
        pendingHandshakes.removeAll()
        sessionCiphers.removeAll()
        clientDeviceNames.removeAll()
        connectionLastSeen.removeAll()
        connectionCreatedAt.removeAll()
        connectionRemoteIp.removeAll()
        notifyUiStatus()
    }
    
    private func resetPairingSecurityState() {
        handshakeGate.reset()
    }

    func unpairAllDevices() {
        let unpairPayload = ClipboardPayload(type: "unpair")
        broadcastPayload(unpairPayload)
        
        networkQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.closeAllConnections()
            self.resetPairingSecurityState()
            DispatchQueue.main.async {
                self.generateNewPairingCode()
            }
        }
    }
    
    func generateNewPairingCode() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codeFile = home.appendingPathComponent(".bridge_pairing_code")
        let newCode = generateSecureSixDigitCode()
        writeSecurePairingCodeFile(newCode, to: codeFile)
        self.pairingCode = newCode
    }
}
