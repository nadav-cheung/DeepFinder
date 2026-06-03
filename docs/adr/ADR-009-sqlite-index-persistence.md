# ADR-009: SQLite for Index Persistence

- **Status:** Accepted
- **Date:** 2026-05-31

## Context

FileRecord data must survive daemon restarts. The daemon holds an in-memory index (Trie, FullSubstringMap, TrigramIndex, PinyinIndex) built from `FileRecord[]` entries. When the daemon stops (clean shutdown, crash, or system reboot), the in-memory index is lost and must be rebuilt on restart. Re-scanning the entire filesystem would take tens of seconds on large volumes -- unacceptable for a tool that promises sub-second query latency on startup.

On M4+ (Apple Silicon, unified memory), rebuilding all in-memory index structures from a persisted `FileRecord[]` takes **less than 1 second** for 1M+ records. The persistence layer therefore does not need to store the index structures themselves -- only the flat `FileRecord[]` data. The index structures are rebuilt in-memory on startup.

The persistence format must support:
- **Atomic writes**: partial writes must not corrupt the database.
- **Concurrent reads during writes**: the daemon may serve queries while persisting batch updates.
- **Inspector-friendly**: developers and power users must be able to inspect the persisted data with standard tools.
- **Zero external dependencies**: the project policy prohibits third-party libraries (including C dependencies) beyond Apple frameworks and system libraries. SQLite3 ships with macOS and is accessed via the system `libsqlite3.tbd`.

### Alternatives considered

1. **CoreData**: Rejected. CoreData is an ORM with object graph management, change tracking, and relationship resolution -- all overhead for a single flat table of FileRecord rows. CoreData does not expose WAL mode control directly; its journaling behavior is opaque. For a single-table workload, the abstraction cost exceeds the benefit.

2. **Property lists (plist)**: Rejected. A plist containing 1M+ FileRecord entries would be hundreds of megabytes on disk. Parsing a plist is O(n) with no incremental read capability -- the entire file must be deserialized before any record is available. Binary plists are faster than XML but still require full-file reads. Plists also lack atomicity guarantees during writes.

3. **LMDB**: Rejected. LMDB is an external C library. The project enforces a strict zero-dependencies policy (pure Swift + Apple frameworks only). While LMDB is excellent for this use case (memory-mapped, ACID, reader-writer concurrency), pulling in any third-party C library violates the project's architectural constraint.

4. **Custom binary format**: Rejected. A custom binary format (e.g., length-prefixed records with a checksum footer) would avoid SQLite's C API verbosity. However, it would require implementing ACID semantics (atomic writes via write-to-temp-then-rename, crash recovery, checksum validation) from scratch. SQLite provides these guarantees for free and has been battle-tested for decades.

## Decision

**Use SQLite3 via direct C API. WAL mode. Batch writes every 5 seconds or 100 accumulated changes.**

The database file lives at `~/.deep-finder/cache/index.db` with file permissions `0600` (owner read/write only). The schema is a single table:

```sql
CREATE TABLE IF NOT EXISTS file_records (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL,
    name TEXT NOT NULL,
    original_name TEXT,
    parent_id INTEGER,
    size INTEGER NOT NULL DEFAULT 0,
    modification_date REAL NOT NULL,
    creation_date REAL,
    kind TEXT NOT NULL,
    is_directory INTEGER NOT NULL DEFAULT 0,
    is_package INTEGER NOT NULL DEFAULT 0,
    volume_id TEXT
);
```

Key design choices:

- **WAL mode** (`PRAGMA journal_mode=WAL`): allows concurrent reads during writes. The daemon's search path reads from the database without blocking on batch writes. The WAL file accumulates changes and is periodically checkpointed.
- **Batch writes**: changes are accumulated in memory and flushed to SQLite every 5 seconds or when 100 changes have accumulated (whichever comes first). This avoids per-event SQLite transaction overhead from FSEvents (which can fire hundreds of events per second during bulk operations).
- **Flat table, no normalization**: FileRecord is stored as a single flat table. No joins, no foreign keys, no triggers. The schema mirrors the `FileRecord` struct fields directly. The in-memory index structures (Trie, etc.) are rebuilt from this flat data on startup.
- **Direct C API**: `sqlite3_open_v2`, `sqlite3_prepare_v2`, `sqlite3_bind_*`, `sqlite3_step`, `sqlite3_finalize`. No Swift wrapper or ORM layer. Parameterized queries are used for all write operations to prevent SQL injection (though the only input is filesystem paths, defense in depth applies).

## Consequences

### Positive

- **ACID transactions**: SQLite provides atomic, consistent, isolated, and durable writes. Partial writes cannot corrupt the database. Crash recovery is handled by SQLite's WAL checkpoint mechanism.
- **Concurrent readers**: WAL mode means readers (daemon query path) never block on writers (batch persistence) and vice versa. This is critical for a daemon that serves queries continuously while indexing updates are being persisted.
- **Well-understood file format**: SQLite databases are inspectable with the `sqlite3` CLI tool (`sqlite3 ~/.deep-finder/cache/index.db .dump`). This aids debugging, support, and power-user inspection.
- **Battle-tested**: SQLite is the most widely deployed database engine in the world. Its correctness and reliability are proven across billions of devices.
- **No dependency cost**: `libsqlite3.tbd` ships with macOS. No third-party libraries, no vendored source, no build system integration.

### Negative

- **C API is verbose in Swift**: SQLite's C API requires manual memory management for statement handles (`sqlite3_finalize`), manual binding and column extraction, and error checking after every call. A typical insert requires ~15 lines of Swift. This verbosity is contained within `IndexPersistence.swift` and does not leak into the rest of the codebase.
- **Parameterized queries must be written manually**: without an ORM, every query is a raw SQL string. Column indices (`sqlite3_column_int(stmt, 0)`) are fragile against schema changes. This is mitigated by colocated schema constants and tests that verify the full persist-rebuild round-trip.
- **WAL file periodic checkpointing**: The WAL file grows unboundedly if never checkpointed. The daemon runs `PRAGMA wal_checkpoint(TRUNCATE)` every 60 seconds or when the WAL exceeds 10MB. This adds a small amount of daemon housekeeping logic.

### Alternatives considered and rejected

See Context section above for detailed rejection rationale for CoreData, plist, LMDB, and custom binary format.

## Related

- [ADR-006](ADR-006-fseventwatcher-actor-isolation-model.md) -- FSEventWatcher produces the change events that trigger batch persistence writes
- `Sources/Persist/IndexPersistence.swift` -- SQLite persistence implementation
- `Sources/Index/FileRecord.swift` -- FileRecord struct whose fields map to the SQLite schema
