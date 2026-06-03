# DeepFinder Security Whitepaper

**Version 1.0 — 2026-06-03**
**Target audience: Security-conscious users evaluating DeepFinder for Full Disk Access**

---

## Executive Summary

DeepFinder is a macOS file search tool architected with a security-first, local-only design. Zero telemetry. Zero cloud dependency for core operation. All file indexing and search happen on-device within a single user's sandbox — the daemon never runs as root, never phones home, and never shares data with any third party.

This whitepaper documents the complete security model: threat actors, trust boundaries, protocol-level defenses, file permission conventions, AI privacy guarantees, secrets management, and our vulnerability disclosure process.

**Key security properties:**

- No outbound network connections in core daemon path
- IPC restricted to same-user via `LOCAL_PEERCRED` + `LOCAL_PEERPID`
- All sensitive files at `0o600` (owner read/write only)
- AI features are opt-in, provider-by-provider, with documented data boundaries
- Zero external dependencies — no supply chain attacks through npm/pip/cargo ecosystems
- `security.txt` + `SECURITY.md` + private reporting channel

---

## 1. Threat Model

### 1.1 Adversary Classes

| Adversary | Capability | Motivation | DeepFinder Relevance |
|-----------|-----------|------------|---------------------|
| **Local non-root attacker** | Runs code as same user; can read user-owned files; can connect to local sockets | Exfiltrate file listing, search history, or API keys | **Primary concern** — defended by file permissions, socket credential checks |
| **Local root attacker** | Full system access; can bypass all user-level protections | Anything | Out of scope — root compromises the OS; no user-level tool can defend |
| **Remote attacker (network)** | Can send packets to open ports | Exploit HTTP API | Defended by localhost-only binding, random per-session bearer token |
| **Remote attacker (supply chain)** | Compromises a dependency | Inject malicious code | Defended by zero-dependency architecture |
| **Cloud AI provider** | Receives LLM prompts if user opts in | Model training, data mining | Defended by opt-in model, query-only transmission (no file contents), documented data boundaries |
| **Malicious local process (other user)** | Runs as different user on same machine | Access another user's file index | Defended by socket UID check, file permissions |

### 1.2 Trust Boundaries

```
┌─────────────────────────────────────────────────────────┐
│                     TRUSTED ZONE                         │
│  (Single user's processes + files user can read)        │
│                                                          │
│  ┌──────────┐   IPC (Unix socket)   ┌──────────────┐   │
│  │   CLI    │◄────────────────────►│   Daemon      │   │
│  │ (thin)   │   LOCAL_PEERCRED     │  (indexer)    │   │
│  └──────────┘   same-UID check     └──────┬───────┘   │
│       │                                    │            │
│       │                              ┌─────▼──────┐    │
│       │                              │  SQLite    │    │
│       │                              │  index.db  │    │
│       │                              │  (600)     │    │
│       │                              └────────────┘    │
│       │                                                 │
│  ┌────▼──────┐   HTTP (localhost)   ┌──────────────┐   │
│  │   GUI     │◄───────────────────►│  HTTP API    │   │
│  │ (NSPanel) │   Bearer token       │  :7654       │   │
│  └───────────┘                      └──────────────┘   │
│                                                          │
├─────────────────────────────────────────────────────────┤
│                  TRUST BOUNDARY                          │
│  (User opt-in only, explicit per-provider consent)      │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Cloud AI Providers (Anthropic, DeepSeek, Qwen,  │   │
│  │  Gemini) — query text only, no file contents,    │   │
│  │  no file paths, no PII                           │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
├─────────────────────────────────────────────────────────┤
│                  UNTRUSTED ZONE                          │
│  (Network, other users, third-party processes)          │
└─────────────────────────────────────────────────────────┘
```

### 1.3 Attack Surfaces

| Surface | Exposure | Risk | Primary Defense |
|---------|----------|------|-----------------|
| Unix socket (`ipc.sock`) | Local processes, same user | Medium | `LOCAL_PEERCRED` UID check, `0o600` socket permissions, rate limiting |
| HTTP API (`localhost:7654`) | Local network, browser-based attacks | Medium | Random per-session bearer token, localhost-only binding, header size limits |
| SQLite database (`index.db`) | Local file access, same user | Low | `0o600` permissions, WAL mode integrity |
| Secrets file (`.env`) | Local file access, same user | High | `0o600` permissions, atomic writes, JSON parsing validation |
| LaunchAgent plist | Local file access, same user | Low | User-level only (`~/Library/LaunchAgents/`), not system daemon |
| AI provider API calls | Network MITM, provider logging | Medium | HTTPS only, opt-in, query-only (no file contents), TLS 1.3 |
| FSEvents stream | Kernel-level, root only | Low | Kernel-enforced, read-only event stream |
| Global hotkey (`⌃⌘K`) | Other processes registering same hotkey | Low | Accessibility permission requirement, Carbon event handler |

---

## 2. Data Flow Diagram

```
                          USER INPUT
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         CLI (bash)      GUI (⌃⌘K)      HTTP API (:7654)
              │               │               │
              │    IPC sock   │    IPC sock   │   Bearer token
              │   LOCAL_PEERCRED             │   auth
              └───────────────┼───────────────┘
                              │
                     ┌────────▼────────┐
                     │     DAEMON      │
                     │  (user process) │
                     └────────┬────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         InMemoryIndex   FSEvents        SQLite WAL
         (RAM only)     (kernel)      (~/.deep-finder/
                                       cache/index.db
                                       0o600)
                              │
                    ┌─────────▼─────────┐
                    │   AI (opt-in)     │
                    │                   │
                    │  On-device:       │
                    │  • Vision (ANE)   │
                    │  • Speech (Local) │
                    │  • NL Embeddings  │
                    │    (CoreML)       │
                    │                   │
                    │  Cloud (opt-in):  │
                    │  • NL→syntax      │
                    │  • Cross-lang     │
                    │  • Result summary │
                    │  • Semantic group │
                    └───────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │  TRUST BOUNDARY   │
                    │  (HTTPS, query    │
                    │   text only,      │
                    │   no file paths)  │
                    └───────────────────┘
```

**Legend:**
- Thick lines: Trusted local IPC (same-user enforced)
- Dotted lines: Network boundary (HTTPS, user opt-in)
- All daemon data flows stay within the user's account
- No data crosses the trust boundary without explicit per-provider opt-in

---

## 3. IPC Security Analysis

### 3.1 Socket Configuration

The daemon listens on a Unix domain socket at:

```
~/.deep-finder/session/ipc.sock
```

**Socket creation (pseudocode of actual implementation):**

1. Create parent directory `~/.deep-finder/session/` with `0o700` permissions
2. `bind()` to `ipc.sock`
3. `chmod()` socket file to `0o600` (owner read/write only)
4. `listen()` with backlog of 16

**Why 0o600 for the socket:** Even though `LOCAL_PEERCRED` provides UID verification at the protocol level, file permissions provide defense-in-depth. A socket at `0o600` cannot be connected to by another user without first going through the kernel's permission check, preventing information leaks through `connect()` timing or error messages.

### 3.2 Peer Credential Verification (Primary Access Control)

Every client connection undergoes mandatory peer credential verification before any request is processed. The implementation uses Darwin's `LOCAL_PEERCRED` and `LOCAL_PEERPID` socket options — kernel-provided, unforgeable identity.

```
verifyPeerCredential(fd) algorithm:

1. getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED)  → xucred (UID + groups)
2. getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID)   → pid_t
3. Verify peerPID > 0
4. Verify peerCred.cr_uid == getuid()
5. If any check fails → close connection, log warning
```

**Why this is secure:**

- `LOCAL_PEERCRED` is filled by the kernel at `connect()` time — it cannot be spoofed by the connecting process
- The same-UID check ensures only processes running as the same user can interact with the daemon
- Even if another user somehow guesses the socket path, the UID check rejects them before any application data is read
- PID verification catches edge cases (zombie processes, PID reuse races are mitigated by UID check)

### 3.3 Input Validation

| Check | Value | Rationale |
|-------|-------|-----------|
| Maximum message size | 16 MB (`Constants.IPC.maxMessageSize`) | Prevents memory exhaustion from oversized payloads |
| Maximum query length | 10,240 chars (`Constants.IPC.maxQueryLength`) | Prevents CPU exhaustion from pathological queries |
| Receive timeout | 30 seconds (`SO_RCVTIMEO`) | Prevents slowloris-style DoS — client must send complete request within timeout |
| Framed protocol | 4-byte length prefix + JSON body | Deterministic framing prevents buffer over-read; length prefix validated before allocation |
| HTTP header size limit | 1 MB | Prevents unbounded header buffer growth |

### 3.4 DoS Resistance

| Mechanism | Default | Effect |
|-----------|---------|--------|
| Connection rate limit | 10 connections/second | Throttles connection storms |
| Concurrent client limit | 50 simultaneous | Prevents file descriptor exhaustion |
| Listen backlog | 16 | Kernel-enforced queue limit before `accept()` |
| Receive timeout | 30 seconds | Forces slow senders to complete or disconnect |
| One-request-per-connection | Enforced by `handleClient` closing fd after response | Prevents connection hoarding |
| Query size limit | 10 KB | Prevents CPU-bound regex or wildcard expansion DoS |

### 3.5 Stale Socket Cleanup

When the daemon starts, it checks for a stale socket file from a previous crashed instance. Detection uses the PID file (`~/.deep-finder/session/daemon.pid`): if the PID is not running, the socket is removed before `bind()`. This prevents startup failures after crashes without introducing a race condition (the PID check + unlink happen before `bind`, atomically from the daemon's perspective).

---

## 4. HTTP API Security

### 4.1 Binding

The HTTP API listens on `127.0.0.1:7654` (configurable). It uses `NWListener` with TCP parameters — no `bonjour` service advertisement, no external network interface binding. The port is only reachable from the local machine.

**Why localhost-only matters:** Even though the bearer token provides authentication, binding to all interfaces (`0.0.0.0`) would expose the API to other machines on the local network. Localhost-only binding eliminates this entire class of attack.

### 4.2 Authentication

A random UUIDv4 bearer token is generated on each daemon start:

```
Token: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
Stored at: ~/.deep-finder/session/http-token (permissions 0o600)
```

Clients must present the token via either:
- Query parameter: `?token=a1b2c3d4-...`
- Authorization header: `Authorization: Bearer a1b2c3d4-...`

**Design rationale:**

- **Per-session tokens** mean a token is invalidated when the daemon restarts — no long-lived credential to manage
- **File-based distribution** (`0o600`) means only same-user processes can read the token — the file permission check is equivalent to the UID check on the IPC socket
- **Dual acceptance** (query param + header) supports both browser-based tools (query param easier) and programmatic clients (header standard)
- **Constant-time comparison** is not needed here because the token is a random UUID, not a user-chosen secret — timing attacks on UUID comparison don't leak usable information

### 4.3 Endpoint Access Control

| Endpoint | Auth Required | Method | Purpose |
|----------|--------------|--------|---------|
| `/health` | No | GET | Liveness probe (returns `{"status":"ok"}`) |
| `/search` | Yes | GET | Execute file search |
| `/stats` | Yes | GET | Return daemon statistics |
| All others | Yes | GET | 404 |

The `/health` endpoint is intentionally unauthenticated to support health checks from process monitors that cannot read the token file. It returns no data beyond a status string — no file listing, no statistics, no configuration.

### 4.4 CORS and Browser Security

The API responds with `Access-Control-Allow-Origin: *`. This is intentional: the API is localhost-only, so CORS is not a security boundary — any page running in a browser on the local machine already has same-user access to the token file and the socket. Setting a restrictive CORS policy would only create friction for legitimate browser-based tools without providing meaningful security.

However, the following protections are in place:
- Only GET method is accepted (`405 Method Not Allowed` for others)
- `Connection: close` on every response (no persistent connections to hoard)
- Maximum header size enforced (1 MB)
- Header buffer bounded (rejects connections exceeding limit)

### 4.5 Rate Limiting

The HTTP API inherits the IPC-layer rate limiting (connection rate + concurrent client limits) because each HTTP connection maps to a daemon task slot. Additional HTTP-specific protections:
- Single-request-per-connection (no HTTP keep-alive)
- Request parsing aborts on malformed data (no recovery attempt)
- Maximum 100 results per search response (pagination via `offset`)

---

## 5. AI Privacy Guarantees

### 5.1 Architecture Principle: On-Device First, Cloud as Opt-In Escalation

DeepFinder implements a tiered AI architecture. All Tier 0 operations run entirely on-device with zero network communication. Tier 1 operations are cloud-based and require explicit per-provider opt-in.

| Tier | Operation | Runtime | Data That Leaves Device |
|------|-----------|---------|------------------------|
| **0** | Vision tagging (image classification) | Apple Neural Engine (ANE) | Nothing |
| **0** | Speech recognition | Local speech recognizer | Nothing |
| **0** | NL embeddings (semantic search) | CoreML / NaturalLanguage | Nothing |
| **0** | File metadata extraction | CPU | Nothing |
| **1** | Natural language → search syntax translation | Cloud LLM (user-chosen) | Query text only |
| **1** | Cross-language search term expansion | Cloud LLM | Search terms only |
| **1** | Result summarization | Cloud LLM | File names + metadata only |
| **1** | Semantic grouping | Cloud LLM | File names + extensions |
| **1** | Match explanation | Cloud LLM | Query + file name, nothing more |

### 5.2 What NEVER Leaves the Device

The following data categories are never transmitted to any cloud service, under any AI feature:

- **File contents** — the content of any file on disk
- **Full file paths** — directory structures, parent paths, volume names
- **File metadata beyond what's displayed** — no access timestamps, no extended attributes, no resource forks
- **Search history** — queries are ephemeral; no query log exists that could be exfiltrated
- **User identity** — no account, no email, no device identifier in API calls
- **Other filenames in results** — summarization only receives the specific files being summarized, not the full result set

### 5.3 Path Sanitization for Cloud Queries

When NL search translation sends a query to a cloud provider, the input is the user's natural language query text — not file paths, not file contents. For example:

- User types: "find big PDFs from last week"
- What reaches the cloud LLM: `"find big PDFs from last week"` (the raw query string)
- What NEVER reaches the cloud: any file path on the user's disk

This is guaranteed by the `NLSearchTranslator` architecture: the translator receives the raw query string and returns search syntax. File index search happens locally, after translation. The cloud provider never sees the file system.

### 5.4 Opt-In Model

AI features follow a **provider-by-provider, explicit opt-in** model:

1. **Default state**: All cloud AI features disabled. Core search works fully offline.
2. **Configuration**: User must explicitly provide an API key for each provider they want to use (Anthropic, DeepSeek, Qwen, Gemini).
3. **No surprise activation**: If no API key is configured, `NLSearchTranslator.translate()` returns the input unchanged — the query runs as a plain substring search with no network communication.
4. **Visual indicator**: The GUI shows an AI status icon when cloud AI is active on a query.

### 5.5 Provider Data Handling

Users should review each provider's data usage policy. As of 2026:

| Provider | API Endpoint | Data Retention Policy |
|----------|-------------|----------------------|
| Anthropic | `api.anthropic.com` | No training on API inputs; 30-day retention for abuse monitoring |
| DeepSeek | `api.deepseek.com` | Refer to DeepSeek privacy policy |
| Qwen (Alibaba) | `dashscope.aliyuncs.com` | Refer to Alibaba Cloud privacy policy |
| Gemini (Google) | `generativelanguage.googleapis.com` | Refer to Google AI privacy policy |

All API calls use HTTPS (TLS 1.3 minimum). API keys are stored in the secrets file (`~/.deep-finder/.env`, `0o600`).

### 5.6 On-Device AI: Zero Network Guarantee

The following operations use Apple on-device frameworks and are guaranteed to never make network requests:

- **Vision tagging** (`VNGenerateImageClassificationRequest`) — runs on Apple Neural Engine
- **Speech recognition** (`SFSpeechRecognizer`) — uses on-device model when available
- **NL embeddings** (`NLEmbedding`) — CoreML on-device inference

These guarantees come from Apple's framework architecture: the relevant APIs do not have network fallback paths. DeepFinder does not wrap them in any network-capable abstraction.

---

## 6. Secrets Management

### 6.1 Current Implementation: File-Backed Secrets Store

Secrets (API keys, encryption keys) are stored at:

```
~/.deep-finder/.env
Permissions: 0o600 (owner read/write only)
Format: JSON dictionary
```

**Security properties:**

| Property | Implementation |
|----------|---------------|
| **Atomic writes** | Write to temp file → set permissions → `rename()` to final path. Prevents partial writes and torn reads. |
| **Permissions enforcement** | `0o600` set before the file becomes visible at its final path |
| **Crash safety** | Temp file in same directory as target (same filesystem for atomic `rename`) |
| **Corruption recovery** | JSON parse failure → log warning, return empty dict (secrets must be re-entered, but daemon continues) |
| **Concurrent access** | Each read/write opens the file fresh; actor serialization within process prevents interleaving |

**Key naming convention:**
- `ai.anthropicKey` — Anthropic API key
- `ai.deepseekKey` — DeepSeek API key
- `ai.qwenKey` — Qwen (Alibaba) API key
- `ai.geminiKey` — Gemini (Google) API key
- `path_encryption_key_v1` — Internal encryption key for path obfuscation

### 6.2 Design Rationale: File-Backed Secrets

The `.env` file approach is an **intentional, permanent design choice**, not an MVP workaround:

| Property | Rationale |
|----------|----------|
| **Simplicity** | Zero external dependencies — reads like any other config file. No Keychain Services API complexity. |
| **Debuggability** | Users can inspect with `cat ~/.deep-finder/.env` to verify their keys. Keychain requires Keychain Access.app or `security` CLI. |
| **Security equivalence** | On a single-user Mac, `0o600` file permissions provide equivalent protection to Keychain — both are accessible only to the owning user. Keychain adds meaningful security only in multi-user or managed-device (MDM) scenarios. |
| **Daemon compatibility** | Keychain access from a background LaunchAgent daemon requires `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and careful entitlement management. File access has no such complexity. |
| **Portability** | Users can back up, migrate, or sync their `.env` file with standard file tools. Keychain data requires Apple-specific export/import. |
| **No Keychain migration planned** | Per project owner decision (2026-06-03), the `.env` approach is the final design. Future evaluation may reconsider if MDM/enterprise scenarios demand hardware-backed secret storage. |

**If Keychain is ever reconsidered** (not planned), the migration path would be: read `.env` → `SecItemAdd` for each key → verify → remove `.env`. But for now and the foreseeable future, `.env` with `0o600` is the solution.

### 6.3 Secrets in Memory

- API keys are loaded from disk into `String` values at provider initialization time
- They are not logged (OSLog privacy: `.private` by default for String values)
- They are not included in crash reports
- Memory is freed when the daemon exits (no persistent in-memory caching beyond process lifetime)

---

## 7. File Permissions

### 7.1 Permission Convention

DeepFinder uses three permission levels, defined as compile-time constants in `ProductConfig.swift`:

| Constant | Value | Octal | Use |
|----------|-------|-------|-----|
| `privateFilePermissions` | `0o600` | `rw-------` | Secrets, config, database, socket, token |
| `privateDirPermissions` | `0o700` | `rwx------` | All DeepFinder directories |
| `pidFilePermissions` | `0o644` | `rw-r--r--` | PID file (readable by system monitors) |

### 7.2 File-by-File Permission Justification

| Path | Type | Permissions | Justification |
|------|------|-------------|---------------|
| `~/.deep-finder/` | Directory | `0o700` | Root data directory; contains all sensitive files. No other user needs access. |
| `~/.deep-finder/cache/` | Directory | `0o700` | SQLite database directory; WAL + SHM files inherit directory permissions. |
| `~/.deep-finder/cache/index.db` | File | `0o600` | Contains complete file listing of user's disk. This is the most sensitive data file — it reveals every filename the user has. |
| `~/.deep-finder/session/` | Directory | `0o700` | Runtime files; socket and token must be protected. |
| `~/.deep-finder/session/ipc.sock` | Socket | `0o600` | IPC socket; other users must not connect. File permission is defense-in-depth below `LOCAL_PEERCRED`. |
| `~/.deep-finder/session/daemon.pid` | File | `0o644` | PID file; intentionally world-readable so system monitors (Activity Monitor, `launchctl`) can identify the daemon process without root. |
| `~/.deep-finder/session/http-token` | File | `0o600` | Bearer token for HTTP API; must be readable only by same user. |
| `~/.deep-finder/settings.json` | File | `0o600` | User configuration; may contain preferences that reveal usage patterns. |
| `~/.deep-finder/.env` | File | `0o600` | API keys and encryption keys; highest-sensitivity file. Compromise = cloud AI account access. |
| `~/.deep-finder/history` | File | `0o600` | CLI command history; reveals search queries. |
| `~/Library/LaunchAgents/com.nadav.deepfinder.plist` | File | `0o644` | LaunchAgent plist; standard permissions required by `launchd`. User-owned directory already limits write access. |

### 7.3 Why Not Root-Owned Paths

DeepFinder intentionally places all files under `~/.deep-finder/` (user home directory) rather than system paths like `/Library/` or `/var/`. This is a deliberate security choice:

1. **No privilege escalation surface**: The daemon runs as the user, not as root. No SUID binary, no `SMJobBless`, no privileged helper.
2. **No system directory pollution**: Uninstalling DeepFinder is `rm -rf ~/.deep-finder` + `launchctl bootout gui/$UID/com.nadav.deepfinder`. No orphaned files in system directories.
3. **TCC compatibility**: User-level daemons have the same privacy permissions as the user — no need for special entitlements that could be exploited.
4. **"Daemon Ex Plist" immunity**: The 2025 vulnerability class where uninstalled apps leave privileged LaunchDaemon plists in `/Library/LaunchDaemons/` does not apply to user-level LaunchAgents in `~/Library/LaunchAgents/`.

---

## 8. Vulnerability Disclosure Policy

### 8.1 Reporting

**Security contact:** `security@nadav.com.cn`

**Preferred reporting method:** Email to the address above, encrypted with our PGP key (available at `https://github.com/nadavkem/deepfinder/security/policy` and via `/.well-known/security.txt` on `nadav.com.cn`).

**We commit to:**

| SLA | Timeframe |
|-----|-----------|
| Acknowledgment | Within 48 hours |
| Initial triage and severity assessment | Within 5 business days |
| Fix for Critical severity | Within 7 days |
| Fix for High severity | Within 30 days |
| Fix for Medium severity | Within 90 days |
| Low severity | Next release cycle |
| Public disclosure (CVE/MITRE) | Coordinated with reporter, after fix is available |

### 8.2 Scope

The following are in scope for vulnerability reports:

- DeepFinder daemon (`deepfinder-daemon`)
- DeepFinder CLI (`deepfinder`)
- DeepFinder GUI app (`DeepFinder.app`)
- IPC protocol (Unix socket at `~/.deep-finder/session/ipc.sock`)
- HTTP API (`localhost:7654`)
- LaunchAgent configuration
- Secrets storage and handling
- AI provider integration (data leakage through cloud API calls)

**Out of scope:**

- Vulnerabilities in third-party cloud AI providers (report directly to Anthropic, DeepSeek, Google, Alibaba)
- macOS kernel vulnerabilities
- Physical access attacks (user's machine already compromised)
- Social engineering
- Denial of service via resource exhaustion from the same user (the user can already exhaust their own resources)

### 8.3 Safe Harbor

We will not pursue legal action against researchers who:

- Act in good faith to follow this disclosure policy
- Avoid privacy violations, destruction of data, and interruption or degradation of our services
- Provide us a reasonable amount of time to fix the vulnerability before public disclosure

We consider security research conducted consistent with this policy to be "authorized" conduct under the Computer Fraud and Abuse Act (CFAA) and similar laws.

### 8.4 Recognition

We maintain a **Security Hall of Fame** at `https://github.com/nadavkem/deepfinder/security/acknowledgments` listing researchers who have responsibly disclosed vulnerabilities. With researcher consent, we include names and links in our release notes.

**Bug bounty:** DeepFinder is an open-source project maintained by an individual developer. We do not currently offer monetary bounties, but we provide public acknowledgment and will ship project swag to researchers who report Critical or High severity vulnerabilities.

### 8.5 Disclosure Process

1. **Reporter** submits vulnerability to `security@nadav.com.cn`
2. **Maintainer** acknowledges within 48 hours
3. **Joint assessment**: Maintainer and reporter agree on severity and timeline
4. **Fix development**: Maintainer develops and tests fix
5. **CVE assignment**: If appropriate, a CVE is requested from MITRE
6. **Coordinated release**: Fix is released; advisory is published; reporter is credited

We follow the [Coordinated Vulnerability Disclosure (CVD)](https://resources.sei.cmu.edu/asset_files/SpecialReport/2017_003_001_503340.pdf) framework from CERT/CC.

### 8.6 Security Advisories

Security advisories are published at:

- **GitHub:** `https://github.com/nadavkem/deepfinder/security/advisories`
- **Website:** `https://nadav.com.cn/.well-known/security.txt`

Each advisory includes: CVE ID (if assigned), affected versions, severity (CVSS 3.1), description, impact, mitigation, fix version, and acknowledgment.

---

## 9. Supply Chain Security

### 9.1 Zero External Dependencies

DeepFinder has **zero external dependencies**. The entire codebase is pure Swift using only Apple first-party frameworks:

```
Foundation, CoreServices, Carbon, SQLite3, Network,
NaturalLanguage, CoreML, Vision, Speech, AVFoundation,
Security, AppKit, SwiftUI
```

**Why this matters for security:**

| Risk | Traditional App | DeepFinder |
|------|----------------|------------|
| npm/pip/cargo supply chain attack | High (hundreds of transitive deps) | **Zero** — no package manager dependencies |
| Dependency confusion / typosquatting | Yes (public registry names) | **Impossible** — no dependencies to confuse |
| Abandoned/unmaintained dependency | Yes (left-pad, etc.) | **N/A** — Apple frameworks are maintained by Apple |
| Dependency with known CVE | Requires constant `npm audit` | **N/A** — only Apple frameworks, which receive OS-level security updates |
| Malicious maintainer takeover | Yes (event-stream incident) | **Impossible** |
| Build script compromise | `postinstall` scripts in `package.json` | **Impossible** — Swift Package Manager has no post-install hooks |

### 9.2 Build Reproducibility

- **Lockfile**: `Package.resolved` is checked into the repository. All dependency versions are pinned.
- **Swift tools version**: Locked to `swift-tools-version 6.2` in `Package.swift`
- **No network during build**: All Apple frameworks are part of the OS SDK. The build does not download anything.
- **Deterministic compilation**: Swift compiler produces bit-for-bit identical output given the same SDK version and source files.

### 9.3 Distribution Integrity

| Channel | Integrity Mechanism |
|---------|-------------------|
| **GitHub Releases** | Git tags signed with maintainer's GPG key; asset checksums published |
| **Homebrew** | Formula references specific git tag + SHA256 of source tarball |
| **Direct build** | `swift build` from signed git tag; verify with `git tag -v v3.0.0` |

### 9.4 Code Signing

- **Daemon binary**: Signed with Developer ID for Gatekeeper acceptance
- **App bundle**: Signed + notarized by Apple for distribution outside Mac App Store
- **Hardened Runtime**: Enabled with appropriate entitlements (Full Disk Access, Accessibility)

---

## 10. Compliance Notes

### 10.1 GDPR

DeepFinder is **not a data controller or processor** under GDPR. The software:

- Runs entirely on the user's device
- Collects zero telemetry, analytics, or usage data
- Makes no network connections in its default configuration
- Stores all data locally under the user's home directory
- Does not transmit personal data to any server operated by the developer

**If the user opts into cloud AI features:** The user is the data controller. DeepFinder transmits only the query text the user types (for NL search translation) or file names + extensions (for summarization/semantic grouping). No file contents, no full paths, no personal identifiers are transmitted. The user is responsible for ensuring their use of cloud AI providers complies with applicable regulations.

### 10.2 CCPA (California Consumer Privacy Act)

DeepFinder does not collect, sell, or share personal information. There is no business relationship between the user and the developer — the software is a tool, not a service.

### 10.3 Accessibility

DeepFinder's GUI is built with SwiftUI and supports:
- Full keyboard navigation (no mouse required)
- VoiceOver compatibility via standard SwiftUI accessibility modifiers
- `LSUIElement` menu bar app (no Dock icon, stays out of the way)

The global hotkey (`⌃⌘K`) requires Accessibility permission, which is requested with a clear explanation dialog on first launch.

### 10.4 macOS Security Compliance

| Requirement | Status |
|-------------|--------|
| Hardened Runtime | Enabled |
| Library Validation | Enabled (no third-party dylibs to load) |
| Disable Executable Memory | Enabled (no JIT) |
| Disable Debugging | Enabled in Release builds |
| App Sandbox | Not applicable (Full Disk Access incompatible with sandbox) |
| Notarization | Yes (Apple-notarized for Gatekeeper) |
| SIP-compatible | Yes (no SIP-protected paths modified; LaunchAgent in user domain) |

### 10.5 Third-Party Audit Readiness

We welcome independent security audits. The codebase is structured to support review:

- Single language (Swift, no C/C++/ObjC interop beyond system frameworks)
- No macros, no code generation, no reflection tricks
- Clear module boundaries with explicit dependency direction
- Comprehensive inline documentation explaining WHY, not just WHAT
- Test suite covers security-critical paths (IPC framing, peer credential verification, token authentication, query validation)

---

## Appendix A: Security Checklist for Users

Before trusting DeepFinder with Full Disk Access, verify:

- [ ] Downloaded from GitHub Releases or installed via Homebrew (never from untrusted sources)
- [ ] Verify code signature: `codesign -dvvv /path/to/deepfinder-daemon`
- [ ] Check file permissions: `ls -la ~/.deep-finder/` — all files should be `0o600`, directories `0o700`, except `daemon.pid` at `0o644`
- [ ] Check socket permissions: `ls -la ~/.deep-finder/session/ipc.sock` should show `srw-------`
- [ ] Verify no listening ports beyond localhost: `lsof -i -P | grep deepfinder` should show only `localhost:7654`
- [ ] Confirm LaunchAgent is user-level: `launchctl list | grep deepfinder` should show status, not system daemon
- [ ] AI features are opt-in: if no API keys are configured, verify no outbound connections with Little Snitch or similar
- [ ] Review `~/.deep-finder/.env` for unexpected entries

## Appendix B: Quick Security Reference

| Item | Value |
|------|-------|
| Daemon runs as | Current user (not root) |
| IPC socket | `~/.deep-finder/session/ipc.sock` (0o600) |
| IPC auth | `LOCAL_PEERCRED` same-UID check |
| HTTP API | `127.0.0.1:7654` (localhost only) |
| HTTP auth | Random UUIDv4 bearer token per session |
| Database | `~/.deep-finder/cache/index.db` (0o600) |
| Secrets | `~/.deep-finder/.env` (0o600) |
| AI cloud data | Query text only (no file contents, no paths) |
| AI on-device | Vision (ANE), Speech (local), NL (CoreML) — zero network |
| Dependencies | Zero (pure Swift + Apple frameworks) |
| Telemetry | Zero |
| Security contact | `security@nadav.com.cn` |
| Disclosure policy | Coordinated Vulnerability Disclosure (CERT/CC model) |

---

*This document will be reviewed and updated with each major release. Last updated: 2026-06-03 for DeepFinder v3.0.0.*
