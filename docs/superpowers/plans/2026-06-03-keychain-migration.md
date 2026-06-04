# ❌ CANCELLED — Keychain Migration Plan

**Date**: 2026-06-03
**Status**: **CANCELLED** (per project owner decision, 2026-06-03)
**Cancellation reason**: `.env` file with `0o600` permissions is the permanent design choice for API key storage. macOS Keychain will NOT be used. See `REQ_CHANGE_LOG.md` CHG-2026-06-03-01.

---

> The following content is preserved for historical reference only. This plan will not be implemented.

---

## Executive Summary

DeepFinder currently stores API keys for Anthropic, DeepSeek, Qwen, Gemini, OpenAI, and other providers in `~/.deep-finder/.env` — a plaintext JSON file protected only by POSIX permissions 600. The privacy model documentation (`docs/explanation/privacy-model.md`) **falsely claims** that "API keys encrypted in Keychain" and "API keys (stored via `KeychainStore`)". Neither claim is true. There is no `KeychainStore.swift` file; the existing `SecretsStore.swift` is a file-backed JSON store.

This document defines the migration from plaintext file storage to the macOS Keychain, fixes the documentation, and establishes a verifiable security boundary for API credentials.

---

## 1. Current Vulnerability

### 1.1 File Layout

```
~/.deep-finder/
  .env          <-- SecretsStore: flat JSON dict { "ai.apiKey": "sk-...", ... }
  settings.json <-- ConfigStore: user config, may also contain ai.apiKey (legacy)
```

### 1.2 Attack Surface

| Threat vector | Risk | Impact |
|---|---|---|
| **Malware with user-level access** | High | Any process running as the current user can `cat ~/.deep-finder/.env` and exfiltrate the keys. No elevation needed. POSIX 600 stops other users but does nothing against same-user processes. |
| **Backup exfiltration** | Medium | Time Machine, iCloud Drive, and third-party backup tools copy `.env` as plaintext. An attacker with access to backup storage (external drive, cloud account) gains all API keys. |
| **Screen-sharing / remote access** | Medium | If an attacker gains remote access to the user session (RDP/VNC/SSH), `.env` is trivially readable. |
| **Supply chain (malicious dependency)** | Medium | Any Swift Package or Homebrew formula running in the same user context can read the file. |
| **Accidental disclosure** | Low | User might share `.env` in screenshots, logs, or support bundles without realizing it contains live API keys. |
| **Memory inspection** | Low | Provider structs hold `private let apiKey: String` — keys remain in process memory as plaintext `String` values on the Swift heap. A memory dump (e.g., `sudo vmmap`) could extract them. |

### 1.3 Current Code Path

```
CLI/Daemon reads config dict
    └─> AIConfig.getAPIKey(config:secretsStore:)
        ├─> SecretsStore.load(key:)  → reads ~/.deep-finder/.env JSON
        └─> returns plaintext String
            └─> ProviderRegistry.instantiate(model:apiKey:...)
                ├─> OpenAICompatibleProvider(apiKey: String)    // stored as let
                ├─> AnthropicProvider(apiKey: String)
                ├─> GeminiProvider(apiKey: String)
                └─> ... all hold plaintext String in memory
```

### 1.4 Documentation Gap

`docs/explanation/privacy-model.md` line 15:
> "API keys encrypted in Keychain"

`docs/explanation/privacy-model.md` line 71:
> "API keys (stored via `KeychainStore`)"

Both statements are **false**. This is not just a documentation bug — it is a **security misrepresentation** to users who rely on the privacy model for trust decisions about opting into cloud AI features.

---

## 2. Target State

### 2.1 Post-Migration Architecture

```
~/.deep-finder/
  .env             <-- DELETED after migration (or .env.backup for rollback)
  .env.migrated     <-- sentinel file confirming migration completed
  settings.json    <-- ai.apiKey key REMOVED from config dict

Keychain (login keychain, ~/Library/Keychains/login.keychain-db):
  Service: cn.com.nadav.deepfinder.apikeys
  Account: anthropic   → Data: sk-ant-...
  Account: deepseek    → Data: sk-...
  Account: qwen        → Data: sk-...
  Account: gemini      → Data: AIza...
  Account: openai      → Data: sk-...
  Account: zhipu       → Data: ...
  Account: moonshot    → Data: sk-...
  Account: minimax     → Data: ...
  Account: custom      → Data: ... (custom API key)

Memory:
  KeychainStore (actor) — loads key on demand, does NOT cache in String
  Providers receive apiKey as Data? → converted to String only for HTTP header injection
```

### 2.2 Security Properties Achieved

- **Encrypted at rest**: Keychain database is encrypted with the user's login password via the Secure Enclave
- **Access-gated by OS**: Keychain prompts on first access per-application; no silent reads by other processes
- **No backup exposure**: Keychain items with `kSecAttrSynchronizable = false` do not sync to iCloud and are NOT included in plaintext file backups
- **Audit trail**: Keychain Access app shows which applications accessed which items
- **Memory hardening**: Minimize plaintext `String` lifetime; use `withUnsafeBytes` for HTTP header injection where practical

---

## 3. Keychain Schema Design

### 3.1 Item Class

Use `kSecClassGenericPassword` — the standard class for application credentials.

`kSecClassInternetPassword` is not appropriate because these are not web login credentials with server/port/protocol attributes.

### 3.2 Attributes Per Entry

| Attribute | Value | Notes |
|---|---|---|
| `kSecClass` | `kSecClassGenericPassword` | |
| `kSecAttrService` | `"cn.com.nadav.deepfinder.apikeys"` | Single service for all provider keys |
| `kSecAttrAccount` | Provider name: `"anthropic"`, `"deepseek"`, `"qwen"`, `"gemini"`, `"openai"`, `"zhipu"`, `"moonshot"`, `"minimax"`, `"custom"` | Matches `ProviderInfo.name` |
| `kSecAttrLabel` | `"DeepFinder API Key — {DisplayName}"` | Human-readable for Keychain Access UI |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` | Key available while user is logged in. Does NOT survive device passcode removal. |
| `kSecAttrSynchronizable` | `kCFBooleanFalse` | **Explicitly disable iCloud Keychain sync**. These keys are device-specific; syncing them to other Macs/iPhones is a security liability. |
| `kSecAttrAccessGroup` | *(omit)* | Not needed for single-app macOS CLI/daemon. Omit to use default. If the daemon and CLI need to share (same team ID), set to `"cn.com.nadav.deepfinder"` with Keychain Sharing entitlement. See §3.4. |
| `kSecValueData` | `apiKey.data(using: .utf8)!` | UTF-8 encoded key bytes |

### 3.3 Accessibility Level Rationale

`kSecAttrAccessibleWhenUnlocked` is the correct choice because:

- The daemon runs while the user is logged in and the keychain is unlocked
- If the screen locks, the daemon continues running but does not need API keys (no queries are being made)
- On first unlock after reboot, the keychain is available before the daemon starts
- This is the **default** for macOS keychain items and provides the right balance of security and usability

**Rejected alternatives**:

| Alternative | Why rejected |
|---|---|
| `kSecAttrAccessibleAlways` | Allows reading when device is locked — unnecessary and less secure |
| `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` | iOS-only concept; macOS does not enforce passcode |
| `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | The `ThisDeviceOnly` variants are relevant for iOS backups. On macOS with `kSecAttrSynchronizable = false`, this is already device-only. Adding `ThisDeviceOnly` is harmless but redundant. |
| `kSecAttrAccessibleAfterFirstUnlock` | Allows background daemon access while screen is locked. Not needed since daemon doesn't make API calls when user is absent. |

### 3.4 Access Group — CLI vs Daemon vs GUI App

DeepFinder has three executables:
- `deepfinder` (CLI) — bundle ID `cn.com.nadav.deepfinder.cli`
- `deepfinder-daemon` — bundle ID `cn.com.nadav.deepfinder.daemon`
- `DeepFinder.app` (GUI) — bundle ID `cn.com.nadav.deepfinder`

On macOS, **Keychain access groups require code signing with the same Team ID**. Since these are all distributed together under the same signing identity, they share access by default. If the team ID is consistent across all three binaries, the default access group works.

**If needed**: Add a shared access group `"cn.com.nadav.deepfinder"` and the Keychain Sharing entitlement to all three targets. This is handled automatically by Xcode when the capability is added.

For Homebrew/SPM distribution (no code signing), macOS grants keychain access per-binary based on the binary's path hash. Each executable gets its own keychain ACL entry. This is acceptable for CLI/daemon since they run in the same user session.

### 3.5 iCloud Sync — Disabled

`kSecAttrSynchronizable = false` (which is the default) ensures:

- API keys never leave the local device
- No key material transmitted to Apple's iCloud Keychain servers
- No risk of keys appearing on the user's iPhone/iPad/other Macs
- Consistent with the "device-specific secret" threat model

Users who want cross-device key sharing can manually copy their API key to each device. This is a deliberate security tradeoff — API keys are bearer tokens; spreading them across devices increases exposure surface.

---

## 4. Migration Strategy

### 4.1 Migration Trigger

Migration runs **on next daemon or CLI startup after upgrade**. Specifically:

1. Daemon starts → checks for `~/.deep-finder/.env.migrated` sentinel
2. If sentinel absent AND `~/.deep-finder/.env` exists → run migration
3. After migration → write sentinel + log success + delete old keys

### 4.2 Step-by-Step Migration Procedure

```
┌─────────────────────────────────────────────────────┐
│ Step 1: Read existing secrets from .env              │
│   SecretsStore.loadAll() → [String: String]          │
│   Expected keys: "ai.apiKey", "ai.customAPIKey",     │
│   provider-scoped keys if already per-provider       │
├─────────────────────────────────────────────────────┤
│ Step 2: Determine active provider                    │
│   AIConfig.modelName(config) → provider name         │
│   Also migrate keys for ALL known providers          │
│   (user may switch providers later)                  │
├─────────────────────────────────────────────────────┤
│ Step 3: Write each key to Keychain                   │
│   KeychainStore.save(account: "deepseek",            │
│                      key: "sk-...")                  │
│   Handle SecItemAdd returning errSecDuplicateItem     │
│   → use SecItemUpdate instead                        │
├─────────────────────────────────────────────────────┤
│ Step 4: Verify Keychain entries                      │
│   KeychainStore.load(account: "deepseek") → value    │
│   Assert each value matches original                 │
├─────────────────────────────────────────────────────┤
│ Step 5: Create backup of .env                        │
│   cp ~/.deep-finder/.env ~/.deep-finder/.env.backup  │
│   Set 600 permissions on backup                      │
├─────────────────────────────────────────────────────┤
│ Step 6: Write sentinel file                          │
│   touch ~/.deep-finder/.env.migrated                  │
│   Content: ISO 8601 timestamp + version              │
│   {"migrated_at": "2026-06-03T...",                   │
│    "version": "1.0",                                  │
│    "keys_migrated": ["anthropic","deepseek",...]}     │
├─────────────────────────────────────────────────────┤
│ Step 7: Strip API keys from config dict              │
│   Remove "ai.apiKey" and "ai.customAPIKey" from      │
│   ConfigStore / settings.json                        │
├─────────────────────────────────────────────────────┤
│ Step 8: Log migration completion                     │
│   OSLog: "Keychain migration complete: N keys        │
│   migrated for providers: [list]."                    │
└─────────────────────────────────────────────────────┘
```

### 4.3 Migration Edge Cases

| Scenario | Behavior |
|---|---|
| `.env.migrated` exists, `.env` has changed keys | Re-run migration (user manually edited `.env`). Update sentinel timestamp. |
| `.env` is empty (no keys configured) | Write sentinel, skip migration. No error. |
| `.env` is corrupt JSON | Log warning, attempt to parse as much as possible. Migrate recoverable keys. |
| Keychain write fails (errSecAuthFailed) | Log error, DO NOT delete `.env`. Notify user: "Keychain access denied. Run `deepfinder keychain diagnose`." |
| Keychain write fails (disk full) | Log error, DO NOT delete `.env`. Retry on next startup. |
| Migration interrupted mid-way | `.env` still intact (not deleted until step 5 backup verified). Sentinel not written → migration retries on next startup. Idempotent. |

### 4.4 Post-Migration Behavior

After migration, `AIConfig.getAPIKey()` should:

1. Check Keychain first → return key
2. If Keychain miss AND `.env` still exists → log warning "Plaintext keys found post-migration", return key, trigger re-migration
3. If Keychain miss AND no `.env` → return `""` (no key configured)

---

## 5. KeychainStore Implementation

### 5.1 What Exists Today

**`Sources/AI/SecretsStore.swift`** (the file-backed store, mischaracterized as "KeychainStore" in docs):
- Stores a flat `[String: String]` JSON dictionary at `Product.secretsPath` (`~/.deep-finder/.env`)
- API: `save(key:value:)`, `load(key:) -> String?`, `delete(key:) -> Bool`
- Atomic writes (temp file + rename), permissions 600
- `Sendable` struct, no actor isolation (callers must serialize)

**No `KeychainStore.swift` exists anywhere in the repository.**

### 5.2 New File: `Sources/AI/KeychainStore.swift`

Create a new `KeychainStore` actor that wraps the Keychain Services C API.

```swift
import Foundation
import Security
import OSLog

/// macOS Keychain-backed secure storage for API keys.
///
/// Each provider gets a separate Keychain entry under the shared service name.
/// Keys are stored as `kSecClassGenericPassword` items with:
/// - `kSecAttrAccessibleWhenUnlocked` — available while user is logged in
/// - `kSecAttrSynchronizable = false` — no iCloud sync
/// - UTF-8 encoded `kSecValueData`
///
/// Thread safety via actor isolation. All Keychain API calls are synchronous
/// (they complete in microseconds) so no async-await bridging is needed.
actor KeychainStore {

    // MARK: - Configuration

    /// Service name used as the primary lookup key for all DeepFinder API keys.
    /// MUST match the value used in the migration script.
    static let service = "cn.com.nadav.deepfinder.apikeys"

    private static let logger = Logger(subsystem: Product.loggingSubsystem, category: "keychain")

    // MARK: - Public API

    /// Save an API key for a provider account.
    ///
    /// If an existing entry for this account exists, it is updated in-place
    /// (SecItemUpdate). Otherwise, a new entry is created (SecItemAdd).
    ///
    /// - Parameters:
    ///   - account: Provider identifier matching `ProviderInfo.name` (e.g., "deepseek")
    ///   - key: The API key string
    ///   - label: Human-readable label for Keychain Access (e.g., "DeepSeek Cloud")
    /// - Throws: `KeychainStoreError` on Keychain API failure
    func save(account: String, key: String, label: String) throws { ... }

    /// Load an API key for a provider account.
    ///
    /// - Parameter account: Provider identifier (e.g., "deepseek")
    /// - Returns: The API key string, or `nil` if no key is stored
    func load(account: String) -> String? { ... }

    /// Delete an API key for a provider account.
    ///
    /// - Parameter account: Provider identifier
    /// - Returns: `true` if the key existed and was deleted
    @discardableResult
    func delete(account: String) -> Bool { ... }

    /// Check whether a key exists for a provider.
    func exists(account: String) -> Bool { ... }

    // MARK: - Migration Support

    /// List all account names stored in the Keychain for this service.
    func listAccounts() -> [String] { ... }

    /// Delete all DeepFinder entries (for use in `keychain reset` command).
    func deleteAll() throws { ... }
}
```

**Keychain Operations Detail**:

For `save(account:key:label:)`:
```
1. Build query dict:
   [kSecClass: kSecClassGenericPassword,
    kSecAttrService: "cn.com.nadav.deepfinder.apikeys",
    kSecAttrAccount: account,
    kSecAttrLabel: label,
    kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
    kSecAttrSynchronizable: false,
    kSecValueData: key.data(using: .utf8)!]

2. Call SecItemAdd(query, nil)
3. If errSecDuplicateItem:
     Build update dict:
       [kSecValueData: key.data(using: .utf8)!]
     Call SecItemUpdate(query, update)
```

For `load(account:) -> String?`:
```
1. Build query dict:
   [kSecClass: kSecClassGenericPassword,
    kSecAttrService: "cn.com.nadav.deepfinder.apikeys",
    kSecAttrAccount: account,
    kSecReturnData: true,
    kSecMatchLimit: kSecMatchLimitOne]

2. Call SecItemCopyMatching(query, &result)
3. Cast result to Data, convert to String
4. Return nil on errSecItemNotFound or any other error
```

### 5.3 Error Type

```swift
enum KeychainStoreError: Error, CustomStringConvertible {
    case saveFailed(account: String, status: OSStatus)
    case loadFailed(account: String, status: OSStatus)
    case deleteFailed(account: String, status: OSStatus)
    case unexpectedData(account: String)

    var description: String {
        switch self {
        case .saveFailed(let account, let status):
            return "Keychain save failed for '\(account)': OSStatus \(status)"
        case .loadFailed(let account, let status):
            return "Keychain load failed for '\(account)': OSStatus \(status)"
        case .deleteFailed(let account, let status):
            return "Keychain delete failed for '\(account)': OSStatus \(status)"
        case .unexpectedData(let account):
            return "Keychain returned unexpected data type for '\(account)'"
        }
    }
}
```

### 5.4 Provider-Scoped Key Management

Currently, the `ai.apiKey` config key stores a single API key. Post-migration:

- **One key per provider**: Each provider account stores its own key
- **AIConfig changes**: `getAPIKey(provider:)` looks up by provider account name
- **CLI config command**: `deepfinder config set ai.apiKey sk-...` writes to both Keychain (for current provider) AND updates secrets
- **Multi-provider config**: User can store keys for multiple providers simultaneously, switching between them without re-entering keys

**Provider account names** (match `ProviderInfo.name`):

| Provider | Account name |
|---|---|
| Qwen | `qwen` |
| 智谱 GLM | `zhipu` |
| DeepSeek | `deepseek` |
| OpenAI | `openai` |
| Moonshot Kimi | `moonshot` |
| MiniMax | `minimax` |
| Claude (Anthropic) | `anthropic` |
| Google Gemini | `gemini` |
| Custom | `custom` |

### 5.5 AIConfig Changes

`AIConfig.getAPIKey()` becomes provider-aware:

```swift
static func getAPIKey(
    for provider: String,
    config: [String: String],
    keychainStore: KeychainStore = KeychainStore(),
    onPlaintextCleanup: ((String) -> Void)? = nil
) -> String {
    // 1. Try Keychain first
    if let key = await keychainStore.load(account: provider), !key.isEmpty {
        // Clean up any stale plaintext
        if config["ai.apiKey"] != nil {
            onPlaintextCleanup?("ai.apiKey")
        }
        return key
    }
    // 2. Fall back to SecretsStore (legacy, pre-migration)
    //    This path is removed once migration is complete in v3.2+
    // ...
}
```

### 5.6 ProviderRegistry Changes

`ProviderRegistry.instantiate(model:apiKey:...)` currently takes `apiKey: String`. This changes to accept `apiKey: String?` — providers that receive `nil` try to load from Keychain internally.

**Alternative (preferred)**: Keep `apiKey` as a required parameter but have the caller (daemon startup / CLIMain) use `KeychainStore` to resolve it before calling `instantiate`. This avoids threading Keychain dependency into the provider layer.

---

## 6. Privacy Model Documentation Fix

### 6.1 Changes to `docs/explanation/privacy-model.md`

**Line 15** — change:
```
| Configuration | `~/.deep-finder/settings.json` (permissions 600) | API keys encrypted in Keychain |
```
to:
```
| Configuration | `~/.deep-finder/settings.json` (permissions 600) | API keys stored in macOS Keychain (encrypted, hardware-backed). Never in plaintext files. |
```

**Line 67-71** — change:
```
| `~/.deep-finder/settings.json` | Configuration (API keys in Keychain, not plaintext) | 600 (owner only) |
...
| `~/Library/Keychains/` | API keys (stored via `KeychainStore`) | System-managed |
```
to:
```
| `~/.deep-finder/settings.json` | Configuration (no API keys stored here) | 600 (owner only) |
...
| `~/Library/Keychains/login.keychain-db` | API keys stored via `SecItemAdd`/`SecItemCopyMatching` (Keychain Services) under service `cn.com.nadav.deepfinder.apikeys` | System-managed, encrypted with Secure Enclave |
```

**Add new section** after "Data Storage":

```markdown
## API Key Storage

DeepFinder stores API keys exclusively in the macOS Keychain, never in plaintext files.

| Property | Value |
|---|---|
| Keychain service | `cn.com.nadav.deepfinder.apikeys` |
| Item class | Generic Password (`kSecClassGenericPassword`) |
| Accessibility | `kSecAttrAccessibleWhenUnlocked` (available while logged in) |
| iCloud sync | **Disabled** — keys are device-specific, never leave the Mac |
| Encryption | AES-256-GCM via Secure Enclave hardware key |

To verify: open Keychain Access.app, search for "DeepFinder".
To delete all keys: `deepfinder config keychain reset`
```

### 6.2 Documentation Review Checklist

- [ ] Remove all references to `KeychainStore` as an existing file (it does not exist)
- [ ] Remove all claims that "API keys are in Keychain" from any current-tense statements
- [ ] Add "as of v3.2" version note to new Keychain storage section
- [ ] Verify no other docs reference `.env` as the key storage location
- [ ] Update `docs/superpowers/USER_JOURNEY.md` if it mentions API key storage
- [ ] Update `docs/SUPPORT.md` if it has troubleshooting for API keys

---

## 7. Testing Strategy

### 7.1 KeychainStore Unit Tests

File: `Tests/AITests/KeychainStoreTests.swift`

```swift
// Test methods:
testSaveAndLoadKey()         // Write key, read back, assert match
testOverwriteExistingKey()   // Save twice, second overwrites first
testLoadNonexistentKey()     // Returns nil
testDeleteKey()              // Delete existing, confirm gone
testDeleteNonexistentKey()   // Delete non-existent, returns false
testExists()                 // Exists returns true/false correctly
testListAccounts()           // List returns all saved accounts
testDeleteAll()              // Clears all entries
testConcurrentAccess()       // Multiple tasks reading same account
testUTF8KeyStorage()         // Keys with non-ASCII chars
testEmptyKeyStorage()        // Empty string key behavior
testVeryLongKeyStorage()     // 10KB+ API key (some providers)
testSpecialCharacters()      // Keys with quotes, backslashes, newlines
```

### 7.2 Keychain in CI

Keychain tests require a keychain that exists. In CI (GitHub Actions macOS runner):

1. **Create a test-specific keychain**:
   ```bash
   security create-keychain -p testpassword swift-test.keychain
   security default-keychain -s swift-test.keychain
   security unlock-keychain -p testpassword swift-test.keychain
   ```

2. **Set timeout**: `security set-keychain-settings -t 3600 swift-test.keychain` (prevents auto-lock during test run)

3. **Teardown**: `security delete-keychain swift-test.keychain`

4. **Swift test invocation**:
   ```bash
   swift test --filter KeychainStoreTests
   ```

5. **CI Detection**: `KeychainStore` should detect CI via `ProcessInfo.processInfo.environment["CI"]` and log a diagnostic message. In CI, tests use the temporary keychain without prompting.

### 7.3 Migration Script Tests

File: `Tests/AITests/KeychainMigrationTests.swift`

| Test | Scenario |
|---|---|
| `testMigrationFromCleanEnv` | `.env` with 3 provider keys, no prior Keychain entries, no sentinel |
| `testMigrationIdempotent` | Run migration twice — second run is no-op (sentinel exists) |
| `testMigrationWithExistingKeychainEntries` | Some keys already in Keychain, `.env` has additional keys |
| `testMigrationEmptyEnv` | `.env` exists but has no API keys |
| `testMigrationNoEnvFile` | No `.env` file exists (fresh install) |
| `testMigrationCorruptEnv` | `.env` is malformed JSON |
| `testMigrationKeychainWriteFailure` | Simulate Keychain error (mock with protocol) |
| `testMigrationBackupCreated` | `.env.backup` exists with correct content after migration |
| `testMigrationSentinelWritten` | `.env.migrated` contains correct JSON |
| `testMigrationConfigStripped` | `ai.apiKey` removed from settings.json |

### 7.4 Integration Tests

| Test | What it validates |
|---|---|
| `testEndToEndKeyFlow` | CLI `config set ai.apiKey sk-...` → persists in Keychain → `config get ai.apiKey` returns key → provider instantiation succeeds |
| `testProviderSwitchPreservesKeys` | Set key for deepseek → switch to qwen → switch back to deepseek → key still available |
| `testKeychainReset` | `deepfinder config keychain reset` → all keys deleted → get returns empty |

### 7.5 Manual Testing Checklist

- [ ] Keychain Access.app shows DeepFinder entries under "All Items"
- [ ] Each entry shows correct "Account" and "Where" (service name)
- [ ] Access Control tab shows application path
- [ ] `security find-generic-password -s "cn.com.nadav.deepfinder.apikeys"` returns entries
- [ ] After `keychain reset`, entries are gone
- [ ] `.env` file deleted or renamed to `.env.backup` after migration
- [ ] `.env.migrated` sentinel file present

---

## 8. Rollback Plan

### 8.1 If Keychain Access Fails at Runtime

If `KeychainStore.load()` fails (e.g., keychain locked, permission denied):

1. **Log the error** via OSLog at `.error` level
2. **Fall back to SecretsStore** (if `.env` still exists and has keys)
3. **Notify user**: CLI displays `⚠ Keychain unavailable; using fallback storage. Run deepfinder keychain diagnose.`
4. **Do NOT crash** — treat as degraded mode

### 8.2 CLI Diagnostic Command

Add `deepfinder config keychain diagnose` command that:

1. Tests Keychain write (temporary test entry)
2. Tests Keychain read (verify the test entry)
3. Tests Keychain delete (clean up test entry)
4. Reports: "Keychain: OK" or "Keychain: <error details>"
5. Checks `.env` existence and warns if plaintext keys found post-migration

### 8.3 Manual Recovery Procedure

If Keychain is permanently broken (corrupt keychain, OS migration issue):

```bash
# 1. Restore from backup
cp ~/.deep-finder/.env.backup ~/.deep-finder/.env

# 2. Delete sentinel to trigger re-migration on next fix
rm ~/.deep-finder/.env.migrated

# 3. Fix Keychain (outside app scope)
#    - Keychain Access → Keychain First Aid
#    - Or: security delete-keychain ~/Library/Keychains/login.keychain-db
#      (WARNING: deletes ALL saved passwords, not just DeepFinder)

# 4. Restart daemon to retry migration
deepfinder daemon restart
```

### 8.4 Rollback Decision Matrix

| Failure mode | Action |
|---|---|
| Keychain write fails during migration | Keep `.env`, log error, skip migration. Sentinel NOT written. |
| Keychain read fails at runtime | Graceful degradation: try SecretsStore fallback, log warning |
| `.env` deleted but Keychain also unavailable | User must re-enter keys. CLI: `deepfinder config set ai.apiKey sk-...` |
| Keychain corrupt (OS-level) | User fixes via Keychain Access First Aid, then re-runs migration |

---

## 9. Implementation Plan

### 9.1 Sequence

| Phase | Owner | Tasks | Estimate |
|---|---|---|---|
| **Phase 1: KeychainStore** | `macos-dev` | Create `KeychainStore.swift` + `KeychainStoreTests.swift` with full unit test suite | 1 session |
| **Phase 2: AIConfig refactor** | `ai-dev` | Update `getAPIKey`/`saveAPIKey` to use KeychainStore. Add provider-scoped lookup. | 1 session |
| **Phase 3: Migration script** | `macos-dev` | Implement migration logic in daemon startup. Handle all edge cases from §4.3. | 1 session |
| **Phase 4: ProviderRegistry** | `ai-dev` | Update `instantiate` to accept key from Keychain. Handle `nil` key gracefully. | 0.5 session |
| **Phase 5: Privacy doc fix** | `architect` | Update `privacy-model.md` per §6. Add new API Key Storage section. | 0.5 session |
| **Phase 6: Integration tests** | `qa-dev` | End-to-end tests: config → keychain → provider → API call. Migration scenario tests. | 1 session |
| **Phase 7: Code review** | `architect` | Security-focused code review. Verify: no plaintext logging, no key leaks in errors, memory handling. | 0.5 session |

### 9.2 Total: ~5.5 sessions

### 9.3 Rollout

- **v3.1.x**: Merge KeychainStore + migration + doc fix
- **v3.2.0**: Remove SecretsStore fallback path (once migration has been in the wild for one version)
- **v3.3.0**: Remove SecretsStore entirely, delete `.env` reading code path

---

## 10. Alternative Considered

### Secure Enclave (rejected for this use case)

The Secure Enclave is designed for **cryptographic key generation and signing** (ECC keys, not arbitrary data). It cannot store arbitrary byte sequences like API keys.

**Correct architecture**: Keychain stores the API key encrypted with a key that is itself protected by the Secure Enclave. This is what the macOS Keychain does automatically — we get Secure Enclave protection without calling it directly.

### Environment Variables (rejected)

`export DEEPSEEK_API_KEY=sk-...` in shell profile:
- Visible to all child processes
- Leaked via `ps aux` on some systems
- Not persisted securely
- Not Mac-native

### FileVault-only (current state, rejected)

Relying solely on FileVault full-disk encryption:
- No protection while user is logged in (all processes can read)
- No per-application access control
- Backup leakage remains

---

## Appendix A: Keychain Services C API Reference

```c
// Add
OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result);

// Read
OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result);

// Update
OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate);

// Delete
OSStatus SecItemDelete(CFDictionaryRef query);
```

Key constants: `kSecClass`, `kSecClassGenericPassword`, `kSecAttrService`, `kSecAttrAccount`, `kSecAttrLabel`, `kSecAttrAccessible`, `kSecAttrAccessibleWhenUnlocked`, `kSecAttrSynchronizable`, `kSecValueData`, `kSecReturnData`, `kSecMatchLimit`, `kSecMatchLimitOne`.

Error codes: `errSecSuccess` (0), `errSecItemNotFound` (-25300), `errSecDuplicateItem` (-25299), `errSecAuthFailed` (-25293), `errSecInteractionNotAllowed` (-25308).

## Appendix B: File Manifest

| File | Action | Description |
|---|---|---|
| `Sources/AI/KeychainStore.swift` | **CREATE** | New Keychain-backed secure storage actor |
| `Sources/AI/AIConfig.swift` | MODIFY | `getAPIKey(provider:)` reads from Keychain first |
| `Sources/AI/SecretsStore.swift` | MODIFY (later: REMOVE) | Deprecate in v3.2, remove in v3.3 |
| `Sources/AI/ProviderRegistry.swift` | MODIFY | Accept optional key, resolve from Keychain |
| `Sources/Index/ProductConfig.swift` | MODIFY | Add `keychainService` constant |
| `Sources/CLI/ConfigCommands.swift` | MODIFY | Add `keychain diagnose` and `keychain reset` commands |
| `Sources/Daemon/DaemonMain.swift` | MODIFY | Call migration on startup |
| `docs/explanation/privacy-model.md` | MODIFY | Fix false claims, add Keychain section |
| `Tests/AITests/KeychainStoreTests.swift` | **CREATE** | Unit tests |
| `Tests/AITests/KeychainMigrationTests.swift` | **CREATE** | Migration scenario tests |
| `Tests/AITests/AIConfigTests.swift` | MODIFY | Update for Keychain-backed config |
