import Foundation
import AppKit
import Network
import CryptoKit

// MARK: - Protocol Models

struct ClipboardPayload: Codable {
    let type: String          // "clip", "ping", "pong", "hello", "welcome", "denied", "sleep"
    let hash: String?         // SHA-256 hex string
    let text: String?         // Plain text content
    let timestamp: Int64      // Milliseconds since epoch
    let code: String?         // Pairing code
    let device: String?       // Device name
    let name: String?         // Server / Host name
}

// MARK: - Helpers

func computeSHA256(_ string: String) -> String {
    let data = Data(string.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
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
    private let networkQueue = DispatchQueue(label: "com.link.bridge.network")
    private let pathMonitor = NWPathMonitor()
    
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
    var onClipboardSynced: ((_ text: String, _ outgoing: Bool) -> Void)?
    var onIpChanged: ((_ ip: String) -> Void)?
    
    init() {
        loadOrGeneratePairingCode()
    }
    
    private func loadOrGeneratePairingCode() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codeFile = home.appendingPathComponent(".bridge_pairing_code")
        
        if let existing = try? String(contentsOf: codeFile, encoding: .utf8) {
            let cleaned = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count == 6 && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: cleaned)) {
                self.pairingCode = cleaned
                return
            }
        }
        
        let newCode = String(format: "%06d", arc4random_uniform(900000) + 100000)
        try? newCode.write(to: codeFile, atomically: true, encoding: .utf8)
        self.pairingCode = newCode
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
            hash: nil,
            text: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            code: nil,
            device: nil,
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
            self.checkPasteboard()
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
            let parameters = NWParameters.tcp
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
    
    private func handleNewConnection(_ conn: NWConnection) {
        let connectionId = UUID()
        networkQueue.async { [weak self, conn] in
            guard let self = self else { return }
            self.connections[connectionId] = conn
            
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self = self, let _ = conn else { return }
                switch state {
                case .ready:
                    self.readNextMessage(from: conn!, id: connectionId, buffer: Data())
                case .failed(_), .cancelled:
                    self.connections.removeValue(forKey: connectionId)
                    self.authenticatedConnections.remove(connectionId)
                    self.clientDeviceNames.removeValue(forKey: connectionId)
                    self.notifyUiStatus()
                default:
                    break
                }
            }
            conn.start(queue: self.networkQueue)
        }
    }
    
    private func readNextMessage(from conn: NWConnection, id: UUID, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] content, _, isComplete, error in
            guard let self = self, let conn = conn else { return }
            var currentBuffer = buffer
            if let data = content, !data.isEmpty {
                currentBuffer.append(data)
                while let newlineIndex = currentBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = currentBuffer.subdata(in: 0..<newlineIndex)
                    currentBuffer.removeSubrange(0...newlineIndex)
                    if !lineData.isEmpty {
                        self.processPayload(lineData, from: conn, id: id)
                    }
                }
            }
            if isComplete || error != nil {
                self.connections.removeValue(forKey: id)
                self.authenticatedConnections.remove(id)
                self.clientDeviceNames.removeValue(forKey: id)
                self.notifyUiStatus()
            } else {
                self.readNextMessage(from: conn, id: id, buffer: currentBuffer)
            }
        }
    }
    
    private func processPayload(_ data: Data, from conn: NWConnection, id: UUID) {
        guard let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data) else { return }
        
        if payload.type == "hello" {
            let incomingCode = payload.code?.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let targetCode = self.pairingCode.replacingOccurrences(of: " ", with: "")
            
            if incomingCode == targetCode {
                self.authenticatedConnections.insert(id)
                let device = payload.device ?? "Android Device"
                self.clientDeviceNames[id] = device
                
                let macName = Host.current().localizedName ?? "Mac"
                let welcome = ClipboardPayload(
                    type: "welcome",
                    hash: nil,
                    text: nil,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    code: nil,
                    device: nil,
                    name: macName
                )
                self.sendDirect(payload: welcome, to: conn)
                self.notifyUiStatus()
            } else {
                let denied = ClipboardPayload(
                    type: "denied",
                    hash: nil,
                    text: nil,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                    code: nil,
                    device: nil,
                    name: nil
                )
                self.sendDirect(payload: denied, to: conn)
            }
            return
        }
        
        guard self.authenticatedConnections.contains(id) else { return }
        
        if payload.type == "ping" {
            let pong = ClipboardPayload(
                type: "pong",
                hash: nil,
                text: nil,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                code: nil,
                device: nil,
                name: nil
            )
            self.sendDirect(payload: pong, to: conn)
            return
        }
        
        if payload.type == "unpair" {
            self.connections.removeValue(forKey: id)
            self.authenticatedConnections.remove(id)
            self.clientDeviceNames.removeValue(forKey: id)
            conn.cancel()
            self.notifyUiStatus()
            return
        }
        
        if payload.type == "clip", let text = payload.text, let hash = payload.hash {
            if hash == self.lastSentHash || hash == self.lastReceivedHash { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastReceivedHash = hash
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                self.lastChangeCount = self.pasteboard.changeCount
                self.onClipboardSynced?(text, false)
            }
        }
    }
    
    private func notifyUiStatus() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let isConnected = !self.authenticatedConnections.isEmpty
            let device = self.clientDeviceNames.values.first
            self.onStatusChanged?(isConnected, device)
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
        
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let hash = computeSHA256(text)
        if hash == lastReceivedHash || hash == lastSentHash { return }
        lastSentHash = hash
        
        let payload = ClipboardPayload(
            type: "clip",
            hash: hash,
            text: text,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            code: nil,
            device: nil,
            name: nil
        )
        broadcastPayload(payload)
        DispatchQueue.main.async { [weak self] in
            self?.onClipboardSynced?(text, true)
        }
    }
    
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: true) { [weak self] _ in
            let ping = ClipboardPayload(
                type: "ping",
                hash: nil,
                text: nil,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                code: nil,
                device: nil,
                name: nil
            )
            self?.broadcastPayload(ping)
        }
    }
    
    private func closeAllConnections() {
        for (_, conn) in connections { conn.cancel() }
        connections.removeAll()
        authenticatedConnections.removeAll()
        clientDeviceNames.removeAll()
        notifyUiStatus()
    }
    
    func unpairAllDevices() {
        let unpairPayload = ClipboardPayload(
            type: "unpair",
            hash: nil,
            text: nil,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            code: nil,
            device: nil,
            name: nil
        )
        broadcastPayload(unpairPayload)
        
        networkQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.closeAllConnections()
            DispatchQueue.main.async {
                self.generateNewPairingCode()
            }
        }
    }
    
    func generateNewPairingCode() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codeFile = home.appendingPathComponent(".bridge_pairing_code")
        let newCode = String(format: "%06d", arc4random_uniform(900000) + 100000)
        try? newCode.write(to: codeFile, atomically: true, encoding: .utf8)
        self.pairingCode = newCode
    }
}
