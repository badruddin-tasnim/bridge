# Security Policy

## Supported Versions

| Version | Supported | Security Policy |
| :--- | :---: | :--- |
| **1.3.5+** | :white_check_mark: | Current stable series with 2048-bit SPEKE PAKE authentication, end-to-end AES-256-GCM session & file encryption, and local-network safeguards. |
| **1.3.0 – 1.3.2** | :x: | Superseded by `v1.3.5`. Upgrade to `v1.3.5+` for SPEKE PAKE and encrypted `:8765` control transport. |
| **< 1.3.0** | :x: | Unsupported. |

---

## Security Model & Current Architecture

**Bridge** operates on a **100% local, zero-cloud model**: all device communication stays on your local Wi-Fi or personal hotspot with no external servers or telemetry (aside from optional GitHub Releases update checks).

### 1. 2048-Bit SPEKE Password-Authenticated Key Exchange (PAKE)
- Pairing authentication uses **SPEKE (Simple Password Exponential Key Exchange)** over the **RFC 3526 Group 14 (2048-bit MODP)** safe prime $p = 2q + 1$:
  - Both peers derive a prime-order Subgroup generator $g = H(\text{"bridge-speke-v1"}, \text{PairingCode}, \text{ClientNonce})^2 \bmod p$ and exchange ephemeral Diffie-Hellman public elements ($A = g^a \bmod p$, $B = g^b \bmod p$).
  - Neither the 6-digit pairing code nor any static hash of it is ever transmitted before Diffie-Hellman key agreement, preventing offline brute-force recovery of the 6-digit code from recorded handshakes and providing **Perfect Forward Secrecy (PFS)**.
  - Public group elements are validated in $[2, p - 2]$ to reject small-subgroup and trivial-element attacks, and mutual transcript key-confirmation proofs (`auth` and `welcome`) are verified in constant time before any session data is accepted.

### 2. End-to-End AES-256-GCM Session Encryption (`TCP :8765`)
- Upon completing the SPEKE handshake, Bridge derives independent 256-bit directional keys (`c2sKey` for Android $\to$ Mac and `s2cKey` for Mac $\to$ Android).
- Every post-handshake message on `TCP :8765` (clipboard text, clipboard images, mirrored notifications, inline replies, settings sync, and file-transfer control headers) is encapsulated in an authenticated **AES-256-GCM** frame (`{"type":"enc","seq":<u64>,"d":"<base64(iv + ciphertext + tag)>"}`):
  - **96-bit IV:** 4-byte CSPRNG salt + 8-byte big-endian monotonic sequence number (`seq`).
  - **AAD:** Binds both direction and sequence number (`"bridge-v1:<direction>:<seq>"`) with a 128-bit authentication tag, preventing tampering, direction reflection, out-of-order injection, and replay.
  - Any unencrypted post-handshake packet is rejected immediately and terminates the connection.

### 3. Local Network Boundary Enforcement
- Bridge accepts connections **only from private/local network ranges** (RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, link-local `169.254.0.0/16`, CGNAT `100.64.0.0/10`, loopback, and IPv6 `fe80:`/`fc`/`fd`).
- Any connection attempt originating from a public WAN IP address is rejected.
- Pairing codes on macOS are stored with POSIX `0600` permissions (`~/.bridge_pairing_code`).

### 4. Brute-Force & Denial-of-Service Defense
- **Per-IP Exponential Lockout:** 5 failed handshake attempts from an IP within 60 seconds trigger a 60-second lockout, doubling exponentially on consecutive violations up to 960 seconds (`16x`).
- **Global Handshake Rate-Limiting:** 10 failed handshake attempts across all IPs within 60 seconds trigger a 30-second global handshake lockout (`globalLockoutUntil`).
- **Anti-Replay Nonce Caching:** Caches up to 256 recent `clientNonce` values to reject replayed `hello` packets.
- **Unauthenticated Handshake Timeout:** Unauthenticated sockets that do not complete the SPEKE handshake within 8 seconds are disconnected.
- **Memory & Connection Bounds:** Unauthenticated sockets are limited to 8 KB buffers and 4 concurrent unauthenticated connections (8 total concurrent connections).

### 5. Encrypted File & Folder Transfers
- **Protected Session Token & Data-Socket Auth Proof:** Per-transfer 256-bit `token` values are exchanged exclusively inside the AES-256-GCM encrypted `:8765` control channel. When connecting to the dedicated transfer TCP socket, the client never transmits the raw `token`; instead it presents a one-way binder `auth = SHA-256("bridge-file-auth-v1:" + token + ":" + id + ":" + offset)` verified in constant time.
- **AES-256-GCM Chunk Framing:** File chunks and folder archives are encrypted on the dedicated data socket using **AES-256-GCM** (`SHA-256(token + ":bridge-file-encryption")`) with a fresh 12-byte random IV/nonce per 64 KB frame and 128-bit authentication tags.
- **SHA-256 Integrity Digests:** Completed transfers verify SHA-256 checksums before moving files out of `.part` staging files.
- **Path Traversal & Symlink Protection:** Incoming filenames and archive entries are sanitized (`sanitizeFileName`), stripping path separators (`/` and `\`), control characters, null bytes, and leading dots. Folder archive extraction rejects symbolic links to prevent symlink escapes.
- **Explicit Confirmation by Default & Executable Guard:** Auto-accepting incoming files is **off by default** (`autoAcceptIncomingFiles = false`) on both macOS and Android. Even if a user opts into auto-accept, both platforms always require manual confirmation for executable, script, bundle, and shortcut extensions (`.app`, `.command`, `.workflow`, `.scpt`, `.sh`, `.py`, `.jar`, `.webloc`, `.apk`, `.dmg`, `.pkg`, `.exe`, etc.) as well as folder archives.
- **OS Metadata Filtering:** System metadata files (`.DS_Store`, `__MACOSX`, `Thumbs.db`, `.Trashes`, `.Spotlight-V100`, `._*`) are skipped during folder packaging.

### 6. Private Content Protection & Android Manifest Hardening
- Clipboard text and notification bodies are not logged in normal sync paths (using truncated SHA-256 hashes for clipboard diagnostics).
- `android:allowBackup="false"` prevents cloud backup extraction of local preferences.
- Internal receivers and helper components (including `FileTransferActionReceiver` and `MacAlertDismissReceiver`) set `android:exported="false"`.

---

## Reporting a Vulnerability

If you discover a security vulnerability or weakness in Bridge, please **do not open a public issue**. Instead, report it responsibly:

1. Submit a private report via GitHub's [**Private Vulnerability Reporting**](../../security/advisories/new) tab.
2. Include a description of the vulnerability, affected version(s), attack surface (`Android`, `macOS`, or `Wire Protocol`), and reproducible steps.

Valid reports are triaged promptly and credited in release notes and advisories once a fix is published.
