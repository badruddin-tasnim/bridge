# Changelog

All notable changes to **Bridge** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and future releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Signed, R8-minified Android release APK builds (`assembleRelease`) in [`.github/workflows/release.yml`](.github/workflows/release.yml) and [`android-app/app/build.gradle.kts`](android-app/app/build.gradle.kts).
- Release verification instructions and Android APK signing certificate SHA-256 fingerprint in [`README.md`](README.md).
- Grouped monthly Dependabot configuration and least-privilege `contents: read` CI token permissions in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).
- Android & macOS unit tests, Android Lint checks, and `CODE_OF_CONDUCT.md`.

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

[Unreleased]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.2...v1.3.0
[1.2]: https://github.com/badruddin-tasnim/bridge/compare/v1.1.1...v1.2
[1.1.1]: https://github.com/badruddin-tasnim/bridge/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/badruddin-tasnim/bridge/releases/tag/v1.0.0
