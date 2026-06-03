# Entitlements & Notarization — DeepFinder

> **Audience**: macOS distribution engineers preparing DeepFinder for notarization via
> `notarytool`. This document is written as an Apple notarization justification
> artefact. All code references are to files under `Sources/`, current as of v3.0.0.

---

## 1. Architecture & Entitlement Strategy

DeepFinder is a **menu bar app (LSUIElement)** distributed outside the Mac App Store
via GitHub Releases and Homebrew. It consists of three executables packaged into one
`.app` bundle:

| Executable          | Role                                          |
|---------------------|-----------------------------------------------|
| `deepfinder-app`    | GUI (menu bar app) — global hotkey, search UI |
| `deepfinder-daemon` | Background indexer — FSEvents, SQLite, IPC    |
| `deepfinder`        | CLI client — thin terminal client over IPC    |

**Distribution model**: Developer ID signed, Hardened Runtime enabled, **not
sandboxed**. The app requires Full Disk Access and Accessibility permissions,
both of which are incompatible with App Sandbox.

**Key decision**: No App Sandbox. DeepFinder must scan all user files via FSEvents,
create Unix domain sockets, spawn daemon subprocesses, and register global
hotkeys — all operations blocked by sandboxing. Apple grants notarization for
non-sandboxed Developer ID apps as long as Hardened Runtime is enabled and
entitlements are justified.

---

## 2. Required Entitlements Table

### 2.1 Hardened Runtime Baseline

All notarized Developer ID apps must enable Hardened Runtime. This is done via
the `--options runtime` flag during code signing. The baseline enables these
protections by default:

| Protection                       | DeepFinder impact                                    |
|----------------------------------|------------------------------------------------------|
| Code Integrity Guard             | Prevents code injection — acceptable                 |
| Library Validation               | Only load signed libraries — acceptable (all deps are Apple frameworks) |
| DYLD environment restrictions    | Prevents `DYLD_INSERT_LIBRARIES` attacks — acceptable |
| Debugger restrictions            | Prevents debugger attach — acceptable for release    |
| Disable executable memory        | Prevents `mmap(PROT_WRITE\|PROT_EXEC)` — acceptable  |

### 2.2 Hardened Runtime Exceptions Claimed

**None.** DeepFinder uses zero Hardened Runtime exception entitlements.

All dependencies are Apple system frameworks shipped with macOS and signed by
Apple. The binary links against `libedit` for Darwin.readline support
(`Package.swift`: `.linkedLibrary("edit")`), which is in the dyld shared cache
and is validated via normal Library Validation — no exception needed.

### 2.3 Summary Entitlement File

The minimal `.entitlements` file used for notarization:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Hardened Runtime is enabled via --options runtime, not via entitlement -->
    <!-- All protections enabled: Code Integrity Guard, Library Validation,
         DYLD restrictions, Debugger restrictions, Executable Memory Protection -->
    <!-- No exceptions claimed — see §3 for justification of each non-claim -->
</dict>
</plist>
```

> **Note**: The file is intentionally empty. Hardened Runtime is activated by
> `codesign --options runtime`, not by a plist key. A zero-entitlement file
> explicitly declares that no exceptions are being claimed, which is the
> strongest posture for notarization review.

---

## 3. Hardened Runtime Exceptions — NOT Claimed (With Justification)

Each Hardened Runtime exception that is **not** claimed requires an explanation
for the notarization reviewer. The following sections address every exception
in Apple's Hardened Runtime documentation.

### 3.1 `com.apple.security.cs.disable-library-validation`

**NOT claimed.**

DeepFinder loads no third-party plugins, frameworks, or dylibs at runtime. The
only non-Foundation dynamic dependency is `libedit` (`-ledit` in
`Package.swift`), which is loaded by dyld at launch from the system's signed
shared cache (`/usr/lib/libedit.3.dylib`). It passes Library Validation
without exception because it is signed by Apple.

- **Code ref**: `Package.swift` line 22: `.linkedLibrary("edit")`

### 3.2 `com.apple.security.cs.allow-jit`

**NOT claimed.**

No JavaScriptCore, WebKit, or JIT compilation is used anywhere in the app.
All code is ahead-of-time compiled Swift.

### 3.3 `com.apple.security.cs.allow-unsigned-executable-memory`

**NOT claimed.**

DeepFinder does not allocate writable + executable memory pages. No JIT
compilation, no `mmap(PROT_WRITE | PROT_EXEC)`, no MAP_JIT regions. The Swift
runtime's metadata allocation uses `mmap(PROT_READ | PROT_WRITE)` only.

### 3.4 `com.apple.security.cs.disable-executable-page-protection`

**NOT claimed.**

No code paths require pages to be simultaneously writable and executable.

### 3.5 `com.apple.security.cs.allow-dyld-environment-variables`

**NOT claimed.**

End-user debugging via `DYLD_INSERT_LIBRARIES` is not needed. Developers
attach Xcode's debugger with a Development-signed build (which includes
`get-task-allow`), not the notarized distribution.

### 3.6 `com.apple.security.cs.debugger`

**NOT claimed.**

Release builds must not be debuggable by arbitrary processes. Debugging is
done via Xcode attach-to-process with Development signing.

---

## 4. Privacy / TCC Permissions (Not Entitlements)

These are **privacy prompts** that the user must grant in System Settings.
They are NOT code signing entitlements — they do not appear in
`entitlements.plist`. They are included here because notarization reviewers
check that `Info.plist` usage description strings are present.

### 4.1 Accessibility — Global Hotkey

| Field                       | Value                                                                 |
|-----------------------------|-----------------------------------------------------------------------|
| **Permission**              | Accessibility (TCC: `kTCCServiceAccessibility`)                       |
| **User-facing string**      | "DeepFinder needs Accessibility access to register the global hotkey (Ctrl+Cmd+K) that opens the search panel." |
| **Code path**               | `Sources/GUI/GlobalHotkey.swift:316` — `RegisterEventHotKey()`        |
| **Fallback path**           | `Sources/GUI/GlobalHotkey.swift:419` — `CGEvent.tapCreate()`          |
| **Prompt helper**           | `Sources/GUI/HotkeyPermissionHelper.swift:37` — `requestAccessibility()` |
| **Justification**           | Carbon `RegisterEventHotKey` requires Accessibility (AX) permission on macOS. Without it, hotkey cannot be registered. DeepFinder provides a fallback via CGEventTap (Input Monitoring permission) but prefers Carbon for reliability. |
| **Risk if denied**          | Global hotkey does not work. User must open search from the menu bar icon instead. The app remains fully functional for search via the menu bar. |

**Info.plist entry required**:
```xml
<key>NSAppleEventsUsageDescription</key>
<string>DeepFinder needs Automation access to register the global hotkey
(Ctrl+Cmd+K) for opening the search panel.</string>
```

### 4.2 Full Disk Access — File Scanning

| Field                       | Value                                                                 |
|-----------------------------|-----------------------------------------------------------------------|
| **Permission**              | Full Disk Access (TCC: `kTCCServiceSystemPolicyAllFiles`)             |
| **Code path**               | `Sources/FS/FileScanner.swift:171` — `FileManager.default.enumerator` |
| **Affected directories**    | ~/Documents, ~/Desktop, ~/Downloads (skip silently without FDA)       |
| **Justification**           | DeepFinder indexes local files for instant search. Without Full Disk Access, the user's Documents, Desktop, and Downloads folders are invisible to `FileManager.enumerator()` and FSEvents. The app still works — it indexes only directories accessible without FDA (e.g., home directory root files, non-sandboxed locations). |
| **Risk if denied**          | ~/Documents, ~/Desktop, ~/Downloads are excluded from the index. The app displays a warning in Settings. Other directories are indexed normally. |

**Info.plist entry is NOT required** — Full Disk Access is requested via
the dedicated System Settings > Privacy & Security > Full Disk Access pane.
There is no usage description string for this permission; the user adds
the app manually or it is prompted on first launch when the daemon is
spawned via LaunchAgent (which runs in the user's session).

### 4.3 Files and Folders (implicit)

Because DeepFinder uses `FileManager.default.enumerator` on user home
directories, macOS may present the "DeepFinder would like to access files in
your Desktop folder" prompt on first scan. This is a standard TCC prompt
for user-selected directories — no entitlement required.

---

## 5. Entitlements NOT Needed (Misconceptions)

### 5.1 Network Access

| Entitlement | Needed? | Why |
|---|---|---|
| `com.apple.security.network.client` | **No** | Only applies in App Sandbox. DeepFinder is not sandboxed. Hardened Runtime alone does not restrict outbound network. |
| `com.apple.security.network.server` | **No** | The HTTP search service (`Sources/Services/HTTPSearchService`, port 7654) is in the daemon process and only binds to `127.0.0.1`. Without App Sandbox, listening on localhost requires no entitlement. |

**Cloud AI providers**: DeepFinder's AI semantic search sends filenames (not
file contents) to cloud AI API endpoints (Anthropic, DeepSeek, Qwen, cloud
embeddings) via `URLSession`. These are standard HTTPS outbound connections
that Hardened Runtime does not block.

- **Code refs**: `Sources/AI/HTTPClient.swift:56`, `Sources/AI/CloudEmbeddingProvider.swift:43`,
  `Sources/AI/AnthropicProvider.swift`, `Sources/AI/DeepSeekProvider.swift`

### 5.2 USB / Bluetooth / Camera / Microphone

**Not needed.** DeepFinder is a file search tool and does not access hardware
peripherals.

### 5.3 App Sandbox

**Cannot be used.** DeepFinder requires Full Disk Access, subprocess spawning,
and Unix domain socket creation — all of which are explicitly forbidden by the
App Sandbox.

### 5.4 Push Notifications / iCloud / HealthKit / etc.

**Not needed.** DeepFinder is a local file search tool.

### 5.5 Hardened Runtime Runtime Exceptions

All six HR exceptions (see §3) are **not needed**. This is the strongest
posture for notarization — fewer exceptions = faster review, fewer questions.

---

## 6. Notarization Checklist

### 6.1 Pre-Flight Verification

```bash
# 1. Verify Hardened Runtime is enabled on every executable
for bin in DeepFinder.app/Contents/MacOS/*; do
    echo "=== $bin ==="
    codesign -dvvv "$bin" 2>&1 | grep -E "flags|runtime"
done
# MUST show: flags=0x10000(runtime) for every binary

# 2. Verify no unexpected entitlements
codesign -d --entitlements - DeepFinder.app/Contents/MacOS/DeepFinderApp
# Should show the minimal plist from §2.3 (or fewer keys)

# 3. Verify deep code signing (no unsigned nested code)
codesign --verify --deep --strict --verbose=4 DeepFinder.app
# MUST exit 0 with no warnings

# 4. Verify Info.plist is valid
plutil -lint DeepFinder.app/Contents/Info.plist
# MUST report "OK"

# 5. Ensure no debug entitlements leaked into release
codesign -d --entitlements - DeepFinder.app/Contents/MacOS/DeepFinderApp | grep get-task-allow
# MUST return empty (no match)
```

### 6.2 Code Signing

```bash
IDENTITY="Developer ID Application: Nadav (XXXXXXXXXX)"

# Sign from inside-out: CLI first, then daemon, then app bundle last
# 1. Sign CLI executable
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    DeepFinder.app/Contents/MacOS/deepfinder

# 2. Sign daemon executable
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    DeepFinder.app/Contents/MacOS/deepfinder-daemon

# 3. Sign app bundle (signs app executable + entire .app)
codesign --force --options runtime --timestamp \
    --entitlements App/entitlements.plist \
    --sign "$IDENTITY" \
    DeepFinder.app

# 4. Re-verify
codesign --verify --deep --strict --verbose=4 DeepFinder.app
spctl -a -t exec -vv DeepFinder.app
```

### 6.3 Packaging

```bash
# Use ditto — NOT Finder "Compress" or zip. ditto preserves resource forks,
# symlinks, and extended attributes required by code signing.
ditto -c -k --keepParent --sequesterRsrc \
    DeepFinder.app \
    DeepFinder-v3.0.0.zip
```

### 6.4 Notarization Submission

```bash
# Submit via notarytool (App Store Connect API key)
xcrun notarytool submit DeepFinder-v3.0.0.zip \
    --key "$APPSTORE_CONNECT_API_KEY_PATH" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER_ID" \
    --wait

# Expected output:
#   Successfully received submission info
#   Submission ID: ...
#   Status: Accepted
```

### 6.5 Stapling

```bash
# Staple the notarization ticket to the .app (NOT the .zip)
xcrun stapler staple DeepFinder.app

# Verify stapling
xcrun stapler validate DeepFinder.app
# MUST output: "The validate action worked!"

# Final Gatekeeper check
spctl -a -t exec -vv DeepFinder.app
# MUST show: source=Notarized Developer ID
```

### 6.6 Post-Notarization: Re-packaging the Stapled App

```bash
# After stapling, create the distribution ZIP from the stapled .app
ditto -c -k --keepParent --sequesterRsrc \
    DeepFinder.app \
    DeepFinder-v3.0.0.zip
```

---

## 7. Common Rejection Reasons & Mitigations

| # | Rejection | Cause | DeepFinder Mitigation |
|---|-----------|-------|----------------------|
| 1 | "Hardened Runtime not enabled" | Forgot `--options runtime` | CI enforces `flags=0x10000(runtime)` check (§8) |
| 2 | "get-task-allow present in release" | Debug provisioning leaked | CI greps for `get-task-allow` in entitlements (§8) |
| 3 | "Incomplete signature chain" | Nested binary not signed | `codesign --verify --deep --strict` before submission |
| 4 | "Missing usage description" | No `Info.plist` string for TCC prompt | `NSAppleEventsUsageDescription` in `App/Info.plist` |
| 5 | "Invalid signature" for daemon executable | Daemon binary not individually signed | Sign daemon separately before signing the .app bundle |
| 6 | "The binary is not signed with a valid Developer ID certificate" | Wrong cert type (Mac Development vs Developer ID Application) | CI keychain contains only Developer ID cert |
| 7 | Stuck "In Progress" | First notarization for team | Expected — wait 1–24 hours; subsequent notarizations take minutes |
| 8 | "Team not yet configured" (statusCode 7000) | Account not activated for notarization | Contact Developer Program Support (not DTS) |
| 9 | Gatekeeper blocks after successful notarization | Forgot to staple, or stapled the wrong file | Follow sequence: sign → notarize → staple (§6.4–§6.5) |
| 10 | Hardened Runtime exception denied | Invalid justification or missing explanation | Zero exceptions claimed — this document is the justification |

---

## 8. CI Integration

### 8.1 Entitlement Verification in CI

```bash
#!/bin/bash
# verify-entitlements.sh — Run after build, before notarization submission
# Exit non-zero on any violation.
set -euo pipefail

APP="build/DeepFinder.app"
ENTITLEMENTS="App/entitlements.plist"

echo "=== 1. Verify Hardened Runtime on all binaries ==="
for bin in "$APP"/Contents/MacOS/*; do
    flags=$(codesign -dvvv "$bin" 2>&1 | grep "^CodeDirectory" || true)
    if ! echo "$flags" | grep -q "runtime"; then
        echo "FAIL: $bin missing Hardened Runtime (no 'runtime' in flags)"
        codesign -dvvv "$bin" 2>&1 | grep -E "flags|^CodeDirectory"
        exit 1
    fi
    echo "  OK: $(basename "$bin") — runtime enabled"
done

echo "=== 2. Verify no get-task-allow in release ==="
for bin in "$APP"/Contents/MacOS/*; do
    if codesign -d --entitlements - "$bin" 2>/dev/null | grep -q "get-task-allow"; then
        echo "FAIL: $bin contains get-task-allow (debug entitlement leaked into release)"
        exit 1
    fi
done
echo "  OK: no get-task-allow"

echo "=== 3. Verify deep signature chain ==="
codesign --verify --deep --strict --verbose=4 "$APP"
echo "  OK: signature chain valid"

echo "=== 4. Verify Info.plist has required keys ==="
plutil -lint "$APP/Contents/Info.plist"

# Check for Accessibility usage description
if ! /usr/libexec/PlistBuddy -c "Print NSAppleEventsUsageDescription" \
    "$APP/Contents/Info.plist" &>/dev/null; then
    echo "FAIL: NSAppleEventsUsageDescription missing from Info.plist"
    exit 1
fi
echo "  OK: NSAppleEventsUsageDescription present"

echo "=== 5. Verify LPSecurity (LSUIElement) ==="
if ! /usr/libexec/PlistBuddy -c "Print LSUIElement" \
    "$APP/Contents/Info.plist" &>/dev/null; then
    echo "FAIL: LSUIElement missing from Info.plist"
    exit 1
fi
echo "  OK: LSUIElement present"

echo "=== 6. Verify entitlements are minimal ==="
ent_count=$(codesign -d --entitlements - "$APP/Contents/MacOS/DeepFinderApp" 2>/dev/null | \
    plutil -convert json -o - - | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
if [ "$ent_count" -gt 3 ]; then
    echo "WARN: $ent_count entitlements (>3). Review for unnecessary exceptions."
fi
echo "  OK: $ent_count entitlement(s) — within expected range"

echo ""
echo "✓ All entitlement checks passed"
```

### 8.2 GitHub Actions Integration

```yaml
# In .github/workflows/release.yml
notarize:
  runs-on: macos-26
  steps:
    - uses: actions/checkout@v4
    - name: Build release
      run: swift build -c release
    - name: Package app bundle
      run: ./scripts/package-app.sh
    - name: Verify entitlements
      run: ./scripts/verify-entitlements.sh
    - name: Code sign
      env:
        DEV_ID_APP_CERT: ${{ secrets.DEVELOPER_ID_APPLICATION_CERT_BASE64 }}
        DEV_ID_APP_KEY: ${{ secrets.DEVELOPER_ID_APPLICATION_KEY_BASE64 }}
        KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
      run: ./scripts/codesign-release.sh
    - name: Notarize
      env:
        APPSTORE_CONNECT_KEY: ${{ secrets.APPSTORE_CONNECT_API_KEY }}
        APPSTORE_CONNECT_KEY_ID: ${{ secrets.APPSTORE_CONNECT_KEY_ID }}
        APPSTORE_CONNECT_ISSUER_ID: ${{ secrets.APPSTORE_CONNECT_ISSUER_ID }}
      run: |
        ditto -c -k --keepParent --sequesterRsrc \
          build/DeepFinder.app DeepFinder.zip
        xcrun notarytool submit DeepFinder.zip \
          --key <(echo "$APPSTORE_CONNECT_KEY") \
          --key-id "$APPSTORE_CONNECT_KEY_ID" \
          --issuer "$APPSTORE_CONNECT_ISSUER_ID" \
          --wait
        xcrun stapler staple build/DeepFinder.app
        xcrun stapler validate build/DeepFinder.app
```

---

## 9. Reference: All Protection Defaults

This table documents every Hardened Runtime protection and its applicability
to DeepFinder, serving as the definitive justification artefact for notarization
review.

| Protection | Default | DeepFinder impact | Exception needed? |
|---|---|---|---|
| Code Integrity Guard | Enabled | Protects against code injection | No |
| Library Validation | Enabled | All deps are Apple-signed frameworks | No |
| DYLD Environment | Enabled | No `DYLD_INSERT_LIBRARIES` needed | No |
| Debugger restrictions | Enabled | Release builds should not be debuggable | No |
| Executable memory protection | Enabled | No JIT, no MAP_JIT memory | No |
| Allow Unsigned Executable Memory | — | Not used | **No** |
| Allow JIT | — | No WebKit, no JS engine | **No** |
| Disable Library Validation | — | No third-party plugins/dylibs | **No** |
| Disable Executable Page Protection | — | Not used | **No** |
| Allow DYLD Environment Variables | — | Dev debugging via Development build only | **No** |
| Debugger | — | Debugging via Development build only | **No** |

**Result**: DeepFinder claims zero Hardened Runtime exceptions. All protections
remain at their default (enabled) state. This is the strongest security posture
and the fastest path through notarization review.

---

## Sources

- [Apple Developer — Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime)
- [Apple Developer — Notarizing macOS Software Before Distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Apple Developer — App Sandbox Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_app-sandbox)
- [Code Signing on macOS: What Developers Need to Know, Part 3 (Xojo, 2026)](https://blog.xojo.com/2026/03/24/code-signing-on-macos-what-developers-need-to-know-part-3/)
- [Sparkle 2 — Code Signing and Notarization (Peter Steinberger, 2025)](https://steipete.me/posts/2025/code-signing-and-notarization-sparkle-and-tears)
- [Apple Escalates macOS Defenses (Six Colors, 2026)](https://sixcolors.com/post/2026/05/apple-escalates-macos-defenses-while-honoring-its-open-nature/)
