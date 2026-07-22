#!/bin/bash
# Nyora for macOS — one-line installer.
#
# This build is ad-hoc signed (not Apple-notarized), so a plain download gets
# Gatekeeper-quarantined and macOS shows "Nyora is damaged and can't be opened".
# This script installs the app and CLEARS that download quarantine, which lets the
# ad-hoc signature launch normally — no "damaged" / "unidentified developer" prompt.
#
#   curl -fsSL https://github.com/Nyora-Manga/nyora-mac/releases/latest/download/install.sh | bash
#
set -euo pipefail

APP="Nyora.app"
DEST="/Applications/$APP"
URL="https://github.com/Nyora-Manga/nyora-mac/releases/latest/download/Nyora-mac.tar.gz"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

printf '\n\033[1mNyora — macOS installer\033[0m\n'
echo "→ Downloading Nyora (~82 MB)…"
curl -fL# "$URL" -o "$TMP/Nyora.tar.gz"

echo "→ Quitting Nyora if it is running…"
osascript -e 'quit app "Nyora"' >/dev/null 2>&1 || true
sleep 1

echo "→ Installing to /Applications…"
if ! ( rm -rf "$DEST" && tar -xzf "$TMP/Nyora.tar.gz" -C "/Applications" ) 2>/dev/null; then
  echo "  (need elevated permission for /Applications)"; 
  sudo rm -rf "$DEST"; sudo tar -xzf "$TMP/Nyora.tar.gz" -C "/Applications"
fi

echo "→ Clearing download quarantine (this is what bypasses the 'damaged' warning)…"
xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || sudo xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
xattr -cr "$DEST" >/dev/null 2>&1 || true

if codesign --verify --deep --strict "$DEST" >/dev/null 2>&1; then
  echo "✓ Signature verified."
else
  echo "⚠ Signature check reported issues — the app should still open after this install."
fi

echo "✓ Installed. Launching Nyora…"
open "$DEST"
printf '\nDone — Nyora is in your Applications folder.\n'
