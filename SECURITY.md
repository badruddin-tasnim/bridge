# Security Policy

## Supported Versions

| Version | Supported | Security Policy |
| :--- | :---: | :--- |
| **1.3.x** | :white_check_mark: | Current stable release with end-to-end encrypted file sharing, conversation threads, and full security suite. |
| **1.2.x** | :white_check_mark: | Maintenance release (critical security fixes only). |
| **< 1.2.0** | :x: | Unsupported. Users must update to v1.2+ for zero-knowledge authentication. |

---

## Security Model & Cryptographic Architecture

**Bridge** is engineered from the ground up on a **100% local, zero-cloud, auditable security model**. All communication is restricted to your local network with zero external servers, zero cloud intermediate, and zero telemetry.

### 1. Zero-Knowledge Mutual Authentication
- Pairing codes are **never transmitted in plaintext** across the network.
- Handshake authentication uses a cryptographic challenge-response protocol:
  $$\text{Proof} = \text{SHA-256}(\text{"bridge-hello:"} + \text{PairingCode} + \text{":"} + \text{ClientNonce})$$
- The Mac verifies the client's proof and responds with a matching salted welcome proof before any session socket or data exchange is authorized.

### 2. Local Network Boundary Enforcement
- Bridge accepts connections **only from private local network boundaries** (RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, link-local `169.254.0.0/16`, and loopback).
- Any connection attempt originating from a public or WAN IP address is immediately dropped.
- Pairing credentials on macOS are stored with strict POSIX `0600` permissions (`~/.bridge_pairing_code`).

### 3. Brute-Force & Denial-of-Service Defense
- **Per-IP Exponential Lockout:** 5 failed handshake attempts from an IP address trigger an immediate 15-second lockout, doubling exponentially on each consecutive violation up to 240 seconds.
- **Global Handshake Rate-Limiting:** Distributed or rapid connection storms trigger a global 30-second handshake halt.
- **Anti-Replay Nonce Caching:** Nonces are cached and invalidated to prevent replay attacks.
- **Unauthenticated Handshake Timeout:** Unauthenticated sockets that fail to complete a valid handshake within 8 seconds are forcibly terminated.
- **Memory Buffer Bounds:** Unauthenticated connections are strictly restricted to 8 KB max payload size to prevent memory exhaustion and buffer-overflow attacks.

### 4. End-to-End Encrypted File & Folder Transfers
- **Hardware-Accelerated AES-GCM:** File chunks and archive streams are encrypted end-to-end using hardware-accelerated **AES-128-GCM** with a unique 12-byte random initialization vector (IV/nonce) per frame and 128-bit authentication tags.
- **SHA-256 Integrity Digests:** Complete file transfers verify SHA-256 checksums before finalizing, guaranteeing zero file tampering or corruption.
- **Path Traversal Protection:** All incoming file names and folder structures are sanitized (`sanitizeFilename`), strictly stripping path traversal sequences (`../`, leading slashes, null bytes) to prevent arbitrary file writes.
- **Sandboxed Storage:** Files are written strictly to user-designated directories via Android's Storage Access Framework (SAF) and macOS Security-Scoped Bookmarks.
- **OS Metadata Filtering:** System metadata and cache files (`.DS_Store`, `__MACOSX`, `Thumbs.db`, `.Trashes`, `.Spotlight-V100`, `._*`) are automatically purged during folder packaging to prevent metadata leakage.

### 5. Private Content Protection & Logging
- Diagnostic logs **never record raw user content** (clipboard text, notification bodies, replies, or file payloads).
- Only payload byte sizes and truncated 8-character SHA-256 digest prefixes are recorded for debugging.
- Internal Android services and helper activities are marked with `android:exported="false"`, and `android:allowBackup="false"` prevents cloud backup extraction of local pairing keys.

---

## Reporting a Vulnerability

If you discover a security vulnerability or weakness in Bridge, please **do not open a public issue**. Instead, report it responsibly:

1. Submit a private report via GitHub's [**Private Vulnerability Reporting**](../../security/advisories/new) tab.
2. Include a detailed description of the vulnerability, affected version(s), attack surface (`Android`, `macOS`, or `Wire Protocol`), and reproducible proof-of-concept steps.

All security reports are acknowledged within 24 hours. Valid vulnerabilities will receive a security advisory and credit in the official release notes once a patch is published.
