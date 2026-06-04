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

APP="dist/HAR & PAC Analyzer.app"
PLIST="Sources/pac-inspector-app/AppInfo.plist"
ICON="Sources/pac-inspector-app/AppIcon.icns"
ENTITLEMENTS="entitlements.plist"
DEVELOPER_ID="Developer ID Application: Rutherford County Schools (S6PHL8CDV2)"
NOTARY_PROFILE="ACNOTARY"
VERSION="1.0"
ZIP="dist/HAR & PAC Analyzer-${VERSION}.zip"

echo "Building..."
if [[ $RELEASE -eq 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -v "^$"
  BIN=".build/apple/Products/Release/pac-inspector-app"
else
  swift build 2>&1 | grep -v "^$"
  BIN=".build/arm64-apple-macosx/debug/pac-inspector-app"
fi

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/pac-inspector-app"
cp "$PLIST" "$APP/Contents/Info.plist"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  echo "Icon copied."
fi

if [[ $SIGN -eq 1 ]]; then
  echo "Signing..."
  codesign --sign "$DEVELOPER_ID" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    --force \
    --deep \
    "$APP"
  codesign --verify --deep --strict "$APP" && echo "Signature verified."
fi

if [[ $NOTARIZE -eq 1 ]]; then
  echo "Creating zip for notarization..."
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "Submitting to Apple notarization (this may take a few minutes)..."
  xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP"

  echo "Recreating distribution zip with stapled app..."
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Distribution zip: $ZIP"
fi

echo "Built: $APP"
