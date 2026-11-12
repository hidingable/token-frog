#!/bin/bash
# Builds build/Tokotoko.app. tokscale and the pixel font are fetched into the ignored .vendor/ on first run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/.vendor"
APP="$ROOT/build/Tokotoko.app"
TOKSCALE_VERSION="4.21.0"
FONT_VERSION="2026.10.25"
FONT_FILE="fusion-pixel-12px-proportional-zh_hans.otf"
TOKSCALE_SHA256="4258bcd6eb3127b46cc5dded07a592afba163edfdd496e97757cbb764b00d6e7"
FOUNDATION_MODELS_SHA256="5efe562d69f1d159f0cb257ad7d981046bb17677d4b30a8e621c1fa6bf7a6392"
FONT_SHA256="2972782f05d7dd5f8414bc0215f69c181561172286b1f9823b5c279d9e5e6674"
FONT_LICENSE_SHA256="bc518cf64b8032c07690f33cc270c35c179255a6ac8efa7c165ebae7e8f76a63"

# Pin extracted files: the same checks cover downloads and existing .vendor caches.
verify_sha256() {
  local file="$1" expected="$2" checksum
  if [[ ! -f "$file" ]]; then
    echo "Missing verified resource: $file" >&2
    return 1
  fi
  checksum="$(shasum -a 256 "$file")" || return 1
  if [[ "${checksum%% *}" != "$expected" ]]; then
    echo "SHA-256 mismatch: $file" >&2
    return 1
  fi
}

TMP=""
cleanup_temp() {
  if [[ -n "$TMP" ]]; then rm -rf "$TMP"; fi
}
trap cleanup_temp EXIT

mkdir -p "$VENDOR"

if [[ ! -e "$VENDOR/tokscale/tokscale" && ! -e "$VENDOR/tokscale/libFoundationModels.dylib" ]]; then
  echo "Fetching tokscale $TOKSCALE_VERSION"
  TMP="$(mktemp -d)"
  (cd "$TMP" && npm pack --silent "@tokscale/cli-darwin-arm64@$TOKSCALE_VERSION" >/dev/null && tar xzf ./*.tgz)
  verify_sha256 "$TMP/package/bin/tokscale" "$TOKSCALE_SHA256"
  verify_sha256 "$TMP/package/bin/libFoundationModels.dylib" "$FOUNDATION_MODELS_SHA256"
  mkdir -p "$VENDOR/tokscale"
  cp "$TMP/package/bin/tokscale" "$TMP/package/bin/libFoundationModels.dylib" "$VENDOR/tokscale/"
  chmod +x "$VENDOR/tokscale/tokscale"
  rm -rf "$TMP"
  TMP=""
fi
verify_sha256 "$VENDOR/tokscale/tokscale" "$TOKSCALE_SHA256"
verify_sha256 "$VENDOR/tokscale/libFoundationModels.dylib" "$FOUNDATION_MODELS_SHA256"

if [[ ! -e "$VENDOR/fonts/$FONT_FILE" && ! -e "$VENDOR/fonts/OFL.txt" ]]; then
  echo "Fetching Fusion Pixel font $FONT_VERSION"
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/font.zip" "https://github.com/TakWolf/fusion-pixel-font/releases/download/$FONT_VERSION/fusion-pixel-font-12px-proportional-otf-v$FONT_VERSION.zip"
  unzip -q -o "$TMP/font.zip" -d "$TMP/font"
  verify_sha256 "$TMP/font/$FONT_FILE" "$FONT_SHA256"
  verify_sha256 "$TMP/font/OFL.txt" "$FONT_LICENSE_SHA256"
  mkdir -p "$VENDOR/fonts"
  cp "$TMP/font/$FONT_FILE" "$VENDOR/fonts/"
  cp "$TMP/font/OFL.txt" "$VENDOR/fonts/"
  rm -rf "$TMP"
  TMP=""
fi
verify_sha256 "$VENDOR/fonts/$FONT_FILE" "$FONT_SHA256"
verify_sha256 "$VENDOR/fonts/OFL.txt" "$FONT_LICENSE_SHA256"

cd "$ROOT"
rm -rf "$ROOT/build/TokenVoyage.app"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/TokenVoyage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/tokscale" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/TokenVoyage"
cp -R "$(dirname "$BIN")/TokenVoyage_TokenVoyage.bundle" "$APP/Contents/Resources/"
cp -R "$ROOT/Content" "$APP/Contents/Resources/Content"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$VENDOR/tokscale/tokscale" "$VENDOR/tokscale/libFoundationModels.dylib" "$APP/Contents/Resources/tokscale/"
cp "$VENDOR/fonts/$FONT_FILE" "$VENDOR/fonts/OFL.txt" "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tokotoko</string>
  <key>CFBundleDisplayName</key><string>Tokotoko</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>CFBundleIdentifier</key><string>local.tokenfrog.voyage</string>
  <key>CFBundleExecutable</key><string>TokenVoyage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>VoyageHubURL</key><string>https://hub.zctd.tech</string>
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
