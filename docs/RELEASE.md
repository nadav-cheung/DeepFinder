# Release Process

This document describes the end-to-end release process for DeepFinder --
from version bump through CI build, code-signing, notarization, and
distribution on GitHub Releases.

## Overview

```
Version bump  -->  Git tag  -->  CI build  -->  Codesign  -->  Notarize  -->  Staple  -->  GitHub Release
   (local)         (local)      (GitHub)        (CI)          (CI)         (CI)         (CI / local)
```

Each release is triggered by pushing a version tag (`vX.Y.Z`) to the
`main` branch. The `.github/workflows/release.yml` workflow builds both
binaries in release configuration, code-signs and notarizes them (when
Apple Developer credentials are configured), and publishes the artifacts
as a GitHub Release.

---

## Prerequisites

### Apple Developer Program

Required for notarization. Enroll at
[developer.apple.com/programs](https://developer.apple.com/programs)
($99/year).

### Signing Certificate

Create a **Developer ID Application** certificate:

1. Open Xcode > Settings > Accounts > Manage Certificates
2. Click "+" > Developer ID Application
3. Export the certificate as a `.p12` file (include the private key):
   ```bash
   security find-identity -v -p basic | grep "Developer ID Application"
   security export -k login.keychain -t certs -f pkcs12 \
     -o developer_id.p12 \
     -P "export-password" \
     "<SHA-1 hash from find-identity>"
   ```
4. Base64-encode for the GitHub secret:
   ```bash
   base64 -i developer_id.p12
   ```

### App Store Connect API Key

Used by `notarytool` to authenticate with Apple's notary service:

1. Go to [App Store Connect > Users and Access > Integrations > API Keys](https://appstoreconnect.apple.com/access/integrations/api)
2. Click "+" to create a new key
3. Select **Developer** as the role
4. Download the `.p8` private key file (you cannot re-download it)
5. Note the **Issuer ID** (UUID at the top of the API Keys page) and
   **Key ID** (10-character alphanumeric identifier next to the key name)

### GitHub Secrets

Store these in the repository: Settings > Secrets and variables > Actions.

| Secret | Description |
|--------|-------------|
| `APPLE_DEVELOPER_ID_CERT` | Base64-encoded `.p12` file (cert + private key) |
| `APPLE_DEVELOPER_ID_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API Issuer ID (UUID) |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API Key ID (10-char alphanumeric) |
| `APPLE_NOTARY_PRIVATE_KEY` | Full `.p8` private key contents (including BEGIN/END lines) |
| `APPLE_TEAM_ID` | Apple Developer Team ID (required only for multi-team accounts) |

---

## Step-by-Step Release Process

### 1. Pre-Release Checklist

- [ ] All tests pass: `swift test`
- [ ] `VERSION` file contains the correct version number
- [ ] `docs/releases/vX.Y.Z.md` release checkpoint exists (see existing
  checkpoints for format)
- [ ] All changes are merged to `main`
- [ ] CI is green on `main`

### 2. Version Bump

Update the `VERSION` file at the repository root:

```bash
echo "X.Y.Z" > VERSION
git add VERSION
git commit -m "chore: bump version to X.Y.Z"
git push origin main
```

The `VERSION` file contains a single line with the version number, e.g.
`3.0.0`. It uses plain SemVer (no `v` prefix).

### 3. Create and Push the Tag

Tags trigger the release workflow. The tag MUST start with `v` (the CI
workflow triggers on `v*`):

```bash
git tag -a vX.Y.Z -m "DeepFinder vX.Y.Z"
git push origin vX.Y.Z
```

Use an annotated tag (`-a`) so the tag message appears in the release
notes.

### 4. CI Build (Automated)

Pushing the tag triggers `.github/workflows/release.yml`, which:

1. Checks out the repository at the tag
2. Builds both binaries in release configuration:
   - `swift build -c release --product deepfinder`
   - `swift build -c release --product deepfinder-daemon`
3. Creates distribution archives (zip) for each binary
4. Generates SHA256 checksums for all artifacts
5. **If notarization is enabled** (see section 5):
   - Imports the signing certificate into a temporary keychain
   - Code-signs both binaries with hardened runtime
   - Submits both binaries to Apple's notary service
   - Staples the notarization ticket to the binaries
   - Re-packages the signed and stapled binaries into zip archives
   - Re-generates checksums for the signed artifacts
6. Creates a GitHub Release with the artifacts attached

### 5. Enabling Notarization in CI

The notarization step is disabled by default (`if: false` in the
workflow). To enable it after configuring all Apple Developer secrets:

Edit `.github/workflows/release.yml` and change:
```yaml
if: false  # Set to `true` after configuring Apple Developer secrets
```
to:
```yaml
if: true
```

Commit this change to `main` before pushing the release tag:
```bash
git add .github/workflows/release.yml
git commit -m "ci: enable notarization for release workflow"
git push origin main
```

### 6. Manual Notarization (Alternative)

If you prefer to sign and notarize locally instead of in CI, follow
these steps after downloading the CI-built artifacts:

#### 6a. Code-sign the binaries

```bash
# Import your Developer ID certificate if not already in the keychain
security unlock-keychain ~/Library/Keychains/login.keychain-db

# Daemon (requires entitlements)
codesign --force --options runtime --timestamp \
  --entitlements packaging/entitlements/deepfinder-daemon.plist \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  deepfinder-daemon

# CLI (hardened runtime, no special entitlements)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  deepfinder
```

#### 6b. Verify the signature

```bash
codesign --verify --verbose deepfinder
codesign --verify --verbose deepfinder-daemon
```

#### 6c. Package for notarization

```bash
ditto -c -k --keepParent deepfinder deepfinder.zip
ditto -c -k --keepParent deepfinder-daemon deepfinder-daemon.zip
```

#### 6d. Submit to notary service

```bash
xcrun notarytool submit deepfinder.zip \
  --issuer "YOUR_ISSUER_ID" \
  --key-id "YOUR_KEY_ID" \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 \
  --wait --timeout 30m

xcrun notarytool submit deepfinder-daemon.zip \
  --issuer "YOUR_ISSUER_ID" \
  --key-id "YOUR_KEY_ID" \
  --key /path/to/AuthKey_XXXXXXXXXX.p8 \
  --wait --timeout 30m
```

#### 6e. Check notarization status

```bash
xcrun notarytool info SUBMISSION_UUID \
  --issuer "YOUR_ISSUER_ID" \
  --key-id "YOUR_KEY_ID" \
  --key /path/to/AuthKey_XXXXXXXXXX.p8
```

The submission UUID is printed by `notarytool submit`. Look for
`status: Accepted`.

#### 6f. Staple the notarization ticket

Stapling embeds the notarization ticket into the binary so Gatekeeper
can verify it offline:

```bash
xcrun stapler staple deepfinder
xcrun stapler staple deepfinder-daemon
```

Verify the staple:
```bash
xcrun stapler validate deepfinder
xcrun stapler validate deepfinder-daemon
```

#### 6g. Verify Gatekeeper acceptance

```bash
spctl --assess --verbose --type execute deepfinder
spctl --assess --verbose --type execute deepfinder-daemon
```

Output should include `accepted` and `source=Notarized Developer ID`.

#### 6h. Re-build distribution archives with stapled binaries

```bash
ditto -c -k --keepParent deepfinder deepfinder.zip
ditto -c -k --keepParent deepfinder-daemon deepfinder-daemon.zip
```

#### 6i. Upload to GitHub Release

Upload the signed, notarized, and stapled zip archives to the GitHub
Release created by CI. You can drag-and-drop into the release page, or
use `gh`:
```bash
gh release upload vX.Y.Z \
  deepfinder.zip \
  deepfinder-daemon.zip
```

### 7. Verify the Release

After the release is published:

- [ ] Download both zip archives from the Releases page
- [ ] Verify checksums:
  ```bash
  shasum -a 256 -c deepfinder.zip.sha256
  shasum -a 256 -c deepfinder-daemon.zip.sha256
  ```
- [ ] Unzip and run the CLI: `./deepfinder --version`
- [ ] If notarized, verify Gatekeeper does not block execution:
  ```bash
  spctl --assess --verbose --type execute ./deepfinder
  ```
- [ ] Check the release notes are generated correctly
- [ ] Update the Homebrew formula in `packaging/homebrew/` with new
  checksums (see Homebrew packaging docs)

---

## Entitlements

### Daemon (`packaging/entitlements/deepfinder-daemon.plist`)

The daemon requires the **Hardened Runtime** with
`com.apple.security.cs.disable-library-validation` because Swift runtime
libraries bundled alongside the binary are not signed by the same
Developer ID certificate. This entitlement is the only one needed --
sandbox entitlements are NOT applicable because the daemon requires Full
Disk Access to index the entire filesystem.

### CLI

The CLI binary uses hardened runtime (`--options runtime`) without
additional entitlements. It does not need `disable-library-validation`
because the CLI links against system Swift libraries.

---

## CI Workflow Architecture

```
┌────────────────────────────────────────────────┐
│  git push origin vX.Y.Z                        │
│       │                                         │
│       ▼                                         │
│  .github/workflows/release.yml                 │
│       │                                         │
│       ├── checkout@v4                           │
│       ├── swift build -c release (CLI)          │
│       ├── swift build -c release (Daemon)       │
│       ├── ditto zip archives                    │
│       ├── shasum checksums                      │
│       ├── [codesign + notarize + staple]  ◄──  │
│       │   ↑ disabled by default                 │
│       │   ↑ enable after Apple secrets set      │
│       └── softprops/action-gh-release@v2        │
│            uploads: .zip + .sha256              │
└────────────────────────────────────────────────┘
```

---

## Troubleshooting

### "Swift is not a valid member of the platform 'macOS'"

The runner must be macOS 26 (Tahoe) with Xcode 26+ and swift-tools-version
>= 6.2. GitHub-hosted `macos-26` runners may not be available yet. Use a
self-hosted runner labeled `macos-26`.

### "The binary is not signed"

The notarization step is disabled by default. Downloaders on macOS will
see a Gatekeeper warning. This is expected for unsigned binaries. Users
can bypass with right-click > Open, or the release can be signed and
notarized.

### "Unable to find application 'deepfinder.zip'"

Notarytool requires a `.zip`, `.dmg`, or `.pkg`. The zip must be created
with `ditto -c -k --keepParent` (not `zip`), as `ditto` preserves
resource forks and extended attributes.

### "The staple couldn't be found"

Ensure the binary was successfully notarized before stapling. Check
status with `notarytool info`. If the notarization status is
`In Progress`, wait and retry.

### "package has no bundle identifier"

Add `--bundle-id "cn.com.nadav.deepfinder"` to the `notarytool submit`
command if Apple requires an explicit bundle identifier.

### Certificate not found in temporary keychain

The CI keychain setup must include `security set-key-partition-list` to
allow `codesign` to access the private key without a GUI prompt. Verify
the `.p12` export includes the private key (not just the certificate).

### Checksum mismatch after manual re-signing

When binaries are re-signed locally, the checksums change. Upload new
checksum files or update the release artifacts. The CI-generated
checksums only apply to CI-signed binaries.

---

## References

- [Apple Developer: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple Developer: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [notarytool man page](https://www.unix.com/man-page/mojave/1/notarytool/)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
