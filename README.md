# DeepFinder

A blazing-fast file search utility for macOS, inspired by [Everything](https://www.voidtools.com/) on Windows.

## Features

- Instant file name search with custom in-memory index (O(1) substring lookup)
- Pinyin search for Chinese filenames
- Spotlight-like UI with Apple Intelligence glow animation
- Global hotkey to invoke search from anywhere (⌃⌘K)
- Menu bar app — no Dock icon, stays out of your way
- Real-time file system monitoring via FSEvents

## Requirements

- Apple Silicon M4 or later
- macOS 26 (Tahoe) or later

## Build

```bash
swift build
```

## Architecture

See [design spec](docs/superpowers/specs/2026-05-26-deep-finder-design.md) for full architecture details.

## License

MIT
