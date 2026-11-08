import Foundation
import AppKit
import Network
import CryptoKit
import UserNotifications

class BridgeFileTransferManager: ObservableObject {
    static let shared = BridgeFileTransferManager()

    @Published var transfers: [FileTransferItem] = []
    @Published var autoAcceptIncomingFiles: Bool {
        didSet {
            UserDefaults.standard.set(autoAcceptIncomingFiles, forKey: Self.keyAutoAcceptFiles)
            if !isApplyingRemoteSettings {
                onAutoAcceptChanged?()
            }
        }
    }
    var isApplyingRemoteSettings = false
    var onAutoAcceptChanged: (() -> Void)?

    var sendControlMessage: ((_ jsonString: String, _ targetDeviceId: UUID?) -> Void)?
    var onTransferListChanged: (() -> Void)?

    private static let keyAutoAcceptFiles = "bridge_file_auto_accept"
    private static let keyCustomSaveLocation = "bridge_file_custom_save_location"
    private static let chunkSize = 64 * 1024 // 64 KB chunk size for hardware-accelerated AES-GCM framing
    private static let hashChunkSize = 1024 * 1024 // 1 MB
    private static let minFreeDiskSpaceMargin: Int64 = 100 * 1024 * 1024 // 100 MB safety buffer
    private static let maxConcurrentChunksInFlight = 4 // Keep TCP pipeline full without blocking on completion

    @Published var customSavePath: String? {
        didSet {
            if let path = customSavePath, !path.isEmpty {
                UserDefaults.standard.set(path, forKey: Self.keyCustomSaveLocation)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.keyCustomSaveLocation)
            }
        }
    }

    var customSaveDirectory: URL? {
        get {
            guard let path = customSavePath, !path.isEmpty else { return nil }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
            return nil
        }
        set {
            customSavePath = newValue?.path
        }
    }

    var effectiveSaveDirectory: URL {
        if let custom = customSaveDirectory {
            return custom
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var hasCustomSaveLocation: Bool {
        return customSaveDirectory != nil
    }

    var saveLocationDisplayName: String {
        if let custom = customSaveDirectory {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if custom.path == home {
                return "~ (Home)"
            } else if custom.path.hasPrefix(home) {
                return "~" + custom.path.dropFirst(home.count)
            }
            return custom.path
        }
        return "Downloads (~/Downloads)"
    }

    func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Location to Save Files"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = effectiveSaveDirectory

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            DispatchQueue.main.async {
                self.customSaveDirectory = url
                self.objectWillChange.send()
                self.onTransferListChanged?()
            }
        }
    }

    func resetSaveLocation() {
        DispatchQueue.main.async {
            self.customSaveDirectory = nil
            self.objectWillChange.send()
            self.onTransferListChanged?()
        }
    }

    private let transferQueue = DispatchQueue(label: "com.link.bridge.filetransfer", qos: .userInitiated)
    private let hashQueue = DispatchQueue(label: "com.link.bridge.filehash", qos: .utility, attributes: .concurrent)

    private struct ActiveSession {
        let transferId: String
        let token: String
        let aesKey: SymmetricKey
        let listener: NWListener
        var connection: NWConnection?
        var fileHandle: FileHandle?
        var isCancelled: Bool = false
        var isPaused: Bool = false
        var lastSpeedCalcTime: TimeInterval = Date().timeIntervalSince1970
        var bytesSinceLastSpeedCalc: Int64 = 0
        var chunksInFlight: Int = 0
        var incomingBuffer: Data = Data()
    }

    private var activeSessions = [String: ActiveSession]()

    private init() {
        if UserDefaults.standard.object(forKey: Self.keyAutoAcceptFiles) == nil {
            self.autoAcceptIncomingFiles = true
        } else {
            self.autoAcceptIncomingFiles = UserDefaults.standard.bool(forKey: Self.keyAutoAcceptFiles)
        }
        self.customSavePath = UserDefaults.standard.string(forKey: Self.keyCustomSaveLocation)
        self.onAutoAcceptChanged = {
            BridgeNotificationManager.shared.recordLocalSettingsChangeAndSync()
        }
    }

    static func deriveAesKey(token: String) -> SymmetricKey {
        let keyData = (token + ":bridge-file-encryption").data(using: .utf8) ?? Data()
        let hash = SHA256.hash(data: keyData)
        return SymmetricKey(data: hash)
    }

    // MARK: - Public Outgoing API (Mac -> Android)

    func sendFiles(urls: [URL], to device: ConnectedDeviceInfo) {
        NSLog("[BridgeFile] sendFiles: %ld URLs to %@", urls.count, device.name)
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
                  fileSize > 0 else {
                continue
            }

            let transferId = "tx_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let cleanName = Self.sanitizeFileName(url.lastPathComponent)

            let item = FileTransferItem(
                id: transferId,
                fileName: cleanName,
                fileSize: fileSize,
                expectedSha256: "",
                direction: .outgoing,
                deviceId: device.id,
                deviceName: device.name,
                sourceUrl: url,
                status: .hashing
            )

            DispatchQueue.main.async {
                self.transfers.insert(item, at: 0)
                self.onTransferListChanged?()
            }

            hashQueue.async { [weak self] in
                guard let self = self else { return }
                guard let sha256 = Self.computeFileSHA256(url: url, shouldAbort: {
                    return item.status == .cancelled
                }) else {
                    DispatchQueue.main.async {
                        if item.status != .cancelled {
                            item.status = .failed("Failed to read file")
                        }
                    }
                    return
                }

                DispatchQueue.main.async {
                    guard item.status != .cancelled else { return }
                    item.expectedSha256 = sha256
                    item.status = .waitingConfirmation
                    self.startOutgoingListenerAndOffer(item: item, isResume: false)
                }
            }
        }
    }

    private func startOutgoingListenerAndOffer(item: FileTransferItem, isResume: Bool) {
        transferQueue.async { [weak self] in
            guard let self = self else { return }
            self.cleanupSession(transferId: item.id)

            let token = Self.generateSecureToken()
            let tcpParams = NWParameters.tcp
            tcpParams.serviceClass = .responsiveData
            if let tcpOpts = tcpParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOpts.noDelay = true
            }

            guard let listener = try? NWListener(using: tcpParams, on: .any) else {
                DispatchQueue.main.async {
                    item.status = .failed("Could not open data port")
                }
                return
            }

            let aesKey = Self.deriveAesKey(token: token)
            let session = ActiveSession(
                transferId: item.id,
                token: token,
                aesKey: aesKey,
                listener: listener,
                connection: nil,
                fileHandle: nil
            )
            self.activeSessions[item.id] = session

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    let offerDict: [String: Any] = [
                        "type": "file_offer",
                        "id": item.id,
                        "name": item.fileName,
                        "size": item.fileSize,
                        "sha256": item.expectedSha256,
                        "port": Int(port),
                        "token": token,
                        "resume": isResume
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: offerDict),
                       let jsonStr = String(data: data, encoding: .utf8) {
                        self.sendControlMessage?(jsonStr, item.deviceId)
                    }
                case .failed:
                    self.cleanupSession(transferId: item.id)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                self.handleOutgoingDataConnection(conn, for: item)
            }

            listener.start(queue: self.transferQueue)
        }
    }

    private func handleOutgoingDataConnection(_ conn: NWConnection, for item: FileTransferItem) {
        guard var session = activeSessions[item.id], session.connection == nil else {
            conn.cancel()
            return
        }

        let remoteHost = Self.extractRemoteIp(from: conn.endpoint)
        if !isLocalOrPrivateIp(remoteHost) {
            conn.cancel()
            return
        }

        session.connection = conn
        activeSessions[item.id] = session
        conn.start(queue: transferQueue)

        // Enforce 5-second authentication timeout
        transferQueue.asyncAfter(deadline: .now() + 5.0) { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            if let current = self.activeSessions[item.id], current.fileHandle == nil {
                conn.cancel()
            }
        }

        readHandshakeHeader(from: conn, buffer: Data()) { [weak self] headerJson, _ in
            guard let self = self else { return }
            guard var currentSession = self.activeSessions[item.id],
                  let dict = try? JSONSerialization.jsonObject(with: headerJson) as? [String: Any],
                  let clientToken = dict["token"] as? String,
                  let clientId = dict["id"] as? String,
                  clientId == item.id,
                  constantTimeEquals(clientToken, currentSession.token) else {
                conn.cancel()
                return
            }

            let offset = (dict["offset"] as? NSNumber)?.int64Value ?? 0
            guard let sourceUrl = item.sourceUrl,
                  let fh = try? FileHandle(forReadingFrom: sourceUrl) else {
                conn.cancel()
                self.failTransfer(item: item, reason: "Cannot open source file")
                return
            }

            if offset > 0 && offset < item.fileSize {
                try? fh.seek(toOffset: UInt64(offset))
            }

            currentSession.fileHandle = fh
            currentSession.lastSpeedCalcTime = Date().timeIntervalSince1970
            currentSession.bytesSinceLastSpeedCalc = 0
            currentSession.chunksInFlight = 0
            self.activeSessions[item.id] = currentSession

            DispatchQueue.main.async {
                item.bytesTransferred = offset
                item.status = .transferring
            }

            self.pumpOutgoingChunks(transferId: item.id, item: item, currentBytes: offset)
        }
    }

    private func pumpOutgoingChunks(transferId: String, item: FileTransferItem, currentBytes: Int64) {
        guard var session = activeSessions[transferId],
              !session.isCancelled,
              !session.isPaused,
              let conn = session.connection,
              let fh = session.fileHandle else {
            return
        }

        var runningBytes = currentBytes
        while session.chunksInFlight < Self.maxConcurrentChunksInFlight {
            let chunkData: Data? = autoreleasepool {
                return try? fh.read(upToCount: Self.chunkSize)
            }

            guard let data = chunkData, !data.isEmpty else {
                // Reached EOF; if all in-flight chunks are also completed, finalize
                if session.chunksInFlight == 0 {
                    try? fh.close()
                    session.fileHandle = nil
                    activeSessions[transferId] = session
                    DispatchQueue.main.async {
                        item.bytesTransferred = item.fileSize
                        item.speedBytesPerSec = 0
                        item.status = .verifying
                    }
                }
                return
            }

            let sentCount = Int64(data.count)
            runningBytes += sentCount
            let chunkBytesForTotal = runningBytes

            session.chunksInFlight += 1
            session.bytesSinceLastSpeedCalc += sentCount
            let now = Date().timeIntervalSince1970
            let elapsed = now - session.lastSpeedCalcTime
            var computedSpeed: Double? = nil
            if elapsed >= 0.25 {
                computedSpeed = Double(session.bytesSinceLastSpeedCalc) / elapsed
                session.lastSpeedCalcTime = now
                session.bytesSinceLastSpeedCalc = 0
            }
            activeSessions[transferId] = session

            DispatchQueue.main.async {
                item.bytesTransferred = chunkBytesForTotal
                if let spd = computedSpeed {
                    item.speedBytesPerSec = spd
                }
            }

            // Encrypt chunk using AES-256-GCM hardware acceleration
            guard let sealed = try? AES.GCM.seal(data, using: session.aesKey),
                  let combined = sealed.combined else {
                self.failTransfer(item: item, reason: "Encryption error")
                return
            }

            var frame = Data()
            var lenBig = UInt32(combined.count).bigEndian
            frame.append(Data(bytes: &lenBig, count: 4))
            frame.append(combined)

            conn.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                self.transferQueue.async {
                    guard var current = self.activeSessions[transferId] else { return }
                    current.chunksInFlight = max(0, current.chunksInFlight - 1)
                    self.activeSessions[transferId] = current

                    if error != nil {
                        if !current.isPaused && !current.isCancelled {
                            self.cleanupSession(transferId: transferId)
                            DispatchQueue.main.async {
                                if item.status == .transferring {
                                    item.status = .paused
                                    item.speedBytesPerSec = 0
                                }
                            }
                        }
                        return
                    }

                    // Pump next available chunks now that capacity has freed up
                    self.pumpOutgoingChunks(transferId: transferId, item: item, currentBytes: chunkBytesForTotal)
                }
            })
        }
    }

    // MARK: - Incoming File Request & Streaming (Android -> Mac)

    func handleControlMessage(_ jsonObject: [String: Any], fromDeviceId: UUID, deviceName: String) {
        guard let type = jsonObject["type"] as? String else { return }
        NSLog("[BridgeFile] handleControlMessage: type=%@, id=%@", type, (jsonObject["id"] as? String) ?? "")

        switch type {
        case "file_request":
            guard let id = jsonObject["id"] as? String,
                  let rawName = jsonObject["name"] as? String,
                  let size = (jsonObject["size"] as? NSNumber)?.int64Value,
                  size > 0 else { return }
            let sha256 = (jsonObject["sha256"] as? String) ?? ""
            let cleanName = Self.sanitizeFileName(rawName)

            if !Self.hasEnoughDiskSpace(requiredBytes: size) {
                sendReject(id: id, reason: "insufficient_space", to: fromDeviceId)
                return
            }

            DispatchQueue.main.async {
                if let existing = self.transfers.first(where: { $0.id == id }) {
                    // Resuming existing incoming transfer
                    self.acceptIncomingTransfer(existing)
                    return
                }

                let targetDir = self.effectiveSaveDirectory
                let partUrl = targetDir.appendingPathComponent(".\(cleanName).\(id.prefix(8)).part")

                let item = FileTransferItem(
                    id: id,
                    fileName: cleanName,
                    fileSize: size,
                    expectedSha256: sha256,
                    direction: .incoming,
                    deviceId: fromDeviceId,
                    deviceName: deviceName,
                    partUrl: partUrl,
                    status: .waitingConfirmation
                )
                self.transfers.insert(item, at: 0)
                self.onTransferListChanged?()

                let shouldAutoAccept = self.autoAcceptIncomingFiles && !item.isExecutable
                NSLog("[BridgeFile] file_request for '%@', autoAccept=%d, isExec=%d -> shouldAutoAccept=%d", cleanName, self.autoAcceptIncomingFiles ? 1 : 0, item.isExecutable ? 1 : 0, shouldAutoAccept ? 1 : 0)
                if shouldAutoAccept {
                    self.acceptIncomingTransfer(item)
                } else {
                    self.postIncomingTransferBanner(item)
                }
            }

        case "file_pause":
            guard let id = jsonObject["id"] as? String else { return }
            pauseTransfer(id: id, notifyPeer: false)

        case "file_resume":
            guard let id = jsonObject["id"] as? String else { return }
            resumeTransfer(id: id, notifyPeer: false)

        case "file_cancel":
            guard let id = jsonObject["id"] as? String else { return }
            cancelTransfer(id: id, notifyPeer: false)

        case "file_complete":
            guard let id = jsonObject["id"] as? String else { return }
            transferQueue.async {
                self.cleanupSession(transferId: id)
            }
            DispatchQueue.main.async {
                if let item = self.transfers.first(where: { $0.id == id }) {
                    item.bytesTransferred = item.fileSize
                    item.speedBytesPerSec = 0
                    item.completedAt = Date()
                    item.status = .completed
                    self.onTransferListChanged?()
                }
            }

        case "file_error":
            guard let id = jsonObject["id"] as? String else { return }
            let reason = (jsonObject["reason"] as? String) ?? "Transfer failed"
            transferQueue.async {
                self.cleanupSession(transferId: id)
            }
            DispatchQueue.main.async {
                if let item = self.transfers.first(where: { $0.id == id }) {
                    item.speedBytesPerSec = 0
                    item.status = .failed(reason)
                    self.onTransferListChanged?()
                }
            }

        default:
            break
        }
    }

    func acceptIncomingTransfer(_ item: FileTransferItem) {
        dismissTransferBanner(id: item.id)
        transferQueue.async { [weak self] in
            guard let self = self else { return }
            self.cleanupSession(transferId: item.id)

            let token = Self.generateSecureToken()
            let tcpParams = NWParameters.tcp
            tcpParams.serviceClass = .responsiveData
            if let tcpOpts = tcpParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOpts.noDelay = true
            }

            guard let listener = try? NWListener(using: tcpParams, on: .any) else {
                DispatchQueue.main.async {
                    item.status = .failed("Could not open data port")
                }
                return
            }

            var existingOffset: Int64 = 0
            if let partUrl = item.partUrl,
               FileManager.default.fileExists(atPath: partUrl.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: partUrl.path),
               let fileSize = (attrs[.size] as? NSNumber)?.int64Value {
                if fileSize < item.fileSize {
                    existingOffset = fileSize
                } else {
                    try? FileManager.default.removeItem(at: partUrl)
                }
            }

            let aesKey = Self.deriveAesKey(token: token)
            let session = ActiveSession(
                transferId: item.id,
                token: token,
                aesKey: aesKey,
                listener: listener,
                connection: nil,
                fileHandle: nil
            )
            self.activeSessions[item.id] = session

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    let acceptDict: [String: Any] = [
                        "type": "file_accept",
                        "id": item.id,
                        "port": Int(port),
                        "token": token,
                        "offset": existingOffset
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: acceptDict),
                       let jsonStr = String(data: data, encoding: .utf8) {
                        self.sendControlMessage?(jsonStr, item.deviceId)
                    }
                case .failed:
                    self.cleanupSession(transferId: item.id)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                self.handleIncomingDataConnection(conn, for: item)
            }

            listener.start(queue: self.transferQueue)
        }
    }

    private func handleIncomingDataConnection(_ conn: NWConnection, for item: FileTransferItem) {
        guard var session = activeSessions[item.id], session.connection == nil else {
            conn.cancel()
            return
        }

        let remoteHost = Self.extractRemoteIp(from: conn.endpoint)
        if !isLocalOrPrivateIp(remoteHost) {
            conn.cancel()
            return
        }

        session.connection = conn
        activeSessions[item.id] = session
        conn.start(queue: transferQueue)

        transferQueue.asyncAfter(deadline: .now() + 5.0) { [weak self, weak conn] in
            guard let self = self, let conn = conn else { return }
            if let current = self.activeSessions[item.id], current.fileHandle == nil {
                conn.cancel()
            }
        }

        readHandshakeHeader(from: conn, buffer: Data()) { [weak self] headerJson, remainingBytes in
            guard let self = self else { return }
            guard var currentSession = self.activeSessions[item.id],
                  let dict = try? JSONSerialization.jsonObject(with: headerJson) as? [String: Any],
                  let clientToken = dict["token"] as? String,
                  let clientId = dict["id"] as? String,
                  clientId == item.id,
                  constantTimeEquals(clientToken, currentSession.token),
                  let partUrl = item.partUrl else {
                conn.cancel()
                return
            }

            let offset = (dict["offset"] as? NSNumber)?.int64Value ?? 0
            if offset == 0 || !FileManager.default.fileExists(atPath: partUrl.path) {
                FileManager.default.createFile(atPath: partUrl.path, contents: nil)
            }

            guard let fh = try? FileHandle(forWritingTo: partUrl) else {
                conn.cancel()
                self.failTransfer(item: item, reason: "Cannot create file in \(self.effectiveSaveDirectory.lastPathComponent)")
                return
            }

            if offset > 0 {
                _ = try? fh.seekToEnd()
            }

            let currentReceived = offset
            currentSession.fileHandle = fh
            currentSession.lastSpeedCalcTime = Date().timeIntervalSince1970
            currentSession.bytesSinceLastSpeedCalc = 0
            if !remainingBytes.isEmpty {
                currentSession.incomingBuffer.append(remainingBytes)
            }
            self.activeSessions[item.id] = currentSession

            self.dismissTransferBanner(id: item.id)

            DispatchQueue.main.async {
                item.bytesTransferred = currentReceived
                item.status = .transferring
            }

            self.receiveNextIncomingChunk(transferId: item.id, item: item, currentBytes: currentReceived)
        }
    }

    private func receiveNextIncomingChunk(transferId: String, item: FileTransferItem, currentBytes: Int64) {
        guard let session = activeSessions[transferId],
              !session.isCancelled,
              !session.isPaused,
              let conn = session.connection else {
            return
        }

        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.chunkSize + 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            guard var currentSession = self.activeSessions[transferId],
                  !currentSession.isCancelled,
                  !currentSession.isPaused,
                  let fh = currentSession.fileHandle else {
                return
            }

            var updatedBytes = currentBytes
            if let chunk = data, !chunk.isEmpty {
                currentSession.incomingBuffer.append(chunk)

                var decryptedBytesThisRound: Int64 = 0
                while currentSession.incomingBuffer.count >= 4 {
                    let frameLen = Int(currentSession.incomingBuffer.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
                    guard frameLen > 28 && frameLen <= (Self.chunkSize + 2048) else {
                        self.failTransfer(item: item, reason: "Corrupted encrypted frame")
                        return
                    }

                    let totalRequired = 4 + frameLen
                    if currentSession.incomingBuffer.count < totalRequired {
                        break
                    }

                    let framePayload = currentSession.incomingBuffer.subdata(in: 4..<totalRequired)
                    currentSession.incomingBuffer.removeSubrange(0..<totalRequired)

                    do {
                        let sealedBox = try AES.GCM.SealedBox(combined: framePayload)
                        let plaintext = try AES.GCM.open(sealedBox, using: currentSession.aesKey)

                        if updatedBytes + Int64(plaintext.count) > item.fileSize {
                            self.failTransfer(item: item, reason: "Exceeded declared file size")
                            return
                        }

                        try fh.write(contentsOf: plaintext)
                        updatedBytes += Int64(plaintext.count)
                        decryptedBytesThisRound += Int64(plaintext.count)
                    } catch {
                        self.failTransfer(item: item, reason: "Decryption or authenticity verification failed")
                        return
                    }
                }

                if decryptedBytesThisRound > 0 {
                    let now = Date().timeIntervalSince1970
                    currentSession.bytesSinceLastSpeedCalc += decryptedBytesThisRound
                    let elapsed = now - currentSession.lastSpeedCalcTime
                    var computedSpeed: Double? = nil
                    if elapsed >= 0.25 {
                        computedSpeed = Double(currentSession.bytesSinceLastSpeedCalc) / elapsed
                        currentSession.lastSpeedCalcTime = now
                        currentSession.bytesSinceLastSpeedCalc = 0
                    }

                    DispatchQueue.main.async {
                        item.bytesTransferred = updatedBytes
                        if let spd = computedSpeed {
                            item.speedBytesPerSec = spd
                        }
                    }
                }

                self.activeSessions[transferId] = currentSession
            }

            if updatedBytes >= item.fileSize {
                self.finalizeIncomingFile(item: item)
            } else if isComplete || error != nil {
                self.cleanupSession(transferId: transferId)
                DispatchQueue.main.async {
                    if item.status == .transferring {
                        item.status = .paused
                        item.speedBytesPerSec = 0
                    }
                }
            } else {
                self.receiveNextIncomingChunk(transferId: transferId, item: item, currentBytes: updatedBytes)
            }
        }
    }

    private func finalizeIncomingFile(item: FileTransferItem) {
        cleanupSession(transferId: item.id)

        guard let partUrl = item.partUrl else {
            failTransfer(item: item, reason: "Missing staging file")
            return
        }

        DispatchQueue.main.async {
            item.bytesTransferred = item.fileSize
            item.speedBytesPerSec = 0
            item.status = .verifying
        }

        hashQueue.async { [weak self] in
            guard let self = self else { return }
            if !item.expectedSha256.isEmpty {
                guard let computedHash = Self.computeFileSHA256(url: partUrl, shouldAbort: { false }),
                      computedHash.lowercased() == item.expectedSha256.lowercased() else {
                    try? FileManager.default.removeItem(at: partUrl)
                    self.failTransfer(item: item, reason: "SHA-256 integrity check failed")
                    return
                }
            }

            let targetDir = self.effectiveSaveDirectory
            let finalUrl = Self.uniqueDestinationUrl(in: targetDir, fileName: item.fileName)

            do {
                try FileManager.default.moveItem(at: partUrl, to: finalUrl)
            } catch {
                self.failTransfer(item: item, reason: "Could not move file to destination folder")
                return
            }

            let completeDict: [String: Any] = [
                "type": "file_complete",
                "id": item.id
            ]
            if let data = try? JSONSerialization.data(withJSONObject: completeDict),
               let jsonStr = String(data: data, encoding: .utf8) {
                self.sendControlMessage?(jsonStr, item.deviceId)
            }

            DispatchQueue.main.async {
                item.destinationUrl = finalUrl
                item.completedAt = Date()
                item.status = .completed
                self.onTransferListChanged?()
                self.postFileReceivedNotification(fileName: finalUrl.lastPathComponent, deviceName: item.deviceName, isExecutable: item.isExecutable)
            }
        }
    }

    // MARK: - Pause / Resume / Cancel

    func pauseTransfer(id: String, notifyPeer: Bool = true) {
        transferQueue.async { [weak self] in
            guard let self = self else { return }
            if var session = self.activeSessions[id] {
                session.isPaused = true
                self.activeSessions[id] = session
            }
            self.cleanupSession(transferId: id)
        }

        DispatchQueue.main.async {
            guard let item = self.transfers.first(where: { $0.id == id }) else { return }
            item.status = .paused
            item.speedBytesPerSec = 0
            if notifyPeer {
                let dict: [String: Any] = ["type": "file_pause", "id": id]
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let str = String(data: data, encoding: .utf8) {
                    self.sendControlMessage?(str, item.deviceId)
                }
            }
            self.onTransferListChanged?()
        }
    }

    func resumeTransfer(id: String, notifyPeer: Bool = true) {
        DispatchQueue.main.async {
            guard let item = self.transfers.first(where: { $0.id == id }) else { return }
            item.status = .waitingConfirmation
            item.speedBytesPerSec = 0

            if item.direction == .outgoing {
                self.startOutgoingListenerAndOffer(item: item, isResume: true)
            } else {
                self.acceptIncomingTransfer(item)
            }
            self.onTransferListChanged?()
        }
    }

    func cancelTransfer(id: String, notifyPeer: Bool = true) {
        dismissTransferBanner(id: id)
        transferQueue.async { [weak self] in
            guard let self = self else { return }
            if var session = self.activeSessions[id] {
                session.isCancelled = true
                self.activeSessions[id] = session
            }
            self.cleanupSession(transferId: id)
        }

        DispatchQueue.main.async {
            guard let item = self.transfers.first(where: { $0.id == id }) else { return }
            if let partUrl = item.partUrl {
                try? FileManager.default.removeItem(at: partUrl)
            }
            item.status = .cancelled
            item.speedBytesPerSec = 0
            if notifyPeer {
                let dict: [String: Any] = ["type": "file_cancel", "id": id]
                if let data = try? JSONSerialization.data(withJSONObject: dict),
                   let str = String(data: data, encoding: .utf8) {
                    self.sendControlMessage?(str, item.deviceId)
                }
            }
            self.onTransferListChanged?()
        }
    }

    func clearCompletedTransfers() {
        DispatchQueue.main.async {
            self.transfers.removeAll { $0.status == .completed }
            self.onTransferListChanged?()
        }
    }

    func clearFinishedTransfers() {
        clearCompletedTransfers()
    }

    func retryTransfer(id: String) {
        guard let item = transfers.first(where: { $0.id == id }) else { return }
        if item.direction == .outgoing, let url = item.sourceUrl {
            let targetDev = ConnectedDeviceInfo(
                id: item.deviceId ?? UUID(),
                name: item.deviceName,
                ip: nil,
                isConnected: true
            )
            DispatchQueue.main.async {
                self.transfers.removeAll { $0.id == id }
                self.onTransferListChanged?()
            }
            sendFiles(urls: [url], to: targetDev)
        } else {
            DispatchQueue.main.async {
                item.status = .waitingConfirmation
                item.bytesTransferred = 0
                item.speedBytesPerSec = 0
                self.onTransferListChanged?()
            }
            let dict: [String: Any] = ["type": "file_resume", "id": id]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: data, encoding: .utf8) {
                self.sendControlMessage?(str, item.deviceId)
            }
        }
    }

    func dismissTransfer(id: String) {
        cancelTransfer(id: id, notifyPeer: false)
        DispatchQueue.main.async {
            self.transfers.removeAll { $0.id == id }
            self.onTransferListChanged?()
        }
    }

    // MARK: - Helpers

    private func readHandshakeHeader(
        from conn: NWConnection,
        buffer: Data,
        completion: @escaping (_ headerData: Data, _ remainingBytes: Data) -> Void
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var currentBuffer = buffer
            if let d = data, !d.isEmpty {
                currentBuffer.append(d)
                if currentBuffer.count > 8192 {
                    conn.cancel()
                    return
                }
                if let newlineIndex = currentBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let headerData = currentBuffer.subdata(in: 0..<newlineIndex)
                    let remaining = currentBuffer.subdata(in: (newlineIndex + 1)..<currentBuffer.count)
                    completion(headerData, remaining)
                    return
                }
            }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.readHandshakeHeader(from: conn, buffer: currentBuffer, completion: completion)
        }
    }

    private func cleanupSession(transferId: String) {
        if let session = activeSessions.removeValue(forKey: transferId) {
            try? session.fileHandle?.close()
            session.connection?.cancel()
            session.listener.cancel()
        }
    }

    private func failTransfer(item: FileTransferItem, reason: String) {
        cleanupSession(transferId: item.id)
        let dict: [String: Any] = ["type": "file_error", "id": item.id, "reason": reason]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            sendControlMessage?(str, item.deviceId)
        }
        DispatchQueue.main.async {
            item.speedBytesPerSec = 0
            item.status = .failed(reason)
            self.onTransferListChanged?()
        }
    }

    private func sendReject(id: String, reason: String, to deviceId: UUID) {
        let dict: [String: Any] = ["type": "file_error", "id": id, "reason": reason]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            sendControlMessage?(str, deviceId)
        }
    }

    func postIncomingTransferBanner(_ item: FileTransferItem) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Incoming File from \(item.deviceName)"
        let formattedSize = ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
        if item.isExecutable {
            content.body = "⚠️ \"\(item.fileName)\" (\(formattedSize))\nExecutable file · Confirm before accepting."
        } else {
            content.body = "\"\(item.fileName)\" (\(formattedSize))"
        }
        content.sound = .default
        content.userInfo = ["transfer_id": item.id]

        let acceptAction = UNNotificationAction(
            identifier: "file_accept_\(item.id)",
            title: "Accept",
            options: []
        )
        let declineAction = UNNotificationAction(
            identifier: "file_decline_\(item.id)",
            title: "Decline",
            options: [.destructive]
        )

        let categoryId = "cat_file_\(item.id)"
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [acceptAction, declineAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        content.categoryIdentifier = categoryId

        center.getNotificationCategories { existing in
            var updated = existing
            updated.insert(category)
            center.setNotificationCategories(updated)

            let req = UNNotificationRequest(
                identifier: "bridge.transfer.\(item.id)",
                content: content,
                trigger: nil
            )
            center.add(req) { error in
                if let error = error {
                    NSLog("[BridgeFile] Error posting incoming transfer banner: \(error.localizedDescription)")
                }
            }
        }
    }

    func dismissTransferBanner(id: String) {
        let reqId = "bridge.transfer.\(id)"
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [reqId])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reqId])
        let categoryId = "cat_file_\(id)"
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let updated = existing.filter { $0.identifier != categoryId }
            UNUserNotificationCenter.current().setNotificationCategories(updated)
        }
    }

    private func postFileReceivedNotification(fileName: String, deviceName: String, isExecutable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "File Received from \(deviceName)"
        let locName = hasCustomSaveLocation ? effectiveSaveDirectory.lastPathComponent : "Downloads"
        if isExecutable {
            content.body = "⚠️ Saved \"\(fileName)\" to \(locName) · Executable file."
        } else {
            content.body = "Saved \"\(fileName)\" to \(locName)"
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: "bridge.file.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    static func computeFileSHA256(url: URL, shouldAbort: () -> Bool) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }

        var hasher = SHA256()

        // For large files (> 500 MB), calculate a fast representative digest from key sampling windows
        // (Header 4MB + Middle 4MB + Tail 4MB + File Size) to avoid stalling flash storage and CPU
        if fileSize > 500 * 1024 * 1024 {
            let sampleSize: UInt64 = 4 * 1024 * 1024
            hasher.update(data: Data("SPARSE_V1_\(fileSize)".utf8))

            // Sample 1: First 4 MB
            if let headChunk = try? fh.read(upToCount: Int(sampleSize)), !headChunk.isEmpty {
                hasher.update(data: headChunk)
            }
            if shouldAbort() { return nil }

            // Sample 2: Middle 4 MB
            let midOffset = UInt64(max(0, (fileSize / 2) - Int64(sampleSize / 2)))
            try? fh.seek(toOffset: midOffset)
            if let midChunk = try? fh.read(upToCount: Int(sampleSize)), !midChunk.isEmpty {
                hasher.update(data: midChunk)
            }
            if shouldAbort() { return nil }

            // Sample 3: Last 4 MB
            let tailOffset = UInt64(max(0, fileSize - Int64(sampleSize)))
            try? fh.seek(toOffset: tailOffset)
            if let tailChunk = try? fh.read(upToCount: Int(sampleSize)), !tailChunk.isEmpty {
                hasher.update(data: tailChunk)
            }

            let digest = hasher.finalize()
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        // Standard sequential hash for files <= 500 MB
        while true {
            if shouldAbort() { return nil }
            let chunk: Data? = autoreleasepool {
                return try? fh.read(upToCount: Self.hashChunkSize)
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizeFileName(_ raw: String) -> String {
        let trimmed = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "_")
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var safe = trimmed
        while safe.hasPrefix(".") {
            safe.removeFirst()
        }
        if safe.isEmpty || safe == ".." {
            return "file_\(Int(Date().timeIntervalSince1970))"
        }
        return String(safe.prefix(200))
    }

    static func uniqueDestinationUrl(in folder: URL, fileName: String) -> URL {
        let baseDestination = folder.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: baseDestination.path) {
            return baseDestination
        }
        let nsName = fileName as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        for counter in 1...9999 {
            let candidateName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            let candidateUrl = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidateUrl.path) {
                return candidateUrl
            }
        }
        return folder.appendingPathComponent("\(UUID().uuidString.prefix(6))_\(fileName)")
    }

    static func hasEnoughDiskSpace(requiredBytes: Int64) -> Bool {
        let targetUrl = BridgeFileTransferManager.shared.effectiveSaveDirectory
        if let values = try? targetUrl.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            return available >= (requiredBytes + Self.minFreeDiskSpaceMargin)
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: targetUrl.path),
           let freeSpace = (attrs[.systemFreeSize] as? NSNumber)?.int64Value {
            return freeSpace >= (requiredBytes + Self.minFreeDiskSpaceMargin)
        }
        return true
    }

    static func generateSecureToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func extractRemoteIp(from endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return ""
        }
    }
}
