# ADR-004: AI Privacy Boundary (FileMetadataSummary vs Raw File Content)

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

DeepFinder v3.0 introduces AI-powered semantic search, query suggestions, and content understanding. These features require sending data to AI providers (local CoreML models and/or cloud APIs). This creates a privacy boundary: what data crosses from the user's local filesystem into AI processing?

The naive approach -- sending raw file content to AI models -- presents severe risks:

1. **Personal data leakage.** File contents may contain passwords, financial data, private correspondence, legal documents, health information, and source code under NDA.
2. **macOS username exposure.** File paths like `/Users/nadav/Documents/tax-2025.pdf` leak the user's macOS account name, which is often their real name.
3. **Volume and cost.** Sending full file content to cloud AI providers incurs token costs proportional to file size. A 10MB log file would cost thousands of tokens.
4. **Regulatory risk.** GDPR, HIPAA, and other frameworks impose strict controls on personal data processing. Sending raw file content to third-party APIs without explicit user consent is legally risky.

## Decision

**Enforce a strict privacy boundary: only `FileMetadataSummary` crosses into AI processing.**

`FileMetadataSummary` (`Sources/AI/FileMetadataSummary.swift`) is the sole data type that passes from the DeepFinder search engine to AI providers. It contains:

| Field         | Type      | Source                  |
|---------------|-----------|-------------------------|
| `name`        | String    | Filename (e.g., "report.pdf") |
| `path`        | String    | File path, optionally anonymized |
| `size`        | Int64     | File size in bytes      |
| `modifiedAt`  | Date      | Last modification date  |
| `extension`   | String?   | File extension (e.g., "pdf") |
| `localTags`   | [String]  | Locally-generated tags (Vision framework labels, user tags) |

**What is explicitly excluded:**
- Raw file content (no text, no binary, no thumbnails)
- File contents hashes (could be used to fingerprint known files)
- Extended attributes or xattr metadata
- Full, non-anonymized paths (by default)

**Path anonymization** (`anonymizePaths: true` by default, controlled by `ai.pathAnonymization` config):
- `/Users/nadav/Documents/report.pdf` becomes `~/Documents/report.pdf`
- Paths outside `/Users/` (e.g., `/Applications/`, `/System/`) are left as-is since they contain no PII

The `FileMetadataSummary.from(_:tags:anonymizePaths:)` factory method is the only constructor. Direct initialization is possible (the struct has a memberwise init) but the doc comment and code review enforce using the factory.

**AI features built on this boundary:**
- `MatchExplainer` — explains why a search result matched a query (uses filename + extension + tags, never content)
- `QuerySuggester` — suggests related queries based on indexed metadata patterns
- `VisionTaggingCoordinator` — runs Vision framework locally (on-device, no cloud) to generate `localTags`, then stores tags in `FileMetadataSummary`. The Vision analysis runs on thumbnails/QuickLook previews locally; raw images never leave the device.

## Consequences

**Positive:**

- **Strong privacy guarantee.** No file content ever leaves the user's machine via DeepFinder's AI pipeline. The privacy boundary is enforced at the type system level (only `FileMetadataSummary` is `Codable` and `Sendable` in the AI module).
- **Predictable cost.** AI API costs are bounded by metadata size (~200 bytes per file), not file content size (potentially gigabytes).
- **Regulatory compliance by design.** GDPR's data minimization principle is satisfied: only metadata necessary for search summarization is processed.
- **User control.** The `ai.pathAnonymization` config flag lets users choose their own privacy/utility tradeoff.

**Negative:**

- **Reduced AI capability.** Without file content, semantic search cannot understand document topics, code semantics, or image content beyond Vision-generated tags. A file named `notes.txt` containing Python code is indexed as "notes.txt" with no knowledge of its content.
- **Vision dependency.** Image understanding relies entirely on on-device Vision framework labels, which are less rich than cloud vision APIs (e.g., "dog" vs "golden retriever sitting on a couch").
- **Config surface.** The `ai.pathAnonymization` flag is another configuration option to document, test, and maintain.

**Future considerations (not yet implemented):**

- **Opt-in content indexing.** A future `content:` search operator could index file content locally (via Spotlight or a custom indexer) and generate embeddings stored on-device, with no cloud round-trip. This would expand AI capability while maintaining the privacy boundary.
- **Per-file consent.** A `.deepfinder-ignore` file or extended attribute could let users mark specific directories as "never send to AI" for an additional safety layer.
- **On-device-only mode.** A configuration flag to restrict all AI processing to CoreML/ANEChip, with zero cloud API calls.
