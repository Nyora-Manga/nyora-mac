#!/bin/bash
# build-dmg.sh — Assemble Nyora.app with a bundled JRE and create a distributable DMG.
#
# Usage (from anywhere inside the repo):
#   ./macApp/scripts/build-dmg.sh
#
# Outputs:
#   nyora-mac/build/Nyora.dmg   (~100 MB compressed, no Java install required by end-user)
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
    # Bake the OAuth client secret into the helper jar's resources so the
    # distributed DMG can complete Google sign-in (end-user Macs have no
    # env/.env.sync). Sourced from GOOGLE_CLIENT_SECRET or the local .env.sync;
    # the file is gitignored and never committed.
    local secret="${GOOGLE_CLIENT_SECRET:-$(grep -hs '^GOOGLE_CLIENT_SECRET=' "$NYORA_MAC/nyora-shared/.env.sync" "$NYORA_MAC/.env.sync" 2>/dev/null | head -1 | cut -d= -f2-)}"
    mkdir -p "$NYORA_MAC/nyora-shared/src/jvmMain/resources"
    printf 'GOOGLE_CLIENT_SECRET=%s\n' "$secret" > "$NYORA_MAC/nyora-shared/src/jvmMain/resources/nyora-oauth.properties"
    [ -z "$secret" ] && echo "⚠ GOOGLE_CLIENT_SECRET not found (env or .env.sync) — Google sign-in won't work in this build."

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

    # App icon (Info.plist's CFBundleIconFile points to "AppIcon")
    cp "$NYORA_MAC/macApp/Nyora/SupportingFiles/AppIcon.icns" \
       "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

    # Helper JAR
    cp "$NYORA_MAC/shared/build/libs/nyora-helper.jar" \
       "$APP_BUNDLE/Contents/Resources/nyora-helper.jar"

    # Bundled JRE — HelperLauncher.swift looks here first so users need no Java.
    echo "  Copying bundled JRE…"
    cp -R "$JRE_CACHE" "$APP_BUNDLE/Contents/Resources/jre"

    # SPM dependency resource bundles (GoogleSignIn UI / localized strings, etc.).
    for b in "$NYORA_MAC/macApp/.build/$SWIFT_TRIPLE/release/"*.bundle; do
        [ -d "$b" ] && cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
    done

    # Logo PNGs loaded via Bundle.main (see Image.bundleResource): SwiftPM here ships
    # a RAW Assets.xcassets (never compiled to Assets.car) and Bundle.module is broken
    # in the relocated .app, so the logos are shipped as loose files.
    cp "$NYORA_MAC/macApp/Nyora/NyoraApp/Assets.xcassets/NyoraLogo.imageset/nyora_logo.png" \
       "$APP_BUNDLE/Contents/Resources/NyoraLogo.png"
    cp "$NYORA_MAC/macApp/Nyora/NyoraApp/Assets.xcassets/GoogleG.imageset/google_g.png" \
       "$APP_BUNDLE/Contents/Resources/GoogleG.png"

    echo "✓ Nyora.app assembled ($(du -sh "$APP_BUNDLE" | cut -f1))"
}

# ── Step 4.5: Ad-hoc code-sign the bundle ─────────────────────────────────────
# An unsigned arm64 .app shows "Nyora is damaged and can't be opened" even after
# the user clears quarantine. Ad-hoc signing (deep) seals the whole bundle so it
# launches once allowed through Gatekeeper. The entitlements keep MLX's Metal JIT
# working under an ad-hoc signature. This is NOT Developer-ID/notarised — users
# still allow it once (right-click → Open / "Open Anyway" / clear quarantine).
sign_app() {
    echo "→ Ad-hoc code-signing Nyora.app…"
    local ent
    ent="$(mktemp)"
    cat > "$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key>                        <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key> <true/>
    <key>com.apple.security.cs.disable-library-validation</key>       <true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key> <true/>
</dict>
</plist>
PLIST
    codesign --force --deep --sign - --entitlements "$ent" "$APP_BUNDLE"
    rm -f "$ent"
    if codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
        echo "✓ Ad-hoc signed (codesign --verify passed)"
    else
        echo "⚠ codesign --verify reported issues (app should still run after the user allows it once)"
    fi
}

# ── Step 5: Create the DMG ────────────────────────────────────────────────────
create_dmg() {
    echo "→ Creating DMG…"
    rm -f "$DMG_OUT"
    # create-dmg adds its own Applications drop-link, so staging holds only the app.
    rm -f "$STAGING/Applications"

    if ! command -v create-dmg >/dev/null 2>&1; then
        echo "ERROR: create-dmg not found — install it with: brew install create-dmg" >&2
        exit 1
    fi

    # Detach any stale Nyora volume so create-dmg can mount cleanly.
    hdiutil detach "/Volumes/Nyora" -force >/dev/null 2>&1 || true

    local icns="$NYORA_MAC/macApp/Nyora/SupportingFiles/AppIcon.icns"
    create-dmg \
        --volname "Nyora" \
        --volicon "$icns" \
        --background "$SCRIPT_DIR/dmg-background.tiff" \
        --window-pos 200 120 \
        --window-size 640 420 \
        --icon-size 128 \
        --icon "Nyora.app" 160 210 \
        --hide-extension "Nyora.app" \
        --app-drop-link 480 210 \
        --no-internet-enable \
        "$DMG_OUT" \
        "$STAGING"

    echo "✓ DMG created: $DMG_OUT ($(du -sh "$DMG_OUT" | cut -f1))"
}

# ── Main ──────────────────────────────────────────────────────────────────────
mkdir -p "$BUILD"

download_jre
build_jar
build_swift
assemble_app
sign_app
create_dmg

echo ""
echo "All done. Distribute: $DMG_OUT"
