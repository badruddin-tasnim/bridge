<div align="center">

<img src="mac-app/Resources/BridgeLogoMark@2x.png" width="96" height="96" alt="Bridge Icon" />

# bridge

### **Android and Mac, connected.**

A lightweight, native open-source bridge that links your **Android phone** and your **Mac** over your local Wi-Fi network—with zero cloud accounts, zero telemetry, and zero latency.

<p align="center">
  <img src="https://img.shields.io/badge/Version-v1.0.0-C8F135?style=for-the-badge&labelColor=0E0F12" alt="Version 1.0.0" />
  <img src="https://img.shields.io/badge/Android-Kotlin-C8F135?style=for-the-badge&logo=android&logoColor=C8F135&labelColor=0E0F12" alt="Android Kotlin" />
  <img src="https://img.shields.io/badge/macOS-Swift_%26_SwiftUI-C8F135?style=for-the-badge&logo=apple&logoColor=C8F135&labelColor=0E0F12" alt="macOS Swift" />
  <img src="https://img.shields.io/badge/Network-100%25_Local_LAN-181B20?style=for-the-badge&labelColor=0E0F12&color=C8F135" alt="100% Local LAN" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-9BA3AD?style=for-the-badge&labelColor=0E0F12" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="#-bridge---features-v10">Features</a> •
  <a href="#-roadmap-upcoming-versions">Roadmap</a> •
  <a href="#-getting-started-v10">Download & Install</a> •
  <a href="#-how-to-pair--use-bridge">How to Use</a> •
  <a href="#-security-privacy--permissions-transparency">Security & Permissions</a>
</p>

</div>

---

> [!IMPORTANT]
> **Active Open-Source Project (`v1.0`)**  
> **Bridge** is built to be a complete continuity bridge between Android and macOS—not just a single-purpose utility. `v1.0` establishes the native local-network link engine, instant QR & 6-digit pairing, automatic Bonjour/mDNS discovery, sleep/wake resilience, and real-time background clipboard synchronization. Upcoming versions will roll out **clipboard image sync**, **notification sync**, and **direct file & media transfer** one by one.

---

## ✨ Bridge - Features (v1.0)

| Feature | Description |
| :--- | :--- |
| **⚡ Instant QR & 6-Digit Pairing** | Open Bridge in your Mac's menu bar and scan the QR code from the Android app—or type the 6-digit pairing code—to link your devices in seconds. |
| **📡 Zero-Config Bonjour Discovery** | Automatically discovers your Mac on your local Wi-Fi via mDNS (`_clipboardsync._tcp`), seamlessly handling router DHCP IP changes. |
| **💻 Sleep & Lid-Close Resilience** | Gracefully pauses when you close your MacBook lid and automatically re-establishes the link within seconds when your Mac wakes up. |
| **🔄 Seamless Background Sync** | Keeps your Android phone and Mac in step in the background—starting in `v1.0` with instant, bi-directional text clipboard synchronization. |
| **🛡️ 100% Local Wi-Fi Architecture** | Every packet travels directly between your phone and your Mac over your local router (`TCP :8765`). Zero cloud relays, zero accounts, zero tracking. |

---

## 🗺️ Roadmap (Upcoming Versions)

Bridge is evolving step by step into a full cross-device ecosystem link between Android and macOS:

| Version | Milestone | Status | Details |
| :--- | :--- | :---: | :--- |
| **`v1.0`** | **Core Link Engine & Text Sync** | ![Shipped](https://img.shields.io/badge/LIVE-C8F135?style=flat-square&labelColor=0E0F12) | Native macOS menu bar app & Android app, QR / 6-digit pairing, Bonjour auto-discovery, sleep/wake auto-reconnect, and two-way text clipboard sync. |
| **`v1.1`** | **Clipboard Image & Screenshot Sync** | ![Next Up](https://img.shields.io/badge/IN_PROGRESS-181B20?style=flat-square&color=C8F135) | Copy an image or take a screenshot on your phone or Mac and paste it directly on the other device. |
| **`v1.2`** | **Notification Sync** | ![Planned](https://img.shields.io/badge/PLANNED-2B2F36?style=flat-square&color=9BA3AD) | View, manage, and dismiss Android notifications directly from your Mac in real time. |
| **`v1.3`** | **Direct File & Media Transfer** | ![Planned](https://img.shields.io/badge/PLANNED-2B2F36?style=flat-square&color=9BA3AD) | Drag and drop files into the Mac menu bar popover or share from Android's share sheet for full-speed local Wi-Fi transfers. |
| **`v1.4+`** | **Quick Actions & E2E Encryption** | ![Planned](https://img.shields.io/badge/PLANNED-2B2F36?style=flat-square&color=9BA3AD) | Battery status, media playback controls, Find My Phone ring, and TLS/Noise channel encryption. |

---

## 🚀 Getting Started (v1.0)

You can install Bridge either by downloading the pre-built release binaries directly from [**GitHub Releases**](../../releases), using terminal commands, or building from source.

### Option 1: Direct Download (Easiest)

1. Visit the [**Releases**](../../releases) page and download the two `v1.0.0` packages:
   - 💻 **`Bridge-v1.0.0-macOS.zip`** — Native macOS Menu Bar App (`macOS 11.0+`)
   - 📱 **`Bridge-v1.0.0-Android.apk`** — Native Android App (`Android 8.0+`)
2. **Install on macOS:**
   - Unzip `Bridge-v1.0.0-macOS.zip` and move **`Bridge.app`** into `/Applications`.
   - Launch **`Bridge.app`**. *(If macOS Gatekeeper prompts on first launch, right-click `Bridge.app` → **Open**, or run `xattr -cr /Applications/Bridge.app && open /Applications/Bridge.app` in Terminal).*
   - The Bridge icon will appear in your Mac's top menu bar.
3. **Install on Android:**
   - Open **`Bridge-v1.0.0-Android.apk`** on your Android phone to install the app.

---

### Option 2: Install via Command Line (CLI)

If you prefer installing directly from your terminal using `curl` and `adb`:

```bash
# 1. Download & launch the macOS Menu Bar app in /Applications
curl -L -o /tmp/Bridge-macOS.zip "https://github.com/badruddin-tasnim/bridge/releases/download/v1.0.0/Bridge-v1.0.0-macOS.zip"
unzip -q -o /tmp/Bridge-macOS.zip -d /Applications
xattr -cr /Applications/Bridge.app
open /Applications/Bridge.app

# 2. Download & install the Android APK over ADB (with your phone plugged in via USB)
curl -L -o /tmp/Bridge-Android.apk "https://github.com/badruddin-tasnim/bridge/releases/download/v1.0.0/Bridge-v1.0.0-Android.apk"
adb install -r /tmp/Bridge-Android.apk
```

---

### Option 3: Build from Source

<details>
<summary><b>Click to expand build instructions (Swift & Gradle)</b></summary>

#### Prerequisites
- **macOS:** macOS 11.0+ with Xcode Command Line Tools (`xcode-select --install`)
- **Android:** JDK 17+ and Android SDK (`compileSdk 34`)

#### Build & Run on macOS
```bash
cd mac-app
make clean && make
make install   # Copies Bridge.app to /Applications/Bridge.app
make run       # Starts Bridge in your Mac menu bar
```

#### Build & Install on Android
```bash
cd android-app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
</details>

---

## 🔗 How to Pair & Use Bridge

1. **Same Wi-Fi Network:** Connect both your Android phone and your Mac to the same Wi-Fi network.
2. **Open Bridge on Your Mac:** Click the **Bridge** icon in the macOS menu bar to reveal your QR code and 6-digit pairing code.
3. **Link from Android:**
   - Open **Bridge** on your Android phone.
   - Tap **Scan QR code** and point your camera at the Mac menu bar popover *(or type the 6-digit code into the boxes and tap **Connect**)*.
   - *Tip:* If you are on a corporate/guest Wi-Fi network that blocks multicast (mDNS), tap **Enter IP address instead** on Android and enter the `IP:port` displayed at the bottom-left of the Mac popover.
4. **One-Time Background Setup on Android:**
   - Grant **Notifications** and **Unrestricted Battery** when prompted so Android doesn't put the socket to sleep while your phone is locked.
   - Tap **Enable in Settings** on the **Bridge Background Service** banner to turn on **Bridge Background Link** inside Android Accessibility Settings.
5. **Connected!** Your Mac popover will switch to `ONLINE` and your phone will display `Linked`. To disconnect or switch devices at any time, click the **Unpair** icon button in the Mac menu bar or tap **Unpair this Mac** on Android.

---

## 🔒 Security, Privacy & Permissions Transparency

As an open-source project that links your personal devices, **Bridge is designed to be 100% auditable and transparent**:

### Core Security Principles
- **Zero Cloud / Zero Telemetry:** Bridge has no analytics SDKs, no crash-reporting trackers, and no external API calls. All traffic stays strictly on your local LAN (`192.168.x.x` / `10.x.x.x`).
- **Unique Per-Mac Pairing Secret:** Each Mac generates a random 6-digit pairing code stored locally in `~/.bridge_pairing_code`. Unpairing from the Mac menu bar immediately terminates active sockets and rotates the pairing code.
- **Redacted Diagnostic Logs:** Logcat statements never log plaintext clipboard contents—only character counts and 8-character SHA-256 hash prefixes used for loop prevention.
- **No Cloud Credential Backups:** `android:allowBackup="false"` is enforced in [`AndroidManifest.xml`](android-app/app/src/main/AndroidManifest.xml) so local pairing state is never backed up to third-party servers.
- **Non-Exported Internal Components:** Internal helper activities and services (`ClipboardReaderActivity`, `PortraitCaptureActivity`, `ClipboardSyncForegroundService`) are strictly marked `android:exported="false"`.

### Why Each Permission Is Needed

Every permission declared in [`AndroidManifest.xml`](android-app/app/src/main/AndroidManifest.xml) is required for a specific, verifiable function:

| Permission | Purpose in Bridge | Source Reference |
| :--- | :--- | :--- |
| `INTERNET` | Opens a direct local TCP socket (`:8765`) between your phone and your Mac over your Wi-Fi router. Never connects to external internet hosts. | [`NetworkSyncClient.kt`](android-app/app/src/main/java/com/link/clipboardsync/NetworkSyncClient.kt) |
| `ACCESS_NETWORK_STATE`<br>`ACCESS_WIFI_STATE` | Detects Wi-Fi state changes so Bridge can automatically reconnect when you switch networks or wake your device. | [`NetworkSyncClient.kt`](android-app/app/src/main/java/com/link/clipboardsync/NetworkSyncClient.kt) |
| `CHANGE_WIFI_MULTICAST_STATE`<br>`WAKE_LOCK` | Required by Android's Bonjour/mDNS (`NsdManager`) to discover your Mac on Wi-Fi and by `WifiLock` to keep the radio from dropping idle connections. | [`ClipboardSyncForegroundService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncForegroundService.kt) |
| `FOREGROUND_SERVICE`<br>`FOREGROUND_SERVICE_CONNECTED_DEVICE` | Keeps the socket connection to your Mac alive in the background so OEM battery managers don't freeze the process. | [`ClipboardSyncForegroundService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncForegroundService.kt) |
| `POST_NOTIFICATIONS` | Displays the silent ongoing status notification (`"Connected with <Mac Name>"`) required by Android for active foreground services. | [`ClipboardSyncForegroundService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncForegroundService.kt) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Prompts once to exempt Bridge from Android Doze mode so your devices stay linked when your phone screen is off. | [`MainActivity.kt`](android-app/app/src/main/java/com/link/clipboardsync/MainActivity.kt) |
| `CAMERA` | Used **only** when you tap **"Scan QR code"** to scan the pairing QR code on your Mac. Camera frames are decoded in-memory by ZXing and never saved. | [`MainActivity.kt`](android-app/app/src/main/java/com/link/clipboardsync/MainActivity.kt) |
| `BIND_ACCESSIBILITY_SERVICE` | **Why it's needed:** Android 10+ blocks background apps from reading the clipboard unless they hold window focus. When enabled, [`ClipboardSyncAccessibilityService`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncAccessibilityService.kt) listens **only** for copy events (`typeViewClicked` on "Copy"/"Cut" actions or "Copied to clipboard" system toasts) and briefly opens an invisible 0-ms activity ([`ClipboardReaderActivity`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardReaderActivity.kt)) to sync the copied text to your Mac. It never logs keystrokes or scrapes screen content. | [`ClipboardSyncAccessibilityService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncAccessibilityService.kt)<br>[`accessibility_service_config.xml`](android-app/app/src/main/res/xml/accessibility_service_config.xml) |

---

## 🤝 Contributing

Contributions, bug reports, and feature ideas are welcome as we build out the `v1.x` roadmap! Feel free to open an issue or submit a pull request.

## 📄 License

Released under the [MIT License](LICENSE).
