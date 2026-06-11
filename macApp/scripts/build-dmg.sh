#!/bin/bash
# build-dmg.sh — Assemble Nyora.app with a bundled JRE and create a distributable DMG.
#
# Usage (from anywhere inside the repo):
#   ./macApp/scripts/build-dmg.sh
#
# Outputs:
#   nyora-mac/build/Nyora.dmg   (~400-500 MB, no Java install required by end-user)
#
# The bundled JRE (Adoptium Temurin 17) is cached in nyora-mac/build/jre-cache/
# so re-runs skip the download.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NYORA_MAC="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD="$NYORA_MAC/build"
STAGING="$BUILD/dmg-staging"
APP_BUNDLE="$STAGING/Nyora.app"
DMG_OUT="$BUILD/Nyora.dmg"

# ── Architecture ──────────────────────────────────────────────────────────────
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "arm64" ]]; then
    JRE_ARCH="aarch64"
    SWIFT_TRIPLE="arm64-apple-macosx"
else
    JRE_ARCH="x64"
    SWIFT_TRIPLE="x86_64-apple-macosx"
fi

JRE_CACHE="$BUILD/jre-cache/$JRE_ARCH"

# ── Step 1: Download and cache Temurin 17 JRE ────────────────────────────────
download_jre() {
    if [[ -x "$JRE_CACHE/bin/java" ]]; then
        echo "✓ Cached JRE found ($JRE_ARCH)"
        return
    fi

    local url="https://api.adoptium.net/v3/binary/latest/17/ga/mac/${JRE_ARCH}/jre/hotspot/normal/eclipse"
    local tmp
    tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    echo "→ Downloading Adoptium Temurin 17 JRE (${JRE_ARCH})…"
    curl -L --progress-bar "$url" -o "$tmp/jre.tar.gz"

    echo "→ Extracting JRE…"
    tar -xzf "$tmp/jre.tar.gz" -C "$tmp"

    # Locate the java binary regardless of the exact directory layout in the archive.
    local java_bin
    java_bin=$(find "$tmp" -name "java" -type f 2>/dev/null | head -1)
    if [[ -z "$java_bin" ]]; then
        echo "ERROR: java binary not found in the downloaded archive" >&2
        exit 1
    fi

    # JRE home = directory that contains bin/java
    local jre_home
    jre_home=$(cd "$(dirname "$java_bin")/.." && pwd)

    mkdir -p "$(dirname "$JRE_CACHE")"
    cp -R "$jre_home" "$JRE_CACHE"

    # Strip docs and source to trim size (~35 MB saved)
    rm -f  "$JRE_CACHE/lib/src.zip"
    rm -rf "$JRE_CACHE/man"

    echo "✓ JRE cached at $JRE_CACHE ($(du -sh "$JRE_CACHE" | cut -f1))"
}

# ── Step 2: Build the fat helper JAR ─────────────────────────────────────────
build_jar() {
    echo "→ Building nyora-helper.jar…"
    cd "$NYORA_MAC"
    ./gradlew :shared:helperJar --quiet
    local jar="$NYORA_MAC/shared/build/libs/nyora-helper.jar"
    echo "✓ nyora-helper.jar built ($(du -sh "$jar" | cut -f1))"
}

# ── Step 3: Build the Swift app in release mode ───────────────────────────────
build_swift() {
    echo "→ Building Swift app (release)…"
    cd "$NYORA_MAC/macApp"
    swift build -c release
    echo "✓ Swift app built"
}

# ── Step 4: Assemble Nyora.app bundle ────────────────────────────────────────
assemble_app() {
    echo "→ Assembling Nyora.app…"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Resources"

    # Executable
    cp "$NYORA_MAC/macApp/.build/$SWIFT_TRIPLE/release/Nyora" \
       "$APP_BUNDLE/Contents/MacOS/Nyora"
    chmod +x "$APP_BUNDLE/Contents/MacOS/Nyora"

    # Info.plist
    cp "$NYORA_MAC/macApp/Nyora/SupportingFiles/Info.plist" \
       "$APP_BUNDLE/Contents/Info.plist"

    # Helper JAR
    cp "$NYORA_MAC/shared/build/libs/nyora-helper.jar" \
       "$APP_BUNDLE/Contents/Resources/nyora-helper.jar"

    # Bundled JRE — HelperLauncher.swift looks here first so users need no Java.
    echo "  Copying bundled JRE…"
    cp -R "$JRE_CACHE" "$APP_BUNDLE/Contents/Resources/jre"

    echo "✓ Nyora.app assembled ($(du -sh "$APP_BUNDLE" | cut -f1))"
}

# ── Step 5: Create the DMG ────────────────────────────────────────────────────
create_dmg() {
    echo "→ Creating DMG…"
    rm -f "$DMG_OUT"

    # Symlink so the installer window shows an Applications shortcut.
    ln -sfn /Applications "$STAGING/Applications"

    hdiutil create \
        -srcfolder "$STAGING" \
        -volname "Nyora" \
        -fs HFS+ \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$DMG_OUT"

    echo "✓ DMG created: $DMG_OUT ($(du -sh "$DMG_OUT" | cut -f1))"
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$BUILD"

download_jre
build_jar
build_swift
assemble_app
create_dmg

echo ""
echo "All done. Distribute: $DMG_OUT"
