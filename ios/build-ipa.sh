#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$IOS_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/ios"
DIST_DIR="$ROOT_DIR/dist"
VERSION="4.0.0"
IPA_NAME="OpenSourceHub-iOS-${VERSION}-unsigned.ipa"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> [1/5] Generating iOS AppIcon asset catalog..."
swift "$IOS_DIR/generate-ios-icons.swift" "$IOS_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

echo "==> [2/5] Generating Xcode project via XcodeGen..."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Error: xcodegen not found. Install via: brew install xcodegen" >&2
  exit 1
fi
(cd "$IOS_DIR" && xcodegen generate)

echo "==> [3/5] Building Release arm64 iOS app (size-optimized -Osize + LTO)..."
xcodebuild \
  -project "$IOS_DIR/OpenSourceHub.xcodeproj" \
  -scheme OpenSourceHub \
  -configuration Release \
  -sdk iphoneos \
  -arch arm64 \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP_PATH="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/OpenSourceHub.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Built .app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> [4/5] Pruning & stripping .app bundle for minimal .ipa size..."
PAYLOAD_DIR="$BUILD_DIR/Payload"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
cp -R "$APP_PATH" "$PAYLOAD_DIR/OpenSourceHub.app"

# Remove any simulator/dev metadata if present
rm -rf \
  "$PAYLOAD_DIR/OpenSourceHub.app/_CodeSignature" \
  "$PAYLOAD_DIR/OpenSourceHub.app/embedded.mobileprovision" \
  "$PAYLOAD_DIR/OpenSourceHub.app/Frameworks/"*.dSYM \
  2>/dev/null || true

strip -x "$PAYLOAD_DIR/OpenSourceHub.app/OpenSourceHub" 2>/dev/null || true

echo "==> [5/5] Packaging compressed .ipa (maximum zip compression)..."
rm -f "$DIST_DIR/$IPA_NAME"
(cd "$BUILD_DIR" && zip -9 -y -r "$DIST_DIR/$IPA_NAME" Payload >/dev/null)

echo "==> Build complete!"
du -sh "$PAYLOAD_DIR/OpenSourceHub.app" "$DIST_DIR/$IPA_NAME"
ls -lh "$DIST_DIR/$IPA_NAME"
