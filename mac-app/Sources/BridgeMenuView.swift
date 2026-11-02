import SwiftUI
import AppKit

// MARK: - Design Tokens & Styles

struct BridgeColors {
    static let ink = Color(red: 0x0E / 255.0, green: 0x0F / 255.0, blue: 0x12 / 255.0)
    static let bg = Color(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0)
    static let panel = Color(red: 0x1C / 255.0, green: 0x1F / 255.0, blue: 0x25 / 255.0)
    static let line = Color(red: 0x2B / 255.0, green: 0x2F / 255.0, blue: 0x36 / 255.0)
    static let line2 = Color(red: 0x3A / 255.0, green: 0x3F / 255.0, blue: 0x47 / 255.0)
    static let text = Color(red: 0xF4 / 255.0, green: 0xF5 / 255.0, blue: 0xF2 / 255.0)
    static let soft = Color(red: 0xC9 / 255.0, green: 0xCE / 255.0, blue: 0xD4 / 255.0)
    static let muted = Color(red: 0x9B / 255.0, green: 0xA3 / 255.0, blue: 0xAD / 255.0)
    static let lime = Color(red: 0xC8 / 255.0, green: 0xF1 / 255.0, blue: 0x35 / 255.0)
    static let coral = Color(red: 0xFF / 255.0, green: 0x9A / 255.0, blue: 0x8A / 255.0)
}

struct BridgeLogoMark: View {
    var body: some View {
        if let img = loadCrispLogo() {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(BridgeColors.lime)
                .frame(width: 32, height: 32)
        }
    }
    
    private func loadCrispLogo() -> NSImage? {
        if let path2x = Bundle.main.path(forResource: "BridgeLogoMark@2x", ofType: "png"),
           let img2x = NSImage(contentsOfFile: path2x) {
            img2x.size = NSSize(width: 32, height: 32)
            return img2x
        }
        if let path = Bundle.main.path(forResource: "BridgeLogoMark", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 32, height: 32)
            return img
        }
        return nil
    }
}

/// Crisp vector unlink / unpair icon in a 24x24 coordinate space
struct UnlinkIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 24.0
        let sy = rect.height / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        
        // Top-right link half
        path.move(to: pt(18.84, 12.25))
        path.addLine(to: pt(20.56, 10.54))
        path.addCurve(to: pt(20.44, 3.47), control1: pt(22.45, 8.65), control2: pt(22.40, 5.43))
        path.addCurve(to: pt(13.49, 3.47), control1: pt(18.52, 1.55), control2: pt(15.41, 1.55))
        path.addLine(to: pt(11.77, 5.18))
        
        // Bottom-left link half
        path.move(to: pt(5.17, 11.75))
        path.addLine(to: pt(3.46, 13.46))
        path.addCurve(to: pt(3.58, 20.53), control1: pt(1.57, 15.35), control2: pt(1.62, 18.57))
        path.addCurve(to: pt(10.53, 20.53), control1: pt(5.50, 22.45), control2: pt(8.61, 22.45))
        path.addLine(to: pt(12.24, 18.82))
        
        // Break ticks (top-left & bottom-right)
        path.move(to: pt(8, 2))
        path.addLine(to: pt(8, 5))
        path.move(to: pt(2, 8))
        path.addLine(to: pt(5, 8))
        path.move(to: pt(16, 19))
        path.addLine(to: pt(16, 22))
        path.move(to: pt(19, 16))
        path.addLine(to: pt(22, 16))
        
        return path
    }
}

// MARK: - Main Menu Bar View

struct BridgeMenuView: View {
    @ObservedObject var model: BridgeModel
    
    var body: some View {
        VStack(spacing: 12) {
            // Header Bar
            HStack(spacing: 10) {
                BridgeLogoMark()
                
                Text("bridge")
                    .font(.custom("PlusJakartaSans-Medium", size: 21))
                    .foregroundColor(BridgeColors.text)
                    .kerning(-0.4)
                
                Spacer()
                
                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.isConnected ? BridgeColors.lime : BridgeColors.muted)
                        .frame(width: 7, height: 7)
                        .scaleEffect(model.dotBreathe && model.isConnected ? 0.8 : 1.0)
                        .opacity(model.dotBreathe && model.isConnected ? 0.35 : 1.0)
                        .animation(
                            model.isConnected
                                ? Animation.easeInOut(duration: 1.2)
                                : .default,
                            value: model.dotBreathe
                        )
                    
                    Text(model.isConnected ? "ONLINE" : "WAITING")
                        .font(.custom("DMMono-Regular", size: 11))
                        .foregroundColor(model.isConnected ? BridgeColors.lime : BridgeColors.muted)
                        .kerning(0.88)
                }
            }
            .padding(.top, 4)

            // Update Notification Banner (Dismissible for 24 hours)
            if let updateVer = model.availableUpdateVersion {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bridge v\(updateVer) is available")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 13.5))
                            .foregroundColor(BridgeColors.text)
                            .lineLimit(1)

                        Text("New release ready on GitHub")
                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Button(action: {
                        model.openUpdateDownload()
                    }) {
                        Text("Update")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 12))
                            .foregroundColor(BridgeColors.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(BridgeColors.lime)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        model.dismissUpdateForToday()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(BridgeColors.muted)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss for today")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(BridgeColors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(BridgeColors.lime.opacity(0.35), lineWidth: 1)
                )
            }
            
            // Device Card (Visible while connected)
            if model.isConnected {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(BridgeColors.lime)
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: "iphone")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(BridgeColors.ink)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.connectedDevice ?? "Galaxy A52s")
                            .font(.custom("PlusJakartaSans-Medium", size: 15.5))
                            .foregroundColor(BridgeColors.text)
                            .kerning(-0.15)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        
                        Text("Linked to this Mac, same Wi-Fi")
                            .font(.custom("PlusJakartaSans-Regular", size: 12.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    .layoutPriority(1)
                    
                    Spacer(minLength: 6)
                    
                    Button(action: {
                        model.unpair()
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(BridgeColors.coral.opacity(0.08))
                                .frame(width: 34, height: 34)
                            
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(BridgeColors.coral.opacity(0.38), lineWidth: 1)
                                .frame(width: 34, height: 34)
                            
                            UnlinkIconShape()
                                .stroke(
                                    BridgeColors.coral,
                                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                                )
                                .frame(width: 15, height: 15)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Unpair device")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(BridgeColors.panel)
                )
                
                // Toggle Button to pair another phone
                Button(action: {
                    model.showPairingSection.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: model.showPairingSection ? "chevron.up" : "plus.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(BridgeColors.lime)
                        
                        Text(model.showPairingSection ? "Hide pairing code" : "Pair another phone")
                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                            .foregroundColor(BridgeColors.soft)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(BridgeColors.line2, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            
            // Pairing Card (Visible when NOT connected, OR when user clicks "Pair another phone")
            if !model.isConnected || model.showPairingSection {
                VStack(spacing: 12) {
                    Text(model.isConnected ? "PAIR ANOTHER PHONE" : "PAIR YOUR PHONE")
                        .font(.custom("DMMono-Regular", size: 11))
                        .foregroundColor(BridgeColors.muted)
                        .kerning(1.54)
                        .padding(.top, 4)
                    
                    // 176pt off-white QR tile
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(BridgeColors.text)
                            .frame(width: 176, height: 176)
                        
                        if let qrImg = model.qrCodeImage {
                            Image(nsImage: qrImg)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .frame(width: 176, height: 176)
                        }
                    }
                    
                    Text("Open Bridge on Android and point it here")
                        .font(.custom("PlusJakartaSans-Regular", size: 13.5))
                        .foregroundColor(BridgeColors.soft)
                        .multilineTextAlignment(.center)
                    
                    // Rule
                    Rectangle()
                        .fill(BridgeColors.line)
                        .frame(height: 1)
                        .padding(.horizontal, 4)
                    
                    // 6-digit code row with Copy button
                    HStack(spacing: 12) {
                        Text(model.formattedCode)
                            .font(.custom("DMMono-Medium", size: 30))
                            .foregroundColor(BridgeColors.lime)
                            .kerning(1.8)
                        
                        Button(action: {
                            model.copyPairingCode()
                        }) {
                            Text(model.copiedNotice ? "Copied" : "Copy")
                                .font(.custom("PlusJakartaSans-Medium", size: 14))
                                .foregroundColor(model.copiedNotice ? BridgeColors.ink : BridgeColors.text)
                                .frame(minWidth: 84, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(model.copiedNotice ? BridgeColors.lime : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(model.copiedNotice ? BridgeColors.lime : BridgeColors.line2, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 4)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(BridgeColors.panel)
                )
            }
            
            // Footer Bar
            HStack {
                Text("\(model.localIp):\(String(model.port))")
                    .font(.custom("DMMono-Regular", size: 12))
                    .foregroundColor(BridgeColors.muted)
                
                Spacer()
                
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Text("Quit Bridge")
                        .font(.custom("PlusJakartaSans-Regular", size: 12))
                        .foregroundColor(BridgeColors.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 360)
        .background(BridgeColors.bg)
    }
}
