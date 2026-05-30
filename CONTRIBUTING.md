# Contributing to DeepFinder

Thank you for your interest in contributing to DeepFinder. This document covers the development setup, workflow, and conventions used in this project.

## Development Setup

### Prerequisites

- macOS 26 (Tahoe) or later
- Xcode 26+ with Swift 6.2+ toolchain
- Apple Silicon M4+ hardware

### Build and Test

```bash
# Clone the repository
git clone https://github.com/nadav/deep-finder.git
cd deep-finder

# Build all targets
swift build

# Run all tests
swift test

# Run a specific test suite
swift test --filter TrieTests

# Run a single test by name
swift test --filter testInsertIncreasesCount

# Build in release mode
swift build -c release
```

### Project Structure

```
Sources/
  Index/          # Core data structures: FileRecord, Trie, FullSubstringMap, etc.
  Search/         # Query parsing, filtering, sorting, provider orchestration
  FS/             # Filesystem scanning, FSEvent monitoring, volume management
  Persist/        # SQLite persistence layer
  Daemon/         # Background daemon: IPC server, config, lifecycle
  CLI/            # Command-line interface: REPL, single-shot, terminal formatting
  GUI/            # SwiftUI search panel, global hotkey, settings
  Media/          # Media metadata extraction (image, audio, video, PDF)
  Services/       # HTTP API, URL schemes, AppleScript integration
  AI/             # AI features: NLP translation, vision, speech, providers
Tests/
  DeepFinderTests/  # Unit and integration tests
docs/
  superpowers/specs/  # Design specifications and requirements
```

## Development Workflow

### Spec-First

All changes begin with the specification in `docs/superpowers/specs/`. Before writing any code:

1. Update or create the relevant spec file
2. Review the spec for consistency with the overall architecture
3. Get spec approval before implementing

Never implement behavior that isn't reflected in the spec, and never leave a spec out of sync with the implementation.

### Test-Driven Development (TDD)

**Write tests before implementation.** For every new component:

1. **Write a failing test** -- Define expected behavior including interface, boundary conditions, and error paths
2. **Implement minimum code** -- Make the test pass with the simplest correct implementation
3. **Refactor** -- Clean up while keeping all tests green

Requirements:
- Every new `struct`/`class`/`actor`/`enum` must have a corresponding test file
- Test names describe behavior: `testInsertIncreasesCount`, not `testTrie1`
- Tests must cover: normal path + boundary conditions + error paths
- Performance-sensitive components (Trie, FullSubstringMap, etc.) must include `measure` block benchmarks

### Feature Cycle

Complete small features incrementally. A "small feature" is a single independently testable unit:

```
spec update -> write failing test -> implement -> tests green -> code review -> fix review issues -> commit
```

Trigger code review after:
- Creating a new file
- Changing existing file behavior
- Completing a requirement item
- Never wait until the end of a version to review

### Branching

- Each version develops on its `dev/vX.Y` branch
- When deliverables pass all tests and review, merge to `main` and tag `vX.Y.Z`
- Next version branches from `main`

## Code Style

### Swift Conventions

- Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Use `///` doc comments on all public types, properties, and methods
- Use `// MARK: - Section Name` to organize code within files
- Prefer Swift concurrency (`actor`, `async`/`await`) over GCD for new code
- Use value types (structs) by default; use classes only when identity or reference semantics are needed
- Use actors for shared mutable state

### Naming

- Types: `UpperCamelCase` (`InMemoryIndex`, `SearchCoordinator`)
- Functions and properties: `lowerCamelCase` (`search(query:)`, `fileCount`)
- Test functions: `test` prefix + descriptive name (`testSearchReturnsEmptyForEmptyQuery`)
- Files: one primary type per file, named to match (`InMemoryIndex.swift`, `Trie.swift`)

### Documentation

- Add `///` doc comments to all public APIs following Apple Swift documentation patterns
- Document protocol requirements, enum cases, and actor public methods
- Module-level doc comments at the top of each module's main file describe the module's purpose, components, and data flow
- Document *why*, not *what* -- explain constraints, tradeoffs, and architectural reasoning

### Concurrency

- `InMemoryIndex`: actor -- all read/write via actor isolation
- `IndexingEngine`: actor -- coordinates FileScanner + FSEventWatcher
- `SearchCoordinator`: plain actor (NOT `@MainActor`) -- works in both daemon and GUI contexts
- All cross-actor calls use `await`; never force-unlock or bypass actor isolation

### Error Handling

- Use typed errors (enums conforming to `Error`) rather than generic `NSError`
- Provide `CustomStringConvertible` conformance for all error types
- Handle realistic failures; don't over-defend against impossible states

### Unicode

- All filenames are NFC-normalized on ingestion via `precomposedStringWithCanonicalMapping`
- Queries are normalized the same way for consistent matching
- Case-insensitive by default; preserve original case for display

### Zero External Dependencies

This project uses only Swift stdlib and Apple frameworks (Foundation, CoreServices, Carbon, SQLite3, SwiftUI, AppKit, Vision, Speech, PDFKit, AVFoundation, ImageIO, Network). Do not add third-party package dependencies.

## Pull Request Process

### Before Submitting

1. All tests pass: `swift test`
2. New code has corresponding tests
3. Public APIs have `///` doc comments
4. Spec files are updated if behavior changed
5. No unrelated refactoring mixed with the feature change
6. Commit messages are descriptive and reference the relevant spec item

### PR Description

Include:
- What changed and why
- Which spec requirement this addresses
- Test coverage summary
- Any manual verification performed

### Review Criteria

Reviewers evaluate:
- **Correctness**: Does it fully satisfy the requirement? Edge cases covered?
- **Simplicity**: Is this the minimum sufficient solution? Can abstractions be removed?
- **Maintainability**: Will this be understandable in 6 months?
- **Consistency**: Does it match project conventions and architecture?
- **Performance**: Unnecessary allocations? Duplicate work?
- **Security**: Injection risks? Trust boundary violations?

## Getting Help

- Check `docs/superpowers/specs/` for architecture and design documentation
- Read the module-level doc comments at the top of each source file
- Review the test files for usage examples
- Open an issue for bugs or feature requests
