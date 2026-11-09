# Contributing to Bridge

Thank you for your interest in contributing to **Bridge**! Our mission is to build an open, ultra-fast, native, and privacy-first continuity bridge between Android and macOS without third-party cloud accounts, telemetry, or proprietary lock-in.

---

## 🛠️ Local Development Setup

Bridge is structured as a native multi-platform repository:

### 1. macOS Menu Bar App (`mac-app/`)
- **Stack:** Swift, SwiftUI, AppKit (`NSPopover` + `NSStatusItem`), `CryptoKit` (AES-GCM), `Network.framework` (`NWListener`), UserNotifications, UniformTypeIdentifiers.
- **Extensions:** Finder Quick Action (`BridgeQuickAction.appex`) and macOS Share Extension (`BridgeShare.appex`).
- **Requirements:** macOS 11.0+ and Xcode Command Line Tools (`xcode-select --install`).
- **Build & Run:**
  ```bash
  cd mac-app
  make clean && make
  make install   # Installs to /Applications/Bridge.app
  make run       # Launches Bridge in your menu bar
  ```

### 2. Android App (`android-app/`)
- **Stack:** Kotlin, Jetpack, Coroutines, custom `Canvas` animations (`BridgeLinkView`), `Socket` + `NsdManager` (mDNS/Bonjour), Storage Access Framework (SAF), NotificationListenerService, AccessibilityService.
- **Requirements:** JDK 17+ and Android SDK (`compileSdk 34`, `minSdk 26`).
- **Build & Install:**
  ```bash
  cd android-app
  ./gradlew assembleDebug
  adb install -r app/build/outputs/apk/debug/app-debug.apk
  ```

---

## 📡 Wire Protocol Specification (`TCP :8765`)

Bridge uses newline-delimited JSON (`\n`) for metadata control framing over a persistent TCP socket on port `8765`, discovered automatically on the local network via Bonjour (`_clipboardsync._tcp`). High-speed binary file streams utilize framed AES-GCM data chunks.

### Control & Data Message Types

| Message `type` | Direction | Description |
| :--- | :---: | :--- |
| **`hello`** | Android → Mac | Initial client handshake containing `proof` (salted SHA-256 HMAC of pairing code + client nonce), `nonce`, and `device` name. |
| **`welcome`** | Mac → Android | Server handshake acknowledgment containing `proof` (matching response salt) and `name` (Mac hostname). Authorizes session. |
| **`denied`** | Mac → Android | Sent when handshake proof fails or client IP is rate-limited. |
| **`clip`** | Bi-directional | Text clipboard sync payload with `text`, `hash` (SHA-256 digest), and `timestamp`. |
| **`image_clip`** | Bi-directional | Screenshot/image sync payload carrying image data, dimension metadata, and verification token. |
| **`notification`** | Android → Mac | Mirrored Android status bar notification payload with app identifier, sender, conversation thread, icon, and action descriptors. |
| **`notif_reply`** | Mac → Android | Inline quick reply text sent from macOS popover/banner to Android's active notification key. |
| **`notif_action`** | Mac → Android | Action button tap event (e.g. *Mark as Read*, *Archive*) routed back to Android. |
| **`notif_dismiss`**| Bi-directional | Two-way notification dismissal synchronization. |
| **`settings_sync`**| Bi-directional | Real-time settings synchronization (notification mirroring toggles, auto-accept file transfer preferences). |
| **`file_offer`** | Bi-directional | File transfer proposal with filename, file size, SHA-256 digest, and mime type. |
| **`file_response`**| Bi-directional | Accept or decline response for an offered file transfer. |
| **`file_cancel`** | Bi-directional | Halts an ongoing file or folder transfer in real-time. |
| **`ping` / `pong`**| Bi-directional | Keepalive heartbeat exchanged every 10–12 seconds to keep router NAT state open. |
| **`sleep`** | Mac → Android | Broadcast before macOS enters system sleep so Android can pause polling and cleanly reconnect on wake. |
| **`unpair`** | Bi-directional | Terminates pairing relationships and triggers credential rotation on both platforms. |

---

## 📋 Pull Request & Contribution Guidelines

1. **Native & Lightweight Above All:**
   - Prefer native platform APIs (`Network.framework`, `CryptoKit`, `android.net.nsd`, `java.security`) over bloated external dependencies.
2. **Zero-Cloud & Zero-Telemetry:**
   - Bridge will **never** include third-party tracking, analytics, or cloud infrastructure. All features must work 100% peer-to-peer on a local network or hotspot.
3. **No Plaintext Logging:**
   - Never log raw clipboard text, notification messages, replies, or file payloads to `Logcat` or console output. Use truncated SHA-256 hashes for debugging.
4. **Security & Sanitization:**
   - File transfer implementations must strictly sanitize paths and block directory traversal attacks (`../`).
   - Android permissions must follow least-privilege principles and be documented in `README.md`.
5. **Pre-Submission Verification:**
   - Before opening a pull request, verify that both platforms build cleanly:
     ```bash
     cd mac-app && make clean && make
     cd ../android-app && ./gradlew assembleDebug
     ```
6. **Branching Model:**
   - Submit PRs against the `main` branch.
   - Use descriptive branch names: `feature/<feature-name>`, `fix/<issue-name>`, or `refactor/<scope>`.
