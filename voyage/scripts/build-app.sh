#!/bin/bash
# Builds build/TokenVoyage.app. tokscale and the pixel font are fetched into the ignored .vendor/ on first run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/.vendor"
APP="$ROOT/build/TokenVoyage.app"
TOKSCALE_VERSION="4.21.0"
FONT_VERSION="2026.10.25"
FONT_FILE="fusion-pixel-12px-proportional-zh_hans.otf"

mkdir -p "$VENDOR"

if [[ ! -x "$VENDOR/tokscale/tokscale" ]]; then
  echo "Fetching tokscale $TOKSCALE_VERSION"
  TMP="$(mktemp -d)"
  (cd "$TMP" && npm pack --silent "@tokscale/cli-darwin-arm64@$TOKSCALE_VERSION" >/dev/null && tar xzf ./*.tgz)
  mkdir -p "$VENDOR/tokscale"
  cp "$TMP/package/bin/tokscale" "$TMP/package/bin/libFoundationModels.dylib" "$VENDOR/tokscale/"
  chmod +x "$VENDOR/tokscale/tokscale"
  rm -rf "$TMP"
fi

if [[ ! -f "$VENDOR/fonts/$FONT_FILE" ]]; then
  echo "Fetching Fusion Pixel font $FONT_VERSION"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/font.zip" "https://github.com/TakWolf/fusion-pixel-font/releases/download/$FONT_VERSION/fusion-pixel-font-12px-proportional-otf-v$FONT_VERSION.zip"
  unzip -q -o "$TMP/font.zip" -d "$TMP/font"
  mkdir -p "$VENDOR/fonts"
  cp "$TMP/font/$FONT_FILE" "$VENDOR/fonts/"
  find "$TMP/font" -maxdepth 2 -iname '*OFL*' -exec cp {} "$VENDOR/fonts/" \;
  rm -rf "$TMP"
fi

cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TokenVoyage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/tokscale" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/TokenVoyage"
cp -R "$(dirname "$BIN")/TokenVoyage_TokenVoyage.bundle" "$APP/Contents/Resources/"
cp -R "$ROOT/Content" "$APP/Contents/Resources/Content"
cp "$VENDOR/tokscale/"* "$APP/Contents/Resources/tokscale/"
cp "$VENDOR/fonts/"* "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Voyage</string>
  <key>CFBundleDisplayName</key><string>Voyage</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleIdentifier</key><string>local.tokenfrog.voyage</string>
  <key>CFBundleExecutable</key><string>TokenVoyage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/tokscale/libFoundationModels.dylib"
codesign --force --sign - "$APP/Contents/Resources/tokscale/tokscale"
codesign --force --sign - "$APP"
echo "Built $APP"
