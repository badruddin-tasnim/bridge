import Foundation
import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

class BridgeModel: ObservableObject {
    @Published var rawCode: String = ""
    @Published var formattedCode: String = ""
    @Published var localIp: String = "127.0.0.1"
    @Published var port: Int = 8765
    @Published var deviceName: String = "Mac"
    @Published var isConnected: Bool = false
    @Published var connectedDevice: String? = nil
    @Published var lastSyncedText: String? = nil
    @Published var lastSyncedOutgoing: Bool = false
    @Published var qrCodeImage: NSImage? = nil
    @Published var copiedNotice: Bool = false
    @Published var dotBreathe: Bool = false
    @Published var showPairingSection: Bool = false {
        didSet {
            onSizeChangeRequested?()
        }
    }
    var onSizeChangeRequested: (() -> Void)?
    
    let server = BridgeServer()
    private var breatheTimer: Timer?
    
    init() {
        self.rawCode = server.pairingCode
        if rawCode.count == 6 {
            self.formattedCode = "\(rawCode.prefix(3)) \(rawCode.suffix(3))"
        } else {
            self.formattedCode = rawCode
        }
        
        self.deviceName = Host.current().localizedName ?? "Mac"
        self.port = Int(server.port.rawValue)
        self.localIp = getPrimaryIPv4Address() ?? "127.0.0.1"
        
        updateQrCode()
        setupServerCallbacks()
        server.start()
        
        breatheTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.dotBreathe.toggle()
        }
    }
    
    private func setupServerCallbacks() {
        server.onStatusChanged = { [weak self] connected, device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnected = connected
                self.connectedDevice = device
                if connected {
                    self.showPairingSection = false
                }
                self.onSizeChangeRequested?()
            }
        }
        
        server.onClipboardSynced = { [weak self] text, outgoing in
            guard let self = self else { return }
            self.lastSyncedText = text
            self.lastSyncedOutgoing = outgoing
        }
        
        server.onIpChanged = { [weak self] newIp in
            guard let self = self else { return }
            if self.localIp != newIp {
                self.localIp = newIp
                self.updateQrCode()
            }
        }
    }
    
    func updateQrCode() {
        let jsonDict: [String: Any] = [
            "bridge": "pair",
            "ip": localIp,
            "port": port,
            "code": rawCode,
            "name": deviceName
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        self.qrCodeImage = generateQrImage(from: jsonString)
    }
    
    private func generateQrImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 7, y: 7)
        let scaledImage = outputImage.transformed(by: scale)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
    
    func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawCode, forType: .string)
        copiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copiedNotice = false
        }
    }
    
    func unpair() {
        server.unpairAllDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            self.rawCode = self.server.pairingCode
            if self.rawCode.count == 6 {
                self.formattedCode = "\(self.rawCode.prefix(3)) \(self.rawCode.suffix(3))"
            } else {
                self.formattedCode = self.rawCode
            }
            self.updateQrCode()
            self.isConnected = false
            self.connectedDevice = nil
            self.showPairingSection = true
            self.onSizeChangeRequested?()
        }
    }
}
