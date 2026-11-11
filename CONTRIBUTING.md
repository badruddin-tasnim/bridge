# Contributing to Bridge

Thank you for your interest in contributing to **Bridge**! Our mission is to build an open, ultra-fast, native, and privacy-first continuity bridge between Android and macOS without third-party cloud accounts, telemetry, or proprietary lock-in.

---

## 🛠️ Local Development Setup

Bridge is structured as a native multi-platform repository:

### 1. macOS Menu Bar App (`mac-app/`)
- **Stack:** Swift, SwiftUI, AppKit (`NSPopover` + `NSStatusItem`), `CryptoKit` (AES-GCM), `Network.framework` (`NWListener`), UserNotifications, UniformTypeIdentifiers.
- **Extensions:** Finder Quick Action (`BridgeQuickAction.appex`) and macOS Share Extension (`BridgeShare.appex`).
- **Requirements:** macOS 14.0+ and Xcode Command Line Tools (`xcode-select --install`).
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
| **`hello`** | Android → Mac | Initial client handshake carrying `hash` (`SHA-256("bridge-hello:" + code + ":" + clientNonce)`), `text` (`clientNonce`), and `device` name. |
| **`welcome`** | Mac → Android | Server handshake acknowledgment carrying `hash` (`SHA-256("bridge-welcome:" + code + ":" + clientNonce)`) and `name` (Mac hostname). |
| **`denied`** | Mac → Android | Sent when handshake verification fails or client IP is rate-limited. |
| **`clip`** | Bi-directional | Text clipboard sync payload with `text`, `hash` (SHA-256 digest), and `timestamp`. |
| **`image`** | Bi-directional | Screenshot/image sync payload carrying Base64 `data`, `mime` (`image/png` or `image/jpeg`), `hash`, and `text` (`"[Image]"`). |
| **`notif_post`** | Android → Mac | Mirrored notification payload with `id`, `pkg`, `app`, `title`, `text`, optional `icon` (Base64 PNG), `actions`, and `messages`. |
| **`notif_remove` / `notif_sync`** | Android → Mac | Removes dismissed Android notifications or synchronizes active notification IDs on Mac. |
| **`notif_action`** | Mac → Android | Action button tap or inline reply (`id`, `actionId`, optional `replyText`) routed back to Android. |
| **`notif_dismiss`**| Bi-directional | Two-way notification dismissal synchronization (`id`, `target`). |
| **`settings_sync`**| Bi-directional | Real-time settings synchronization (notification mirroring toggles and `autoAcceptFiles`). |
| **`file_offer` / `file_request`** | Bi-directional | Proposes a file or zipped folder transfer (`id`, `name`, `size`, `sha256`, `isFolder`; `file_offer` also sends `port`, `token`, `resume`). |
| **`file_accept` / `file_reject`**| Bi-directional | Accepts (with `port`, `token`, `offset`) or declines (`reason`) a transfer request. |
| **`file_pause` / `file_resume` / `file_cancel` / `file_complete` / `file_error`** | Bi-directional | Transfer lifecycle state messages keyed by `id`. |
| **`ping` / `pong`**| Bi-directional | Keepalive heartbeat sent every 2.5–3 seconds (`ping` → `pong`) to detect dropped connections quickly. |
| **`sleep`** | Mac → Android | Sent before macOS enters system sleep so Android can drop and cleanly reconnect on wake. |
| **`disconnect`** | Android → Mac | Cleanly closes the current session while keeping pairing credentials intact. |
| **`unpair`** | Bi-directional | Terminates pairing and clears/rotates pairing credentials on both devices. |

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
   - Before opening a pull request, verify that both platforms build and pass tests/lint cleanly:
     ```bash
     cd mac-app && make test && make clean && make
     cd ../android-app && ./gradlew testDebugUnitTest lintDebug assembleDebug
     ```
6. **Branching Model:**
   - Submit PRs against the `main` branch.
   - Use descriptive branch names: `feature/<feature-name>`, `fix/<issue-name>`, or `refactor/<scope>`.
