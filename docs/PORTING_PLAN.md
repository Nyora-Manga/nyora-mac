# Nyora → Nyora Mac Porting Plan

This document is the bridge between the Android codebase (~1240 Kotlin/Java files, AndroidX, Hilt, Room, ViewBinding XML) and a macOS-native SwiftUI build that shares logic via Kotlin Multiplatform.

## Architecture overview

```
┌────────────────────────────────────────────────────────────┐
│                  SwiftUI app (macApp/)                     │
│  Views / AppState (@MainActor) / NyoraHelperBridge actor   │
└─────────────────┬──────────────────────────────────────────┘
                  │  HTTP (loopback) + NyoraShared.framework
                  ▼
┌────────────────────────────────────────────────────────────┐
│  JVM Helper Sidecar (gradle :shared:run, HelperMain)       │
│  MihonProxyServer + JavaScriptExtensionService (GraalVM)   │
│  JsonLibraryRepository (~/Library/Application Support/...) │
└─────────────────┬──────────────────────────────────────────┘
                  │  uses
                  ▼
┌────────────────────────────────────────────────────────────┐
│  shared/commonMain  — pure-Kotlin domain types + parsers    │
│   Manga, MangaSource, MangaChapter, Library, MangaPage,     │
│   MangaExtensionService, SourceCatalogParser, NyoraFacade   │
└────────────────────────────────────────────────────────────┘
```

The SwiftUI app never imports JVM types directly. It either:

1. Speaks HTTP to the JVM helper sidecar (used today, simplest path).
2. Links the macOS-native `NyoraShared.framework` produced from `macosArm64` for offline state and parsing.

Two-target strategy keeps the heavy GraalVM and Mihon-APK code on the JVM where it works, while the SwiftUI app stays light and native.

## What the Android codebase contributes

Mapping of Android packages → port destination:

| Android package | Port destination | Notes |
|---|---|---|
| `com.nyora.android.core.model` | `shared/commonMain/com/nyora/shared/model` | Strip Android `Parcelable`, `@Parcelize`, `Resources`. |
| `com.nyora.android.core.db.entity` | TBD — SQLDelight schema | Room → SQLDelight; ~50 migrations to fold or drop. |
| `com.nyora.android.core.network` | `shared/jvmMain/com/nyora/shared/net` | Use `java.net.http.HttpClient` instead of OkHttp+WebView. |
| `com.nyora.android.core.parser` | `shared/jvmMain/com/nyora/shared/extension` | Wraps `org.koitharu.nyora.parsers`. |
| `com.nyora.android.mihon` | `shared/jvmMain` + decision | See "Mihon strategy" below. |
| `com.nyora.android.reader` | `macApp/Views/ReaderView` | UI logic re-implemented in SwiftUI; page loader stays in `shared`. |
| `com.nyora.android.details` | `macApp/Views/DetailsView` (TODO) | XML/ViewBinding → SwiftUI. |
| `com.nyora.android.explore` / `remotelist` / `search` | `macApp/Views/ExploreView` | In progress. |
| `com.nyora.android.favourites` / `history` / `bookmarks` / `local` | `macApp/Views/*` placeholders | Phase 5. |
| `com.nyora.android.download` | `shared/jvmMain/com/nyora/shared/download` (TODO) | Reuse the HTTP client + write CBZ in JVM. |
| `com.nyora.android.tracker` / `scrobbling` / `sync` | TBD | Phase 5. |
| `com.nyora.android.settings` | `macApp/Views/SettingsView` | Mac-native `Form`. |
| `com.nyora.android.widget` | Drop | Android-only. |
| `com.nyora.android.browser` | Drop | WebView-backed; not portable. |
| `com.nyora.android.novel` | Drop | Out of scope for manga-only port (per Nyora desktop notes). |
| `com.nyora.android.ai` | TBD | AI translation is in Android; revisit in Phase 6. |

## Mihon strategy

Mihon extensions ship as Android APKs. Three options:

1. **Remote proxy** — keep a paired Android device or emulator and forward `/dalvik` requests. Lowest engineering cost, highest user friction.
2. **APK → JVM bytecode** — `dex2jar` the APK at install time and load it into the helper's classpath. Requires shimming `android.*` classes.
3. **Drop Mihon on Mac** — rely only on JavaScript-engine sources and the native `org.koitharu.nyora.parsers` library.

Recommendation for v1: ship with Nyora native parsers + JavaScript sources; defer Mihon.

## Storage

Android uses Room with ~50 migrations. For Mac we can start fresh:

- v1: JSON file at `~/Library/Application Support/Nyora/library.json` (already wired via `JsonLibraryRepository`).
- v2: SQLDelight database `nyora.db` in the same directory, with a one-shot importer from the JSON file.

Backup/restore should target the v1 JSON format from day one so users can move libraries between Android and Mac.

## SwiftUI ↔ Kotlin bridging

Two patterns used:

1. **HTTP** (today): `NyoraHelperBridge` actor talks to `MihonProxyServer` on a loopback port. Survives helper restarts; isolates SwiftUI from JVM crashes.
2. **Framework linking** (future): `assembleNyoraSharedXCFramework` produces `NyoraShared.xcframework` containing the macOS-native targets. SwiftUI imports `NyoraShared` and calls Kotlin objects directly — but only `commonMain` + `macosMain` code (no GraalVM, no Mihon).

The two patterns coexist: framework-linked code handles local state and parsing of helper responses; the helper handles extension execution.

## What was salvaged from `nyora-desktop`

| Source file (nyora-desktop) | Destination (nyora-mac) |
|---|---|
| `model/Models.kt` | `shared/commonMain/.../model/Manga.kt`, `MangaSource.kt`, `Library.kt`, `SortOrder.kt` |
| `extension/MangaExtensionService.kt` | `shared/commonMain/.../extension/MangaExtensionService.kt` |
| `extension/UnsupportedExtensionService.kt` | `shared/commonMain/.../extension/UnsupportedExtensionService.kt` |
| `extension/MangaExtensionRuntime.kt` | `shared/commonMain/.../extension/MangaExtensionRuntime.kt` (+ JVM/macOS factories) |
| `extension/JavaScriptExtensionService.kt` | `shared/jvmMain/.../extension/JavaScriptExtensionService.kt` |
| `data/JsonStore.kt` | `shared/jvmMain/.../data/JsonStore.kt` (Mac-only path) |
| `data/SourceCatalogClient.kt` | split: parser → `commonMain`, HTTP → `jvmMain` |
| `data/ExtensionInstaller.kt` | `shared/jvmMain/.../data/ExtensionInstaller.kt` |
| `reader/PageImageLoader.kt` | `shared/jvmMain/.../reader/PageImageLoader.kt` (now returns bytes; UI decodes) |
| `proxy/MihonProxyServer.kt` | `shared/jvmMain/.../proxy/MihonProxyServer.kt` |
| `resources/extensions/demo-manga.js` | `shared/src/jvmMain/resources/extensions/demo-manga.js` |
| `Main.kt` (Compose desktop UI) | Replaced by SwiftUI views in `macApp/` |
| `DesktopAppState.kt` | Replaced by `NyoraFacade` + `AppState.swift` |

What was *not* salvaged: the Compose Desktop UI (entire `Main.kt`) since we picked SwiftUI as the target.
