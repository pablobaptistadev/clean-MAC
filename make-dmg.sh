#!/bin/bash
# Gera ~/Downloads/Limpo-<versão>.dmg a partir do app instalado em /Applications.
set -euo pipefail
APP="/Applications/Limpo.app"
[ -d "$APP" ] || { echo "Limpo não está instalado. Rode ./build-app.sh antes."; exit 1; }
VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
OUT="$HOME/Downloads/Limpo-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Limpo $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "✓ DMG: $OUT"
