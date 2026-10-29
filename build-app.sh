#!/bin/bash
# Compila o Limpo e ATUALIZA o app instalado em /Applications (sem deixar cópias).
# Uso: ./build-app.sh        → atualiza o app
#      ./build-app.sh --dmg  → atualiza e gera ~/Downloads/Limpo-<versão>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(date +%Y%m%d%H%M)"
TARGET="/Applications/Limpo.app"
STAGE="$(mktemp -d)/Limpo.app"

echo "→ Compilando Limpo $VERSION ($BUILD)…"
swift build -c release

mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/Limpo "$STAGE/Contents/MacOS/Limpo"

# Ícone
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for SZ in 16 32 128 256 512; do
  sips -z $SZ $SZ Resources/AppIcon.png --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
  sips -z $((SZ * 2)) $((SZ * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Limpo</string>
    <key>CFBundleDisplayName</key><string>Limpo</string>
    <key>CFBundleIdentifier</key><string>br.com.pablobaptista.limpo</string>
    <key>CFBundleExecutable</key><string>Limpo</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Assinatura: com o certificado "Limpo Dev" (Acesso às Chaves › Assistente de Certificado, tipo
# Assinatura de código) a identidade do app não muda entre versões e o macOS mantém as permissões.
# Sem ele, assinatura provisória: o macOS pede as permissões de novo a cada versão.
SIGN_ID="${LIMPO_SIGN_ID:-Limpo Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$STAGE"
  echo "→ Assinado com \"$SIGN_ID\" (permissões mantidas entre versões)"
else
  codesign --force --deep --sign - "$STAGE"
  echo "⚠ Certificado \"$SIGN_ID\" não encontrado: assinatura provisória (o macOS vai pedir as permissões de novo)"
fi

echo "→ Encerrando o Limpo aberto…"
pkill -x Limpo 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x Limpo >/dev/null || break; sleep 0.5; done
pkill -9 -x Limpo 2>/dev/null || true

echo "→ Atualizando $TARGET…"
rm -rf "$TARGET"
ditto "$STAGE" "$TARGET"
rm -rf "$(dirname "$STAGE")" "$(dirname "$ICONSET")"

# Remove cópias antigas que ficaram fora de /Applications e tira do registro do macOS
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
for OLD in "$(pwd)/build/Limpo.app" "$HOME/Downloads/Limpo/build/Limpo.app"; do
  [ -d "$OLD" ] && "$LSREGISTER" -u "$OLD" 2>/dev/null || true
done
rm -rf build
"$LSREGISTER" -f "$TARGET" 2>/dev/null || true

open "$TARGET"
echo "✓ Limpo $VERSION ($BUILD) instalado em $TARGET"

if [[ "${1:-}" == "--dmg" ]]; then
  ./make-dmg.sh
fi
