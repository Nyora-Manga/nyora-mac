# Install Nyora desktop

Nyora desktop now uses one Electron application on macOS, Windows and Linux. The previous native desktop clients are deprecated. Android and iOS are separate projects.

Download from [nyora-desktop releases](https://github.com/Nyora-Manga/nyora-desktop/releases/latest) or the corresponding [Mac](https://github.com/Nyora-Manga/nyora-mac/releases/latest), [Windows](https://github.com/Nyora-Manga/nyora-windows/releases/latest) or [Linux](https://github.com/Nyora-Manga/nyora-linux/releases/latest) release mirror.

## Pick the right build

| System | Intel / AMD 64-bit | ARM64 |
|---|---|---|
| macOS 14 or newer | mac-x64 | mac-arm64 (Apple Silicon) |
| Windows 10 or newer | win-x64 | win-arm64 (Windows on ARM) |
| Supported 64-bit Linux desktop with glibc | linux-x64 | linux-arm64 |

`x64` means `x86_64`/`amd64`, not 32-bit x86. There are six supported OS/CPU combinations. Each release can include an installer and a portable archive for each combination.

The app bundles Chromium, the helper and its Java runtime. You do not install Java, Chrome, Node, or a server separately. Source access requires an internet connection; previously downloaded chapters can be read offline. Optional translation/colorization model downloads are separate from installing the reader.

## macOS

1. Download the matching `.dmg`, open it and drag Nyora into Applications.
2. Open Nyora from Applications.
3. These initial builds are not notarized. If macOS blocks a verified download, use **System Settings → Privacy & Security → Open Anyway** when offered. Do not disable Gatekeeper globally.

The `.zip` is an alternative containing the application bundle. Quit Nyora before replacing an existing installation.

## Windows

1. Download the matching `.exe` installer and run it.
2. After installation, launch Nyora from the Start menu.
3. These initial builds are unsigned. Windows may show an unknown-publisher warning; confirm the source and checksum before proceeding.

The `.zip` is a portable alternative. Extract the entire archive and run `Nyora.exe`; keep its resources beside it. Windows on ARM should use arm64, not x64 emulation.

## Linux

Download the matching `.AppImage`, make it executable and launch it:

```sh
chmod +x Nyora-*-linux-*.AppImage
./Nyora-VERSION-linux-ARCH.AppImage
```

Replace `VERSION` and `ARCH` with the downloaded filename. On distributions needing FUSE 2, install the distribution's FUSE compatibility package. Alternatively extract and launch with `./Nyora-VERSION-linux-ARCH.AppImage --appimage-extract-and-run`, or use the `.tar.gz` archive and run its `nyora-desktop` executable. A graphical desktop session is required. Do not launch Nyora as root or disable Chromium's sandbox to work around desktop configuration problems.

## Verify a download

Download `SHA256SUMS.txt` from the same release. Compare the file hash:

- macOS: `shasum -a 256 DOWNLOADED_FILE`
- Linux: `sha256sum DOWNLOADED_FILE`
- Windows PowerShell: `Get-FileHash .\DOWNLOADED_FILE -Algorithm SHA256`

## Moving from the old native app

Export a backup from the old app and keep the old installation/data until you have checked the Electron app. In Nyora, use **Settings → Backup & Data → Restore backup** for a supported `.nyorabk` backup. Renaming another backup format does not convert it. Website sessions, downloaded chapter files and platform-specific data are not automatically migrated; sign in/verify sources and download those chapters again as needed. Cloud sync is optional and manual by default.

## Updates and support

Install a newer release over the previous Electron version after closing it. There is no silent unsigned auto-updater. Report app issues in [nyora-desktop](https://github.com/Nyora-Manga/nyora-desktop/issues); the platform repositories distribute identical verified assets and no longer develop separate desktop applications.
