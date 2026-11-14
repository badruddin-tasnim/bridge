import Foundation
import Combine

enum FileTransferDirection: String, Codable {
    case outgoing = "outgoing" // Mac -> Android
    case incoming = "incoming" // Android -> Mac
}

enum FileTransferStatus: Equatable {
    case hashing
    case waitingConfirmation // Waiting for user or peer accept
    case transferring
    case paused
    case verifying
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .hashing, .waitingConfirmation, .transferring, .verifying:
            return true
        default:
            return false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

class FileTransferItem: ObservableObject, Identifiable {
    let id: String
    let fileName: String
    var fileSize: Int64
    var expectedSha256: String
    let direction: FileTransferDirection
    let deviceId: UUID?
    let deviceName: String
    let sourceUrl: URL?
    @Published var destinationUrl: URL?
    var partUrl: URL?
    let isFolder: Bool
    var tempArchiveUrl: URL?

    @Published var bytesTransferred: Int64 = 0
    @Published var speedBytesPerSec: Double = 0
    @Published var status: FileTransferStatus = .waitingConfirmation
    @Published var completedAt: Date? = nil
    let createdAt: Date = Date()

    init(
        id: String,
        fileName: String,
        fileSize: Int64,
        expectedSha256: String = "",
        direction: FileTransferDirection,
        deviceId: UUID?,
        deviceName: String,
        sourceUrl: URL? = nil,
        destinationUrl: URL? = nil,
        partUrl: URL? = nil,
        isFolder: Bool = false,
        tempArchiveUrl: URL? = nil,
        status: FileTransferStatus = .waitingConfirmation
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.expectedSha256 = expectedSha256
        self.direction = direction
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.sourceUrl = sourceUrl
        self.destinationUrl = destinationUrl
        self.partUrl = partUrl
        self.isFolder = isFolder
        self.tempArchiveUrl = tempArchiveUrl
        self.status = status
    }

    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesTransferred) / Double(fileSize)))
    }

    var percentageInt: Int {
        return Int((progress * 100.0).rounded())
    }

    var formattedProgressSize: String {
        return "\(Self.formatBytes(bytesTransferred)) / \(Self.formatBytes(fileSize))"
    }

    var formattedTotalSize: String {
        return Self.formatBytes(fileSize)
    }

    var formattedSpeed: String {
        guard speedBytesPerSec > 0 else { return "" }
        return "\(Self.formatBytes(Int64(speedBytesPerSec)))/s"
    }

    var remainingTimeText: String {
        guard status == .transferring else { return "" }
        let remainingBytes = fileSize - bytesTransferred
        guard remainingBytes > 0, speedBytesPerSec > 10_000 else { return "" }
        let seconds = Int((Double(remainingBytes) / speedBytesPerSec).rounded())
        if seconds < 5 {
            return "A few seconds remaining"
        } else if seconds < 60 {
            return "About \(seconds) sec remaining"
        } else if seconds < 3600 {
            let mins = max(1, (seconds + 30) / 60)
            return "About \(mins) min remaining"
        } else {
            let hours = (seconds + 1800) / 3600
            return "About \(hours) hr remaining"
        }
    }

    var iconSymbolName: String {
        if isFolder {
            return "folder.fill"
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "svg":
            return "photo.fill"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return "film.fill"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "music.note"
        case "zip", "tar", "gz", "7z", "rar", "dmg", "iso":
            return "doc.zipper"
        case "pdf":
            return "doc.richtext.fill"
        case "apk", "app":
            return "shippingbox.fill"
        default:
            return "doc.fill"
        }
    }

    static let executableExtensions: Set<String> = [
        "sh", "command", "bash", "zsh", "csh", "ksh", "fish",
        "app", "pkg", "mpkg", "dmg", "workflow", "action",
        "scpt", "scptd", "applescript", "webloc", "url", "inetloc",
        "apk", "dex", "jar", "class",
        "exe", "bat", "cmd", "msi", "msp", "vbs", "wsf", "hta", "ps1", "com", "scr", "pif", "cpl", "gadget",
        "bin", "tool", "run", "elf", "py", "rb", "pl", "php", "js", "mjs",
        "dylib", "so", "bundle", "kext", "prefpane", "qlgenerator", "mdimporter", "saver", "xpc"
    ]

    var isExecutable: Bool {
        if isFolder { return false }
        let ext = (fileName as NSString).pathExtension.lowercased()
        return Self.executableExtensions.contains(ext)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1.0 {
            return "\(bytes) B"
        }
        let mb = kb / 1024.0
        if mb < 1.0 {
            return String(format: "%.1f KB", kb)
        }
        let gb = mb / 1024.0
        if gb < 1.0 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.2f GB", gb)
    }
}
