import AppKit
import CryptoKit
import Foundation

/// Parsed snapshot emitted by `media-control stream --no-diff` or `media-control get`.
struct MediaControlPayload: Equatable {
    var title: String
    var artist: String
    var album: String
    var bundleIdentifier: String
    var durationSeconds: Double
    var elapsedSeconds: Double
    var isPlaying: Bool
    var playbackRate: Double
    var timestamp: Date?
    var artworkData: Data?

    static func parse(jsonData: Data) -> MediaControlPayload?? {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return .none
        }
        return .some(parse(jsonObject: obj))
    }

    static func parse(jsonObject root: [String: Any]) -> MediaControlPayload? {
        let payload: [String: Any]
        if root.keys.contains("payload") {
            guard let inner = root["payload"] as? [String: Any], !inner.isEmpty else {
                return nil
            }
            payload = inner
        } else {
            guard !root.isEmpty else { return nil }
            payload = root
        }

        let rawTitle = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawTitle.isEmpty else { return nil }

        let artist = (payload["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = (payload["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleId = (payload["bundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let durationSeconds: Double = {
            if let dur = (payload["duration"] as? NSNumber)?.doubleValue {
                return max(0.0, dur)
            }
            if let micros = (payload["durationMicros"] as? NSNumber)?.doubleValue {
                return max(0.0, micros / 1_000_000.0)
            }
            return 0.0
        }()

        let elapsedSeconds: Double = {
            if let elapsed = (payload["elapsedTime"] as? NSNumber)?.doubleValue {
                return max(0.0, elapsed)
            }
            if let elapsedNow = (payload["elapsedTimeNow"] as? NSNumber)?.doubleValue {
                return max(0.0, elapsedNow)
            }
            if let micros = (payload["elapsedTimeMicros"] as? NSNumber)?.doubleValue {
                return max(0.0, micros / 1_000_000.0)
            }
            return 0.0
        }()

        let isPlaying: Bool = {
            if let playing = payload["playing"] as? Bool {
                return playing
            }
            if let num = payload["playing"] as? NSNumber {
                return num.boolValue
            }
            return false
        }()

        let playbackRate: Double = {
            if let rate = (payload["playbackRate"] as? NSNumber)?.doubleValue {
                return rate
            }
            return isPlaying ? 1.0 : 0.0
        }()

        let timestamp: Date? = {
            if let tsStr = payload["timestamp"] as? String {
                return parseISO8601Date(tsStr)
            }
            if let micros = (payload["timestampEpochMicros"] as? NSNumber)?.doubleValue {
                return Date(timeIntervalSince1970: micros / 1_000_000.0)
            }
            return nil
        }()

        let artworkData: Data? = {
            guard let b64 = payload["artworkData"] as? String, !b64.isEmpty else {
                return nil
            }
            return Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
        }()

        return MediaControlPayload(
            title: rawTitle,
            artist: artist,
            album: album,
            bundleIdentifier: bundleId,
            durationSeconds: durationSeconds,
            elapsedSeconds: elapsedSeconds,
            isPlaying: isPlaying,
            playbackRate: playbackRate,
            timestamp: timestamp,
            artworkData: artworkData
        )
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: value) {
            return d
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    func estimatedPositionMs(at now: Date = Date()) -> Int64 {
        var sec = elapsedSeconds
        if isPlaying, let ts = timestamp {
            let delta = max(0.0, now.timeIntervalSince(ts))
            let rate = playbackRate > 0.0 ? playbackRate : 1.0
            sec += delta * rate
        }
        let ms = max(0, Int64((sec * 1000.0).rounded()))
        let durMs = max(0, Int64((durationSeconds * 1000.0).rounded()))
        return durMs > 0 ? min(durMs, ms) : ms
    }
}

protocol MacMediaControlClientProviding: AnyObject {
    var isAvailable: Bool { get }
    func startStreaming(onUpdate: @escaping (MediaControlPayload?) -> Void, onFailure: @escaping () -> Void)
    func stopStreaming()
    func fetchCurrent() -> MediaControlPayload?
    @discardableResult func play() -> Bool
    @discardableResult func pause() -> Bool
    @discardableResult func togglePlayPause() -> Bool
    @discardableResult func nextTrack() -> Bool
    @discardableResult func previousTrack() -> Bool
    @discardableResult func stopPlayback() -> Bool
    @discardableResult func seek(toSeconds seconds: Double) -> Bool
}

/// Wrapper around the bundled `mediaremote-adapter` helper (or external `media-control` CLI),
/// enabling universal macOS Now Playing metadata streaming and playback controls across all
/// MediaRemote-compatible apps.
final class MacMediaControlCLI: MacMediaControlClientProviding {
    static let shared = MacMediaControlCLI()

    enum LaunchBackend: Equatable {
        case bundledAdapter(perlPath: String, scriptPath: String, frameworkPath: String)
        case externalCLI(binaryPath: String)

        var executablePath: String {
            switch self {
            case .bundledAdapter(let perlPath, _, _):
                return perlPath
            case .externalCLI(let binaryPath):
                return binaryPath
            }
        }

        var prefixArguments: [String] {
            switch self {
            case .bundledAdapter(_, let scriptPath, let frameworkPath):
                return [scriptPath, frameworkPath]
            case .externalCLI:
                return []
            }
        }

        func arguments(forStreamNoDiff: Bool) -> [String] {
            prefixArguments + ["stream", "--no-diff"]
        }

        func argumentsForGetNow() -> [String] {
            prefixArguments + ["get", "--now"]
        }

        func arguments(forCommand command: String) -> [String] {
            switch self {
            case .bundledAdapter:
                let mapped: [String]
                switch command {
                case "play": mapped = ["send", "0"]
                case "pause": mapped = ["send", "1"]
                case "toggle-play-pause": mapped = ["send", "2"]
                case "stop": mapped = ["send", "3"]
                case "next-track": mapped = ["send", "4"]
                case "previous-track": mapped = ["send", "5"]
                default: mapped = [command]
                }
                return prefixArguments + mapped
            case .externalCLI:
                return prefixArguments + [command]
            }
        }

        func arguments(forSeekSeconds seconds: Double) -> [String] {
            let clamped = max(0.0, seconds)
            switch self {
            case .bundledAdapter:
                let micros = max(0, Int64((clamped * 1_000_000.0).rounded()))
                return prefixArguments + ["seek", String(micros)]
            case .externalCLI:
                return prefixArguments + ["seek", String(format: "%.3f", clamped)]
            }
        }
    }

    static let perlPath = "/usr/bin/perl"
    static let fallbackBinaryPaths = [
        "/opt/homebrew/bin/media-control",
        "/usr/local/bin/media-control"
    ]

    private let stateQueue = DispatchQueue(label: "com.link.bridge.mediaControlCLI", qos: .utility)
    private var cachedLaunchBackend: LaunchBackend?
    private var streamProcess: Process?
    private var streamPipe: Pipe?
    private var lineBuffer = Data()
    private var isStreamingActive = false
    private var retryCount = 0
    private let maxRetries = 8
    private var onUpdateHandler: ((MediaControlPayload?) -> Void)?
    private var onFailureHandler: (() -> Void)?
    private let customBinaryPath: String?

    init(customBinaryPath: String? = nil) {
        self.customBinaryPath = customBinaryPath
    }

    var isAvailable: Bool {
        resolveLaunchBackend() != nil
    }

    func resolveLaunchBackend() -> LaunchBackend? {
        if let customBinaryPath {
            return FileManager.default.isExecutableFile(atPath: customBinaryPath)
                ? .externalCLI(binaryPath: customBinaryPath)
                : nil
        }
        return stateQueue.sync {
            resolveLaunchBackendLocked()
        }
    }

    private func resolveLaunchBackendLocked() -> LaunchBackend? {
        if let cached = cachedLaunchBackend {
            switch cached {
            case .bundledAdapter(let perl, let script, let fw):
                if FileManager.default.isExecutableFile(atPath: perl),
                   FileManager.default.fileExists(atPath: script),
                   FileManager.default.fileExists(atPath: fw) {
                    return cached
                }
            case .externalCLI(let bin):
                if FileManager.default.isExecutableFile(atPath: bin) {
                    return cached
                }
            }
        }
        let resolved = Self.discoverLaunchBackend(
            bundle: Bundle.main,
            fallbackPaths: Self.fallbackBinaryPaths
        )
        cachedLaunchBackend = resolved
        return resolved
    }

    static func discoverLaunchBackend(
        bundle: Bundle = .main,
        fallbackPaths: [String] = fallbackBinaryPaths,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> LaunchBackend? {
        if FileManager.default.isExecutableFile(atPath: perlPath),
           let scriptPath = bundle.resourceURL?.appendingPathComponent("mediaremote-adapter.pl").path,
           FileManager.default.fileExists(atPath: scriptPath) {
            let frameworkCandidates = [
                bundle.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework").path,
                bundle.bundleURL.appendingPathComponent("Contents/Frameworks/MediaRemoteAdapter.framework").path
            ].compactMap { $0 }

            for fwPath in frameworkCandidates {
                let binaryInsideFramework = (fwPath as NSString).appendingPathComponent("MediaRemoteAdapter")
                if FileManager.default.fileExists(atPath: binaryInsideFramework) {
                    return .bundledAdapter(perlPath: perlPath, scriptPath: scriptPath, frameworkPath: fwPath)
                }
            }
        }

        if let binPath = findExecutable(
            named: "media-control",
            bundle: bundle,
            fallbackPaths: fallbackPaths,
            environmentPath: environmentPath
        ) {
            return .externalCLI(binaryPath: binPath)
        }
        return nil
    }

    static func findExecutable(
        named name: String,
        bundle: Bundle = .main,
        fallbackPaths: [String] = fallbackBinaryPaths,
        environmentPath: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String? {
        let bundledCandidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            bundle.resourceURL?.appendingPathComponent(name).path
        ].compactMap { $0 }

        for candidate in bundledCandidates + fallbackPaths {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        let envPath = environmentPath ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        for dir in envPath.components(separatedBy: ":") where !dir.isEmpty {
            let fullPath = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    func startStreaming(onUpdate: @escaping (MediaControlPayload?) -> Void, onFailure: @escaping () -> Void) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.onUpdateHandler = onUpdate
            self.onFailureHandler = onFailure
            if self.isStreamingActive, let proc = self.streamProcess, proc.isRunning {
                return
            }
            self.isStreamingActive = true
            self.retryCount = 0
            self.launchStreamProcessLocked()
        }
    }

    func stopStreaming() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isStreamingActive = false
            self.retryCount = 0
            self.onUpdateHandler = nil
            self.onFailureHandler = nil
            self.terminateStreamProcessLocked()
        }
    }

    func fetchCurrent() -> MediaControlPayload? {
        guard let backend = resolveLaunchBackend() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: backend.executablePath)
        proc.arguments = backend.argumentsForGetNow()
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        let doneSem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            doneSem.signal()
        }
        do {
            try proc.run()
        } catch {
            return nil
        }

        if doneSem.wait(timeout: .now() + 1.2) == .timedOut {
            if proc.isRunning { proc.terminate() }
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty, case .some(let payload) = MediaControlPayload.parse(jsonData: data) else {
            return nil
        }
        return payload
    }

    @discardableResult func play() -> Bool { runCommand("play") }
    @discardableResult func pause() -> Bool { runCommand("pause") }
    @discardableResult func togglePlayPause() -> Bool { runCommand("toggle-play-pause") }
    @discardableResult func nextTrack() -> Bool { runCommand("next-track") }
    @discardableResult func previousTrack() -> Bool { runCommand("previous-track") }
    @discardableResult func stopPlayback() -> Bool { runCommand("stop") }

    @discardableResult
    func seek(toSeconds seconds: Double) -> Bool {
        guard let backend = resolveLaunchBackend() else { return false }
        return runProcess(executablePath: backend.executablePath, arguments: backend.arguments(forSeekSeconds: seconds))
    }

    private func runCommand(_ command: String) -> Bool {
        guard let backend = resolveLaunchBackend() else { return false }
        return runProcess(executablePath: backend.executablePath, arguments: backend.arguments(forCommand: command))
    }

    private func runProcess(executablePath: String, arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let doneSem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            doneSem.signal()
        }
        do {
            try proc.run()
        } catch {
            NSLog("[BridgeMacMedia] Failed to launch %@ %@: %@", executablePath, arguments.joined(separator: " "), error.localizedDescription)
            return false
        }
        if doneSem.wait(timeout: .now() + 1.5) == .timedOut {
            if proc.isRunning { proc.terminate() }
            return false
        }
        return proc.terminationStatus == 0
    }

    private func terminateStreamProcessLocked() {
        if let proc = streamProcess {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
            }
        }
        streamPipe?.fileHandleForReading.readabilityHandler = nil
        streamProcess = nil
        streamPipe = nil
        lineBuffer.removeAll()
    }

    private func launchStreamProcessLocked() {
        guard isStreamingActive else { return }
        guard let backend = resolveLaunchBackendLocked() else {
            isStreamingActive = false
            let failCb = onFailureHandler
            DispatchQueue.global(qos: .utility).async { failCb?() }
            return
        }
        terminateStreamProcessLocked()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: backend.executablePath)
        proc.arguments = backend.arguments(forStreamNoDiff: true)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.stateQueue.async { [weak self] in
                self?.consumeStreamChunkLocked(chunk)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            readHandle.readabilityHandler = nil
            self?.stateQueue.async { [weak self] in
                guard let self, self.isStreamingActive else { return }
                if self.retryCount < self.maxRetries {
                    self.retryCount += 1
                    let delay = min(Double(self.retryCount) * 0.5, 3.0)
                    NSLog("[BridgeMacMedia] media-control stream exited; retrying (%d/%d) in %.1fs", self.retryCount, self.maxRetries, delay)
                    self.stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.launchStreamProcessLocked()
                    }
                } else {
                    NSLog("[BridgeMacMedia] media-control stream reached max retries; falling back to AppleScript/CoreAudio")
                    self.isStreamingActive = false
                    let failCb = self.onFailureHandler
                    DispatchQueue.global(qos: .utility).async { failCb?() }
                }
            }
        }

        streamProcess = proc
        streamPipe = pipe

        do {
            try proc.run()
            NSLog("[BridgeMacMedia] Started universal media-control stream (%@)", backend.executablePath)
        } catch {
            NSLog("[BridgeMacMedia] Could not start media-control stream: %@", error.localizedDescription)
            proc.terminationHandler = nil
            terminateStreamProcessLocked()
            if retryCount < maxRetries {
                retryCount += 1
                let delay = min(Double(retryCount) * 0.5, 3.0)
                stateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.launchStreamProcessLocked()
                }
            } else {
                isStreamingActive = false
                let failCb = onFailureHandler
                DispatchQueue.global(qos: .utility).async { failCb?() }
            }
        }
    }

    private func consumeStreamChunkLocked(_ chunk: Data) {
        guard isStreamingActive else { return }
        lineBuffer.append(chunk)
        let newline = UInt8(ascii: "\n")
        while let idx = lineBuffer.firstIndex(of: newline) {
            let lineData = lineBuffer.subdata(in: 0..<idx)
            lineBuffer.removeSubrange(0...idx)
            guard !lineData.isEmpty else { continue }
            if case .some(let payload) = MediaControlPayload.parse(jsonData: lineData) {
                retryCount = 0
                let updateCb = onUpdateHandler
                DispatchQueue.global(qos: .utility).async {
                    updateCb?(payload)
                }
            }
        }
    }
}
