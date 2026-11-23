# Changelog

All notable changes to **Bridge** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and future releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.4.0] - 2026-11-23

### Added
- **In-App Phone Mirroring (Zero ADB Required):** Real-time Android-to-Mac display streaming using `MediaProjection` + H.264 `MediaCodec` ([`ScreenMirrorForegroundService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ScreenMirrorForegroundService.kt), [`PhoneMirrorController.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneMirrorController.kt)) and hardware Apple `VideoToolbox` decoding ([`PhoneVideoDecoder.swift`](mac-app/Sources/PhoneVideoDecoder.swift), [`PhoneMirrorManager.swift`](mac-app/Sources/PhoneMirrorManager.swift)), presented in a borderless iPhone Mirroring-style macOS window ([`PhoneMirrorWindowController.swift`](mac-app/Sources/PhoneMirrorWindowController.swift)) with hover-reveal controls (`Screen Dim`, `Pin on Top`, `Back`, `Home`, `Recents`), two-finger trackpad swipes, Mac keyboard input (`⌘C`, `⌘X`, `⌘V`, `⌘A`, `⌘1`–`⌘4`), auto-hidden phone keyboard, and physical phone screen dimming.
- **Calls on Mac with Live Duration & Multi-App Controls:** Native macOS Notification Center frosted-glass floating call banner ([`CallBannerPanelController.swift`](mac-app/Sources/CallBannerPanelController.swift)) showing resolved caller names and app icons for cellular and VoIP calls (Telegram, Messenger, WhatsApp), live `MM:SS` active call duration timer, **Accept / Decline / Silence** and active **Mute / End Call** controls ([`PhoneCallMonitor.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneCallMonitor.kt)), plus optional **Auto-Pause Mac Media** ([`MacMediaPauser.swift`](mac-app/Sources/MacMediaPauser.swift)).
- **Bidirectional Universal Now Playing & Remote Device Controls:** Control Android media playback and volume from Mac ([`PhoneMediaManager.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneMediaManager.kt), [`BridgeMenuView.swift`](mac-app/Sources/BridgeMenuView.swift)) and universal Mac media playback (bundled `MediaRemoteAdapter.framework`, Spotify, Apple Music, VLC, and browser YouTube tabs via [`MacMediaMonitor.swift`](mac-app/Sources/MacMediaMonitor.swift) and [`MacMediaControlCLI.swift`](mac-app/Sources/MacMediaControlCLI.swift)), Mac mute/volume ([`MacSystemControlManager.swift`](mac-app/Sources/MacSystemControlManager.swift)), and live circular battery telemetry on both devices (`BatteryRingView`, [`MacBatteryRingView.kt`](android-app/app/src/main/java/com/link/clipboardsync/MacBatteryRingView.kt)).
- **Quick Controls, Low-Battery Alerts & Launch at Login:** Added remote Android **Sound / Vibrate / Silent**, **Do Not Disturb**, and **Ring Phone** beacon controls ([`PhoneControlManager.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneControlManager.kt)), optional ≤ 15% phone low-battery alerts on Mac, and macOS **Launch at Login** ([`LaunchAtLoginManager.swift`](mac-app/Sources/LaunchAtLoginManager.swift)).

### Fixed
- **Android 13/14 / One UI 6 Background Clipboard Sync:** Improved Android-to-Mac clipboard copy detection and sync reliability ([`ClipboardSyncAccessibilityService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncAccessibilityService.kt), [`ClipboardSyncManager.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardSyncManager.kt), [`ClipboardReaderActivity.kt`](android-app/app/src/main/java/com/link/clipboardsync/ClipboardReaderActivity.kt)).
- **Multi-App Call Answering & Cleanup:** Improved VoIP call answer/decline action resolution across messaging apps ([`BridgeNotificationListenerService.kt`](android-app/app/src/main/java/com/link/clipboardsync/BridgeNotificationListenerService.kt), [`PhoneCallMonitor.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneCallMonitor.kt)) and cleaned up `MediaRemoteAdapter` helper stream lifecycles on macOS termination ([`MacMediaControlCLI.swift`](mac-app/Sources/MacMediaControlCLI.swift), [`main.swift`](mac-app/Sources/main.swift)).

### Security
- **Encrypted Phone Mirroring Video Stream (`PhoneMirrorStreamCipher`):** Secured the dedicated mirroring video socket with one-way SHA-256 handshake proofs (`computeStreamAuthProof`), per-packet **AES-256-GCM** encryption with monotonic 96-bit IVs and header/sequence AAD binding, bounded receive buffers (8 MB + 64 KB), and local-LAN-only RFC 1918 IP validation ([`PhoneMirrorModels.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneMirrorModels.kt), [`ScreenMirrorForegroundService.kt`](android-app/app/src/main/java/com/link/clipboardsync/ScreenMirrorForegroundService.kt), [`PhoneVideoDecoder.swift`](mac-app/Sources/PhoneVideoDecoder.swift), [`PhoneMirrorManager.swift`](mac-app/Sources/PhoneMirrorManager.swift)).
- **Privacy & Input Hardening:** Redacted inline notification reply text, notification dedupe keys, and remote mirroring input JSON from diagnostic logs ([`BridgeNotificationManager.swift`](mac-app/Sources/BridgeNotificationManager.swift), [`BridgeNotificationListenerService.kt`](android-app/app/src/main/java/com/link/clipboardsync/BridgeNotificationListenerService.kt), [`PhoneMirrorController.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneMirrorController.kt), [`PhoneMirrorInputController.kt`](android-app/app/src/main/java/com/link/clipboardsync/PhoneMirrorInputController.kt)), validated extracted YouTube `videoId` values before passing to AppleScript/URLs ([`MacMediaMonitor.swift`](mac-app/Sources/MacMediaMonitor.swift)), and updated [`SECURITY.md`](SECURITY.md), [`README.md`](README.md), and [`CONTRIBUTING.md`](CONTRIBUTING.md).

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

[Unreleased]: https://github.com/badruddin-tasnim/bridge/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.5...v1.4.0
[1.3.5]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.2...v1.3.5
[1.3.2]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/badruddin-tasnim/bridge/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.2...v1.3.0
[1.2]: https://github.com/badruddin-tasnim/bridge/compare/v1.1.1...v1.2
[1.1.1]: https://github.com/badruddin-tasnim/bridge/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/badruddin-tasnim/bridge/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/badruddin-tasnim/bridge/releases/tag/v1.0.0
