import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Security
import VideoToolbox

enum PhoneMirrorPacketType: UInt8 {
    case config = 0x01
    case frame = 0x02
    case geometry = 0x03
}

struct PhoneMirrorHandshake: Equatable {
    let token: String
    let width: Int
    let height: Int
    let rotation: Int

    static let byteLength = 69

    static func computeAuthProof(token: String, width: Int, height: Int, rotation: Int) -> String {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let safeW = min(max(1, width), 65535)
        let safeH = min(max(1, height), 65535)
        let safeRot = rotation & 0xFF
        let message = "bridge-mirror-auth-v1:\(normalizedToken):\(safeW):\(safeH):\(safeRot)"
        let digest = SHA256.hash(data: Data(message.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func parse(from data: Data) -> PhoneMirrorHandshake? {
        guard data.count >= byteLength else { return nil }
        let tokenData = data.subdata(in: 0..<64)
        guard let token = String(data: tokenData, encoding: .ascii)?.lowercased() else {
            return nil
        }
        let w = Int(UInt16(data[64]) << 8 | UInt16(data[65]))
        let h = Int(UInt16(data[66]) << 8 | UInt16(data[67]))
        let rot = Int(data[68])
        guard w > 0, h > 0 else { return nil }
        return PhoneMirrorHandshake(token: token, width: w, height: h, rotation: rot)
    }
}

/// Per-packet AES-256-GCM cipher matching Android's `PhoneMirrorStreamCipher`.
final class PhoneMirrorStreamCipher {
    private let key: SymmetricKey
    private let lock = NSLock()
    private let sendSalt: Data
    private var sendSeq: UInt64 = 0
    private var receiveSeq: UInt64 = 0

    init(token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let keyMaterial = SHA256.hash(data: Data("\(normalized):bridge-mirror-encryption".utf8))
        self.key = SymmetricKey(data: keyMaterial)
        var saltBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &saltBytes)
        self.sendSalt = Data(saltBytes)
    }

    func seal(type: UInt8, flags: UInt8, ptsUs: UInt64, plaintext: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let seq = sendSeq
        var iv = Data(capacity: 12)
        iv.append(sendSalt)
        var beSeq = seq.bigEndian
        withUnsafeBytes(of: &beSeq) { iv.append(contentsOf: $0) }
        guard let nonce = try? AES.GCM.Nonce(data: iv) else { return nil }
        let aad = Self.buildAad(type: type, flags: flags, ptsUs: ptsUs, seq: seq)
        guard let sealed = try? AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad),
              let combined = sealed.combined else {
            return nil
        }
        sendSeq = seq &+ 1
        return combined
    }

    func open(type: UInt8, flags: UInt8, ptsUs: UInt64, encryptedPayload: Data) -> Data? {
        guard encryptedPayload.count >= 28 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let seq = receiveSeq
        var expectedSeq = Data(capacity: 8)
        var beSeq = seq.bigEndian
        withUnsafeBytes(of: &beSeq) { expectedSeq.append(contentsOf: $0) }
        let actualSeqSlice = encryptedPayload.subdata(in: 4..<12)
        var diff: UInt8 = 0
        for i in 0..<8 {
            diff |= (actualSeqSlice[i] ^ expectedSeq[i])
        }
        guard diff == 0 else { return nil }

        let aad = Self.buildAad(type: type, flags: flags, ptsUs: ptsUs, seq: seq)
        guard let box = try? AES.GCM.SealedBox(combined: encryptedPayload),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad) else {
            return nil
        }
        receiveSeq = seq &+ 1
        return plain
    }

    private static func buildAad(type: UInt8, flags: UInt8, ptsUs: UInt64, seq: UInt64) -> Data {
        return Data("bridge-mirror-pkt-v1:\(type):\(flags):\(ptsUs):\(seq)".utf8)
    }
}

struct PhoneMirrorPacketHeader: Equatable {
    let type: PhoneMirrorPacketType
    let flags: UInt8
    let ptsUs: UInt64
    let length: Int

    var isKeyframe: Bool {
        (flags & 0x01) != 0
    }

    static let byteLength = 14
    static let maxPayloadLength = 8 * 1024 * 1024 // 8 MB safety bound per video frame

    static func parse(from data: Data) -> PhoneMirrorPacketHeader? {
        guard data.count >= byteLength else { return nil }
        guard let type = PhoneMirrorPacketType(rawValue: data[0]) else { return nil }
        let flags = data[1]

        var pts: UInt64 = 0
        for i in 2..<10 {
            pts = (pts << 8) | UInt64(data[i])
        }

        let len = (Int(data[10]) << 24) |
                  (Int(data[11]) << 16) |
                  (Int(data[12]) << 8) |
                  Int(data[13])

        guard len >= 0 && len <= maxPayloadLength else { return nil }
        return PhoneMirrorPacketHeader(type: type, flags: flags, ptsUs: pts, length: len)
    }
}

struct PhoneMirrorGeometry: Equatable {
    let width: Int
    let height: Int
    let rotation: Int

    static let byteLength = 5

    static func parse(from data: Data) -> PhoneMirrorGeometry? {
        guard data.count >= byteLength else { return nil }
        let w = Int(UInt16(data[0]) << 8 | UInt16(data[1]))
        let h = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        let rot = Int(data[4])
        guard w > 0, h > 0 else { return nil }
        return PhoneMirrorGeometry(width: w, height: h, rotation: rot)
    }
}

/// Coordinates aspect-fit video rect & normalized pointer mapping shared by UI + unit tests.
enum PhoneMirrorCoordinates {
    static func videoContentRect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              videoSize.width > 0, videoSize.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let drawW = videoSize.width * scale
        let drawH = videoSize.height * scale
        let x = bounds.minX + (bounds.width - drawW) * 0.5
        let y = bounds.minY + (bounds.height - drawH) * 0.5
        return CGRect(x: x, y: y, width: drawW, height: drawH)
    }

    /// Converts an AppKit view-local point (origin bottom-left when !isFlipped) to Android top-left normalized [0, 1].
    static func normalizedPoint(
        viewPoint: CGPoint,
        viewBounds: CGRect,
        videoSize: CGSize,
        isFlipped: Bool
    ) -> CGPoint? {
        let rect = videoContentRect(in: viewBounds, videoSize: videoSize)
        guard rect.width > 1, rect.height > 1 else { return nil }
        let clampedX = min(max(viewPoint.x, rect.minX), rect.maxX)
        let clampedY = min(max(viewPoint.y, rect.minY), rect.maxY)
        let xNorm = (clampedX - rect.minX) / rect.width
        let yNorm: CGFloat
        if isFlipped {
            yNorm = (clampedY - rect.minY) / rect.height
        } else {
            yNorm = (rect.maxY - clampedY) / rect.height
        }
        return CGPoint(
            x: min(max(xNorm, 0.0), 1.0),
            y: min(max(yNorm, 0.0), 1.0)
        )
    }
}

/// Hardware-accelerated H.264 Annex-B decoder powered by VideoToolbox.
final class PhoneVideoDecoder {
    private let decodeQueue = DispatchQueue(label: "com.link.bridge.h264decoder", qos: .userInteractive)

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var lastKeyframeRequestAt: TimeInterval = 0

    var onFrameDecoded: ((CGImage, Int, Int) -> Void)?
    var onKeyframeNeeded: (() -> Void)?

    deinit {
        resetSync()
    }

    func reset() {
        decodeQueue.async { [weak self] in
            self?.resetSync()
        }
    }

    private func resetSync() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        sps = nil
        pps = nil
    }

    func feedConfig(_ data: Data) {
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let converted = Self.convertAnnexBToAvcc(data)
            var updated = false
            if let newSps = converted.sps, newSps != self.sps {
                self.sps = newSps
                updated = true
            }
            if let newPps = converted.pps, newPps != self.pps {
                self.pps = newPps
                updated = true
            }
            if updated {
                self.rebuildSessionIfReady()
            }
        }
    }

    func feedFrame(_ data: Data, ptsUs: UInt64, isKeyframe: Bool) {
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let converted = Self.convertAnnexBToAvcc(data)
            var updatedParams = false
            if let newSps = converted.sps, newSps != self.sps {
                self.sps = newSps
                updatedParams = true
            }
            if let newPps = converted.pps, newPps != self.pps {
                self.pps = newPps
                updatedParams = true
            }
            if updatedParams || self.decompressionSession == nil {
                self.rebuildSessionIfReady()
            }

            guard !converted.avccData.isEmpty else { return }
            guard let formatDesc = self.formatDescription,
                  let session = self.decompressionSession else {
                self.requestKeyframeThrottled()
                return
            }

            self.decodeAvccData(
                converted.avccData,
                formatDescription: formatDesc,
                session: session,
                ptsUs: ptsUs
            )
        }
    }

    private func requestKeyframeThrottled() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastKeyframeRequestAt >= 0.75 {
            lastKeyframeRequestAt = now
            onKeyframeNeeded?()
        }
    }

    private func rebuildSessionIfReady() {
        guard let spsData = sps, let ppsData = pps else { return }

        var newDesc: CMVideoFormatDescription?
        let descStatus: OSStatus = spsData.withUnsafeBytes { spsRaw in
            ppsData.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-1)
                }
                let ptrs: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [spsData.count, ppsData.count]
                return ptrs.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newDesc
                        )
                    }
                }
            }
        }

        guard descStatus == noErr, let formatDesc = newDesc else {
            NSLog("[PhoneMirror] Failed creating CMVideoFormatDescription (status=%d)", descStatus)
            return
        }

        if let existing = decompressionSession,
           let currentDesc = formatDescription,
           VTDecompressionSessionCanAcceptFormatDescription(existing, formatDescription: formatDesc),
           CMFormatDescriptionEqual(currentDesc, otherFormatDescription: formatDesc) {
            return
        }

        if let existing = decompressionSession {
            VTDecompressionSessionInvalidate(existing)
            decompressionSession = nil
        }

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelBufferAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )

        guard sessionStatus == noErr, let session = newSession else {
            NSLog("[PhoneMirror] Failed creating VTDecompressionSession (status=%d)", sessionStatus)
            return
        }

        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.formatDescription = formatDesc
        self.decompressionSession = session
    }

    private func decodeAvccData(
        _ avccData: Data,
        formatDescription: CMVideoFormatDescription,
        session: VTDecompressionSession,
        ptsUs: UInt64
    ) {
        var blockBuffer: CMBlockBuffer?
        let count = avccData.count
        var createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let block = blockBuffer else { return }

        createStatus = avccData.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: ptr,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: count
            )
        }
        guard createStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleSize = count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sample = sampleBuffer else { return }

        var infoFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }
            var cgImage: CGImage?
            let cgStatus = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            guard cgStatus == noErr, let image = cgImage else { return }
            self?.onFrameDecoded?(image, image.width, image.height)
        }

        if decodeStatus == kVTInvalidSessionErr {
            decompressionSession = nil
            rebuildSessionIfReady()
            requestKeyframeThrottled()
        } else if decodeStatus != noErr {
            requestKeyframeThrottled()
        }
    }

    // MARK: - Annex-B <-> AVCC Utilities

    static func extractAnnexBNalus(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        let count = bytes.count
        var nalus: [Data] = []
        var naluStart: Int? = nil
        var i = 0

        while i < count {
            var startCodeLen = 0
            if i + 3 < count && bytes[i] == 0x00 && bytes[i + 1] == 0x00 && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01 {
                startCodeLen = 4
            } else if i + 2 < count && bytes[i] == 0x00 && bytes[i + 1] == 0x00 && bytes[i + 2] == 0x01 {
                startCodeLen = 3
            }

            if startCodeLen > 0 {
                if let prevStart = naluStart, i > prevStart {
                    nalus.append(Data(bytes[prevStart..<i]))
                }
                i += startCodeLen
                naluStart = i
            } else {
                i += 1
            }
        }

        if let prevStart = naluStart, prevStart < count {
            nalus.append(Data(bytes[prevStart..<count]))
        }
        return nalus
    }

    static func convertAnnexBToAvcc(_ data: Data) -> (avccData: Data, sps: Data?, pps: Data?, isIdr: Bool) {
        let nalus = extractAnnexBNalus(data)
        var avcc = Data()
        var sps: Data? = nil
        var pps: Data? = nil
        var isIdr = false

        for nalu in nalus where !nalu.isEmpty {
            let nalType = nalu[0] & 0x1F
            switch nalType {
            case 7:
                sps = nalu
            case 8:
                pps = nalu
            case 1...5:
                if nalType == 5 {
                    isIdr = true
                }
                var lengthBE = UInt32(nalu.count).bigEndian
                withUnsafeBytes(of: &lengthBE) { lenBytes in
                    avcc.append(contentsOf: lenBytes)
                }
                avcc.append(nalu)
            default:
                break
            }
        }
        return (avcc, sps, pps, isIdr)
    }
}
