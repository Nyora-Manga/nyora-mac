# Nyora for macOS

**Official macOS downloads for the Electron-based Nyora desktop app.**

[Download the latest release](https://github.com/Nyora-Manga/nyora-mac/releases/latest) · [Installation and migration instructions](INSTALL.md) · [Source and issues](https://github.com/Nyora-Manga/nyora-desktop)

## Choose a build

- **mac-x64**: Intel/AMD 64-bit.
- **mac-arm64**: Apple Silicon (M-series).

The release includes both architectures. Java, Chromium and the local helper are bundled; you do not need a separate Java installation or server. Initial Electron builds are unsigned/not notarized. Verify downloads using the release's `SHA256SUMS.txt` and follow the OS-specific steps in [INSTALL.md](INSTALL.md).

## One desktop application

Nyora has moved desktop development entirely to [nyora-desktop](https://github.com/Nyora-Manga/nyora-desktop). This repository distributes the macOS builds only. File bugs and contribute code in the canonical repository.

The previous native desktop implementation is **deprecated**. Its source is preserved in the [`legacy/native-desktop`](https://github.com/Nyora-Manga/nyora-mac/tree/legacy/native-desktop) branch and Git history; historical releases remain available. Its old build/store workflows no longer run on this default branch. Back up data before migration: sessions and downloaded files do not automatically transfer.

## Release automation

Every successful push to the canonical repository builds and tests all six macOS/Windows/Linux x64/ARM64 targets. Only a complete matrix publishes a central release. This repository's scheduled workflow checks roughly every 15 minutes and mirrors its two architectures with SHA-256 verification. GitHub can delay scheduled jobs; maintainers can also run **Mirror Electron desktop release** manually.

No native application source or independent build pipeline is maintained here. Mirrored files are unchanged from the [central releases](https://github.com/Nyora-Manga/nyora-desktop/releases), where all six targets and native validation reports are available.
