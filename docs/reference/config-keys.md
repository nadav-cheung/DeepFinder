# Configuration Reference

DeepFinder configuration is stored as JSON at the path below and managed
via the `config` subcommand or the `:config` REPL command.

## Config Keys

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `excludedPaths` | `[String]` | `["/System", "/Library"]` | Paths excluded from indexing |
| `excludedVolumes` | `[String]` | `[]` | Volume mount paths excluded (e.g., Time Machine disks) |
| `indexBatchSize` | `Int` | `100` | Records per SQLite batch write |
| `maxResults` | `Int` | `1000` | Maximum results per query |
| `configVersion` | `Int` | `1` | Schema version for migrations |

## Config Commands

| Command | Description |
|---------|-------------|
| `deepfinder config get <key>` | Get a single config value |
| `deepfinder config set <key> <value>` | Set a config value |
| `deepfinder config list` | List all config keys and values |
| `deepfinder config reset` | Reset to defaults (prompts for confirmation) |

In the REPL, the same operations are available via `:config KEY [VALUE]`.

## File Location

`~/.deep-finder/settings.json` (permissions 600, owner-only).

For step-by-step configuration, see [Configure DeepFinder](../how-to/configure.md).
