# Nyora macOS Google Sign-In Findings

Date: 2026-06-08

## Scope

Analyzed both macOS sign-in entry points:

- Onboarding/start screen: `macApp/Nyora/NyoraApp/Views/WelcomeView.swift`
- Settings sync screen: `macApp/Nyora/NyoraApp/Views/PlaceholderViews.swift`

Also checked the shared helper/Supabase path, the GoogleSignIn package code used by SwiftPM, the running helper process, and the local SQLite restore result.

## Findings

1. Crash reports show the app is crashing before any Google or Supabase code appears on the stack.

   Latest crash reports under `~/Library/Logs/DiagnosticReports/Nyora-*.ips` all show:

   - `EXC_BAD_ACCESS`
   - `SIGSEGV`
   - main thread
   - SwiftUI button dispatch frames:
     - `swift_task_isMainExecutorImpl`
     - `MainActor.assumeIsolated`
     - `_ButtonGesture.internalBody`

   This points at SwiftUI button/action dispatch, not the Supabase HTTP call or the Google callback.

2. Runtime stderr shows Google OAuth is failing independently of the crash:

   ```text
   Google Sign-In error: invalid_request: client_secret is missing.
   ```

   This means the GoogleSignIn native token exchange is using a client ID that Google treats as confidential. The checked-out GoogleSignIn/AppAuth code creates a token request with `clientSecret: nil`, which is correct only for a public/native app client.

3. The mac app was using this active Google app client ID:

   ```text
   181067068545-5r2ob1jv4mc0v8gd52fgk2jt28pk3370.apps.googleusercontent.com
   ```

   That client is the one producing `client_secret is missing`.

4. The iOS Nyora app already uses this public Google client:

   ```text
   181067068545-9jkcbv6cb552jvmn6o3rdk87m2195g7n.apps.googleusercontent.com
   ```

   Supabase local config already allows it together with the Android/server client:

   ```text
   181067068545-4jkfesn716ucqbuhcbtvdtlqfg3ar38u.apps.googleusercontent.com
   ```

5. The onboarding screen and Settings screen had separate hardcoded Google client setup and both wrapped sign-in button work in explicit `Task { @MainActor in ... }` closures. That duplicated configuration and matched the crash stack's actor/button-dispatch failure area.

6. The helper restore/sync endpoints returned `{"ok":true}` before the cloud work finished.

   That made the mac app reload local data immediately against an empty DB, which looked like "sign in did nothing" even when Supabase auth had succeeded.

7. The real restore failure was hidden by `getOrNull()` inside the helper sync code.

   Once the endpoint was made deterministic, restore returned this concrete error:

   ```text
   Serializer for class 'Any' is not found.
   ```

   Root cause: sync request bodies were built as `Map<String, Any>`, which Kotlin serialization cannot encode at runtime.

8. After fixing the request body encoding, restore reached the edge function and exposed the next mismatch:

   ```text
   Field 'user_id' is required for type ... SbManga, but it was missing
   ```

   This is expected from the edge function: `sanitizeColumns()` strips `user_id` from select results. The mac pull DTOs needed to treat `user_id` as write-only/defaulted.

9. Cloud-applied history rows were going through the normal `recordHistory()` path. That path is for local reading activity, so it triggers a push and stamps `updated_at` with local "now". Restore needs a sync-specific upsert that preserves cloud timestamps and does not re-push each pulled row.

10. The mac helper had already overwritten cloud `nyora_manga.source_ref` values with `Unknown` during a previous sync because `pushManga()` pushed every local manga row, including restored manga whose source metadata could not be decoded.

    I stopped future syncs from pushing `MangaSourceRef.Unknown` manga metadata back to cloud. For already-damaged rows, source ids can only be inferred when the manga URL is absolute and matches an installed source base URL.

## Changes Applied

1. Updated `Info.plist` so macOS uses the public Nyora iOS client as `GIDClientID`.

2. Added the public iOS callback URL scheme and kept the previous mac callback scheme as a compatibility fallback.

3. Centralized Google sign-in constants and result handling in `SupabaseGoogleAuthHelper`.

4. Changed `SupabaseGoogleAuthHelper` to return:

   - success with ID token
   - cancellation
   - concrete failure message

5. Updated onboarding and Settings sign-in flows to use the same helper and show real failure messages through `AppState.statusMessage`.

6. Removed explicit `Task { @MainActor in ... }` wrappers from the sign-in-related button paths so button dispatch does not create an extra actor-isolated closure around sign-in startup.

7. Fixed helper sync DTOs that were missing `updated_at` fields while push code was constructing payloads with that field:

   - `SbFavourite`
   - `SbBookmark`
   - `SbCategory`

   This was blocking `:shared:helperJar` and would have left the app packaged with a stale helper jar.

8. Made `/supabase/sync` and `/supabase/restore-from-cloud` run synchronously in the helper. They now return `ok` only after work finishes, and return a real 500 error if the edge function, decoding, or apply step fails.

9. Replaced the helper's `Map<String, Any>` sync request encoding with explicit JSON/typed request bodies.

10. Defaulted `user_id` on pull DTOs so mac restore matches the edge function contract, where selected rows omit `user_id`.

11. Added a sync-specific history upsert that preserves Supabase `updated_at`, `scroll`, and `chapters_count`, and does not trigger push during restore.

12. Added helper debug logging around cloud pulls so a future "nothing happened" report shows whether pull started, completed, and how many manga/history/favourite rows landed.

13. Prevented sync from pushing manga rows with `MangaSourceRef.Unknown`, so mac restore cannot clobber better Android/cloud source metadata in future syncs.

14. Added restore-time source-id inference for history rows with empty cloud `source_id`:

   - first from `source_ref.name`, for intact cloud rows like `JS_ASURASCANS_US`
   - then from absolute manga URLs, by matching installed source `baseUrl`

15. Matched Android's source metadata storage format for restored manga rows.

   Android stores source metadata as compact JSON with a `name` field, for example:

   ```text
   {"name":"JS_ASURASCANS_US"}
   ```

   The desktop helper now reads that Android shape, still accepts the older Kotlin polymorphic JSON shape, and writes the Android-compatible shape.

16. Added restore-time repair for already-damaged cloud manga rows whose `source_ref` is `UNKNOWN`.

   If the manga URL can be matched to an installed JavaScript source, restore now writes `MangaSourceRef.Script("JS_<parser id>")` into the local row. This repairs the two Asura rows that the old mac sync had previously clobbered to `UNKNOWN`.

## Verification

Builds now pass:

```bash
cd /Users/hasanraza/Desktop/kotatsu/Nyora/nyora-mac
./gradlew :shared:helperJar --stacktrace
cd macApp
./scripts/dev-launch.sh
```

Verified after relaunch:

- `/tmp/Nyora-dev.app/Contents/Info.plist` has `GIDClientID = 181067068545-9jkcbv6cb552jvmn6o3rdk87m2195g7n.apps.googleusercontent.com`
- `/tmp/Nyora-dev.app/Contents/Info.plist` includes callback schemes for both the new public client and the previous mac client
- helper `/supabase/status` returns `isConfigured=true`
- helper `/supabase/status` returns `isAuthenticated=true`
- helper `/supabase/status` returns user `06499d43-49c4-42cc-8d15-6c737e41d5b4`
- direct restore call now returns `{"ok":true}` with `HTTP 200` after the helper finishes the restore
- local SQLite after restore:
  - `manga=4`
  - `history=4`
  - `fav=1`
  - `category=1`
  - `manga_prefs=4`
- helper `/library/history?limit=5` returns 4 entries:
  - `Golden Forest` (source unresolved because the cloud row has only a relative URL and unknown source metadata)
  - `Chronicles of the Demon Faction` (`parser:ASURASCANS_US` / `Asura Scans`)
  - `Solo Leveling` (`parser:ASURASCANS_US` / `Asura Scans`)
  - `The Demon Lord's Channel` (source unresolved because the cloud row has only a relative URL and unknown source metadata)
- helper `/library/favourites` returns 1 entry:
  - `Chronicles of the Demon Faction`
- raw SQLite `manga.source_ref` after restore:
  - `Chronicles of the Demon Faction` = `{"name":"JS_ASURASCANS_US"}`
  - `Solo Leveling` = `{"name":"JS_ASURASCANS_US"}`
  - `Golden Forest` = `{"name":"UNKNOWN"}` because the restored URL is relative and the damaged cloud row has no source metadata
  - `The Demon Lord's Channel` = `{"name":"UNKNOWN"}` because the restored URL is relative and the damaged cloud row has no source metadata
- `/tmp/nyora-stderr.log` has no new crash or Swift continuation misuse output after relaunch/restore

Manual checks still needed:

- If testing a completely fresh OAuth popup, sign out or clear tokens and click Sign in with Google again. The app should now either authenticate and restore, or show the real Google/Supabase/helper error instead of silently doing nothing.

If Google still rejects the sign-in, the app should now show the exact OAuth error instead of silently doing nothing.

## Cross-Platform Sync Pass

Date: 2026-06-08

Additional findings and changes:

- Confirmed Android source format is `{"name":"JS_<parser id>"}` for JavaScript sources.
- Shared desktop helper now decodes Android `{"name":...}` source refs, preserves older Kotlin source-ref JSON, and writes Android-compatible source refs.
- Shared desktop helper now exposes `googleDesktopClientId` through `/supabase/status`.
- Windows and Linux use the mac shared helper source, so the source-ref and edge-function sync fixes compile into both helper jars.
- Windows and Linux Settings now use Supabase `/supabase/*` helper endpoints with a browser-loopback Google OAuth flow and the mac public desktop client ID.
- Docker and JVM Nyora Web configs now pass the public Supabase config plus desktop/web Google client IDs.
- Browser-only Nyora Web and Cloudflare static builds now include Cloud Sync settings backed by Supabase Auth plus the `nyora-sync` edge function; no Google client secret is used.
- The supplied web OAuth JSON only lists `http://127.0.0.1:3000` as an authorized JavaScript origin, so deployed web origins must be added in Google Cloud.

Cross-platform verification:

```bash
cd /Users/hasanraza/Desktop/kotatsu/Nyora/nyora-mac
./gradlew :shared:helperJar --stacktrace

cd /Users/hasanraza/Desktop/kotatsu/Nyora/nyora-windows
./gradlew :shared:helperJar :desktopApp:compileKotlin --stacktrace

cd /Users/hasanraza/Desktop/kotatsu/Nyora/nyora-linux
./gradlew :shared:helperJar :desktopApp:compileKotlin --stacktrace

cd /Users/hasanraza/Desktop/kotatsu/Nyora/nyora-web
./gradlew :shared:webJar --stacktrace
node --check shared/src/jvmMain/resources/web/core/sync.js
node --check cloudflare/public/core/sync.js
```

All commands above passed. Docker compose config validation also passed for
`nyora-docker`, `nyora-web/docker-compose.yml`, and
`nyora-web/docker-compose.https.yml` when `DOMAIN` was supplied for the HTTPS
stack.
