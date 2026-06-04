#!/bin/zsh
set -e
cd "$(dirname "$0")"

RELEASE=0
SIGN=0
NOTARIZE=0
for arg in "$@"; do
  case $arg in
    --release)  RELEASE=1 ;;
    --sign)     SIGN=1 ;;
    --notarize) NOTARIZE=1; SIGN=1 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="dist/HAR & PAC Analyzer.app"
PKG="dist/HAR & PAC Analyzer-${VERSION}.pkg"
PKG_SHA="${PKG}.sha256"
ZIP="dist/HAR & PAC Analyzer-${VERSION}.zip"
PLIST="Sources/pac-inspector-app/AppInfo.plist"
ICON="Sources/pac-inspector-app/AppIcon.icns"
ENTITLEMENTS="entitlements.plist"
APP_SIGN_IDENTITY="Developer ID Application: Rutherford County Schools (S6PHL8CDV2)"
PKG_SIGN_IDENTITY="Developer ID Installer: Rutherford County Schools (S6PHL8CDV2)"
NOTARY_PROFILE="ACNOTARY"

echo "Building v${VERSION}..."
if [[ $RELEASE -eq 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -v "^$"
  BIN=".build/apple/Products/Release/pac-inspector-app"
else
  swift build 2>&1 | grep -v "^$"
  BIN=".build/arm64-apple-macosx/debug/pac-inspector-app"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/pac-inspector-app"
cp "$PLIST" "$APP/Contents/Info.plist"
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon copied."
fi
cp "Sources/pac-inspector-app/Help.html" "$APP/Contents/Resources/Help.html"

if [[ $SIGN -eq 1 ]]; then
  echo "Signing app..."
  codesign --sign "$APP_SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    --force \
    --deep \
    "$APP"
  codesign --verify --deep --strict "$APP" && echo "App signature verified."

  echo "Building PKG installer..."
  rm -f "$PKG" "$PKG_SHA"
  pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --sign "$PKG_SIGN_IDENTITY" \
    "$PKG"
  echo "PKG created: $PKG"
fi

if [[ $NOTARIZE -eq 1 ]]; then
  echo "Submitting PKG to Apple notarization (this may take a few minutes)..."
  xcrun notarytool submit "$PKG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "Stapling notarization ticket to PKG..."
  xcrun stapler staple "$PKG"
  xcrun stapler validate "$PKG" && echo "PKG staple verified."

  echo "Generating SHA256..."
  shasum -a 256 "$PKG" > "$PKG_SHA"
  echo "$(cat "$PKG_SHA")"

  echo "Creating companion zip..."
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Distribution zip: $ZIP"
fi

echo ""
echo "Built: $APP"
[[ -f "$PKG" ]] && echo "Installer: $PKG"
[[ -f "$PKG_SHA" ]] && echo "Checksum:  $PKG_SHA"
