# Nyora for Mac

A native **macOS** build of the Nyora manga reader — a SwiftUI front end over the
shared Kotatsu engine (run as a bundled JVM helper). Ships as a `.dmg` with its own
Java runtime bundled, so there's nothing else to install.

> **Download:** grab `Nyora.dmg` from the [Releases page](https://github.com/Hasan72341/nyora-mac/releases/latest) (Apple Silicon & Intel). Open the DMG and drag **Nyora** to Applications; on first launch right-click → **Open** to bypass Gatekeeper for the unsigned build.

## Features

### Sources & reading
- **Huge source catalogue** — browse, search and filter hundreds of online manga/manhwa/manhua sources, powered by the shared Kotatsu parser engine.
- **Standard & Webtoon reader** — paged (LTR/RTL) and vertical webtoon modes, zoom, double-page spreads and per-title settings.
- **AI page translation** — translate a whole page at once: Apple **Vision** OCR (with a rotated-ensemble pass that handles vertical Japanese / tategaki) plus a bundled **MangaOCR** CoreML model detect the text, which is then translated and typeset back over the art. Includes a side-by-side translation sheet (⌘T).
- **Dynamic colour correction** — adjust brightness, contrast and colour filters live while reading.

### Library, tracking & sync
- **Favourites in custom categories**, **reading history**, resume-where-you-left-off, and **incognito** mode.
- **Offline downloads** — download chapters for offline reading.
- **Tracker integration** — sync reading progress with online trackers.
- **Cloud sync** — sign in with Google (loopback OAuth) and your library, favourites, categories, history and progress sync across all your Nyora devices (Supabase backend).
- **Themes** — light / dark / system.

## Architecture

```
nyora-mac/
├── shared/        # thin :shared Gradle module — compiles the nyora-shared engine (submodule) for the JVM
├── nyora-shared/  # the shared Kotatsu engine (git submodule)
└── macApp/        # SwiftUI app (Nyora/NyoraApp) + build scripts
```

The SwiftUI app launches a small **JVM helper** (`nyora-helper.jar`) that owns the
parser runtime + a loopback REST API; the app talks to it over localhost. The
packaged `.app` bundles a Temurin JRE so end users need no Java.

## Build from source

Requires **Xcode**, **JDK 17** and the `nyora-shared` submodule.

```bash
git clone --recurse-submodules https://github.com/Hasan72341/nyora-mac.git
cd nyora-mac

# dev: build + wrap + launch the app
./macApp/scripts/dev-launch.sh

# release: assemble Nyora.app (bundled JRE) and a branded .dmg
./macApp/scripts/build-dmg.sh         # → build/Nyora.dmg
```

## Author & license

Developed and maintained by **Md Hasan Raza** — [GitHub](https://github.com/Hasan72341) · [Instagram](https://instagram.com/md_hasan_raza____) · [LinkedIn](https://www.linkedin.com/in/md-hasan-raza) · hasanraza96@outlook.com

Licensed under the **GNU General Public License v3.0**. Nyora is a fork of [Kotatsu](https://github.com/KotatsuApp/Kotatsu) and is not affiliated with any of the manga sources it can access.
