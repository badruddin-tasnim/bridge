<div align="center">

<img src="mac-app/Resources/BridgeLogoMark@2x.png" width="96" height="96" alt="Bridge Icon" />

# bridge

### **Android and Mac, seamlessly connected.**

A lightweight, native open-source bridge linking your **Android phone** and your **Mac** over your local Wi-Fi network—with zero cloud accounts, zero telemetry, and zero latency.

<p align="center">
  <img src="https://img.shields.io/badge/Version-v1.3.5-C8F135?style=for-the-badge&labelColor=0E0F12" alt="Version 1.3.5" />
  <img src="https://img.shields.io/badge/Android-Kotlin-C8F135?style=for-the-badge&logo=android&logoColor=C8F135&labelColor=0E0F12" alt="Android Kotlin" />
  <img src="https://img.shields.io/badge/macOS-Swift_%26_SwiftUI-C8F135?style=for-the-badge&logo=apple&logoColor=C8F135&labelColor=0E0F12" alt="macOS Swift" />
  <img src="https://img.shields.io/badge/Network-100%25_Local_LAN-181B20?style=for-the-badge&labelColor=0E0F12&color=C8F135" alt="100% Local LAN" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-9BA3AD?style=for-the-badge&labelColor=0E0F12" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="#-whats-new-in-v135">What's New in v1.3.5</a> •
  <a href="#-key-features">Key Features</a> •
  <a href="#-getting-started">Getting Started</a> •
  <a href="#-pairing--multi-device-connection">Pairing & Multi-Device</a> •
  <a href="#-security-privacy--architecture-transparency">Security & Privacy</a>
</p>

<table align="center">
  <tr>
    <td align="center"><b>macOS Menu Bar App (Local File Sharing & Transfer)</b></td>
    <td align="center"><b>Android App (3-Tab Floating Pill Navigation)</b></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/mac/04-mac-connected-transfer.png" width="380" alt="macOS Menu Bar Popover with File Sharing & Live Transfer" /></td>
    <td align="center"><img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/android/01-android-home-connected.png" width="240" alt="Android App Connected Screen" /></td>
  </tr>
</table>

</div>

---

> [!NOTE]
> **Active Open-Source Project**  
> Bridge is an actively maintained open-source project updated on a regular basis with continuous stability enhancements, new features, and design improvements. Star the repository to follow releases and upcoming roadmap milestones.

---

## ⚡ What's New in v1.3.5

Bridge **v1.3.5** introduces end-to-end encrypted local control transport, 2048-bit SPEKE PAKE authentication, and macOS menu bar UI stability fixes:

- **2048-Bit SPEKE PAKE Handshake** — Replaced the static salted SHA-256 pairing challenge with a 2048-bit **SPEKE (Simple Password Exponential Key Exchange)** over RFC 3526 Group 14 (`hello` $\to$ `challenge` $\to$ `auth` $\to$ `welcome`), preventing offline brute-force recovery of the 6-digit pairing code from captured handshakes and providing Perfect Forward Secrecy (PFS).
- **End-to-End AES-256-GCM Session Transport (`TCP :8765`)** — All post-handshake control and sync traffic (clipboard text/images, mirrored notifications, inline replies, settings sync, and file-transfer control headers) is now encrypted with directional **AES-256-GCM** session keys, monotonic sequence numbers, and AAD direction binding.
- **Hardened File Sharing & Menu Bar Popover Scroll Fix** — Incoming file auto-accept now defaults to off (`false`) with expanded executable/script/bundle extension guards and hashed data-socket auth proofs (`computeDataSocketAuth`), plus fixed the macOS menu bar popover displacing when long multi-message notifications arrive (`ViewThatFits` + screen height clamping).

---

## ✨ Key Features

### 📁 High-Speed Encrypted Local File & Folder Sharing
* **Unlimited Transfers:** Transfer single files, batches, or full directory structures directly between Mac and Android with zero file size limits.
* **Direct LAN Stream:** Transfers stream straight across your local network or hotspot with hardware-accelerated AES-GCM encryption and post-transfer SHA-256 verification.
* **Folder Structure Integrity:** Directories are packaged cleanly without OS metadata (`.DS_Store`, `__MACOSX`, `Thumbs.db`) using fast deflate compression.
* **Native OS Shortcuts:** Drag and drop onto the macOS menu bar icon, right-click in Finder to "Share with Bridge", or share from Android's system share sheet (`ACTION_SEND`).
* **Custom Save Locations:** Choose your custom downloads folder on both Mac (via persistent Security-Scoped Bookmarks) and Android (via Storage Access Framework).

### 📋 Two-Way Clipboard Synchronization (Text & Photos)
* **Instant Text Copy:** Copy any text, code snippet, or link on your phone or Mac; immediately paste it on the other device with zero extra taps.
* **Screenshot & Image Sync:** Copy an image in Preview, capture a macOS screenshot (`Cmd+Shift+4`), or copy a photo on Android—it syncs directly into the other device's pasteboard.
* **Echo Suppression:** Robust SHA-256 digest hashing prevents infinite clipboard feedback loops.

### 🔔 Interactive Notification Mirroring
* **Instant Forwarding:** Phone notifications appear instantly in the macOS menu bar popover and as native macOS notification banners with app icons.
* **Inline Quick Reply:** Type and send replies directly to messages without touching your phone.
* **Smart Filtering:** Persistent background services and duplicate group summaries are automatically filtered out to keep your Mac feed clean.
* **Bidirectional Settings Sync:** Toggle notification sync on either phone or Mac with changes synchronized across both devices in real time.
* **Mac Alert Mirroring:** Optionally forward Mac system notifications to your Android device with smart duplicate detection (drops alerts for apps already installed on your phone).

### ⚡ Seamless Local Connectivity
* **Zero-Config Bonjour Discovery:** Discovers your Mac automatically on Wi-Fi via mDNS (`_clipboardsync._tcp`), adapting seamlessly to DHCP router changes.
* **Sleep & Wake Resilience:** Automatically pauses when your MacBook lid closes and re-establishes the connection within 1.5 seconds upon waking.
* **100% Local Wi-Fi:** All communication travels strictly over your local router on `TCP :8765`. Zero cloud servers, zero third-party accounts, zero tracking.

### 📱 Multiple Device Connectivity
* **One Mac, Multiple Phones:** Keep your personal and work phones linked to your MacBook at the same time.
* **Unified Feed:** Notifications from both devices are displayed with individual device tags.
* **Selective Unpairing:** Unpair or disconnect one phone without affecting other active devices.

---

## 🚀 Getting Started

You can install Bridge by downloading the pre-built binaries from [**GitHub Releases**](../../releases), using terminal commands, or building from source.

### Option 1: Direct Download

1. Download the latest release assets from [**Releases**](../../releases):
   - 💻 **`Bridge-v*-macOS.dmg`** — Native macOS Menu Bar App (`macOS 13.0+`)
   - 📱 **`Bridge-v*-Android.apk`** — Native Android App (`Android 8.0+`)
2. **Install on macOS:**
   - Double-click the downloaded **`.dmg`** file and drag **`Bridge.app`** into the **Applications** folder in the installer window.
   - Launch **`Bridge.app`**. *(If macOS Gatekeeper prompts on first launch, right-click `Bridge.app` → **Open**, or run `xattr -cr /Applications/Bridge.app && open /Applications/Bridge.app` in Terminal).*
   - The Bridge icon will appear in your top menu bar.
3. **Install on Android:**
   - Open the downloaded **`.apk`** on your Android phone to install the app.
   - **Android 14–16 Google Play Protect Notice:** Because Bridge uses `BIND_NOTIFICATION_LISTENER_SERVICE` and `BIND_ACCESSIBILITY_SERVICE`, Play Protect's sideload fraud protection on newer Android devices may block opening the APK from a browser or file manager (*"App blocked to protect your device"*). If that happens, install from your Mac using **ADB** instead (Option 2 below):
     ```bash
     adb install -r /tmp/Bridge-Android.apk
     ```
   - **Android 13+ Restricted Settings:** If **Accessibility** or **Notification Access** appears grayed out after sideloading, open **Settings → Apps → Bridge → ⋮ (top right) → Allow restricted settings**, then enable the permissions.

---

### Option 2: Install via Command Line (CLI)

```bash
TAG=$(curl -fsSL https://api.github.com/repos/badruddin-tasnim/bridge/releases/latest | grep -m1 '"tag_name"' | cut -d'"' -f4)

# 1. Download, install, and launch the macOS Menu Bar app
curl -L -o /tmp/Bridge-macOS.dmg "https://github.com/badruddin-tasnim/bridge/releases/download/${TAG}/Bridge-${TAG}-macOS.dmg"
hdiutil attach -nobrowse -quiet /tmp/Bridge-macOS.dmg
rm -rf /Applications/Bridge.app && cp -R /Volumes/Bridge/Bridge.app /Applications/Bridge.app
hdiutil detach /Volumes/Bridge -quiet
xattr -cr /Applications/Bridge.app
open /Applications/Bridge.app

# 2. Download & install the Android APK over ADB
curl -L -o /tmp/Bridge-Android.apk "https://github.com/badruddin-tasnim/bridge/releases/download/${TAG}/Bridge-${TAG}-Android.apk"
adb install -r /tmp/Bridge-Android.apk
```

---

### Option 3: Build from Source

<details>
<summary><b>Click to expand build instructions (Swift & Gradle)</b></summary>

#### Prerequisites
- **macOS:** macOS 13.0+ with Xcode Command Line Tools (`xcode-select --install`)
- **Android:** JDK 17+ and Android SDK (`compileSdk 34`)

#### Build macOS Menu Bar App
```bash
cd mac-app
make clean && make
make install   # Installs Bridge.app to /Applications/Bridge.app
make run       # Launches Bridge in your menu bar
make dmg       # Packages a drag-to-Applications Bridge-macOS.dmg installer
```

#### Build Android App
```bash
cd android-app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
</details>

### Verify Release Downloads

All official release assets include `SHA256SUMS.txt` on the GitHub Release page. Starting in `v1.3.2`, release APKs are also signed with Bridge's dedicated Android release certificate:

```bash
# 1. Verify archive & APK checksums against SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt

# 2. Verify the Android APK signing certificate SHA-256 fingerprint
apksigner verify --print-certs Bridge-*-Android.apk
```

Expected Android signing certificate SHA-256 digest:

```text
AC:40:63:01:B9:1F:9D:49:65:8D:37:12:3D:4C:D6:A7:F7:91:13:2C:D7:BB:3A:3F:51:F5:60:BD:60:B9:77:DC
```

---

## 🔗 Pairing & Multi-Device Connection

Pairing your devices is fast, private, and requires zero account creation:

<table align="center">
  <tr>
    <td align="center" width="50%"><b>Step 1: Open Mac Menu Bar</b></td>
    <td align="center" width="50%"><b>Step 2: Scan QR or Enter Code on Phone</b></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/mac/01-mac-unpaired-waiting.png" width="340" alt="macOS Unpaired Waiting Screen" /></td>
    <td align="center"><img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/android/09-android-unpaired-pairing-screen.png" width="240" alt="Android Pairing Screen" /></td>
  </tr>
  <tr>
    <td align="center" width="50%"><b>Step 3: Permissions & Device Controls</b></td>
    <td align="center" width="50%"><b>Step 4: Connected & Ready</b></td>
  </tr>
  <tr>
    <td align="center"><img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/android/02-android-settings-permissions-devices.png" width="240" alt="Android Permissions and Device Management Screen" /></td>
    <td align="center"><img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/mac/03-mac-connected-devices.png" width="340" alt="macOS Connected Ready Screen" /></td>
  </tr>
</table>

### Step-by-Step Instructions:

1. **Connect to Same Wi-Fi:** Ensure your Android phone and Mac are connected to the same local Wi-Fi network. *(Tip: When traveling or away from home, you can also connect your Mac directly to your phone's Personal Hotspot).*
2. **Open Bridge on Mac:** Click the **Bridge** icon in your Mac menu bar. It displays your instant QR code and 6-digit code.
3. **Scan or Type Code on Android:**
   - Tap **Scan QR code** in the Android app and point your camera at the Mac menu bar popover.
   - *Alternatively:* Enter the 6-digit pairing code shown on your Mac.
   - *Manual IP:* If on an enterprise network blocking multicast (mDNS), tap **Enter IP address instead** and click the eye icon in the bottom bar of the Mac popover to view your `IP:port`.
4. **Grant Permissions on Android:**
   - **Notification Access:** Allows Bridge to mirror your incoming notifications and route quick replies.
   - **Accessibility Service:** Android 10+ restricts background apps from reading the clipboard. Bridge uses an accessibility event listener to capture copy actions without screen reading or keylogging.
   - **Battery Optimization Exemption:** Prevents OEM task killers from freezing background sync when your phone is locked.
5. **Adding Another Phone:**
   - Click **Add another phone** in the Mac popover anytime.
   - The QR drawer expands smoothly without disconnecting your existing device.
   - Scan with your second device to link both phones simultaneously!

<div align="center">
  <img src="https://raw.githubusercontent.com/badruddin-tasnim/bridge/assets/mac/10-mac-connected-add-another-phone.png" width="380" alt="Pairing another phone simultaneously" />
  <p><i>Expand "Add another phone" anytime to connect an additional device.</i></p>
</div>

---

## 🔒 Security, Privacy & Architecture Transparency

Bridge is built to be **100% local, zero-cloud, and auditable** (see [SECURITY.md](SECURITY.md) for full cryptographic specifications).

### 1. 2048-Bit SPEKE PAKE Authentication & End-to-End AES-256-GCM Transport
* **Zero-knowledge PAKE handshake (`BridgeSpeke`):** Devices authenticate using a 2048-bit **SPEKE (Simple Password Exponential Key Exchange)** over RFC 3526 Group 14 ($p = 2q + 1$). Neither the 6-digit pairing code nor any static hash of it is sent before Diffie-Hellman key agreement, preventing offline brute-force attacks against recorded handshakes and providing **Perfect Forward Secrecy (PFS)**.
* **Encrypted control & data channels (`BridgeSessionCipher`):** All post-handshake traffic on `TCP :8765` (clipboard text/images, notifications, inline replies, settings sync, and file-transfer control messages) is encrypted with directional **AES-256-GCM** keys, monotonic 64-bit sequence numbers, and AAD direction binding. File-transfer data streams are likewise encrypted with **AES-256-GCM** and authenticated via one-way SHA-256 data-socket proofs (`computeDataSocketAuth`).

### 2. Brute-Force & Denial-of-Service Defense
* **Per-IP Exponential Lockout:** 5 failed handshake attempts from an IP within 60 seconds trigger an immediate 60-second lockout, doubling exponentially on consecutive violations up to 960 seconds.
* **Global Rate-Limiting:** 10 failed handshake attempts across all IPs within 60 seconds trigger a 30-second global handshake lockout.
* **Anti-Replay Nonce Caching:** Caches the most recent 256 handshake nonces to reject replayed `hello` packets.
* **Unauthenticated Handshake Timeout:** Connections that do not authenticate within 8 seconds are automatically dropped.
* **Bounded Buffers:** Unauthenticated connections are restricted to 8 KB max payload size (and max 4 concurrent unauthenticated sockets) to mitigate memory exhaustion and socket DoS.

### 3. Local Network Boundary Enforcement
* Bridge rejects connections originating from public or non-private IP addresses.
* Only local LAN addresses (RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, link-local `169.254.0.0/16`, CGNAT `100.64.0.0/10`, and loopback/link-local IPv6) are accepted.
* Pairing codes on macOS are stored with strict POSIX `0600` permissions (`~/.bridge_pairing_code`).

### 4. Transparent Permission Usage

| Permission | Exact Purpose in Bridge | Source Reference |
| :--- | :--- | :--- |
| `BIND_NOTIFICATION_LISTENER_SERVICE` | Reads incoming Android status bar notifications to mirror them to your Mac and delivers replies/dismissals back to apps. | [`BridgeNotificationListenerService.kt`](android-app/app/src/main/java/com/link/clipboardsync/BridgeNotificationListenerService.kt) |
| `BIND_ACCESSIBILITY_SERVICE` | Detects copy events on Android 10+ so clipboard text can be synced without background polling. Does not read screen text or log keystrokes. | [`ClipboardSyncAccessibilityService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncAccessibilityService.kt) |
| `INTERNET` | Establishes the local LAN TCP socket (`:8765`) between phone and Mac. Checks GitHub API for new releases. | [`NetworkSyncClient.kt`](android-app/app/src/main/java/com/link/clipboardsync/NetworkSyncClient.kt) |
| `CAMERA` | Active only when scanning the pairing QR code. Video frames are decoded in memory and discarded immediately. | [`MainActivity.kt`](android-app/app/src/main/java/com/link/clipboardsync/MainActivity.kt) |
| `POST_NOTIFICATIONS` | Displays the persistent foreground notification required by Android to keep the background sync engine alive. | [`ClipboardSyncForegroundService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncForegroundService.kt) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Prevents Android Doze mode from killing the socket connection when the device is locked. | [`MainActivity.kt`](android-app/app/src/main/java/com/link/clipboardsync/MainActivity.kt) |

---

## 🤝 Contributing

Contributions, bug reports, and suggestions are welcome! Feel free to open an issue or submit a pull request.

## 📄 License

Released under the [MIT License](LICENSE).
