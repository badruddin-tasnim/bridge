# Contributing to Bridge

Thank you for your interest in contributing to **Bridge**! Our goal is to build a fast, native, privacy-first continuity bridge between Android and macOS.

---

## 🛠️ Local Development Setup

Bridge consists of two native apps in a single repository:

### 1. macOS Menu Bar App (`mac-app/`)
- **Stack:** Swift, SwiftUI, AppKit (`NSPopover` + `NSStatusItem`), `Network.framework` (`NWListener`)
- **Requirements:** macOS 11.0+ and Xcode Command Line Tools (`xcode-select --install`)
- **Build & Run:**
  ```bash
  cd mac-app
  make clean && make
  make run
  ```

### 2. Android App (`android-app/`)
- **Stack:** Kotlin, XML Views, custom `Canvas` animations (`BridgeLinkView`), `Socket` + `NsdManager` (Bonjour/mDNS)
- **Requirements:** JDK 17+ and Android SDK (`compileSdk 34`, `minSdk 26`)
- **Build & Install:**
  ```bash
  cd android-app
  ./gradlew assembleDebug
  adb install -r app/build/outputs/apk/debug/app-debug.apk
  ```

---

## 📡 Wire Protocol Overview (`TCP :8765`)

Bridge uses newline-delimited JSON (`\n`) over a persistent TCP socket on port `8765`, advertised on the local network via Bonjour (`_clipboardsync._tcp`).

| Message `type` | Direction | Description |
| :--- | :---: | :--- |
| `hello` | Android → Mac | Initial handshake containing `code` (6-digit pairing code) and `device` (Android model name). |
| `welcome` | Mac → Android | Sent when `code` matches. Includes `name` (Mac hostname). Marks session authenticated. |
| `denied` | Mac → Android | Sent when `code` does not match. |
| `clip` | Bi-directional | Text clipboard sync payload containing `text`, `hash` (SHA-256 hex), and `timestamp`. |
| `ping` / `pong` | Bi-directional | Keepalive heartbeat exchanged every 10–12 seconds to keep NAT/router state warm. |
| `sleep` | Mac → Android | Broadcast immediately before macOS enters sleep so Android can pause and reconnect on wake. |
| `unpair` | Bi-directional | Terminates the pairing relationship on both devices and rotates the Mac's pairing code. |

---

## 📋 Pull Request Guidelines

1. **Keep It Native & Lightweight:** Avoid adding heavy third-party frameworks when platform APIs (`Network.framework`, `android.net.nsd`, `Canvas`) can do the job cleanly.
2. **Respect User Privacy:**
   - Never add analytics, telemetry, or external network requests.
   - Never log raw user content (clipboard text, notifications, file contents) to `Logcat` or `stdout`.
   - Do not add new Android permissions unless strictly required for a roadmap milestone, and always document them in `README.md`.
3. **Test Both Sides:** Verify that both `cd android-app && ./gradlew assembleDebug` and `cd mac-app && make` succeed before opening a PR.
