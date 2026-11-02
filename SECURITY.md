# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

## Security Model & Privacy Architecture

**Bridge** is designed around a local-only, zero-cloud security model:

1. **Local Network Only (`TCP :8765`):** Bridge communicates exclusively over your local Wi-Fi network (`192.168.x.x` / `10.x.x.x`). Neither the Android app nor the macOS menu bar app makes any external internet requests.
2. **Per-Mac Pairing Code:** Each macOS installation generates a unique 6-digit pairing secret stored in `~/.bridge_pairing_code`. Connections that do not present the valid pairing code during the initial `hello` handshake receive a `denied` response and are rejected before any payload can be exchanged.
3. **Instant Unpair & Code Rotation:** Clicking **Unpair** in the macOS menu bar immediately closes all active client sockets, notifies connected devices to clear stored credentials, and generates a fresh 6-digit pairing code.
4. **No Plaintext Content Logging:** Diagnostic logs record only payload character counts and truncated 8-character SHA-256 hash prefixes—never raw clipboard or notification text.
5. **Scoped Android Permissions:** Internal helper activities (`ClipboardReaderActivity`, `PortraitCaptureActivity`) and background services are marked `android:exported="false"`, and `android:allowBackup="false"` prevents cloud backup of pairing tokens.

## Reporting a Vulnerability

If you discover a security vulnerability in Bridge, please **do not open a public GitHub issue**. Instead:

1. Use GitHub's [**Private Vulnerability Reporting**](../../security/advisories/new) tab on this repository to submit a report privately.
2. Include a clear description of the issue, affected platform (`Android`, `macOS`, or `Wire Protocol`), and steps to reproduce.

We review all security reports promptly and will credit reporters in the release notes once a fix is published.
