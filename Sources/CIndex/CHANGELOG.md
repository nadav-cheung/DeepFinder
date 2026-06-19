# Changelog

All notable changes to **libdfindex** (the DeepFinder C index core) are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-06-19

First standalone release of the C index core, extracted from DeepFinder 3.2.0.

### Added
- **CTrigramIndex** — standalone byte-level trigram inverted index. Flat posting
  lists + binary-searched `PostingBlock` index + lazy pending buffer (sort+merge
  flush) + two-pointer intersection from the shortest list + `strncasecmp`
  verification against an arena of lowercased names. CJK-native (byte-level
  trigrams over UTF-8). Thread-safe via `pthread_mutex`.
- **`dfindex.h`** umbrella header — single include for the whole public API.
- **`tests/test_core.c`** — pure-C test suite (7 tests), runnable via `make test`
  with no Swift toolchain.
- **`make test`** and **`make install`** targets.
- Standalone `Makefile` producing `libdfindex.a` + `dfdemo`, zero dependencies
  beyond libSystem.

### Changed
- `cindex_search_substring` now guarantees `*out_ids == NULL` when it returns 0
  results, so callers may `free(*out_ids)` unconditionally.
- Sources reorganised into `src/` (canonical C layout); SPM `Package.swift`
  references the new paths.

### Credits
- Parallel walk: [rq](https://github.com/seeyebe/rq) (subtree partitioning → GCD `dispatch_apply`).
- Trigram index: xgrep / lattice (flat postings, block index, two-pointer merge, arena verification).
