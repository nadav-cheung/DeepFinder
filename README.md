# Everything Search

A blazing-fast file search utility for macOS, inspired by [Everything](https://www.voidtools.com/) on Windows.

## Features

- Instant file name search with custom in-memory index
- Spotlight-like UI with Apple Intelligence glow animation
- Global hotkey to invoke search from anywhere (⌥Space)
- Menu bar app — no Dock icon, stays out of your way
- Real-time file system monitoring via FSEvents

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+

## Build

```bash
swift build
```

## Run

```bash
swift run
```

## Architecture

See [design spec](docs/superpowers/specs/2026-05-26-everything-search-design.md) for full architecture details.

## License

MIT
