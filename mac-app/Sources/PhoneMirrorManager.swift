import Foundation
import AppKit
import Network
import Security

enum PhoneMirrorSessionState: Equatable {
    case idle
    case waitingForPhone
    case streaming
    case error(String)
}

/// Manages the dedicated TCP video listener, one-time session token authentication,
/// H.264 decoding, and input forwarding for Option A Phone Mirroring.
final class PhoneMirrorManager: ObservableObject {
    static let shared = PhoneMirrorManager()

    @Published private(set) var stateByDevice: [UUID: PhoneMirrorSessionState] = [:]
    @Published private(set) var activeDeviceId: UUID? = nil
    @Published private(set) var activeDeviceName: String = "Phone"
    @Published private(set) var streamSize: CGSize = CGSize(width: 720, height: 1600)
    @Published var isPhoneScreenDimmed: Bool = true
    @Published var isAlwaysOnTop: Bool = false {
        didSet {
            DispatchQueue.main.async {
                PhoneMirrorWindowController.shared.setAlwaysOnTop(self.isAlwaysOnTop)
            }
        }
    }

    var sendMirrorControl: ((_ payload: [String: Any], _ toDeviceId: UUID) -> Void)?
    var sendMirrorInput: ((_ payload: [String: Any], _ toDeviceId: UUID) -> Void)?

    private let streamQueue = DispatchQueue(label: "com.link.bridge.mirrorstream", qos: .userInteractive)
    private let decoder = PhoneVideoDecoder()

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var activeToken: String?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var receiveBuffer = Data()
    private var isStreamAuthenticated = false
    private var currentMirrorSessionTokenId = UUID()

    private init() {
        decoder.onFrameDecoded = { [weak self] image, width, height in
            guard let self = self else { return }
            let size = CGSize(width: width, height: height)
            DispatchQueue.main.async {
                if self.activeDeviceId != nil {
                    if self.currentState(for: self.activeDeviceId!) != .streaming,
                       let devId = self.activeDeviceId {
                        self.stateByDevice[devId] = .streaming
                    }
                    if self.streamSize != size {
                        self.streamSize = size
                    }
                    PhoneMirrorWindowController.shared.updateFrame(image, videoSize: size)
                }
            }
        }

        decoder.onKeyframeNeeded = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let devId = self.activeDeviceId else { return }
                self.sendMirrorControl?(["action": "request_keyframe"], devId)
            }
        }
    }

    func currentState(for deviceId: UUID) -> PhoneMirrorSessionState {
        return stateByDevice[deviceId] ?? .idle
    }

    func isMirroringOrPending(deviceId: UUID) -> Bool {
        switch currentState(for: deviceId) {
        case .waitingForPhone, .streaming:
            return true
        case .idle, .error:
            return false
        }
    }

    func toggleMirroring(for device: ConnectedDeviceInfo) {
        if isMirroringOrPending(deviceId: device.id) {
            stopMirroring(deviceId: device.id, notifyDevice: true)
        } else {
            startMirroring(deviceId: device.id, deviceName: device.name, action: "request_start")
        }
    }

    private func startMirroring(deviceId: UUID, deviceName: String, action: String) {
        if let existingId = activeDeviceId, existingId != deviceId {
            stopMirroring(deviceId: existingId, notifyDevice: true)
        }

        let token = generateRandomTokenHex(byteCount: 32)
        let sessionTag = UUID()
        currentMirrorSessionTokenId = sessionTag

        activeDeviceId = deviceId
        activeDeviceName = deviceName
        isPhoneScreenDimmed = true
        stateByDevice[deviceId] = .waitingForPhone
        decoder.reset()

        PhoneMirrorWindowController.shared.show(
            deviceName: deviceName,
            initialSize: streamSize,
            alwaysOnTop: isAlwaysOnTop,
            isDimmed: isPhoneScreenDimmed
        )

        startListener(token: token, sessionTag: sessionTag) { [weak self] listeningPort in
            DispatchQueue.main.async {
                guard let self = self, self.currentMirrorSessionTokenId == sessionTag else { return }
                guard let port = listeningPort else {
                    self.setError(for: deviceId, message: "Could not open mirror stream port.")
                    return
                }
                self.sendMirrorControl?([
                    "action": action,
                    "port": Int(port),
                    "token": token,
                    "maxDimension": 1280,
                    "bitRate": 5_000_000,
                    "fps": 60
                ], deviceId)
            }
        }
    }

    func stopMirroring(deviceId: UUID? = nil, notifyDevice: Bool = true) {
        let targetId = deviceId ?? activeDeviceId
        if let id = targetId {
            if notifyDevice {
                sendMirrorControl?(["action": "stop"], id)
            }
            if activeDeviceId == id {
                activeDeviceId = nil
                currentMirrorSessionTokenId = UUID()
                tearDownNetwork()
                decoder.reset()
                PhoneMirrorWindowController.shared.closeWindow()
            }
            stateByDevice[id] = .idle
        }
    }

    func handleDeviceDisconnected(deviceId: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.activeDeviceId == deviceId || self.stateByDevice[deviceId] != nil {
                self.stopMirroring(deviceId: deviceId, notifyDevice: false)
                self.stateByDevice.removeValue(forKey: deviceId)
            }
        }
    }

    func handleControlMessage(_ jsonObject: [String: Any], fromDeviceId deviceId: UUID, deviceName: String) {
        let action = (jsonObject["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case "request_offer":
                self.startMirroring(deviceId: deviceId, deviceName: deviceName, action: "stream_offer")
            case "status":
                let state = (jsonObject["state"] as? String)?.lowercased() ?? ""
                let reason = jsonObject["reason"] as? String
                if state == "streaming" {
                    if self.activeDeviceId == deviceId {
                        self.stateByDevice[deviceId] = .streaming
                        if let w = jsonObject["width"] as? Int, let h = jsonObject["height"] as? Int, w > 0, h > 0 {
                            let newSize = CGSize(width: w, height: h)
                            self.streamSize = newSize
                            PhoneMirrorWindowController.shared.updateStreamSize(newSize)
                        }
                    }
                } else if state == "stopped" {
                    let message: String? = (reason == "permission_denied") ? "Screen capture permission denied on \(deviceName)." : nil
                    if self.activeDeviceId == deviceId {
                        self.activeDeviceId = nil
                        self.currentMirrorSessionTokenId = UUID()
                        self.tearDownNetwork()
                        self.decoder.reset()
                        PhoneMirrorWindowController.shared.closeWindow()
                    }
                    if let errMsg = message {
                        self.setError(for: deviceId, message: errMsg)
                    } else {
                        self.stateByDevice[deviceId] = .idle
                    }
                }
            default:
                break
            }
        }
    }

    private func setError(for deviceId: UUID, message: String) {
        if activeDeviceId == deviceId {
            activeDeviceId = nil
            tearDownNetwork()
            decoder.reset()
            PhoneMirrorWindowController.shared.closeWindow()
        }
        stateByDevice[deviceId] = .error(message)
        let capturedId = deviceId
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            if case .error = self?.stateByDevice[capturedId] {
                self?.stateByDevice[capturedId] = .idle
            }
        }
    }

    // MARK: - Input Dispatch

    func sendTap(normPoint: CGPoint) {
        guard let devId = activeDeviceId else { return }
        sendMirrorInput?([
            "action": "tap",
            "xNorm": Double(normPoint.x),
            "yNorm": Double(normPoint.y)
        ], devId)
    }

    func sendLongPress(normPoint: CGPoint) {
        guard let devId = activeDeviceId else { return }
        sendMirrorInput?([
            "action": "long_press",
            "xNorm": Double(normPoint.x),
            "yNorm": Double(normPoint.y)
        ], devId)
    }

    func sendSwipe(from start: CGPoint, to end: CGPoint, durationMs: Int) {
        guard let devId = activeDeviceId else { return }
        sendMirrorInput?([
            "action": "swipe",
            "startXNorm": Double(start.x),
            "startYNorm": Double(start.y),
            "endXNorm": Double(end.x),
            "endYNorm": Double(end.y),
            "durationMs": max(60, min(1200, durationMs))
        ], devId)
    }

    func sendGlobalAction(_ globalAction: String) {
        guard let devId = activeDeviceId else { return }
        sendMirrorInput?([
            "action": "global",
            "globalAction": globalAction
        ], devId)
    }

    func sendText(_ text: String) {
        guard let devId = activeDeviceId, !text.isEmpty else { return }
        sendMirrorInput?([
            "action": "text",
            "text": text
        ], devId)
    }

    func sendKeyAction(_ keyAction: String) {
        guard let devId = activeDeviceId else { return }
        sendMirrorInput?([
            "action": "key",
            "keyAction": keyAction
        ], devId)
    }

    func togglePhoneScreenDimmed() {
        isPhoneScreenDimmed.toggle()
        let next = isPhoneScreenDimmed
        DispatchQueue.main.async {
            PhoneMirrorWindowController.shared.updateDimButtonAppearance(next)
        }
        guard let devId = activeDeviceId else { return }
        sendMirrorControl?([
            "action": "set_dim",
            "dimmed": next
        ], devId)
    }

    // MARK: - Ephemeral TCP Video Receiver

    private func startListener(token: String, sessionTag: UUID, onPortReady: @escaping (UInt16?) -> Void) {
        streamQueue.async { [weak self] in
            guard let self = self else { return }
            self.tearDownNetworkSync()
            self.activeToken = token

            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            do {
                let newListener = try NWListener(using: params, on: .any)
                self.listener = newListener
                var notifiedReady = false

                newListener.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        if !notifiedReady {
                            notifiedReady = true
                            let portVal = newListener.port?.rawValue
                            onPortReady(portVal)
                        }
                    case .failed(_):
                        if !notifiedReady {
                            notifiedReady = true
                            onPortReady(nil)
                        }
                        DispatchQueue.main.async {
                            if self.currentMirrorSessionTokenId == sessionTag, let devId = self.activeDeviceId {
                                self.setError(for: devId, message: "Mirror listener failed.")
                            }
                        }
                    default:
                        break
                    }
                }

                newListener.newConnectionHandler = { [weak self] conn in
                    self?.handleIncomingStreamConnection(conn, sessionTag: sessionTag)
                }

                newListener.start(queue: self.streamQueue)
            } catch {
                NSLog("[PhoneMirror] Failed starting listener: %@", error.localizedDescription)
                onPortReady(nil)
            }
        }
    }

    private func handleIncomingStreamConnection(_ conn: NWConnection, sessionTag: UUID) {
        let remoteIp = extractRemoteIp(from: conn)
        guard remoteIp == "local" || isLocalOrPrivateIp(remoteIp) else {
            NSLog("[PhoneMirrorSecurity] Rejected mirror stream from non-private IP: %@", remoteIp)
            conn.cancel()
            return
        }

        guard activeConnection == nil else {
            conn.cancel()
            return
        }

        activeConnection = conn
        receiveBuffer.removeAll(keepingCapacity: true)
        isStreamAuthenticated = false

        let timeout = DispatchWorkItem { [weak self, weak conn] in
            guard let self = self else { return }
            if !self.isStreamAuthenticated {
                NSLog("[PhoneMirrorSecurity] Mirror stream handshake timeout")
                conn?.cancel()
            }
        }
        handshakeTimeoutWorkItem = timeout
        streamQueue.asyncAfter(deadline: .now() + 10.0, execute: timeout)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            switch state {
            case .ready:
                self.readStreamBytes(from: conn, sessionTag: sessionTag)
            case .failed(_), .cancelled:
                conn.cancel()
                if self.activeConnection === conn {
                    self.activeConnection = nil
                    DispatchQueue.main.async {
                        if self.currentMirrorSessionTokenId == sessionTag, let devId = self.activeDeviceId {
                            self.stopMirroring(deviceId: devId, notifyDevice: false)
                        }
                    }
                }
            default:
                break
            }
        }

        conn.start(queue: streamQueue)
    }

    private func readStreamBytes(from conn: NWConnection, sessionTag: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn else { return }
            if let chunk = data, !chunk.isEmpty {
                self.receiveBuffer.append(chunk)
                if !self.processReceiveBuffer(on: conn, sessionTag: sessionTag) {
                    return
                }
            }

            if isComplete || error != nil {
                conn.cancel()
                return
            }

            if self.activeConnection === conn {
                self.readStreamBytes(from: conn, sessionTag: sessionTag)
            }
        }
    }

    private func processReceiveBuffer(on conn: NWConnection, sessionTag: UUID) -> Bool {
        if !isStreamAuthenticated {
            guard receiveBuffer.count >= PhoneMirrorHandshake.byteLength else {
                return true
            }
            let handshakeSlice = receiveBuffer.subdata(in: 0..<PhoneMirrorHandshake.byteLength)
            receiveBuffer.removeSubrange(0..<PhoneMirrorHandshake.byteLength)

            guard let handshake = PhoneMirrorHandshake.parse(from: handshakeSlice),
                  let expectedToken = activeToken,
                  constantTimeEquals(handshake.token, expectedToken) else {
                NSLog("[PhoneMirrorSecurity] Rejected unauthenticated mirror stream handshake")
                conn.cancel()
                return false
            }

            isStreamAuthenticated = true
            handshakeTimeoutWorkItem?.cancel()
            handshakeTimeoutWorkItem = nil

            let initialSize = CGSize(width: handshake.width, height: handshake.height)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.currentMirrorSessionTokenId == sessionTag, let devId = self.activeDeviceId else {
                    return
                }
                self.streamSize = initialSize
                self.stateByDevice[devId] = .streaming
                PhoneMirrorWindowController.shared.updateStreamSize(initialSize)
            }
        }

        while receiveBuffer.count >= PhoneMirrorPacketHeader.byteLength {
            let headerData = receiveBuffer.subdata(in: 0..<PhoneMirrorPacketHeader.byteLength)
            guard let header = PhoneMirrorPacketHeader.parse(from: headerData) else {
                NSLog("[PhoneMirror] Malformed packet header, closing stream")
                conn.cancel()
                return false
            }

            let totalPacketLen = PhoneMirrorPacketHeader.byteLength + header.length
            guard receiveBuffer.count >= totalPacketLen else {
                break
            }

            let payload = header.length > 0
                ? receiveBuffer.subdata(in: PhoneMirrorPacketHeader.byteLength..<totalPacketLen)
                : Data()
            receiveBuffer.removeSubrange(0..<totalPacketLen)

            switch header.type {
            case .config:
                decoder.feedConfig(payload)
            case .frame:
                decoder.feedFrame(payload, ptsUs: header.ptsUs, isKeyframe: header.isKeyframe)
            case .geometry:
                if let geom = PhoneMirrorGeometry.parse(from: payload) {
                    let newSize = CGSize(width: geom.width, height: geom.height)
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.currentMirrorSessionTokenId == sessionTag else { return }
                        self.streamSize = newSize
                        PhoneMirrorWindowController.shared.updateStreamSize(newSize)
                    }
                }
            }
        }
        return true
    }

    private func tearDownNetwork() {
        streamQueue.async { [weak self] in
            self?.tearDownNetworkSync()
        }
    }

    private func tearDownNetworkSync() {
        handshakeTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem = nil
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        activeToken = nil
        isStreamAuthenticated = false
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

    private func generateRandomTokenHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
