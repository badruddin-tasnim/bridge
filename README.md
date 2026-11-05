<div align="center">

<img src="mac-app/Resources/BridgeLogoMark@2x.png" width="96" height="96" alt="Bridge Icon" />

# bridge

### **Android and Mac, seamlessly connected.**

A lightweight, native open-source bridge linking your **Android phone** and your **Mac** over your local Wi-Fi network—with zero cloud accounts, zero telemetry, and zero latency.

<p align="center">
  <img src="https://img.shields.io/badge/Version-v1.2-C8F135?style=for-the-badge&labelColor=0E0F12" alt="Version 1.2" />
  <img src="https://img.shields.io/badge/Android-Kotlin-C8F135?style=for-the-badge&logo=android&logoColor=C8F135&labelColor=0E0F12" alt="Android Kotlin" />
  <img src="https://img.shields.io/badge/macOS-Swift_%26_SwiftUI-C8F135?style=for-the-badge&logo=apple&logoColor=C8F135&labelColor=0E0F12" alt="macOS Swift" />
  <img src="https://img.shields.io/badge/Network-100%25_Local_LAN-181B20?style=for-the-badge&labelColor=0E0F12&color=C8F135" alt="100% Local LAN" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-9BA3AD?style=for-the-badge&labelColor=0E0F12" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="#-whats-new-in-v12">What's New in v1.2</a> •
  <a href="#-key-features">Key Features</a> •
  <a href="#-getting-started">Getting Started</a> •
  <a href="#-pairing--multi-device-connection">Pairing & Multi-Device</a> •
  <a href="#-security-privacy--permissions-transparency">Security & Privacy</a> •
  <a href="#-bug-fixes-in-v12">Bug Fixes</a>
</p>

<table align="center">
  <tr>
    <td align="center"><b>macOS Menu Bar App (Interactive Notifications)</b></td>
    <td align="center"><b>Android App (Floating Pill Navigation)</b></td>
  </tr>
  <tr>
    <td align="center"><img src="screenshots/mac/04-mac-connected-notifications-active.png" width="380" alt="macOS Menu Bar Popover with Interactive Notifications" /></td>
    <td align="center"><img src="screenshots/android/01-android-home-connected.png" width="240" alt="Android App Connected Screen" /></td>
  </tr>
</table>

</div>

---

> [!NOTE]
> **Active Open-Source Project**  
> Bridge is an actively maintained open-source project updated on a regular basis with continuous stability enhancements, new features, and design improvements. Star the repository to follow releases and upcoming roadmap milestones.

---

## ⚡ What's New in v1.2

Bridge **v1.2** introduces interactive bidirectional notifications, multi-device connectivity, end-to-end security hardening, and a ground-up UI refresh:

1. **Interactive Notification Mirroring & Quick Reply:**
   - Real-time notification mirroring from Android to macOS.
   - Reply directly to chat messages (WhatsApp, Telegram, Signal, SMS, Slack) from the Mac menu bar popover or native macOS notification banners.
   - Tap action buttons (e.g. *Mark as Read*, *Archive*, *Call Back*) directly from your Mac.
   - Two-way dismissal sync: clearing a notification on your phone immediately dismisses it from your Mac, and dismissing on Mac dismisses it on Android.

2. **Multiple Device Connectivity:**
   - Link multiple Android phones to a single Mac simultaneously.
   - Mac clipboard broadcasts to all connected phones at once.
   - Notifications from all phones mirror concurrently with smart per-device routing for replies and actions.
   - Pair an additional phone anytime without interrupting the active connection.

3. **Complete UI/UX Overhaul:**
   - **Android:** Redesigned dark interface featuring an elevated floating pill navigation bar, smooth sliding pill indicators, tactile haptic feedback, and modern permission cards.
   - **macOS:** Adaptive, flicker-free dark popover with smooth QR code drawer animation, native SF Symbols & Plus Jakarta Sans typography, and zero window jumping.

4. **Hardened Local Security Suite:**
   - Zero-knowledge mutual authentication: pairing codes are never transmitted in plaintext over the wire.
   - Anti-replay nonce tracking and exponential per-IP brute-force lockout.
   - Strict unauthenticated rate-limiting, connection timeouts, and memory buffer bounds.

---

## ✨ Key Features

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

1. Download the latest **`v1.2`** release assets from [**Releases**](../../releases):
   - 💻 **`Bridge-v1.2-macOS.zip`** — Native macOS Menu Bar App (`macOS 11.0+`)
   - 📱 **`Bridge-v1.2-Android.apk`** — Native Android App (`Android 8.0+`)
2. **Install on macOS:**
   - Unzip `Bridge-v1.2-macOS.zip` and move **`Bridge.app`** into `/Applications`.
   - Launch **`Bridge.app`**. *(If macOS Gatekeeper prompts on first launch, right-click `Bridge.app` → **Open**, or run `xattr -cr /Applications/Bridge.app && open /Applications/Bridge.app` in Terminal).*
   - The Bridge icon will appear in your top menu bar.
3. **Install on Android:**
   - Open **`Bridge-v1.2-Android.apk`** on your Android phone to install the app.

---

### Option 2: Install via Command Line (CLI)

```bash
# 1. Download & launch the macOS Menu Bar app
curl -L -o /tmp/Bridge-macOS.zip "https://github.com/badruddin-tasnim/bridge/releases/download/v1.2/Bridge-v1.2-macOS.zip"
unzip -q -o /tmp/Bridge-macOS.zip -d /Applications
xattr -cr /Applications/Bridge.app
open /Applications/Bridge.app

# 2. Download & install the Android APK over ADB
curl -L -o /tmp/Bridge-Android.apk "https://github.com/badruddin-tasnim/bridge/releases/download/v1.2/Bridge-v1.2-Android.apk"
adb install -r /tmp/Bridge-Android.apk
```

---

### Option 3: Build from Source

<details>
<summary><b>Click to expand build instructions (Swift & Gradle)</b></summary>

#### Prerequisites
- **macOS:** macOS 11.0+ with Xcode Command Line Tools (`xcode-select --install`)
- **Android:** JDK 17+ and Android SDK (`compileSdk 34`)

#### Build macOS Menu Bar App
```bash
cd mac-app
make clean && make
make install   # Installs Bridge.app to /Applications/Bridge.app
make run       # Launches Bridge in your menu bar
```

#### Build Android App
```bash
cd android-app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
</details>

---

## 🔗 Pairing & Multi-Device Connection

Pairing your devices is fast, private, and requires zero account creation:

<table align="center">
  <tr>
    <td align="center" width="50%"><b>Step 1: Open Mac Menu Bar</b></td>
    <td align="center" width="50%"><b>Step 2: Scan QR or Enter Code on Phone</b></td>
  </tr>
  <tr>
    <td align="center"><img src="screenshots/mac/01-mac-unpaired-waiting.png" width="340" alt="macOS Unpaired Waiting Screen" /></td>
    <td align="center"><img src="screenshots/android/09-android-unpaired-pairing-screen.png" width="240" alt="Android Pairing Screen" /></td>
  </tr>
  <tr>
    <td align="center" width="50%"><b>Step 3: Enable Permissions</b></td>
    <td align="center" width="50%"><b>Step 4: Connected & Ready</b></td>
  </tr>
  <tr>
    <td align="center"><img src="screenshots/android/02-android-home-connected-permissions-needed.png" width="240" alt="Android Permissions Screen" /></td>
    <td align="center"><img src="screenshots/mac/03-mac-connected-notifications-empty.png" width="340" alt="macOS Connected Ready Screen" /></td>
  </tr>
</table>

### Step-by-Step Instructions:

1. **Connect to Same Wi-Fi:** Ensure your Android phone and Mac are connected to the same local Wi-Fi network. *(Tip: When traveling or away from home, you can also connect your Mac directly to your phone's Personal Hotspot).*
2. **Open Bridge on Mac:** Click the **Bridge** icon in your Mac menu bar. It displays your instant QR code and 6-digit code.
3. **Scan or Type Code on Android:**
   - Tap **Scan QR code** in the Android app and point your camera at the Mac menu bar popover.
   - *Alternatively:* Enter the 6-digit pairing code shown on your Mac.
   - *Manual IP:* If on an enterprise network blocking multicast (mDNS), tap **Enter IP address manually** and input the `IP:port` shown in the bottom bar of the Mac popover.
4. **Grant Permissions on Android:**
   - **Notification Access:** Allows Bridge to mirror your incoming notifications and route quick replies.
   - **Accessibility Service:** Android 10+ restricts background apps from reading the clipboard. Bridge uses an accessibility event listener to capture copy actions without screen reading or keylogging.
   - **Battery Optimization Exemption:** Prevents OEM task killers from freezing background sync when your phone is locked.
5. **Adding Another Phone:**
   - Click **Add another phone** in the Mac popover anytime.
   - The QR drawer expands smoothly without disconnecting your existing device.
   - Scan with your second device to link both phones simultaneously!

<div align="center">
  <img src="screenshots/mac/10-mac-connected-add-another-phone.png" width="380" alt="Pairing another phone simultaneously" />
  <p><i>Expand "Add another phone" anytime to connect an additional device.</i></p>
</div>

---

## 🔒 Security, Privacy & Architecture Transparency

Bridge is built from the ground up to be **100% private, local, and auditable**.

### 1. Zero-Knowledge Nonce-Hashed Authentication
* Pairing codes are **never transmitted in plaintext** across the network.
* Handshake authentication uses a challenge-response scheme:
  $$\text{Proof} = \text{SHA-256}(\text{"bridge-hello:"} + \text{PairingCode} + \text{":"} + \text{ClientNonce})$$
* Mutual authentication: The Mac verifies the client's proof and responds with a matching salted welcome proof before any data socket is authorized.

### 2. Brute-Force & Denial-of-Service Defense
* **Per-IP Exponential Lockout:** 5 failed handshake attempts from an IP results in an immediate 15-second lockout, doubling on each subsequent violation up to 240 seconds.
* **Global Rate-Limiting:** Coordinated attempts trigger a 30-second global handshake halt.
* **Anti-Replay Nonce Caching:** Prevents replay attacks by invalidating reused authentication nonces.
* **Unauthenticated Handshake Timeout:** Connections that do not authenticate within 8 seconds are automatically dropped.
* **Bounded Buffers:** Unauthenticated connections are restricted to 8 KB max payload size to eliminate buffer overflow and socket exhaustion attacks.

### 3. Local Network Boundary Enforcement
* Bridge rejects connections originating from public or non-private IP addresses.
* Only local LAN addresses (RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, link-local `169.254.0.0/16`, and loopback) are accepted.
* Pairing secrets are stored with strict POSIX `0600` permissions (`~/.bridge_pairing_code`).

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

## 🛠️ Bug Fixes in v1.2

* **Popover Shift & Layout Glitch:** Fixed an issue where clicking "Add another phone" shifted the macOS popover position and clipped UI elements.
* **Fixed Height Clipping:** Eliminated hardcoded frame constraints that cut off text and buttons in macOS menu bar views.
* **Notification Key Newline Parsing:** Fixed an issue where apps encoding keys in base64 with trailing newlines (e.g. WhatsApp) failed to match on dismissal.
* **Real-Time Dismissal Reconciliation:** Fixed stale notifications remaining on Mac after being cleared on the phone while the connection was briefly reconnecting.
* **Clipboard Image Provider Hardening:** Implemented cryptographically secure tokens and strict path validation in `ClipboardImageProvider`.

---

## 🤝 Contributing

Contributions, bug reports, and suggestions are welcome! Feel free to open an issue or submit a pull request.

## 📄 License

Released under the [MIT License](LICENSE).
