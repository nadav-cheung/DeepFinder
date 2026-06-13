# Security Policy

## Supported Versions

We release patches for security vulnerabilities in the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 3.x.x   | :white_check_mark: |
| < 3.0   | :x:                |

Only the latest major version (v3) receives security updates. If you are running an older version, please upgrade before reporting a vulnerability.

## Reporting a Vulnerability

If you discover a security vulnerability in DeepFinder, please report it responsibly.

**Contact**: [security@nadav.com.cn](mailto:security@nadav.com.cn)

**Response pledge**: We will acknowledge your report within **48 hours** and provide an initial assessment, including a timeline for a fix if the issue is confirmed.

When reporting, please include as much of the following as possible:

- Affected component and version
- Step-by-step reproduction instructions
- Proof-of-concept code or a sample exploit (if available)
- Any relevant logs, crash reports, or screenshots
- Your assessment of the severity and potential impact

**Do not open a public GitHub issue** for security vulnerabilities. We follow a coordinated disclosure process (see below).

## Disclosure Policy

We follow a **90-day coordinated disclosure** timeline:

1. **Day 0**: You report the vulnerability to [security@nadav.com.cn](mailto:security@nadav.com.cn).
2. **Day 0–30**: We validate, reproduce, and develop a fix.
3. **Day 30–60**: We release a patched version and notify downstream packagers (Homebrew).
4. **Day 60–90**: Users are given time to update. A CVE may be requested if warranted.
5. **After Day 90**: Public disclosure is permitted. We will publish an advisory on GitHub with full details and credit to the reporter (unless you prefer to remain anonymous).

We may negotiate a shorter or longer timeline depending on the complexity and severity of the issue. Our goal is to protect users while recognizing the value of public disclosure.

## Scope

### In Scope

The following components and attack surfaces are considered in scope:

- **Daemon** (`DeepFinderDaemon`): Unix domain socket IPC server, privilege model, daemon lifecycle, PID/socket file handling
- **IPC Protocol**: Message parsing, length-prefix framing, JSON deserialization, authentication and authorization of connected clients
- **AI / Semantic Search** (v3.0): CoreML model loading, Vision tagging, LLM API communication, vector indexing, RAG pipeline, user-content privacy boundaries
- **CLI** (`DeepFinderCLI`): Argument parsing, REPL input handling, output formatting, history persistence, inter-process communication with daemon
- **GUI** (v2.0+): NSPanel search interface, global hotkey handling, Accessibility permissions, IPC client, Quick Look integration
- **Index Persistence**: SQLite database at `~/.deep-finder/index.db`, FSEvents cursor state, configuration storage
- **File System Access**: FSEventStream permissions, Full Disk Access handling, external/network volume indexing

### Out of Scope

- **Social engineering** attacks (phishing, pretexting, impersonation)
- **Physical access** attacks (direct hardware access, DMA attacks)
- **Denial of Service (DoS)** attacks that rely on saturating the local machine's resources (CPU, memory, disk I/O) — DeepFinder is a local-only tool by design
- **Issues in third-party dependencies** unless you can demonstrate a specific impact within DeepFinder's context
- **Theoretical vulnerabilities** without a practical proof of concept
- **Missing security headers or cookie flags** (DeepFinder is a native macOS application, not a web service)

If you are unsure whether an issue is in scope, please email us before investing significant research time.

## Safe Harbor

We consider security research conducted in good faith to be:

- **Authorized** under this policy, provided you comply with all applicable laws
- **Exempt** from our Acceptable Use Policy and any account restrictions related to such research
- **Protected** from legal action by nadav.com.cn, provided the research is conducted in accordance with this policy

**Good-faith research means**:

- Making a reasonable effort to avoid privacy violations, data destruction, and service disruption
- Not exploiting a vulnerability beyond what is necessary to demonstrate it
- Not accessing, modifying, or exfiltrating data that does not belong to you
- Giving us a reasonable amount of time to address the issue before public disclosure
- Not weaponizing vulnerabilities for extortion, ransomware, or other malicious purposes

**Our commitment**: We will not pursue legal action against individuals who report vulnerabilities in accordance with this policy. We will not request law enforcement investigation of good-faith security research. We will credit reporters in our public advisories (unless you request anonymity).

We are grateful for the work of the security research community and are committed to working with researchers to resolve issues promptly and transparently.
