---
name: oss-release-checklist
description: Pre-release checklist for OSS publication — license headers, docs, security, CI verification
---

# OSS Release Checklist

Run this checklist before publishing DeepFinder as open source.

## Steps

1. **License Headers**: Verify all `.swift` files under `Sources/` have the correct license header
   ```bash
   find Sources -name "*.swift" -exec head -5 {} \; | grep -c "LICENSE"
   ```

2. **Required Files**:
   - [ ] `LICENSE` — MIT or chosen license file exists at repo root
   - [ ] `CONTRIBUTING.md` — contribution guidelines
   - [ ] `CODE_OF_CONDUCT.md` — community standards
   - [ ] `SECURITY.md` — vulnerability reporting process
   - [ ] `README.md` — build instructions, usage, screenshots

3. **Secret Scan**: No hardcoded API keys, tokens, or credentials
   ```bash
   grep -rn "sk-\|api_key\|secret\|token\|password" Sources/ --include="*.swift"
   ```

4. **CI Verification**: Clean clone build + test passes
   ```bash
   swift build && swift test
   ```

5. **API Documentation Coverage**: Public types and functions have doc comments
   ```bash
   # Count public declarations without /// doc comments
   ```

6. **Security Review**: Run `/code-review` with security focus, or invoke `swift-security-reviewer` agent

7. **Homebrew Formula**: Verify `Formula/deepfinder.rb` mirrors latest version and SHA

8. **VERSION file**: Matches the tag being released

9. **Changelog**: `CHANGELOG.md` updated with version, date, and changes

10. **Git Tag**: Tag follows semver (`vX.Y.Z`), signed if possible
