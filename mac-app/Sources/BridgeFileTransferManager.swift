import Foundation
import AppKit
import Network
import CryptoKit
import UserNotifications
import zlib

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
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                continue
            }
            let isFolder = isDir.boolValue
            let transferId = "tx_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let cleanName = Self.sanitizeFileName(url.lastPathComponent)

            if isFolder {
                let item = FileTransferItem(
                    id: transferId,
                    fileName: cleanName,
                    fileSize: 0,
                    expectedSha256: "",
                    direction: .outgoing,
                    deviceId: device.id,
                    deviceName: device.name,
                    sourceUrl: url,
                    isFolder: true,
                    status: .hashing
                )

                DispatchQueue.main.async {
                    self.transfers.insert(item, at: 0)
                    self.onTransferListChanged?()
                }

                hashQueue.async { [weak self] in
                    guard let self = self else { return }
                    switch Self.packageFolderToZip(folderUrl: url, transferId: transferId, shouldAbort: {
                        return item.status == .cancelled
                    }) {
                    case .failure(let err):
                        DispatchQueue.main.async {
                            if item.status != .cancelled {
                                item.status = .failed(err.localizedDescription)
                                self.onTransferListChanged?()
                            }
                        }
                    case .success(let result):
                        DispatchQueue.main.async {
                            guard item.status != .cancelled else {
                                try? FileManager.default.removeItem(at: result.zipUrl)
                                return
                            }
                            item.tempArchiveUrl = result.zipUrl
                            item.fileSize = result.size
                            item.expectedSha256 = result.sha256
                            item.status = .waitingConfirmation
                            self.startOutgoingListenerAndOffer(item: item, isResume: false)
                        }
                    }
                }
            } else {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
                      fileSize > 0 else {
                    continue
                }

                let item = FileTransferItem(
                    id: transferId,
                    fileName: cleanName,
                    fileSize: fileSize,
                    expectedSha256: "",
                    direction: .outgoing,
                    deviceId: device.id,
                    deviceName: device.name,
                    sourceUrl: url,
                    isFolder: false,
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
                        "resume": isResume,
                        "isFolder": item.isFolder
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
            let readUrl = item.tempArchiveUrl ?? item.sourceUrl
            guard let sourceUrl = readUrl,
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
            let isFolder = (jsonObject["isFolder"] as? Bool) ?? false
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
                    isFolder: isFolder,
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

            if item.isFolder {
                let success = Self.extractFolderArchive(archiveUrl: partUrl, destinationFolderUrl: finalUrl)
                try? FileManager.default.removeItem(at: partUrl)
                guard success else {
                    self.failTransfer(item: item, reason: "Could not extract folder archive")
                    return
                }
            } else {
                do {
                    try FileManager.default.moveItem(at: partUrl, to: finalUrl)
                } catch {
                    self.failTransfer(item: item, reason: "Could not move file to destination folder")
                    return
                }
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
                self.postFileReceivedNotification(fileName: finalUrl.lastPathComponent, deviceName: item.deviceName, isFolder: item.isFolder, isExecutable: item.isExecutable)
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
            if let temp = item.tempArchiveUrl {
                try? FileManager.default.removeItem(at: temp)
                item.tempArchiveUrl = nil
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let item = self.transfers.first(where: { $0.id == transferId }),
               item.status.isFinished,
               let temp = item.tempArchiveUrl {
                try? FileManager.default.removeItem(at: temp)
                item.tempArchiveUrl = nil
            }
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
        content.title = item.isFolder ? "Incoming Folder from \(item.deviceName)" : "Incoming File from \(item.deviceName)"
        let formattedSize = ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
        if item.isExecutable {
            content.body = "⚠️ \"\(item.fileName)\" (\(formattedSize))\nExecutable file · Confirm before accepting."
        } else if item.isFolder {
            content.body = "Folder \"\(item.fileName)\" (\(formattedSize))"
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

    private func postFileReceivedNotification(fileName: String, deviceName: String, isFolder: Bool, isExecutable: Bool) {
        let content = UNMutableNotificationContent()
        content.title = isFolder ? "Folder Received from \(deviceName)" : "File Received from \(deviceName)"
        let locName = hasCustomSaveLocation ? effectiveSaveDirectory.lastPathComponent : "Downloads"
        if isExecutable {
            content.body = "⚠️ Saved \"\(fileName)\" to \(locName) · Executable file."
        } else if isFolder {
            content.body = "Saved folder \"\(fileName)\" to \(locName)"
        } else {
            content.body = "Saved \"\(fileName)\" to \(locName)"
        }
        content.sound = .default
        let req = UNNotificationRequest(identifier: "bridge.file.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - In-Process Fast Zip Packaging Engine

    private class BridgeZipWriter {
        struct Entry {
            let path: String
            let isDirectory: Bool
            let uncompressedSize: UInt64
            let crc: UInt32
            let headerOffset: UInt64
            let modTime: UInt16
            let modDate: UInt16
        }

        private let outHandle: FileHandle
        private var entries: [Entry] = []
        private var currentOffset: UInt64 = 0
        private let shouldAbort: () -> Bool

        init(url: URL, shouldAbort: @escaping () -> Bool = { false }) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.outHandle = try FileHandle(forWritingTo: url)
            self.shouldAbort = shouldAbort
        }

        deinit {
            try? outHandle.close()
        }

        func addDirectory(relPath: String, modDate: Date = Date()) throws {
            guard !shouldAbort() else { throw NSError(domain: "BridgeZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aborted"]) }
            let cleanPath = relPath.hasSuffix("/") ? relPath : "\(relPath)/"
            let pathBytes = [UInt8](cleanPath.utf8)
            let (dosDate, dosTime) = toDosTime(modDate)

            let headerOffset = currentOffset
            var header = Data()
            header.append(contentsOf: [0x50, 0x4b, 0x03, 0x04]) // PK\3\4
            header.append(contentsOf: [20, 0]) // version needed
            header.append(contentsOf: [0x00, 0x08]) // flags (UTF-8)
            header.append(contentsOf: [0, 0]) // store
            header.append(contentsOf: [UInt8(dosTime & 0xFF), UInt8((dosTime >> 8) & 0xFF)])
            header.append(contentsOf: [UInt8(dosDate & 0xFF), UInt8((dosDate >> 8) & 0xFF)])
            header.append(contentsOf: [0, 0, 0, 0]) // crc
            header.append(contentsOf: [0, 0, 0, 0]) // comp size
            header.append(contentsOf: [0, 0, 0, 0]) // uncomp size
            header.append(contentsOf: [UInt8(pathBytes.count & 0xFF), UInt8((pathBytes.count >> 8) & 0xFF)])
            header.append(contentsOf: [0, 0]) // extra len
            header.append(contentsOf: pathBytes)

            try outHandle.write(contentsOf: header)
            currentOffset += UInt64(header.count)

            entries.append(Entry(
                path: cleanPath,
                isDirectory: true,
                uncompressedSize: 0,
                crc: 0,
                headerOffset: headerOffset,
                modTime: dosTime,
                modDate: dosDate
            ))
        }

        func addFile(fileUrl: URL, relPath: String) throws {
            guard !shouldAbort() else { throw NSError(domain: "BridgeZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aborted"]) }
            let pathBytes = [UInt8](relPath.utf8)
            let attrs = try FileManager.default.attributesOfItem(atPath: fileUrl.path)
            let modDate = (attrs[.modificationDate] as? Date) ?? Date()
            let (dosDate, dosTime) = toDosTime(modDate)

            guard let inHandle = try? FileHandle(forReadingFrom: fileUrl) else {
                return
            }
            defer { try? inHandle.close() }

            let headerOffset = currentOffset
            var header = Data()
            header.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            header.append(contentsOf: [45, 0]) // version needed: 4.5 (Zip64 capable)
            header.append(contentsOf: [0x00, 0x08]) // flags (UTF-8)
            header.append(contentsOf: [0, 0]) // store
            header.append(contentsOf: [UInt8(dosTime & 0xFF), UInt8((dosTime >> 8) & 0xFF)])
            header.append(contentsOf: [UInt8(dosDate & 0xFF), UInt8((dosDate >> 8) & 0xFF)])

            // Placeholder for crc, compSize, uncompSize (12 bytes)
            let placeholderOffset = header.count
            header.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

            // Zip64 extra field placeholder (tag=0x0001, size=16, 8 bytes uncomp, 8 bytes comp)
            let zip64LocalExtra: [UInt8] = [
                0x01, 0x00, // Tag 0x0001
                0x10, 0x00, // Size 16 bytes
                0, 0, 0, 0, 0, 0, 0, 0, // Uncompressed size
                0, 0, 0, 0, 0, 0, 0, 0  // Compressed size
            ]
            let extraLen = UInt16(zip64LocalExtra.count)
            let zip64PlaceholderOffset = placeholderOffset + 12 + 2 + 2 + pathBytes.count

            header.append(contentsOf: [UInt8(pathBytes.count & 0xFF), UInt8((pathBytes.count >> 8) & 0xFF)])
            header.append(contentsOf: [UInt8(extraLen & 0xFF), UInt8((extraLen >> 8) & 0xFF)])
            header.append(contentsOf: pathBytes)
            header.append(contentsOf: zip64LocalExtra)

            try outHandle.write(contentsOf: header)
            currentOffset += UInt64(header.count)

            var crc: uLong = crc32(0, nil, 0)
            let bufferSize = 256 * 1024
            var totalBytesWritten: UInt64 = 0

            while true {
                guard !shouldAbort() else { throw NSError(domain: "BridgeZip", code: -1, userInfo: [NSLocalizedDescriptionKey: "Aborted"]) }
                let chunk = inHandle.readData(ofLength: bufferSize)
                if chunk.isEmpty { break }
                chunk.withUnsafeBytes { ptr in
                    crc = crc32(crc, ptr.bindMemory(to: Bytef.self).baseAddress, uInt(chunk.count))
                }
                try outHandle.write(contentsOf: chunk)
                totalBytesWritten += UInt64(chunk.count)
            }

            let endOffset = currentOffset + totalBytesWritten
            let crcUint = UInt32(crc)

            // Patch standard 32-bit fields
            try outHandle.seek(toOffset: UInt64(headerOffset + UInt64(placeholderOffset)))
            var patch = Data()
            patch.append(contentsOf: [UInt8(crcUint & 0xFF), UInt8((crcUint >> 8) & 0xFF), UInt8((crcUint >> 16) & 0xFF), UInt8((crcUint >> 24) & 0xFF)])
            let standardSize32 = totalBytesWritten >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(totalBytesWritten)
            patch.append(contentsOf: [UInt8(standardSize32 & 0xFF), UInt8((standardSize32 >> 8) & 0xFF), UInt8((standardSize32 >> 16) & 0xFF), UInt8((standardSize32 >> 24) & 0xFF)])
            patch.append(contentsOf: [UInt8(standardSize32 & 0xFF), UInt8((standardSize32 >> 8) & 0xFF), UInt8((standardSize32 >> 16) & 0xFF), UInt8((standardSize32 >> 24) & 0xFF)])
            try outHandle.write(contentsOf: patch)

            // Patch Zip64 extra field with 64-bit sizes
            try outHandle.seek(toOffset: UInt64(headerOffset + UInt64(zip64PlaceholderOffset) + 4))
            var zip64Patch = Data()
            withUnsafeBytes(of: totalBytesWritten.littleEndian) { zip64Patch.append(contentsOf: $0) }
            withUnsafeBytes(of: totalBytesWritten.littleEndian) { zip64Patch.append(contentsOf: $0) }
            try outHandle.write(contentsOf: zip64Patch)

            try outHandle.seek(toOffset: UInt64(endOffset))
            currentOffset = endOffset

            entries.append(Entry(
                path: relPath,
                isDirectory: false,
                uncompressedSize: totalBytesWritten,
                crc: crcUint,
                headerOffset: headerOffset,
                modTime: dosTime,
                modDate: dosDate
            ))
        }

        func finish() throws {
            let centralStart = currentOffset
            var centralData = Data()

            for entry in entries {
                let pathBytes = [UInt8](entry.path.utf8)
                let isZip64 = entry.uncompressedSize >= 0xFFFFFFFF || entry.headerOffset >= 0xFFFFFFFF

                centralData.append(contentsOf: [0x50, 0x4b, 0x01, 0x02]) // PK\1\2
                centralData.append(contentsOf: [0x1e, 0x03]) // version made by (Unix)
                centralData.append(contentsOf: [isZip64 ? 45 : 20, 0]) // version needed
                centralData.append(contentsOf: [0x00, 0x08]) // UTF-8
                centralData.append(contentsOf: [0, 0]) // store
                centralData.append(contentsOf: [UInt8(entry.modTime & 0xFF), UInt8((entry.modTime >> 8) & 0xFF)])
                centralData.append(contentsOf: [UInt8(entry.modDate & 0xFF), UInt8((entry.modDate >> 8) & 0xFF)])
                centralData.append(contentsOf: [UInt8(entry.crc & 0xFF), UInt8((entry.crc >> 8) & 0xFF), UInt8((entry.crc >> 16) & 0xFF), UInt8((entry.crc >> 24) & 0xFF)])

                let size32 = entry.uncompressedSize >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(entry.uncompressedSize)
                let offset32 = entry.headerOffset >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(entry.headerOffset)
                centralData.append(contentsOf: [UInt8(size32 & 0xFF), UInt8((size32 >> 8) & 0xFF), UInt8((size32 >> 16) & 0xFF), UInt8((size32 >> 24) & 0xFF)])
                centralData.append(contentsOf: [UInt8(size32 & 0xFF), UInt8((size32 >> 8) & 0xFF), UInt8((size32 >> 16) & 0xFF), UInt8((size32 >> 24) & 0xFF)])
                centralData.append(contentsOf: [UInt8(pathBytes.count & 0xFF), UInt8((pathBytes.count >> 8) & 0xFF)])

                var extraData = Data()
                if isZip64 {
                    extraData.append(contentsOf: [0x01, 0x00]) // Tag 0x0001
                    var fieldLen: UInt16 = 0
                    var fieldData = Data()
                    if entry.uncompressedSize >= 0xFFFFFFFF {
                        withUnsafeBytes(of: entry.uncompressedSize.littleEndian) { fieldData.append(contentsOf: $0) }
                        withUnsafeBytes(of: entry.uncompressedSize.littleEndian) { fieldData.append(contentsOf: $0) }
                        fieldLen += 16
                    }
                    if entry.headerOffset >= 0xFFFFFFFF {
                        withUnsafeBytes(of: entry.headerOffset.littleEndian) { fieldData.append(contentsOf: $0) }
                        fieldLen += 8
                    }
                    extraData.append(contentsOf: [UInt8(fieldLen & 0xFF), UInt8((fieldLen >> 8) & 0xFF)])
                    extraData.append(fieldData)
                }

                centralData.append(contentsOf: [UInt8(extraData.count & 0xFF), UInt8((extraData.count >> 8) & 0xFF)])
                centralData.append(contentsOf: [0, 0, 0, 0, 0, 0]) // comment len, disk start, internal attrs
                let extAttrs: UInt32 = entry.isDirectory ? 0x41ED0010 : 0x81A40000
                centralData.append(contentsOf: [UInt8(extAttrs & 0xFF), UInt8((extAttrs >> 8) & 0xFF), UInt8((extAttrs >> 16) & 0xFF), UInt8((extAttrs >> 24) & 0xFF)])
                centralData.append(contentsOf: [UInt8(offset32 & 0xFF), UInt8((offset32 >> 8) & 0xFF), UInt8((offset32 >> 16) & 0xFF), UInt8((offset32 >> 24) & 0xFF)])
                centralData.append(contentsOf: pathBytes)
                centralData.append(extraData)
            }

            try outHandle.write(contentsOf: centralData)
            currentOffset += UInt64(centralData.count)
            let centralSize = UInt64(centralData.count)

            let needsZip64Eocd = centralStart >= 0xFFFFFFFF || centralSize >= 0xFFFFFFFF || entries.count >= 0xFFFF
            if needsZip64Eocd {
                let zip64EocdOffset = currentOffset
                var zip64Eocd = Data()
                zip64Eocd.append(contentsOf: [0x50, 0x4b, 0x06, 0x06]) // PK\6\6
                withUnsafeBytes(of: UInt64(44).littleEndian) { zip64Eocd.append(contentsOf: $0) }
                zip64Eocd.append(contentsOf: [0x1e, 0x03]) // version made by
                zip64Eocd.append(contentsOf: [45, 0]) // version needed
                zip64Eocd.append(contentsOf: [0, 0, 0, 0]) // disk number
                zip64Eocd.append(contentsOf: [0, 0, 0, 0]) // disk start
                withUnsafeBytes(of: UInt64(entries.count).littleEndian) { zip64Eocd.append(contentsOf: $0) }
                withUnsafeBytes(of: UInt64(entries.count).littleEndian) { zip64Eocd.append(contentsOf: $0) }
                withUnsafeBytes(of: centralSize.littleEndian) { zip64Eocd.append(contentsOf: $0) }
                withUnsafeBytes(of: centralStart.littleEndian) { zip64Eocd.append(contentsOf: $0) }

                // Zip64 locator
                zip64Eocd.append(contentsOf: [0x50, 0x4b, 0x06, 0x07]) // PK\6\7
                zip64Eocd.append(contentsOf: [0, 0, 0, 0]) // disk number
                withUnsafeBytes(of: zip64EocdOffset.littleEndian) { zip64Eocd.append(contentsOf: $0) }
                zip64Eocd.append(contentsOf: [1, 0, 0, 0]) // total disks

                try outHandle.write(contentsOf: zip64Eocd)
                currentOffset += UInt64(zip64Eocd.count)
            }

            // Standard End of central directory record
            var eocd = Data()
            eocd.append(contentsOf: [0x50, 0x4b, 0x05, 0x06]) // PK\5\6
            eocd.append(contentsOf: [0, 0, 0, 0]) // disk numbers
            let countField = UInt16(min(entries.count, 0xFFFF))
            eocd.append(contentsOf: [UInt8(countField & 0xFF), UInt8((countField >> 8) & 0xFF)])
            eocd.append(contentsOf: [UInt8(countField & 0xFF), UInt8((countField >> 8) & 0xFF)])
            let centralSize32 = centralSize >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(centralSize)
            let centralStart32 = centralStart >= 0xFFFFFFFF ? 0xFFFFFFFF : UInt32(centralStart)
            eocd.append(contentsOf: [UInt8(centralSize32 & 0xFF), UInt8((centralSize32 >> 8) & 0xFF), UInt8((centralSize32 >> 16) & 0xFF), UInt8((centralSize32 >> 24) & 0xFF)])
            eocd.append(contentsOf: [UInt8(centralStart32 & 0xFF), UInt8((centralStart32 >> 8) & 0xFF), UInt8((centralStart32 >> 16) & 0xFF), UInt8((centralStart32 >> 24) & 0xFF)])
            eocd.append(contentsOf: [0, 0]) // comment len

            try outHandle.write(contentsOf: eocd)
            try outHandle.synchronize()
        }

        private func toDosTime(_ date: Date) -> (UInt16, UInt16) {
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let year = max(1980, comps.year ?? 1980) - 1980
            let month = comps.month ?? 1
            let day = comps.day ?? 1
            let hour = comps.hour ?? 0
            let minute = comps.minute ?? 0
            let second = (comps.second ?? 0) / 2

            let dosDate = UInt16((year << 9) | (month << 5) | day)
            let dosTime = UInt16((hour << 11) | (minute << 5) | second)
            return (dosDate, dosTime)
        }
    }

    // MARK: - Folder Packaging & Extraction

    enum BridgePackageError: LocalizedError {
        case permissionDenied
        case cancelled
        case empty
        case hashFailed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Permission denied · Allow in System Settings"
            case .cancelled:
                return "Cancelled"
            case .empty:
                return "Generated archive was empty"
            case .hashFailed:
                return "Integrity hashing failed"
            case .failed(let msg):
                return msg
            }
        }
    }

    var isFilesAndFoldersAllowed: Bool {
        guard let docsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return true }
        return (try? FileManager.default.contentsOfDirectory(atPath: docsUrl.path)) != nil
    }

    func openFilesAndFoldersSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(fallback)
        }
    }

    static func isIgnoredMetadataItem(name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".ds_store" || lower == "thumbs.db" || lower == "desktop.ini" { return true }
        if lower == "__macosx" || lower == ".trashes" || lower == ".spotlight-v100" ||
           lower == ".fseventsd" || lower == ".temporaryitems" || lower == ".apdisk" { return true }
        if name.hasPrefix("._") || name.hasPrefix(".~") { return true }
        return false
    }

    static func packageFolderToZip(folderUrl: URL, transferId: String, shouldAbort: @escaping () -> Bool) -> Result<(zipUrl: URL, size: Int64, sha256: String), BridgePackageError> {
        let tempZipName = "bridge_pkg_\(transferId).zip"
        let tempZipUrl = FileManager.default.temporaryDirectory.appendingPathComponent(tempZipName)
        try? FileManager.default.removeItem(at: tempZipUrl)

        let isAccessing = folderUrl.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                folderUrl.stopAccessingSecurityScopedResource()
            }
        }

        // Test readability first to distinguish permission issues from other failures
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folderUrl.path)
        } catch {
            let nsErr = error as NSError
            if nsErr.code == 257 || nsErr.localizedDescription.contains("permission") {
                return .failure(.permissionDenied)
            }
            return .failure(.failed("Cannot open folder: \(error.localizedDescription)"))
        }

        let startTime = Date()
        NSLog("[BridgeFile] packageFolderToZip starting for '%@'...", folderUrl.path)

        do {
            let writer = try BridgeZipWriter(url: tempZipUrl, shouldAbort: shouldAbort)
            let parentName = folderUrl.lastPathComponent

            // Add top-level folder entry
            try writer.addDirectory(relPath: parentName)

            let baseFolderPrefix = folderUrl.standardized.path.hasSuffix("/")
                ? folderUrl.standardized.path
                : "\(folderUrl.standardized.path)/"

            let enumerator = FileManager.default.enumerator(
                at: folderUrl,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            var entryCount = 0
            while let itemUrl = enumerator?.nextObject() as? URL {
                if shouldAbort() {
                    try? FileManager.default.removeItem(at: tempZipUrl)
                    return .failure(.cancelled)
                }

                let isDir = (try? itemUrl.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

                // Exclude OS metadata files & folders (.DS_Store, __MACOSX, Thumbs.db, etc.)
                let name = itemUrl.lastPathComponent
                if isIgnoredMetadataItem(name: name) {
                    if isDir {
                        enumerator?.skipDescendants()
                    }
                    continue
                }

                let standardPath = itemUrl.standardized.path
                var cleanRel = standardPath
                if cleanRel.hasPrefix(baseFolderPrefix) {
                    cleanRel = String(cleanRel.dropFirst(baseFolderPrefix.count))
                }
                guard !cleanRel.isEmpty else { continue }
                let zipRelPath = "\(parentName)/\(cleanRel)"

                if isDir {
                    try writer.addDirectory(relPath: zipRelPath)
                } else {
                    try writer.addFile(fileUrl: itemUrl, relPath: zipRelPath)
                    entryCount += 1
                }
            }

            try writer.finish()
            let duration = Date().timeIntervalSince(startTime)
            NSLog("[BridgeFile] packageFolderToZip finished in %.2fs (%ld files)", duration, entryCount)
        } catch {
            NSLog("[BridgeFile] packageFolderToZip error: %@", error.localizedDescription)
            try? FileManager.default.removeItem(at: tempZipUrl)
            return .failure(.failed("Failed to package folder: \(error.localizedDescription)"))
        }

        if shouldAbort() {
            try? FileManager.default.removeItem(at: tempZipUrl)
            return .failure(.cancelled)
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempZipUrl.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            try? FileManager.default.removeItem(at: tempZipUrl)
            return .failure(.empty)
        }

        guard let sha256 = computeFileSHA256(url: tempZipUrl, shouldAbort: shouldAbort) else {
            try? FileManager.default.removeItem(at: tempZipUrl)
            return .failure(.hashFailed)
        }

        return .success((tempZipUrl, size, sha256))
    }

    static func extractFolderArchive(archiveUrl: URL, destinationFolderUrl: URL) -> Bool {
        let tempExtractDir = FileManager.default.temporaryDirectory.appendingPathComponent("bridge_ext_\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: tempExtractDir)
        try? FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveUrl.path, tempExtractDir.path]

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: tempExtractDir)
                return false
            }
        } catch {
            try? FileManager.default.removeItem(at: tempExtractDir)
            return false
        }

        // Zip Slip defense: verify all extracted entries stay within tempExtractDir
        guard let enumerator = FileManager.default.enumerator(at: tempExtractDir, includingPropertiesForKeys: nil) else {
            try? FileManager.default.removeItem(at: tempExtractDir)
            return false
        }
        let canonicalBase = tempExtractDir.resolvingSymlinksInPath().path
        var metadataUrlsToRemove: [URL] = []
        for case let fileUrl as URL in enumerator {
            let canonicalFile = fileUrl.resolvingSymlinksInPath().path
            if !canonicalFile.hasPrefix(canonicalBase) {
                try? FileManager.default.removeItem(at: tempExtractDir)
                return false
            }
            if isIgnoredMetadataItem(name: fileUrl.lastPathComponent) {
                metadataUrlsToRemove.append(fileUrl)
            }
        }
        for url in metadataUrlsToRemove {
            try? FileManager.default.removeItem(at: url)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(at: tempExtractDir, includingPropertiesForKeys: nil)) ?? []
        guard !contents.isEmpty else {
            try? FileManager.default.removeItem(at: tempExtractDir)
            return false
        }

        do {
            if contents.count == 1, (try? contents[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try FileManager.default.moveItem(at: contents[0], to: destinationFolderUrl)
            } else {
                try? FileManager.default.createDirectory(at: destinationFolderUrl, withIntermediateDirectories: true)
                for item in contents {
                    let destChild = destinationFolderUrl.appendingPathComponent(item.lastPathComponent)
                    try FileManager.default.moveItem(at: item, to: destChild)
                }
            }
            try? FileManager.default.removeItem(at: tempExtractDir)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempExtractDir)
            return false
        }
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
