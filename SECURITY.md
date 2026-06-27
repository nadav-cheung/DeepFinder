# Security Policy

## Supported Versions

DeepFind is pre-1.0 (`0.1.x`). Security fixes are applied to the latest release line:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

Only the latest `0.1.x` release receives security updates. If you are running an older version, please upgrade before reporting a vulnerability.

## Reporting a Vulnerability

If you discover a security vulnerability in DeepFind, please report it privately. **Do not open a public GitHub issue.**

**Preferred — GitHub Private Vulnerability Reporting:** click **"Report a vulnerability"** on this repository's [Security → Advisories](../../security/advisories/new) tab. Reports submitted this way are encrypted, visible only to maintainers, and support coordinated disclosure end-to-end (draft security advisory → optional CVE → controlled publication). This is the fastest and safest path.

**Email:** [security@nadav.com.cn](mailto:security@nadav.com.cn) if you cannot use the GitHub channel above.

**Response pledge:** We will acknowledge your report within **48 hours** and provide an initial assessment, including a timeline for a fix if the issue is confirmed.

When reporting, please include as much of the following as possible:

- Affected component and DeepFind version (`deepfind --version`)
- Step-by-step reproduction instructions
- Proof-of-concept code or a sample exploit (if available)
- Any relevant logs, crash reports, or screenshots
- Your assessment of the severity and potential impact

**Do not open a public GitHub issue** for security vulnerabilities. We follow a coordinated disclosure process (see below).

## Disclosure Policy

We follow a **90-day coordinated disclosure** timeline:

1. **Day 0**: You report the vulnerability via GitHub Private Reporting or [security@nadav.com.cn](mailto:security@nadav.com.cn).
2. **Day 0–30**: We validate, reproduce, and develop a fix.
3. **Day 30–60**: We release a patched version and notify downstream packagers (Homebrew).
4. **Day 60–90**: Users are given time to update. A CVE may be requested if warranted.
5. **After Day 90**: Public disclosure is permitted. We will publish an advisory on GitHub with full details and credit to the reporter (unless you prefer to remain anonymous).

We may negotiate a shorter or longer timeline depending on the complexity and severity of the issue. Our goal is to protect users while recognizing the value of public disclosure.

## Scope

DeepFind is a **local-only** macOS tool: the daemon listens on a Unix domain socket (`~/.deep-find/daemon.sock`), not a network port, and never transmits indexed data over the network.

### In Scope

The following components and attack surfaces are considered in scope:

- **Daemon (`deepfindd`)**: Unix domain socket IPC server, daemon lifecycle, socket/PID file handling, lockless shard hot-swap (`ArcSwap`), and the `df-watch` watcher (`rebuild_and_swap`, self-write filtering).
- **IPC protocol (`df-ipc`)**: message parsing, 4-byte length-prefix framing, `bincode` deserialization, and access control on the local socket.
- **CLI (`deepfind`)**: argument parsing, output formatting, the `--direct` online-scan fallback, and IPC client behavior.
- **Index persistence (`df-index` / `df-core` / `df-content`)**: the filename DB `index.dfdb` (pread) and content shards `shard-*.dfcs` (mmap), the `MANIFEST`, the multi-DB registry `dbs.toml`, and atomic-write / rename-swap correctness (no half-written or SIGBUS-prone state).
- **Filesystem access**: `ignore` / FSEvents traversal, Full Disk Access / TCC handling, `same_file_system` behavior, and `--scope` / skip-path enforcement.

### Out of Scope

- **Social engineering** attacks (phishing, pretexting, impersonation).
- **Physical access** attacks (direct hardware access, DMA attacks).
- **Denial of Service (DoS)** that relies on saturating the local machine's resources (CPU, memory, disk I/O) — DeepFind is a local-only tool by design.
- **Issues in third-party dependencies** unless you can demonstrate a specific impact within DeepFind's context.
- **Theoretical vulnerabilities** without a practical proof of concept.
- **Missing security headers or cookie flags** — DeepFind is a native macOS application with no network/web-service surface.

If you are unsure whether an issue is in scope, please email us before investing significant research time.

## Safe Harbor

We consider security research conducted in good faith to be:

- **Authorized** under this policy, provided you comply with all applicable laws.
- **Exempt** from our Acceptable Use Policy and any account restrictions related to such research.
- **Protected** from legal action, provided the research is conducted in accordance with this policy.

**Good-faith research means:**

- Making a reasonable effort to avoid privacy violations, data destruction, and service disruption.
- Not exploiting a vulnerability beyond what is necessary to demonstrate it.
- Not accessing, modifying, or exfiltrating data that does not belong to you.
- Giving us a reasonable amount of time to address the issue before public disclosure.
- Not weaponizing vulnerabilities for extortion, ransomware, or other malicious purposes.

**Our commitment:** We will not pursue legal action against individuals who report vulnerabilities in accordance with this policy. We will not request law enforcement investigation of good-faith security research. We will credit reporters in our public advisories (unless you request anonymity).

We are grateful for the work of the security research community and are committed to working with researchers to resolve issues promptly and transparently.
