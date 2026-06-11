# Nyora Mac TODO

Path to full parity with `nyora-android`. Items are roughly ordered by what unblocks the next layer.

## Phase 0 — Scaffold (done)

- [x] Folder layout (`shared/` KMP module + `macApp/` SwiftUI app).
- [x] Domain models in `commonMain` (Manga, MangaChapter, MangaPage, MangaSource, FavouriteCategory, sort/zoom enums, Library).
- [x] `MangaExtensionService` interface and unsupported-engine stubs in `commonMain`.
- [x] GraalVM JS runtime moved into `jvmMain` (`JavaScriptExtensionService`).
- [x] `MihonProxyServer` moved into `jvmMain` with the same `/dalvik` protocol as Android.
- [x] JSON-backed `JsonLibraryRepository` in `jvmMain`.
- [x] `NyoraFacade` (shared) and JVM/macOS factories.
- [x] SwiftUI shell with sidebar matching Nyora Android destinations.
- [x] `NyoraHelperBridge` actor that discovers the JVM helper sidecar.
- [x] `HelperMain` entry point + `gradle :shared:run` task.
- [x] Demo JS extension copied into resources.

## Phase 1 — Make the helper bridge real

- [x] HTTP endpoints on the helper (`NyoraRestServer`): `/health`, `/sources`, `/sources/refresh`, `/sources/install`, `/sources/uninstall`, `/sources/pin`, `/sources/popular`, `/sources/latest`, `/sources/search`, `/manga/details`, `/manga/pages`, `/image` (header-injecting proxy).
- [x] Codable DTOs in Swift (`HelperDTOs.swift`) that mirror the helper JSON output.
- [x] Replace placeholder data in `NyoraHelperBridge` with real `URLSession` calls (`get/post<T: Decodable>`).
- [x] Wire `openDetails` / `openChapter` into `AppState`; tapping a chapter loads pages and navigates to the Reader.
- [x] Image proxy URL builder (`imageProxyURL(for:)`) so `AsyncImage` can render header-protected CDN images.
- [x] Smoke-tested helper end-to-end against the built-in Demo JS source.
- [x] Fat helper JAR via `:shared:helperJar` (39 MB, includes GraalVM JS + all deps).
- [x] Helper auto-launch from the SwiftUI app — `HelperLauncher` finds Java + JAR and spawns via `Process`.
- [x] Parent-PID watchdog (`HelperMain` polls `ProcessHandle.of(pid).isAlive`) so the helper exits if the SwiftUI app is SIGKILL'd.
- [x] Clean shutdown on Cmd-Q via `NyoraAppDelegate.applicationShouldTerminate`.
- [x] Refine `guessContentType` for URLs without extensions — sniff JPEG/PNG/GIF/WEBP/AVIF/HEIC magic bytes.
- [ ] Bundle a minimal JRE (jlink) so users don't need their own Java install. **Attempted, deferred.** A jlink JRE with `java.base,java.net.http,java.naming,java.logging,java.management,java.scripting,java.xml,java.sql,java.compiler,jdk.httpserver,jdk.unsupported,jdk.crypto.ec,jdk.crypto.cryptoki,jdk.management,jdk.zipfs,jdk.security.auth,jdk.security.jgss,jdk.charsets,jdk.localedata` boots the helper and `/health` works, but GraalJS can't find its language provider — Truffle's polyglot discovery requires the GraalJS jars on the **module-path**, not the fat-jar classpath. Fix requires splitting the fat JAR back into modular jars, generating module-info for non-modular deps, and configuring `--add-modules` for Graal-specific modules. Multi-hour task.

## Phase 2 — Storage parity with Android

Android uses Room. We're using SQLDelight 2.1 (KMP-native, JDBC driver on JVM, native-driver wired for macosX64/macosArm64 future use).

- [x] Picked **SQLDelight 2.1** — KMP-native, generates Kotlin types, works on JVM + macOS Native.
- [x] Schema: `manga`, `manga_source` tables (`.sq` files under `shared/src/commonMain/sqldelight/com/nyora/shared/db/`). Tags/authors/chapters/altTitles stored as JSON columns for now.
- [x] `SqlDelightLibraryRepository` (jvmMain) implementing `LibraryRepository`. Composes a `Library` snapshot from the DB on `load()`.
- [x] One-shot migration from legacy `library.json` → SQLite. Renames the file to `library.json.migrated` afterwards.
- [x] Wired into `HelperMain`; demo source seeded only on first DB boot.
- [x] **Service-file merger** in `helperJar` task — concatenates `META-INF/services/*` from all dep JARs so GraalJS's Truffle polyglot discovery still works under shading.
- [x] Smoke-tested: fresh boot → seed → write-through `/manga/details` → restart → data persists.
- [x] `manga_history` + `manga_favourite` tables; REST endpoints `/library/history`, `/library/history/record`, `/library/favourites`, `/library/favourites/toggle`, `/library/favourites/check`.
- [x] SwiftUI: History view shows recent reads with covers + relative time; Favourites view shows hearted manga grid; heart toggle in details pane; opening a chapter records history.
- [ ] Normalize chapter rows into a `chapter` table (currently a JSON column on `manga`). Needed for the chapter-page cache.
- [x] `bookmark` table with unique `(manga_id, chapter_id, page)` index. REST: `/library/bookmarks`, `/library/bookmarks/add`, `/library/bookmarks/remove`, `/library/bookmarks/check`.
- [x] SwiftUI: bookmark button in reader toolbar (filled/empty based on current-page state), Bookmarks sidebar item shows real entries grouped by manga, tap to jump to that page, right-click → Delete.
- [ ] Tables for `favourite_category`, `external_repo`.
- [ ] Port `MangaPrefsEntity` schema (per-manga reader prefs).
- [ ] Backup/restore matching `com.nyora.android.backups` (zip + JSON), bi-directionally compatible with Android.

## Phase 3 — Extension engines

- [x] **JavaScript:** wired and working (GraalVM JS under the JVM helper).
- [x] **Nyora native parsers** (`org.koitharu:nyora-parsers-redo` from JitPack): `JvmMangaLoaderContext` + `SimpleCookieJar` + `ParserMangaExtensionService` bridge a parser source to our `MangaExtensionService`. ~1300 sources available; **5 seeded pre-installed**: MangaDex, MANGA Plus, MangaReader, Asura Scans, ComicK.
- [x] Dispatch wired in `JvmExtensionRuntime` via `SourceEngine.Parser`; parser instances cached so cookies persist across calls.
- [x] Chapter title fallback (e.g. "Vol. 15 Ch. 114") when the parser returns a null/blank title.
- [x] OkHttp 4 + org.json bundled so the JAR works on plain JVM without Android core libs.
- [x] Smoke-tested end-to-end against MangaDex (20 results → details → 7 chapters → 20 page URLs) and ComicK (50 results).
- [ ] **Mihon APK:** decide between (a) remote Android proxy, (b) dex2jar to JVM, or (c) drop Mihon on Mac.
- [ ] Dart parser sources: drop (Android-only).
- [ ] Per-source preferences, headers, cookies, filters surfaced to SwiftUI.
- [x] Source discovery UI — `/sources/catalog` lists all 1346 parser sources; SwiftUI `CatalogSheet` lets the user search/filter/install on tap. Parser sources install directly (no APK download) since they're baked into the JAR.
- [x] Sort-order fallback in `firstNonEmpty()` — popular() / latest() now cycle through every available sort order so sources that don't support POPULARITY can still surface manga.
- [ ] Hook GraalVM JS into `JvmMangaLoaderContext.evaluateJs` so sources that need browser-side JS execution work.
- [ ] Bitmap manipulation (`redrawImageResponse` / `createBitmap`) via java.awt for the rare sources that scramble page images.

## Phase 4 — Reader

- [x] Paged + webtoon modes with a toolbar segmented picker.
- [x] Per-page header propagation already in place via the `/image` proxy.
- [x] Resume from last page — `openChapter` reads the saved `page` from history and starts there.
- [x] Continuous page-position persistence via `/library/history/record` on every navigation.
- [x] Prev/next chapter buttons in the reader toolbar; clears the saved-page so the next chapter starts at 0.
- [x] Arrow-key navigation in paged mode (←/→).
- [x] Pinch-to-zoom (1.0×–4.0×) + drag-to-pan + double-tap toggle (1.0× ↔ 2.0×) in `ReaderPagedView`.
- [x] Right-to-left reading order — `AppState.rtlReading` (UserDefaults-backed), toolbar toggle, flips paged nav + arrow-key direction.
- [x] **Chapter page cache** keyed by `chapter_url` — new `chapter_pages` SQLite table, 7-day TTL, `?refresh=1` cache-bypass query param. Measured 37× speedup on cache hit (410 ms cold → 11 ms warm).
- [ ] Double-page mode (two pages side-by-side).
- [ ] Download-to-CBZ (mirrors Android's downloader).

## Phase 5 — Library features

- [x] **Favourites** — heart toggle, persisted, dedicated grid view.
- [x] **History** — auto-recorded on chapter open, dedicated view with covers + relative time.
- [x] **Bookmarks** — per-page bookmark in the reader, grouped Bookmarks view.
- [x] **Updates feed** — `manga_update` table tracks `last_chapter_count`; `/library/updates/refresh` iterates favourites and diffs against the source; `UpdatesView` shows manga with new chapters and "Mark as seen" action.
- [x] **Local CBZ reader** — `NSOpenPanel` folder picker, helper endpoints `/local/scan`, `/local/chapter`, `/local/image` extract pages from `.cbz/.cbr/.zip` on demand and serve through the same reader.
- [x] **Settings** — real Form with reader defaults (paged/webtoon, prefetch, RTL), library prefs (history retention, NSFW filter), Storage section with "Reveal in Finder", helper status.
- [ ] Favourites categories (Phase 5.1).
- [ ] Sync (Mihon Sync / nyora.app endpoints).
- [ ] Trackers (AniList, MAL, Shikimori, Kitsu, Bangumi).
- [ ] Filter sheet on remote source lists.
- [ ] Suggestions + Feed views (currently still empty placeholders).

## Phase 6 — UI polish

- [ ] Details screen parity: backdrop blur, metadata table, tags, related manga, chapters bottom sheet.
- [ ] Explore parity: pinned sources, random, local/bookmarks/downloads shortcuts, filter chips.
- [ ] Global search across installed sources.
- [ ] Keyboard shortcuts (`⌘⇧F` global search, arrow nav in reader, `⌘D` download).
- [ ] Localisation — Android ships 100+ locales; port via `.strings` files.
- [ ] App icon and asset catalog.

## Phase 7 — Distribution

- [ ] Code-signing identity + entitlements for sandboxed file/network access.
- [ ] Notarised `.dmg` packaging.
- [ ] Sparkle (or similar) auto-update.
- [ ] Crash reporting (Sentry parity with Android).
