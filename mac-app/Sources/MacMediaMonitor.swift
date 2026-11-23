import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import IOKit.hidsystem

/// Snapshot of active Mac media playback sent to Android over `mac_media_status`.
struct MacMediaSnapshot: Equatable {
    var isActive: Bool = false
    var isPlaying: Bool = false
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var appName: String = ""
    var bundleId: String = ""
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var playbackSpeed: Double = 1.0
    var canSeek: Bool = false
    var canSkipNext: Bool = false
    var canSkipPrevious: Bool = false
    var artworkHash: String? = nil
    var artworkBase64: String? = nil

    func contentSignature() -> String {
        "\(isActive)|\(isPlaying)|\(title)|\(artist)|\(album)|\(appName)|\(durationMs)|\(canSeek)|\(canSkipNext)|\(canSkipPrevious)|\(artworkHash ?? "")"
    }

    func toJsonObject(includeArtworkData: Bool, timestampMs: Int64) -> [String: Any] {
        var obj: [String: Any] = [
            "type": "mac_media_status",
            "isActive": isActive,
            "isPlaying": isPlaying,
            "updatedAtMs": timestampMs
        ]
        guard isActive else { return obj }

        obj["title"] = title
        obj["artist"] = artist
        obj["album"] = album
        obj["appName"] = appName
        obj["durationMs"] = durationMs
        obj["positionMs"] = positionMs
        obj["playbackSpeed"] = playbackSpeed
        obj["canSeek"] = canSeek
        obj["canSkipNext"] = canSkipNext
        obj["canSkipPrevious"] = canSkipPrevious
        if let artworkHash, !artworkHash.isEmpty {
            obj["artworkHash"] = artworkHash
        }
        if includeArtworkData, let artworkBase64, !artworkBase64.isEmpty {
            obj["artworkBase64"] = artworkBase64
        }
        return obj
    }

    func toJsonString(includeArtworkData: Bool, timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String? {
        let obj = toJsonObject(includeArtworkData: includeArtworkData, timestampMs: timestampMs)
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

protocol MacMediaMonitoringBackend {
    func runningPlayerBundleIds() -> Set<String>
    func isAnyMacAudioPlaying() -> Bool
    func queryPlayer(bundleId: String) -> MacMediaMonitor.PlayerQueryResult?
    func queryBrowserTabs(bundleId: String) -> MacMediaMonitor.BrowserQueryResult
    func performPlayerAction(_ action: String, bundleId: String, positionMs: Int64?, deltaMs: Int64?) -> Bool
    func sendMediaKey(keyType: Int32)
}

extension MacMediaMonitoringBackend {
    func queryBrowserTabs(bundleId: String) -> MacMediaMonitor.BrowserQueryResult { .none }
}

final class MacMediaMonitor {
    static let shared = MacMediaMonitor()

    struct BrowserTabCandidate: Equatable {
        var url: String
        var title: String
        var browserName: String
        var bundleId: String
        var isActiveTab: Bool
    }

    enum BrowserQueryResult {
        case found([BrowserTabCandidate])
        case none
        case permissionDenied
    }

    enum PlayerQueryResult {
        case active(MacMediaSnapshot, artworkUrl: String?)
        case inactive
        case permissionDenied
    }

    private final class SystemBackend: MacMediaMonitoringBackend {
        private let audioController = SystemMacMediaController()

        func runningPlayerBundleIds() -> Set<String> {
            Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        }

        func isAnyMacAudioPlaying() -> Bool {
            audioController.isAudioPlaying()
        }

        func queryPlayer(bundleId: String) -> PlayerQueryResult? {
            switch bundleId {
            case "com.spotify.client":
                return querySpotify()
            case "com.apple.Music":
                return queryAppleMusic()
            case "org.videolan.vlc":
                return queryVlc()
            default:
                return nil
            }
        }

        private static let browserConfigByBundleId: [String: (appName: String, displayName: String, isSafari: Bool)] = [
            "com.brave.Browser": ("Brave Browser", "Brave", false),
            "com.google.Chrome": ("Google Chrome", "Chrome", false),
            "com.apple.Safari": ("Safari", "Safari", true),
            "com.microsoft.edgemac": ("Microsoft Edge", "Edge", false),
            "company.thebrowser.Browser": ("Arc", "Arc", false),
            "com.vivaldi.Vivaldi": ("Vivaldi", "Vivaldi", false)
        ]

        private var promptedBundleIds: Set<String> = []

        func queryBrowserTabs(bundleId: String) -> BrowserQueryResult {
            guard let cfg = Self.browserConfigByBundleId[bundleId] else { return .none }
            if !ensureAutomationPermission(bundleId: bundleId) {
                return .permissionDenied
            }
            let scriptSource: String
            if cfg.isSafari {
                scriptSource = """
                tell application "Safari"
                    set outList to ""
                    if (count of windows) > 0 then
                        try
                            set curT to current tab of front window
                            set outList to "ACTIVE\t" & (URL of curT) & "\t" & (name of curT) & linefeed
                        end try
                        try
                            set allUrls to URL of every tab of every window
                            set allTitles to name of every tab of every window
                            repeat with wIdx from 1 to count of allUrls
                                set wUrls to item wIdx of allUrls
                                set wTitles to item wIdx of allTitles
                                repeat with tIdx from 1 to count of wUrls
                                    set u to item tIdx of wUrls
                                    if u is not missing value and (u contains "youtube.com/" or u contains "youtu.be/") then
                                        set t to item tIdx of wTitles
                                        set outList to outList & "TAB\t" & u & "\t" & (t as string) & linefeed
                                    end if
                                end repeat
                            end repeat
                        end try
                    end if
                    return outList
                end tell
                """
            } else {
                scriptSource = """
                tell application "\(cfg.appName)"
                    set outList to ""
                    if (count of windows) > 0 then
                        try
                            set activeT to active tab of front window
                            set outList to "ACTIVE\t" & (URL of activeT) & "\t" & (title of activeT) & linefeed
                        end try
                        try
                            set allUrls to URL of every tab of every window
                            set allTitles to title of every tab of every window
                            repeat with wIdx from 1 to count of allUrls
                                set wUrls to item wIdx of allUrls
                                set wTitles to item wIdx of allTitles
                                repeat with tIdx from 1 to count of wUrls
                                    set u to item tIdx of wUrls
                                    if u is not missing value and (u contains "youtube.com/" or u contains "youtu.be/") then
                                        set t to item tIdx of wTitles
                                        set outList to outList & "TAB\t" & u & "\t" & (t as string) & linefeed
                                    end if
                                end repeat
                            end repeat
                        end try
                    end if
                    return outList
                end tell
                """
            }
            let (desc, denied) = executeScript(scriptSource, bundleId: bundleId)
            if denied { return .permissionDenied }
            guard let raw = desc?.stringValue, !raw.isEmpty else { return .none }

            var results: [BrowserTabCandidate] = []
            for line in raw.components(separatedBy: "\n") where !line.isEmpty {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 3 else { continue }
                let kind = cols[0]
                let url = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = cols[2...].joined(separator: "\t").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { continue }
                results.append(BrowserTabCandidate(
                    url: url,
                    title: title,
                    browserName: cfg.displayName,
                    bundleId: bundleId,
                    isActiveTab: kind == "ACTIVE"
                ))
            }
            return results.isEmpty ? .none : .found(results)
        }

        private func ensureAutomationPermission(bundleId: String) -> Bool {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
            guard let ptr = target.aeDesc else { return true }
            var desc = ptr.pointee
            let check = AEDeterminePermissionToAutomateTarget(&desc, typeWildCard, typeWildCard, false)
            if check == noErr { return true }
            if check == OSStatus(errAEEventWouldRequireUserConsent) {
                if !promptedBundleIds.contains(bundleId) {
                    promptedBundleIds.insert(bundleId)
                    var promptResult: OSStatus = OSStatus(errAEEventNotPermitted)
                    let askBlock = {
                        var mutableDesc = ptr.pointee
                        promptResult = AEDeterminePermissionToAutomateTarget(&mutableDesc, typeWildCard, typeWildCard, true)
                    }
                    if Thread.isMainThread {
                        askBlock()
                    } else {
                        DispatchQueue.main.sync(execute: askBlock)
                    }
                    NSLog("[BridgeMacMedia] Prompted Automation permission for %@ -> status %d", bundleId, promptResult)
                    return promptResult == noErr
                }
                return false
            }
            if check == OSStatus(errAEEventNotPermitted) {
                NSLog("[BridgeMacMedia] Automation permission not permitted for %@ (enable in System Settings > Privacy & Security > Automation)", bundleId)
                return false
            }
            return true
        }

        func performPlayerAction(_ action: String, bundleId: String, positionMs: Int64?, deltaMs: Int64?) -> Bool {
            switch (bundleId, action) {
            case ("com.spotify.client", "play"):
                return runAppleScript("tell application \"Spotify\" to play") != nil
            case ("com.spotify.client", "pause"), ("com.spotify.client", "stop"):
                return runAppleScript("tell application \"Spotify\" to pause") != nil
            case ("com.spotify.client", "play_pause"):
                return runAppleScript("tell application \"Spotify\" to playpause") != nil
            case ("com.spotify.client", "next"):
                return runAppleScript("tell application \"Spotify\" to next track") != nil
            case ("com.spotify.client", "previous"):
                return runAppleScript("tell application \"Spotify\" to previous track") != nil
            case ("com.spotify.client", "seek"):
                guard let posMs = positionMs else { return false }
                let sec = max(0.0, Double(posMs) / 1000.0)
                return runAppleScript("tell application \"Spotify\" to set player position to \(sec)") != nil

            case ("com.apple.Music", "play"):
                return runAppleScript("tell application \"Music\" to play") != nil
            case ("com.apple.Music", "pause"):
                return runAppleScript("tell application \"Music\" to pause") != nil
            case ("com.apple.Music", "stop"):
                return runAppleScript("tell application \"Music\" to stop") != nil
            case ("com.apple.Music", "play_pause"):
                return runAppleScript("tell application \"Music\" to playpause") != nil
            case ("com.apple.Music", "next"):
                return runAppleScript("tell application \"Music\" to next track") != nil
            case ("com.apple.Music", "previous"):
                return runAppleScript("tell application \"Music\" to previous track") != nil
            case ("com.apple.Music", "seek"):
                guard let posMs = positionMs else { return false }
                let sec = max(0.0, Double(posMs) / 1000.0)
                return runAppleScript("tell application \"Music\" to set player position to \(sec)") != nil

            case ("org.videolan.vlc", "play"):
                return runAppleScript("tell application \"VLC\"\nif not playing then play\nend tell") != nil
            case ("org.videolan.vlc", "pause"):
                return runAppleScript("tell application \"VLC\"\nif playing then play\nend tell") != nil
            case ("org.videolan.vlc", "stop"):
                return runAppleScript("tell application \"VLC\" to stop") != nil
            case ("org.videolan.vlc", "play_pause"):
                return runAppleScript("tell application \"VLC\" to play") != nil
            case ("org.videolan.vlc", "next"):
                return runAppleScript("tell application \"VLC\" to next") != nil
            case ("org.videolan.vlc", "previous"):
                return runAppleScript("tell application \"VLC\" to previous") != nil
            case ("org.videolan.vlc", "seek"):
                guard let posMs = positionMs else { return false }
                let sec = max(0, Int((Double(posMs) / 1000.0).rounded()))
                return runAppleScript("tell application \"VLC\" to set current time to \(sec)") != nil

            case (_, "seek_delta"):
                guard let deltaMs, let current = queryPlayer(bundleId: bundleId),
                      case .active(let snap, _) = current, snap.canSeek else {
                    return false
                }
                let targetMs = max(0, min(snap.durationMs > 0 ? snap.durationMs : .max, snap.positionMs + deltaMs))
                return performPlayerAction("seek", bundleId: bundleId, positionMs: targetMs, deltaMs: nil)

            default:
                return false
            }
        }

        func sendMediaKey(keyType: Int32) {
            if keyType == Int32(NX_KEYTYPE_PLAY) {
                _ = audioController.sendPlayPauseKey()
                return
            }
            DispatchQueue.main.async {
                func post(down: Bool) {
                    let flags = down ? 0xa00 : 0xb00
                    let data1 = Int((keyType << 16) | Int32(flags))
                    guard let event = NSEvent.otherEvent(
                        with: .systemDefined,
                        location: .zero,
                        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: 0,
                        context: nil,
                        subtype: 8,
                        data1: data1,
                        data2: -1
                    ) else { return }
                    event.cgEvent?.post(tap: .cghidEventTap)
                }
                post(down: true)
                post(down: false)
            }
        }

        private func querySpotify() -> PlayerQueryResult {
            let source = """
            tell application "Spotify"
                if player state is stopped then return "stopped"
                set pState to (player state as string)
                set tName to name of current track
                set tArtist to artist of current track
                set tAlbum to album of current track
                set tDur to duration of current track
                set tPos to player position
                set tArt to artwork url of current track
                return pState & "\n" & tName & "\n" & tArtist & "\n" & tAlbum & "\n" & (tDur as string) & "\n" & (tPos as string) & "\n" & tArt
            end tell
            """
            let (desc, denied) = executeScript(source)
            if denied { return .permissionDenied }
            guard let raw = desc?.stringValue else { return .inactive }
            if raw == "stopped" { return .inactive }
            let parts = raw.components(separatedBy: "\n")
            guard parts.count >= 6 else { return .inactive }
            let isPlaying = parts[0].lowercased().contains("playing")
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .inactive }
            let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let durationMs = Int64(Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0)
            let positionSec = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            let positionMs = max(0, Int64((positionSec * 1000.0).rounded()))
            let artUrl = parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : nil

            let snap = MacMediaSnapshot(
                isActive: true,
                isPlaying: isPlaying,
                title: title,
                artist: artist,
                album: album,
                appName: "Spotify",
                bundleId: "com.spotify.client",
                durationMs: max(0, durationMs),
                positionMs: positionMs,
                playbackSpeed: isPlaying ? 1.0 : 0.0,
                canSeek: durationMs > 0,
                canSkipNext: true,
                canSkipPrevious: true
            )
            return .active(snap, artworkUrl: artUrl)
        }

        private func queryAppleMusic() -> PlayerQueryResult {
            let source = """
            tell application "Music"
                if player state is stopped then return "stopped"
                set pState to (player state as string)
                set tName to name of current track
                set tArtist to artist of current track
                set tAlbum to album of current track
                set tDur to duration of current track
                set tPos to player position
                return pState & "\n" & tName & "\n" & tArtist & "\n" & tAlbum & "\n" & (tDur as string) & "\n" & (tPos as string)
            end tell
            """
            let (desc, denied) = executeScript(source, bundleId: "com.apple.Music")
            if denied { return .permissionDenied }
            guard let raw = desc?.stringValue else { return .inactive }
            if raw == "stopped" { return .inactive }
            let parts = raw.components(separatedBy: "\n")
            guard parts.count >= 6 else { return .inactive }
            let isPlaying = parts[0].lowercased().contains("playing")
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return .inactive }
            let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let durationSec = Double(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
            let positionSec = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            let durationMs = max(0, Int64((durationSec * 1000.0).rounded()))
            let positionMs = max(0, Int64((positionSec * 1000.0).rounded()))

            var artworkHash: String?
            var artworkBase64: String?
            let artScriptRaw = "tell application \"Music\" to raw data of artwork 1 of current track"
            let artScriptData = "tell application \"Music\" to data of artwork 1 of current track"
            if let artData = (runAppleScript(artScriptRaw)?.data ?? runAppleScript(artScriptData)?.data),
               !artData.isEmpty,
               let encoded = MacMediaMonitor.encodeThumbnail(fromData: artData) {
                artworkHash = encoded.hash
                artworkBase64 = encoded.base64
            }

            let snap = MacMediaSnapshot(
                isActive: true,
                isPlaying: isPlaying,
                title: title,
                artist: artist,
                album: album,
                appName: "Music",
                bundleId: "com.apple.Music",
                durationMs: durationMs,
                positionMs: positionMs,
                playbackSpeed: isPlaying ? 1.0 : 0.0,
                canSeek: durationMs > 0,
                canSkipNext: true,
                canSkipPrevious: true,
                artworkHash: artworkHash,
                artworkBase64: artworkBase64
            )
            return .active(snap, artworkUrl: nil)
        }

        private func queryVlc() -> PlayerQueryResult {
            let source = """
            tell application "VLC"
                set isPlay to playing
                set itemName to name of current item
                set itemDur to duration of current item
                set itemPos to current time
                return (isPlay as string) & "\n" & itemName & "\n" & (itemDur as string) & "\n" & (itemPos as string)
            end tell
            """
            let (desc, denied) = executeScript(source)
            if denied { return .permissionDenied }
            guard let raw = desc?.stringValue else { return .inactive }
            let parts = raw.components(separatedBy: "\n")
            guard parts.count >= 4 else { return .inactive }
            let isPlaying = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != "missing value" else { return .inactive }
            let durationSec = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            let positionSec = Double(parts[3].replacingOccurrences(of: ",", with: ".")) ?? 0
            let durationMs = max(0, Int64((durationSec * 1000.0).rounded()))
            let positionMs = max(0, Int64((positionSec * 1000.0).rounded()))

            let snap = MacMediaSnapshot(
                isActive: true,
                isPlaying: isPlaying,
                title: title,
                artist: "",
                album: "",
                appName: "VLC",
                bundleId: "org.videolan.vlc",
                durationMs: durationMs,
                positionMs: positionMs,
                playbackSpeed: isPlaying ? 1.0 : 0.0,
                canSeek: durationMs > 0,
                canSkipNext: true,
                canSkipPrevious: true
            )
            return .active(snap, artworkUrl: nil)
        }

        private func runAppleScript(_ source: String) -> NSAppleEventDescriptor? {
            executeScript(source, bundleId: nil).0
        }

        private func executeScript(_ source: String, bundleId: String? = nil) -> (NSAppleEventDescriptor?, Bool) {
            guard let script = NSAppleScript(source: source) else { return (nil, false) }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            if let err {
                let errNum = (err[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                if errNum == -1743 {
                    NSLog("[BridgeMacMedia] AppleScript -1743 (Automation denied) for %@", bundleId ?? "unknown")
                    return (nil, true)
                }
                if errNum != -1728 && errNum != -1719 {
                    NSLog("[BridgeMacMedia] AppleScript error %d for %@: %@", errNum, bundleId ?? "app", String(describing: err[NSAppleScript.errorMessage] ?? ""))
                }
                return (nil, false)
            }
            return (result, false)
        }
    }

    private let backend: MacMediaMonitoringBackend
    private let mediaControlClient: MacMediaControlClientProviding
    private let queue = DispatchQueue(label: "com.link.bridge.macMedia", qos: .utility)

    var onStatusChanged: ((String) -> Void)?
    var hasConnectedClientsProvider: () -> Bool = { false }

    private var isRunning = false
    private var timer: DispatchSourceTimer?
    private var lastSnapshot = MacMediaSnapshot()
    private var lastBroadcastTimeMs: Int64 = 0
    private var lastSentArtworkHash: String?
    private var cachedArtworkByUrl: [String: (hash: String, base64: String)] = [:]
    private var cachedYouTubeMetaById: [String: (title: String?, author: String?, thumbUrl: String?)] = [:]
    private var deniedRetryUntilByBundleId: [String: Date] = [:]
    private var lastActiveBundleId: String?
    private var lastBrowserVideoId: String?
    private var lastBrowserMediaSnapshot: MacMediaSnapshot?

    private var isUniversalStreamActive = false
    private var hasReceivedUniversalEvent = false
    private var latestUniversalPayload: MediaControlPayload?
    private var cachedUniversalArtwork: (rawHash: String, encoded: (hash: String, base64: String))?
    private var cachedAppNameByBundleId: [String: String] = [:]

    init(
        backend: MacMediaMonitoringBackend = SystemBackend(),
        mediaControlClient: MacMediaControlClientProviding = MacMediaControlCLI.shared
    ) {
        self.backend = backend
        self.mediaControlClient = mediaControlClient
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 2.0)
            t.setEventHandler { [weak self] in
                guard let self, self.isRunning else { return }
                guard self.hasConnectedClientsProvider() else {
                    self.stopUniversalStreamLocked()
                    return
                }
                self.ensureUniversalStreamIfAvailableLocked()
                self.pollAndBroadcast(force: false)
            }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.stopUniversalStreamLocked()
            self.lastSnapshot = MacMediaSnapshot()
            self.lastSentArtworkHash = nil
            self.lastBrowserVideoId = nil
            self.lastBrowserMediaSnapshot = nil
            self.cachedUniversalArtwork = nil
        }
    }

    func currentStatusJson(forceArtwork: Bool = true) -> String? {
        return queue.sync {
            if hasConnectedClientsProvider() {
                ensureUniversalStreamIfAvailableLocked()
            }
            if mediaControlClient.isAvailable && !hasReceivedUniversalEvent {
                if let fetched = mediaControlClient.fetchCurrent() {
                    latestUniversalPayload = filterSelfPayload(fetched)
                    hasReceivedUniversalEvent = true
                }
            }
            let snap = captureCurrentSnapshot()
            lastSnapshot = snap
            if forceArtwork || snap.artworkHash != lastSentArtworkHash {
                lastSentArtworkHash = snap.artworkHash
            }
            return snap.toJsonString(includeArtworkData: forceArtwork || snap.artworkBase64 != nil)
        }
    }

    func handleMediaAction(jsonObject: [String: Any]) {
        guard let action = jsonObject["action"] as? String else { return }
        if action == "set_volume" {
            if let vol = (jsonObject["volumePercent"] as? NSNumber)?.intValue {
                MacSystemControlManager.shared.handleControlCommand(jsonObject: [
                    "action": "set_volume",
                    "volumePercent": vol
                ])
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let bundleId = self.lastActiveBundleId ?? self.lastSnapshot.bundleId
            let positionMs = (jsonObject["positionMs"] as? NSNumber)?.int64Value
            let deltaMs = (jsonObject["deltaMs"] as? NSNumber)?.int64Value

            var handled = false

            if action == "seek" || action == "seek_delta" {
                let targetMs = self.resolveSeekTargetMs(action: action, positionMs: positionMs, deltaMs: deltaMs)
                if let targetMs {
                    if !bundleId.isEmpty && !self.isTemporarilyDenied(bundleId) {
                        handled = self.backend.performPlayerAction(
                            "seek",
                            bundleId: bundleId,
                            positionMs: targetMs,
                            deltaMs: nil
                        )
                    }
                    if !handled && self.mediaControlClient.isAvailable {
                        handled = self.mediaControlClient.seek(toSeconds: Double(targetMs) / 1000.0)
                        if handled, var payload = self.latestUniversalPayload {
                            payload.elapsedSeconds = Double(targetMs) / 1000.0
                            payload.timestamp = Date()
                            self.latestUniversalPayload = payload
                        }
                    }
                    if handled {
                        self.lastSnapshot.positionMs = targetMs
                        self.lastBroadcastTimeMs = Int64(Date().timeIntervalSince1970 * 1000)
                    }
                }
            } else {
                if self.mediaControlClient.isAvailable {
                    switch action {
                    case "play":
                        handled = self.mediaControlClient.play()
                    case "pause":
                        handled = self.mediaControlClient.pause()
                    case "play_pause":
                        handled = self.mediaControlClient.togglePlayPause()
                    case "next":
                        handled = self.mediaControlClient.nextTrack()
                    case "previous":
                        handled = self.mediaControlClient.previousTrack()
                    case "stop":
                        handled = self.mediaControlClient.stopPlayback()
                    default:
                        break
                    }
                }

                if !handled && !bundleId.isEmpty && !self.isTemporarilyDenied(bundleId) {
                    handled = self.backend.performPlayerAction(
                        action,
                        bundleId: bundleId,
                        positionMs: positionMs,
                        deltaMs: deltaMs
                    )
                }

                if !handled && self.lastSnapshot.isActive {
                    switch action {
                    case "play_pause":
                        self.backend.sendMediaKey(keyType: Int32(NX_KEYTYPE_PLAY))
                    case "play":
                        if !self.lastSnapshot.isPlaying {
                            self.backend.sendMediaKey(keyType: Int32(NX_KEYTYPE_PLAY))
                        }
                    case "pause":
                        if self.lastSnapshot.isPlaying {
                            self.backend.sendMediaKey(keyType: Int32(NX_KEYTYPE_PLAY))
                        }
                    case "next":
                        self.backend.sendMediaKey(keyType: Int32(NX_KEYTYPE_NEXT))
                    case "previous":
                        self.backend.sendMediaKey(keyType: Int32(NX_KEYTYPE_PREVIOUS))
                    default:
                        break
                    }
                }
            }

            self.queue.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.pollAndBroadcast(force: true)
            }
            self.queue.asyncAfter(deadline: .now() + 0.95) { [weak self] in
                self?.pollAndBroadcast(force: false)
            }
        }
    }

    private func resolveSeekTargetMs(action: String, positionMs: Int64?, deltaMs: Int64?) -> Int64? {
        let durMs = lastSnapshot.durationMs
        if action == "seek" {
            guard let positionMs else { return nil }
            let clamped = max(0, positionMs)
            return durMs > 0 ? min(durMs, clamped) : clamped
        }
        guard let deltaMs else { return nil }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let currentMs = expectedPositionMs(for: lastSnapshot, atMs: nowMs)
        let rawTarget = max(0, currentMs + deltaMs)
        return durMs > 0 ? min(durMs, rawTarget) : rawTarget
    }

    private func ensureUniversalStreamIfAvailableLocked() {
        guard mediaControlClient.isAvailable, !isUniversalStreamActive else { return }
        isUniversalStreamActive = true
        mediaControlClient.startStreaming(
            onUpdate: { [weak self] payload in
                self?.queue.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    self.hasReceivedUniversalEvent = true
                    self.latestUniversalPayload = self.filterSelfPayload(payload)
                    self.pollAndBroadcast(force: false)
                }
            },
            onFailure: { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.isUniversalStreamActive = false
                    self.hasReceivedUniversalEvent = false
                    self.latestUniversalPayload = nil
                    self.pollAndBroadcast(force: false)
                }
            }
        )
    }

    private func stopUniversalStreamLocked() {
        guard isUniversalStreamActive || hasReceivedUniversalEvent || latestUniversalPayload != nil else { return }
        isUniversalStreamActive = false
        hasReceivedUniversalEvent = false
        latestUniversalPayload = nil
        mediaControlClient.stopStreaming()
    }

    private func filterSelfPayload(_ payload: MediaControlPayload?) -> MediaControlPayload? {
        guard let payload else { return nil }
        let ownBundleId = Bundle.main.bundleIdentifier ?? ""
        if !ownBundleId.isEmpty && payload.bundleIdentifier == ownBundleId {
            return nil
        }
        return payload
    }

    func applyUniversalPayloadForTesting(_ payload: MediaControlPayload?) -> String? {
        return queue.sync {
            self.hasReceivedUniversalEvent = true
            self.latestUniversalPayload = filterSelfPayload(payload)
            return pollAndBroadcastInternalForTesting(force: true)
        }
    }

    private func isTemporarilyDenied(_ bundleId: String) -> Bool {
        if let until = deniedRetryUntilByBundleId[bundleId], until > Date() {
            return true
        }
        deniedRetryUntilByBundleId.removeValue(forKey: bundleId)
        return false
    }

    func pollAndBroadcastForTesting(force: Bool = true) -> String? {
        return queue.sync {
            return pollAndBroadcastInternalForTesting(force: force)
        }
    }

    private func pollAndBroadcastInternalForTesting(force: Bool) -> String? {
        let snap = captureCurrentSnapshot()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sigChanged = snap.contentSignature() != lastSnapshot.contentSignature()
        let artworkChanged = snap.artworkHash != nil && snap.artworkHash != lastSentArtworkHash
        guard force || sigChanged else { return nil }
        lastSnapshot = snap
        lastBroadcastTimeMs = nowMs
        if artworkChanged { lastSentArtworkHash = snap.artworkHash }
        return snap.toJsonString(includeArtworkData: force || artworkChanged, timestampMs: nowMs)
    }

    private func pollAndBroadcast(force: Bool) {
        let snap = captureCurrentSnapshot()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let sigChanged = snap.contentSignature() != lastSnapshot.contentSignature()
        let posDriftMs = abs(snap.positionMs - expectedPositionMs(for: lastSnapshot, atMs: nowMs))
        let significantSeekOrTick = snap.isActive && snap.canSeek && posDriftMs > 2_500
        let periodicSync = snap.isActive && snap.isPlaying && (nowMs - lastBroadcastTimeMs) >= 12_000

        guard force || sigChanged || significantSeekOrTick || periodicSync else {
            return
        }

        let artworkChanged = snap.artworkHash != nil && snap.artworkHash != lastSentArtworkHash
        lastSnapshot = snap
        lastBroadcastTimeMs = nowMs
        if artworkChanged {
            lastSentArtworkHash = snap.artworkHash
        }
        guard let json = snap.toJsonString(includeArtworkData: force || artworkChanged, timestampMs: nowMs) else {
            return
        }
        onStatusChanged?(json)
    }

    private func expectedPositionMs(for snap: MacMediaSnapshot, atMs: Int64) -> Int64 {
        guard snap.isActive else { return 0 }
        guard snap.isPlaying else { return snap.positionMs }
        let elapsed = max(0, atMs - lastBroadcastTimeMs)
        let projected = snap.positionMs + Int64(Double(elapsed) * max(0.0, snap.playbackSpeed))
        return snap.durationMs > 0 ? min(snap.durationMs, projected) : projected
    }

    private func captureCurrentSnapshot() -> MacMediaSnapshot {
        if hasReceivedUniversalEvent, let payload = latestUniversalPayload {
            let universalSnap = snapshot(from: payload)
            if universalSnap.isActive {
                lastActiveBundleId = payload.bundleIdentifier
                lastBrowserVideoId = nil
                lastBrowserMediaSnapshot = nil
                return universalSnap
            }
        }

        let running = backend.runningPlayerBundleIds()
        let audioActive = backend.isAnyMacAudioPlaying()

        let candidates = ["com.spotify.client", "com.apple.Music", "org.videolan.vlc"]
        var pausedCandidate: MacMediaSnapshot?

        for bundleId in candidates where running.contains(bundleId) && !isTemporarilyDenied(bundleId) {
            guard let res = backend.queryPlayer(bundleId: bundleId) else { continue }
            switch res {
            case .permissionDenied:
                deniedRetryUntilByBundleId[bundleId] = Date().addingTimeInterval(20)
            case .inactive:
                continue
            case .active(var snap, let artUrl):
                if let artUrl, !artUrl.isEmpty {
                    attachSpotifyArtwork(&snap, urlString: artUrl)
                }
                if snap.isPlaying {
                    lastActiveBundleId = bundleId
                    lastBrowserVideoId = nil
                    lastBrowserMediaSnapshot = nil
                    return snap
                } else if pausedCandidate == nil {
                    pausedCandidate = snap
                }
            }
        }

        // Check running web browsers for YouTube / YouTube Music playback & video thumbnails.
        if let browserMedia = captureBrowserYouTubeSnapshot(running: running, audioActive: audioActive) {
            return browserMedia
        }

        if let pausedCandidate {
            lastActiveBundleId = pausedCandidate.bundleId
            return pausedCandidate
        }

        lastActiveBundleId = nil
        return MacMediaSnapshot(isActive: false, isPlaying: false)
    }

    private func snapshot(from payload: MediaControlPayload) -> MacMediaSnapshot {
        let trimmedTitle = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return MacMediaSnapshot(isActive: false, isPlaying: false)
        }
        let durationMs = max(0, Int64((payload.durationSeconds * 1000.0).rounded()))
        let positionMs = payload.estimatedPositionMs()
        let appName = resolveAppName(for: payload.bundleIdentifier)

        var artworkHash: String?
        var artworkBase64: String?
        if let rawArt = payload.artworkData, !rawArt.isEmpty {
            let rawDigest = SHA256.hash(data: rawArt).map { String(format: "%02x", $0) }.joined()
            if let cached = cachedUniversalArtwork, cached.rawHash == rawDigest {
                artworkHash = cached.encoded.hash
                artworkBase64 = cached.encoded.base64
            } else if let encoded = Self.encodeThumbnail(fromData: rawArt) {
                cachedUniversalArtwork = (rawDigest, encoded)
                artworkHash = encoded.hash
                artworkBase64 = encoded.base64
            }
        }

        return MacMediaSnapshot(
            isActive: true,
            isPlaying: payload.isPlaying,
            title: payload.title,
            artist: payload.artist,
            album: payload.album,
            appName: appName,
            bundleId: payload.bundleIdentifier,
            durationMs: durationMs,
            positionMs: positionMs,
            playbackSpeed: payload.isPlaying ? (payload.playbackRate > 0 ? payload.playbackRate : 1.0) : 0.0,
            canSeek: durationMs > 0,
            canSkipNext: true,
            canSkipPrevious: true,
            artworkHash: artworkHash,
            artworkBase64: artworkBase64
        )
    }

    private func resolveAppName(for bundleId: String) -> String {
        guard !bundleId.isEmpty else { return "Mac Audio" }
        if let cached = cachedAppNameByBundleId[bundleId] {
            return cached
        }
        let knownNames: [String: String] = [
            "com.spotify.client": "Spotify",
            "com.apple.Music": "Music",
            "org.videolan.vlc": "VLC",
            "com.google.Chrome": "Google Chrome",
            "com.apple.Safari": "Safari",
            "com.brave.Browser": "Brave",
            "com.microsoft.edgemac": "Microsoft Edge",
            "company.thebrowser.Browser": "Arc",
            "com.vivaldi.Vivaldi": "Vivaldi",
            "org.mozilla.firefox": "Firefox",
            "com.apple.podcasts": "Podcasts",
            "com.apple.QuickTimePlayerX": "QuickTime Player",
            "com.colliderli.iina": "IINA"
        ]
        var resolved = knownNames[bundleId]
        if resolved == nil {
            if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
               let name = runningApp.localizedName, !name.isEmpty {
                resolved = name
            } else if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
                      let bundle = Bundle(url: appUrl) {
                let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                if let display, !display.isEmpty {
                    resolved = display
                }
            }
        }
        let finalName = resolved ?? bundleId.split(separator: ".").last.map(String.init) ?? "Mac Audio"
        if cachedAppNameByBundleId.count > 32 {
            cachedAppNameByBundleId.removeAll()
        }
        cachedAppNameByBundleId[bundleId] = finalName
        return finalName
    }

    private func captureBrowserYouTubeSnapshot(running: Set<String>, audioActive: Bool) -> MacMediaSnapshot? {
        let browserBundles = [
            "com.brave.Browser",
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi"
        ]

        var allTabs: [BrowserTabCandidate] = []
        for bundleId in browserBundles where running.contains(bundleId) && !isTemporarilyDenied(bundleId) {
            switch backend.queryBrowserTabs(bundleId: bundleId) {
            case .permissionDenied:
                deniedRetryUntilByBundleId[bundleId] = Date().addingTimeInterval(20)
            case .none:
                continue
            case .found(let tabs):
                allTabs.append(contentsOf: tabs)
            }
        }

        let ytTabs = allTabs.compactMap { tab -> (tab: BrowserTabCandidate, videoId: String, isYtMusic: Bool)? in
            guard let vid = Self.extractYouTubeVideoId(from: tab.url) else { return nil }
            let isMusic = tab.url.lowercased().contains("music.youtube.com")
            return (tab, vid, isMusic)
        }

        guard !ytTabs.isEmpty else {
            lastBrowserVideoId = nil
            lastBrowserMediaSnapshot = nil
            return nil
        }

        // Choose best candidate: active tab with YT video > previous playing videoId > YT Music > first YT watch tab
        let chosen = ytTabs.first(where: { $0.tab.isActiveTab })
            ?? ytTabs.first(where: { $0.videoId == lastBrowserVideoId })
            ?? ytTabs.first(where: { $0.isYtMusic })
            ?? ytTabs.first!

        // Show browser YouTube only when audio is playing or the previously-playing video is paused.
        let matchesPaused = (chosen.videoId == lastBrowserVideoId)
        guard audioActive || matchesPaused else {
            lastBrowserVideoId = nil
            lastBrowserMediaSnapshot = nil
            return nil
        }

        let prevId = lastBrowserVideoId
        lastBrowserVideoId = chosen.videoId
        lastActiveBundleId = ""

        if prevId == chosen.videoId,
           let prev = lastBrowserMediaSnapshot,
           prev.bundleId == chosen.tab.bundleId {
            var updated = prev
            updated.isPlaying = audioActive
            updated.playbackSpeed = audioActive ? 1.0 : 0.0
            lastBrowserMediaSnapshot = updated
            return updated
        }

        let oembed = fetchYouTubeOEmbedIfNeeded(videoId: chosen.videoId)
        let cleanedTabTitle = Self.cleanYouTubeTitle(chosen.tab.title)
        let title = (oembed.title?.isEmpty == false ? oembed.title! : cleanedTabTitle)
        let artist = oembed.author ?? ""
        let appLabel = chosen.isYtMusic ? "YouTube Music" : "YouTube · \(chosen.tab.browserName)"
        let thumbUrl = oembed.thumbUrl ?? "https://i.ytimg.com/vi/\(chosen.videoId)/hqdefault.jpg"

        var snap = MacMediaSnapshot(
            isActive: true,
            isPlaying: audioActive,
            title: title.isEmpty ? "YouTube Video" : title,
            artist: artist,
            album: "",
            appName: appLabel,
            bundleId: chosen.tab.bundleId,
            durationMs: 0,
            positionMs: 0,
            playbackSpeed: audioActive ? 1.0 : 0.0,
            canSeek: false,
            canSkipNext: true,
            canSkipPrevious: true
        )
        attachSpotifyArtwork(&snap, urlString: thumbUrl)
        lastBrowserMediaSnapshot = snap
        return snap
    }

    static func extractYouTubeVideoId(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else {
            return nil
        }
        var rawId: String? = nil
        if host.contains("youtu.be") {
            let trimmed = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            rawId = trimmed.split(separator: "/").first.map(String.init)
        } else if host.contains("youtube.com") || host.contains("youtube-nocookie.com") {
            if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                rawId = v
            } else {
                let segments = components.path.split(separator: "/").map(String.init)
                if segments.count >= 2 && (segments[0] == "shorts" || segments[0] == "live" || segments[0] == "embed") {
                    rawId = segments[1]
                }
            }
        }
        guard let candidate = rawId,
              candidate.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    static func cleanYouTubeTitle(_ rawTitle: String) -> String {
        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        for suffix in [" - YouTube Music", " - YouTube"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count))
                break
            }
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchYouTubeOEmbedIfNeeded(videoId: String) -> (title: String?, author: String?, thumbUrl: String?) {
        if let cached = cachedYouTubeMetaById[videoId] {
            return cached
        }
        guard let url = URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=\(videoId)&format=json") else {
            return (nil, nil, "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        }
        let sem = DispatchSemaphore(value: 0)
        var fetched: Data?
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 2.0)) { data, _, _ in
            fetched = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2.1)

        var parsed: (title: String?, author: String?, thumbUrl: String?) = (nil, nil, "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg")
        if let data = fetched,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let t = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let a = (obj["author_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let thumb = (obj["thumbnail_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            parsed = (t, a, thumb ?? parsed.thumbUrl)
        }
        if cachedYouTubeMetaById.count > 24 {
            cachedYouTubeMetaById.removeAll()
        }
        cachedYouTubeMetaById[videoId] = parsed
        return parsed
    }

    private func attachSpotifyArtwork(_ snap: inout MacMediaSnapshot, urlString: String) {
        if let cached = cachedArtworkByUrl[urlString] {
            snap.artworkHash = cached.hash
            snap.artworkBase64 = cached.base64
            return
        }
        guard let url = URL(string: urlString), url.scheme == "https" else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var fetchedData: Data?
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.cachePolicy = .returnCacheDataElseLoad
        URLSession.shared.dataTask(with: request) { data, _, _ in
            fetchedData = data
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.6)

        if let data = fetchedData, let encoded = Self.encodeThumbnail(fromData: data) {
            if cachedArtworkByUrl.count > 12 {
                cachedArtworkByUrl.removeAll()
            }
            cachedArtworkByUrl[urlString] = encoded
            snap.artworkHash = encoded.hash
            snap.artworkBase64 = encoded.base64
        }
    }

    static func encodeThumbnail(fromData data: Data, maxSide: CGFloat = 240) -> (hash: String, base64: String)? {
        guard let image = NSImage(data: data) else { return nil }
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }

        let scale = min(1.0, min(maxSide / srcSize.width, maxSide / srcSize.height))
        let targetW = max(1, Int((srcSize.width * scale).rounded()))
        let targetH = max(1, Int((srcSize.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetW,
            pixelsHigh: targetH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetW, height: targetH),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return nil
        }
        let digest = SHA256.hash(data: jpegData)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return (hash, jpegData.base64EncodedString())
    }
}
