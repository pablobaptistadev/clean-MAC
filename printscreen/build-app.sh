#!/bin/bash
# Compila o PrintScreen e ATUALIZA o app instalado em /Applications (sem deixar cópias).
# Uso: ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
TARGET="/Applications/PrintScreen.app"
STAGE="$(mktemp -d)/PrintScreen.app"

echo "→ Compilando PrintScreen $VERSION ($BUILD)…"
swift build -c release

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/PrintScreen "$STAGE/Contents/MacOS/PrintScreen"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PrintScreen</string>
    <key>CFBundleDisplayName</key><string>PrintScreen</string>
    <key>CFBundleIdentifier</key><string>br.com.pablobaptista.printscreen</string>
    <key>CFBundleExecutable</key><string>PrintScreen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Mesmo certificado do Limpo: com ele o macOS mantém a permissão de Gravação de Tela entre versões.
SIGN_ID="${LIMPO_SIGN_ID:-Limpo Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$STAGE"
  echo "→ Assinado com \"$SIGN_ID\" (permissões mantidas entre versões)"
else
  codesign --force --deep --sign - "$STAGE"
  echo "⚠ Certificado \"$SIGN_ID\" não encontrado: assinatura provisória (o macOS vai pedir a Gravação de Tela de novo)"
fi

echo "→ Encerrando o PrintScreen aberto…"
pkill -x PrintScreen 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x PrintScreen >/dev/null || break; sleep 0.5; done
pkill -9 -x PrintScreen 2>/dev/null || true

echo "→ Atualizando $TARGET…"
rm -rf "$TARGET"
ditto "$STAGE" "$TARGET"
rm -rf "$(dirname "$STAGE")"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" 2>/dev/null || true

open "$TARGET"
echo "✓ PrintScreen $VERSION ($BUILD) instalado em $TARGET"
