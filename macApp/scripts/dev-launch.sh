#!/bin/bash
# Build + wrap the SwiftPM executable in a proper .app bundle + launch.
#
# Why this exists: running the raw Mach-O directly (./.build/.../Nyora) or
# via `open .build/.../Nyora` doesn't give you a visible window — macOS
# treats unbundled binaries as headless processes. This script wraps the
# binary in a minimal .app bundle so SwiftUI actually shows the window.
#
# Idempotent — safe to re-run after every code change.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${NYORA_DEV_APP:-/tmp/Nyora-dev.app}"
LOG=/tmp/nyora_translate.log

echo "→ Building (swift build --product Nyora)…"
cd "$ROOT"
swift build --product Nyora 2>&1 | tail -3

BUILD="$ROOT/.build/arm64-apple-macosx/debug"
PROJ_RES="$ROOT/Nyora/NyoraApp/Resources"
JAR="$ROOT/../shared/build/libs/nyora-helper.jar"

echo "→ Packaging $APP"
pkill -9 -f "$APP/Contents/MacOS/Nyora" 2>/dev/null || true
sleep 0.5

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BUILD/Nyora" "$APP/Contents/MacOS/Nyora"

# Copy CoreML models directly into Contents/Resources/ so Bundle.main
# can find them (the SwiftPM Bundle.module accessor uses a build-dir
# path that hangs in _CFIterateDirectory from a relocated binary).
if [ -d "$PROJ_RES/MangaOcrEncoder.mlmodelc" ]; then
  rm -rf "$APP/Contents/Resources/MangaOcrEncoder.mlmodelc"
  cp -R "$PROJ_RES/MangaOcrEncoder.mlmodelc" "$APP/Contents/Resources/"
fi
if [ -d "$PROJ_RES/MangaOcrDecoder.mlmodelc" ]; then
  rm -rf "$APP/Contents/Resources/MangaOcrDecoder.mlmodelc"
  cp -R "$PROJ_RES/MangaOcrDecoder.mlmodelc" "$APP/Contents/Resources/"
fi
[ -f "$PROJ_RES/MangaOcrMeta.json" ] && cp -f "$PROJ_RES/MangaOcrMeta.json" "$APP/Contents/Resources/"
[ -f "$PROJ_RES/mokuro_daemon.py" ] && cp -f "$PROJ_RES/mokuro_daemon.py" "$APP/Contents/Resources/"

# Helper jar (so the JVM helper auto-launches)
[ -f "$JAR" ] && cp -f "$JAR" "$APP/Contents/Resources/"

# Also drop the SPM resource bundle as a backup lookup path
if [ -d "$BUILD/Nyora_NyoraApp.bundle" ]; then
  rm -rf "$APP/Contents/Resources/Nyora_NyoraApp.bundle"
  cp -R "$BUILD/Nyora_NyoraApp.bundle" "$APP/Contents/Resources/"
fi

# MLX needs `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` next
# to the binary at runtime — but `swift build` (CLI) cannot compile Metal
# shaders, so we generate the metallib ONCE via xcodebuild and cache it.
# Subsequent dev-launches just copy from cache (fast).
METALLIB_CACHE="$ROOT/build-xcode/Build/Products/Debug/mlx-swift_Cmlx.bundle"
if [ ! -f "$METALLIB_CACHE/Contents/Resources/default.metallib" ]; then
  echo "→ MLX metallib not cached — building via xcodebuild (one-time, ~5-10 min)…"
  (cd "$ROOT" && xcodebuild -scheme Nyora -derivedDataPath ./build-xcode -destination 'platform=macOS' build 2>&1 | tail -3)
fi
if [ -d "$METALLIB_CACHE" ]; then
  rm -rf "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  cp -R "$METALLIB_CACHE" "$APP/Contents/Resources/"
  # Also place next to the executable — MLX may look in either spot
  rm -rf "$APP/Contents/MacOS/mlx-swift_Cmlx.bundle"
  cp -R "$METALLIB_CACHE" "$APP/Contents/MacOS/"
fi

# Use the app's real Info.plist so Launch Services and GoogleSignIn see
# the same bundle identifier, client ID, and URL callback schemes as release.
cp -f "$ROOT/Nyora/SupportingFiles/Info.plist" "$APP/Contents/Info.plist"

# Entitlements: MLX framework requires JIT (for Metal shader compilation)
# and disabled library validation (it loads its own dylibs at runtime).
# Without these, ad-hoc-signed builds crash on first MLX.GPU access.
ENT=/tmp/Nyora-dev.entitlements
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>             <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key> <true/>
    <key>com.apple.security.cs.disable-library-validation</key>      <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc resign with entitlements. --deep so nested bundles (like
# mlx-swift_Cmlx.bundle, copied with its own xcodebuild signature) get
# resigned too — otherwise Launch Services rejects the .app with
# "code has no resources but signature indicates they must be present"
# and the window never appears.
codesign --force --deep --sign - --entitlements "$ENT" "$APP/Contents/MacOS/Nyora" >/dev/null 2>&1
codesign --force --deep --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1

# Fresh translate-log so debug lines are easy to find
rm -f "$LOG"

echo "→ Launching $APP"
STDERR=/tmp/nyora-stderr.log
rm -f "$STDERR"
# Launch via `open --stdout/--stderr` so we capture fatal errors / Swift
# preconditionFailures that don't go through our file logger.
open --stdout "$STDERR" --stderr "$STDERR" "$APP"
echo "  Translation log: $LOG"
echo "  Stdout/Stderr:   $STDERR"
echo "  ⌘T in the reader opens the side-by-side translation sheet."
