import Foundation
import AppKit
import Network
import CryptoKit

// MARK: - Protocol Models

struct ClipboardPayload: Codable {
    let type: String          // "clip", "image", "ping", "pong", "hello", "welcome", "denied", "sleep", "unpair"
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

// MARK: - Bridge Server Engine

class BridgeServer {
    let port: NWEndpoint.Port = 8765
    private var listener: NWListener?
    private var connections = [UUID: NWConnection]()
    private var authenticatedConnections = Set<UUID>()
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
    private static let maxFailedAttemptsPerIp = 5
    private static let attemptWindowSeconds: TimeInterval = 60.0
    private static let baseLockoutSeconds: TimeInterval = 60.0
    private static let maxGlobalFailedAttempts = 10
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "bmp", "gif"
    ]

    // Brute-force & replay protection state (accessed on networkQueue)
    private var failedHelloTimestampsByIp = [String: [TimeInterval]]()
    private var ipLockoutUntil = [String: TimeInterval]()
    private var ipLockoutCount = [String: Int]()
    private var globalFailedHelloTimestamps = [TimeInterval]()
    private var globalLockoutUntil: TimeInterval = 0
    private var usedHelloNonces = Set<String>()
    private var usedHelloNonceOrder = [String]()
    
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

    private func isIpLockedOut(_ ip: String, now: TimeInterval) -> Bool {
        if let until = ipLockoutUntil[ip], now < until {
            return true
        }
        return false
    }

    private func recordFailedHelloAttempt(for ip: String, now: TimeInterval) {
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
            globalLockoutUntil = now + 30.0
            globalFailedHelloTimestamps.removeAll()
            NSLog("[BridgeSecurity] Global handshake rate-limit triggered for 30s")
        }
    }

    private func clearFailedAttempts(for ip: String) {
        failedHelloTimestampsByIp.removeValue(forKey: ip)
        ipLockoutUntil.removeValue(forKey: ip)
        ipLockoutCount.removeValue(forKey: ip)
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
    
    private func processPayload(_ data: Data, from conn: NWConnection, id: UUID) {
        let isAuth = self.authenticatedConnections.contains(id)

        // Fast inspect message type from JSON structure
        guard let jsonObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = jsonObject["type"] as? String else {
            if !isAuth {
                NSLog("[BridgeSecurity] Disconnecting unauthenticated client due to malformed JSON")
                conn.cancel()
                self.removeConnection(id: id)
            }
            return
        }
        
        if type == "hello" {
            let now = Date().timeIntervalSince1970
            let remoteIp = self.connectionRemoteIp[id] ?? self.extractRemoteIp(from: conn)

            if self.isIpLockedOut(remoteIp, now: now) {
                NSLog("[BridgeSecurity] Denied 'hello' from rate-limited IP: %@", remoteIp)
                self.denyAndDisconnect(conn, id: id)
                return
            }

            let targetCode = self.pairingCode.replacingOccurrences(of: " ", with: "")
            let incomingHash = (jsonObject["hash"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let clientNonce = (jsonObject["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawCode = (jsonObject["code"] as? String)?
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var isAuthenticated = false

            if !incomingHash.isEmpty && clientNonce.count >= 16 && clientNonce.count <= 128 {
                // Anti-replay check on clientNonce
                if self.usedHelloNonces.contains(clientNonce) {
                    NSLog("[BridgeSecurity] Rejected replayed hello nonce from %@", remoteIp)
                    self.recordFailedHelloAttempt(for: remoteIp, now: now)
                    self.denyAndDisconnect(conn, id: id)
                    return
                }
                let expectedHash = computeSHA256("bridge-hello:\(targetCode):\(clientNonce)")
                if constantTimeEquals(incomingHash, expectedHash) {
                    isAuthenticated = true
                    self.usedHelloNonces.insert(clientNonce)
                    self.usedHelloNonceOrder.append(clientNonce)
                    if self.usedHelloNonceOrder.count > 256 {
                        let oldest = self.usedHelloNonceOrder.removeFirst()
                        self.usedHelloNonces.remove(oldest)
                    }
                }
            } else if incomingHash.isEmpty && !rawCode.isEmpty {
                isAuthenticated = constantTimeEquals(rawCode, targetCode)
            }
            
            if isAuthenticated {
                self.clearFailedAttempts(for: remoteIp)
                self.authenticatedConnections.insert(id)
                let rawDevice = (jsonObject["device"] as? String) ?? "Android Device"
                let sanitizedDevice = String(
                    rawDevice
                        .components(separatedBy: .controlCharacters).joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(64)
                )
                self.clientDeviceNames[id] = sanitizedDevice.isEmpty ? "Android Device" : sanitizedDevice
                
                let macName = Host.current().localizedName ?? "Mac"
                let welcomeProof = clientNonce.isEmpty
                    ? computeSHA256("bridge-welcome:\(targetCode)")
                    : computeSHA256("bridge-welcome:\(targetCode):\(clientNonce)")
                let welcome = ClipboardPayload(type: "welcome", hash: welcomeProof, name: macName)
                self.sendDirect(payload: welcome, to: conn)
                if let settingsStr = BridgeNotificationManager.shared.buildSettingsSyncJson(),
                   var settingsData = settingsStr.data(using: .utf8) {
                    settingsData.append(UInt8(ascii: "\n"))
                    conn.send(content: settingsData, completion: .contentProcessed({ _ in }))
                }
                self.notifyUiStatus()
            } else {
                self.recordFailedHelloAttempt(for: remoteIp, now: now)
                NSLog("[BridgeSecurity] Invalid pairing attempt from %@", remoteIp)
                self.denyAndDisconnect(conn, id: id)
            }
            return
        }
        
        guard isAuth else {
            NSLog("[BridgeSecurity] Rejected unauthenticated message of type '%@' — disconnecting", type)
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
            self.sendDirect(payload: pong, to: conn)
            return
        }

        if type == "pong" {
            return
        }
        
        if type == "unpair" {
            conn.cancel()
            self.removeConnection(id: id)
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
                self.sendDirect(payload: unpairPayload, to: conn)
                self.networkQueue.asyncAfter(deadline: .now() + 0.1) {
                    conn.cancel()
                    self.removeConnection(id: id)
                }
            }
        }
    }
    
    private func sendDirect(payload: ClipboardPayload, to conn: NWConnection) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        conn.send(content: line, completion: .contentProcessed({ _ in }))
    }
    
    private func broadcastPayload(_ payload: ClipboardPayload) {
        guard !authenticatedConnections.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        var line = data
        line.append(UInt8(ascii: "\n"))
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for id in self.authenticatedConnections {
                if let conn = self.connections[id] {
                    conn.send(content: line, completion: .contentProcessed({ _ in }))
                }
            }
        }
    }

    func broadcastRawJson(_ jsonString: String) {
        guard !authenticatedConnections.isEmpty else { return }
        guard var data = jsonString.data(using: .utf8) else { return }
        data.append(UInt8(ascii: "\n"))
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            for id in self.authenticatedConnections {
                if let conn = self.connections[id] {
                    conn.send(content: data, completion: .contentProcessed({ _ in }))
                }
            }
        }
    }

    func sendRawJson(_ jsonString: String, toDeviceId: UUID?) {
        guard var data = jsonString.data(using: .utf8) else { return }
        data.append(UInt8(ascii: "\n"))
        
        networkQueue.async { [weak self] in
            guard let self = self else { return }
            if let targetId = toDeviceId {
                if self.authenticatedConnections.contains(targetId), let conn = self.connections[targetId] {
                    conn.send(content: data, completion: .contentProcessed({ _ in }))
                } else if let firstId = self.authenticatedConnections.first, let conn = self.connections[firstId] {
                    conn.send(content: data, completion: .contentProcessed({ _ in }))
                }
            } else {
                for id in self.authenticatedConnections {
                    if let conn = self.connections[id] {
                        conn.send(content: data, completion: .contentProcessed({ _ in }))
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
        var line = data
        line.append(UInt8(ascii: "\n"))
        
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
                    conn.send(content: line, completion: .contentProcessed({ [weak self, weak conn] error in
                        if error != nil {
                            conn?.cancel()
                            self?.removeConnection(id: id)
                        }
                    }))
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
        clientDeviceNames.removeAll()
        connectionLastSeen.removeAll()
        connectionCreatedAt.removeAll()
        connectionRemoteIp.removeAll()
        notifyUiStatus()
    }
    
    func unpairAllDevices() {
        let unpairPayload = ClipboardPayload(type: "unpair")
        broadcastPayload(unpairPayload)
        
        networkQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.closeAllConnections()
            self.failedHelloTimestampsByIp.removeAll()
            self.ipLockoutUntil.removeAll()
            self.ipLockoutCount.removeAll()
            self.usedHelloNonces.removeAll()
            self.usedHelloNonceOrder.removeAll()
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
