# Changelog

All notable changes to **Bridge** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and future releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.5] - 2026-11-14

### Added
- **2048-Bit SPEKE PAKE Handshake:** Replaced the static salted SHA-256 pairing challenge with a 2048-bit **SPEKE (Simple Password Exponential Key Exchange)** over the RFC 3526 Group 14 safe prime (`hello` $\to$ `challenge` $\to$ `auth` $\to$ `welcome`) in [`BridgeServer.swift`](mac-app/Sources/BridgeServer.swift) and [`NetworkSyncClient.kt`](android-app/app/src/main/java/com/link/clipboardsync/NetworkSyncClient.kt), preventing offline brute-force recovery of the 6-digit pairing code from captured handshakes and providing Perfect Forward Secrecy.
- **End-to-End AES-256-GCM Session Transport (`TCP :8765`):** Encrypted all post-handshake traffic on port `8765` (clipboard text/images, notifications, inline replies, settings sync, and file-transfer control messages) with directional **AES-256-GCM** keys, monotonic 64-bit sequence numbers, and AAD direction binding (`BridgeSessionCipher`).
- macOS `.dmg` drag-to-Applications installer (`Bridge-vX.Y.Z-macOS.dmg`) with custom dark-and-green branding and external drive volume icon (`mac-app/scripts/make-dmg.sh`, `make dmg` target, and release/CI workflows) replacing the `.zip` archive.
- Adaptive Liquid Glass / Dark Icons bundle (`mac-app/Resources/Bridge.icon` + `Assets.car`) so `Bridge.app` renders its green glyph on a dark background in macOS Dark Icons appearance instead of monochrome black-on-black.

### Fixed
- Fixed macOS menu bar popover displacing from beneath the status bar icon when 1–2 long or multi-message notifications arrive by wrapping the notification and transfer lists in `ViewThatFits(in: .vertical)` with a capped `ScrollView` ([`BridgeMenuView.swift`](mac-app/Sources/BridgeMenuView.swift)) and clamping popover height to the screen's visible frame ([`main.swift`](mac-app/Sources/main.swift)) ([#19](https://github.com/badruddin-tasnim/bridge/pull/19)).
- Removed the `NSWorkspace.shared.setIcon` `.icns` Finder override from [`mac-app/Makefile`](mac-app/Makefile) so macOS renders the `Assets.car` adaptive icon cleanly while keeping `Bridge.icns` as fallback.

### Security
- Resolved all 7 security findings tracked in [#9](https://github.com/badruddin-tasnim/bridge/issues/9):
  - Encrypted all `:8765` control and sync traffic with **AES-256-GCM** (`BridgeSessionCipher`) and rejected any unencrypted post-handshake messages.
  - Upgraded pairing authentication to **2048-bit SPEKE PAKE** (`BridgeSpeke`) so the 6-digit pairing code cannot be brute-forced offline from a recorded handshake.
  - Protected file-transfer `token` values inside the encrypted `:8765` channel and replaced raw token transmission on the secondary data socket with a one-way SHA-256 auth proof (`computeDataSocketAuth`).
  - Expanded `executableExtensions` coverage (`.command`, `.workflow`, `.scpt`, `.py`, `.jar`, `.webloc`, `.dylib`, etc.) so scripts/executables always prompt for confirmation even when auto-accept is enabled, and rejected symbolic links during folder archive extraction.
  - Updated [`SECURITY.md`](SECURITY.md) and [`README.md`](README.md) to reflect the `v1.3.5` cryptographic protocol.

## [1.3.2] - 2026-11-12

### Added
- Signed, R8-minified Android release APK builds (`assembleRelease`) in [`.github/workflows/release.yml`](.github/workflows/release.yml) and [`android-app/app/build.gradle.kts`](android-app/app/build.gradle.kts).
- Release verification instructions and Android APK signing certificate SHA-256 fingerprint in [`README.md`](README.md).
- Grouped monthly Dependabot configuration and least-privilege `contents: read` CI token permissions in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
- Android & macOS unit tests, Android Lint checks, and `CODE_OF_CONDUCT.md`.
- Fade and slide animation when opening and closing the macOS menu bar popover (fade only with Reduce Motion) in [`main.swift`](mac-app/Sources/main.swift).

### Fixed
- macOS builds now pass an explicit `-target` (minimum macOS 13.0) in [`mac-app/Makefile`](mac-app/Makefile). Previously binaries required the build machine's macOS version, so release builds would not launch on older macOS.

### Security
- Enforced global handshake rate-limiting (`globalLockoutUntil` across all IPs) and removed the legacy plaintext `code` login fallback in [`BridgeServer.swift`](mac-app/Sources/BridgeServer.swift).
- Restricted `FileTransferActionReceiver` with `android:exported="false"` in [`AndroidManifest.xml`](android-app/app/src/main/AndroidManifest.xml).
- Aligned [`SECURITY.md`](SECURITY.md), [`README.md`](README.md), and [`CONTRIBUTING.md`](CONTRIBUTING.md) with the current cryptographic and wire protocol implementation.

## [1.3.1] - 2026-11-10

### Fixed & Changed
- Stacked macOS notification banners now show the latest message first while keeping older messages visible when expanded.
- Added Disconnect / Connect controls on Android, fixed unpaired state handling, and synchronized remote unpairing across devices.
- Masked IP addresses by default in the macOS menu bar popover with an eye-icon toggle.
- Updated [`README.md`](README.md) documentation and screenshots.

## [1.3.0] - 2026-11-09

### Added
- High-speed encrypted local file and folder sharing (`AES-256-GCM` streaming + SHA-256 verification), Finder Quick Action / Share Extension, drag-and-drop onto menu bar icon, and custom Mac save location.
- Conversation-grouped notification threads and background file transfer progress notifications.

## [1.2] - 2026-11-05

### Added
- Interactive bidirectional notification mirroring (inline replies, action buttons, and synchronized dismissal).
- Simultaneous multi-device connectivity and real-time settings synchronization.
- Ground-up UI refresh across macOS and Android plus pairing/rate-limit hardening.

## [1.1.1] - 2026-11-02

### Added
- Android Wi-Fi caution banner and improved local network detection.

## [1.1.0] - 2026-11-02

### Added
- Two-way clipboard image and screenshot synchronization.
- In-app and system GitHub Release update notifications with 24-hour cooldown.

## [1.0.0] - 2026-11-02

### Added
- Initial public release of Bridge for Android and macOS.
- Two-way local-network text clipboard synchronization, Bonjour (`_clipboardsync._tcp`) discovery, and 6-digit / QR pairing.

[Unreleased]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.5...HEAD
[1.3.5]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.2...v1.3.5
[1.3.2]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.2...v1.3.0
[1.2]: https://github.com/badruddin-tasnim/bridge/compare/v1.1.1...v1.2
[1.1.1]: https://github.com/badruddin-tasnim/bridge/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/badruddin-tasnim/bridge/releases/tag/v1.0.0
