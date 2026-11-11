# Security Policy

## Supported Versions

| Version | Supported | Security Policy |
| :--- | :---: | :--- |
| **1.3.x** | :white_check_mark: | Current stable series with AES-256-GCM file transfers, conversation threads, and local-network safeguards. |
| **1.2.x** | :white_check_mark: | Maintenance release (critical security fixes only). |
| **< 1.2.0** | :x: | Unsupported. Users should update to v1.3+ for challenge-response pairing and file integrity verification. |

---

## Security Model & Current Architecture

**Bridge** operates on a **100% local, zero-cloud model**: all device communication stays on your local Wi-Fi or personal hotspot with no external servers or telemetry (aside from optional GitHub Releases update checks).

> [!IMPORTANT]
> **Current Threat Model (Trusted Local Networks):**
> Control traffic on `TCP :8765` currently runs over a **plaintext local TCP socket** (no TLS yet). Because a 6-digit pairing code has only 900,000 combinations, an attacker on the same Wi-Fi network who captures a `hello` handshake can brute-force the 6-digit code offline or read unencrypted `:8765` control messages (including clipboard text/images, notifications, and `file_offer` / `file_accept` tokens). **TLS transport encryption and PAKE / high-entropy pairing authentication are planned for `v1.4.0`.** Until then, use Bridge only on trusted private networks or a personal hotspot.

### 1. Challenge-Response Mutual Authentication
- The Android client authenticates using a salted SHA-256 challenge-response rather than sending the 6-digit pairing code:
  $$\text{Proof} = \text{SHA-256}(\text{"bridge-hello:"} + \text{PairingCode} + \text{":"} + \text{ClientNonce})$$
- The Mac verifies the proof in constant time and returns a matching `welcome` proof before authorizing session messages. Legacy unhashed plaintext `code` handshakes are rejected.

### 2. Local Network Boundary Enforcement
- Bridge accepts connections **only from private/local network ranges** (RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, link-local `169.254.0.0/16`, CGNAT `100.64.0.0/10`, loopback, and IPv6 `fe80:`/`fc`/`fd`).
- Any connection attempt originating from a public WAN IP address is rejected.
- Pairing codes on macOS are stored with POSIX `0600` permissions (`~/.bridge_pairing_code`).

### 3. Brute-Force & Denial-of-Service Defense
- **Per-IP Exponential Lockout:** 5 failed handshake attempts from an IP within 60 seconds trigger a 60-second lockout, doubling exponentially on consecutive violations up to 960 seconds (`16x`).
- **Global Handshake Rate-Limiting:** 10 failed handshake attempts across all IPs within 60 seconds trigger a 30-second global handshake lockout.
- **Anti-Replay Nonce Caching:** Caches up to 256 recent `clientNonce` values to reject replayed `hello` packets.
- **Unauthenticated Handshake Timeout:** Unauthenticated sockets that do not complete a handshake within 8 seconds are disconnected.
- **Memory & Connection Bounds:** Unauthenticated sockets are limited to 8 KB buffers and 4 concurrent unauthenticated connections (8 total concurrent connections).

### 4. Encrypted File & Folder Transfers
- **AES-256-GCM Framing:** File chunks and folder archives are encrypted on dedicated data sockets using **AES-256-GCM** (256-bit key derived via `SHA-256(token + ":bridge-file-encryption")`) with a fresh 12-byte random IV/nonce per 64 KB frame and 128-bit authentication tags.
  - *Note:* Because the per-transfer `token` is currently sent inside `file_offer`/`file_accept` over `:8765`, confidentiality against a passive network sniffer depends on adding TLS in `v1.4.0`.
- **SHA-256 Integrity Digests:** Completed transfers verify SHA-256 checksums before moving files out of `.part` staging files.
- **Path Traversal Protection:** Incoming filenames and archive entries are sanitized (`sanitizeFileName`), stripping path separators (`/` and `\`), control characters, null bytes, and leading dots.
- **Executable Guard & Save Location:** Both platforms prompt for confirmation before accepting listed executable extensions (`.sh`, `.app`, `.dmg`, `.pkg`, `.apk`, `.exe`, etc.) even when auto-accept is enabled (note: folder archives currently bypass the per-file executable check).
- **OS Metadata Filtering:** System metadata files (`.DS_Store`, `__MACOSX`, `Thumbs.db`, `.Trashes`, `.Spotlight-V100`, `._*`) are skipped during folder packaging.

### 5. Private Content Protection & Android Manifest Hardening
- Clipboard text and notification bodies are not logged in normal sync paths (using truncated SHA-256 hashes for clipboard diagnostics).
- `android:allowBackup="false"` prevents cloud backup extraction of local preferences.
- Internal receivers and helper components (including `FileTransferActionReceiver` and `MacAlertDismissReceiver`) set `android:exported="false"`.

---

## Reporting a Vulnerability

If you discover a security vulnerability or weakness in Bridge, please **do not open a public issue**. Instead, report it responsibly:

1. Submit a private report via GitHub's [**Private Vulnerability Reporting**](../../security/advisories/new) tab.
2. Include a description of the vulnerability, affected version(s), attack surface (`Android`, `macOS`, or `Wire Protocol`), and reproducible steps.

Valid reports are triaged promptly and credited in release notes and advisories once a fix is published.
