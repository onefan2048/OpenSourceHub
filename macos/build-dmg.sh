#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT_DIR/app"
MACOS_DIR="$ROOT_DIR/macos"
BUILD_DIR="$ROOT_DIR/build"
CACHE_DIR="$ROOT_DIR/build-cache"
DIST_DIR="$ROOT_DIR/dist"

APP_NAME="OpenSource Hub"
VERSION="1.0.0"
NODE_VERSION="v22.14.0"
NODE_TARBALL="$CACHE_DIR/node-${NODE_VERSION}-darwin-arm64.tar.xz"
NODE_BIN="$CACHE_DIR/node-${NODE_VERSION}-darwin-arm64"

APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
RES_DIR="$CONTENTS_DIR/Resources"
SERVER_DIR="$RES_DIR/server"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_OUTPUT="$DIST_DIR/OpenSourceHub-${VERSION}-arm64.dmg"

echo "==> [1/7] Preparing bundled Node.js ${NODE_VERSION} (darwin-arm64)..."
mkdir -p "$BUILD_DIR/tmp/modcache" "$CACHE_DIR" "$DIST_DIR"
if [[ ! -x "$NODE_BIN" ]]; then
  if [[ ! -f "$NODE_TARBALL" ]]; then
    curl -fSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-darwin-arm64.tar.xz" -o "$NODE_TARBALL"
  fi
  tar -xJf "$NODE_TARBALL" -C "$CACHE_DIR" "node-${NODE_VERSION}-darwin-arm64/bin/node"
  mv "$CACHE_DIR/node-${NODE_VERSION}-darwin-arm64/bin/node" "$NODE_BIN"
  rm -rf "$CACHE_DIR/node-${NODE_VERSION}-darwin-arm64"
  chmod +x "$NODE_BIN"
fi

echo "==> [2/7] Generating Prisma client (darwin-arm64) & building Next.js standalone..."
(
  cd "$APP_SRC"
  npx prisma generate
  NEXT_TELEMETRY_DISABLED=1 npm run build
)

echo "==> [3/7] Bundling background worker (worker.cjs)..."
ESBUILD_BIN="$APP_SRC/node_modules/.bin/esbuild"
"$ESBUILD_BIN" "$APP_SRC/src/worker/index.ts" \
  --bundle \
  --platform=node \
  --format=cjs \
  --target=node22 \
  --minify \
  --external:@prisma/client \
  --external:.prisma/client \
  --outfile="$BUILD_DIR/tmp/worker.cjs"

echo "==> [4/7] Creating pre-initialized empty SQLite template (hub-template.db)..."
rm -f "$BUILD_DIR/tmp/hub-template.db" "$BUILD_DIR/tmp/hub-template.db-shm" "$BUILD_DIR/tmp/hub-template.db-wal"
(
  cd "$APP_SRC"
  DATABASE_URL="file:$BUILD_DIR/tmp/hub-template.db" npx prisma db push --skip-generate
)

echo "==> [5/7] Compiling native macOS Swift shell & generating AppIcon.icns..."
if [[ ! -f "$BUILD_DIR/tmp/AppIcon.icns" ]]; then
  swift -module-cache-path "$BUILD_DIR/tmp/modcache" "$MACOS_DIR/generate-icon.swift" "$BUILD_DIR/tmp/AppIcon.iconset"
  iconutil -c icns "$BUILD_DIR/tmp/AppIcon.iconset" -o "$BUILD_DIR/tmp/AppIcon.icns"
fi
swiftc -O \
  -module-cache-path "$BUILD_DIR/tmp/modcache" \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework WebKit \
  "$MACOS_DIR/Sources/main.swift" \
  -o "$BUILD_DIR/tmp/OpenSourceHub"
strip -x "$BUILD_DIR/tmp/OpenSourceHub"

echo "==> [6/7] Assembling '${APP_NAME}.app' and pruning bloat..."
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS_DIR/MacOS" "$RES_DIR/bin" "$SERVER_DIR"

cp "$BUILD_DIR/tmp/OpenSourceHub" "$CONTENTS_DIR/MacOS/OpenSourceHub"
chmod +x "$CONTENTS_DIR/MacOS/OpenSourceHub"
cp "$MACOS_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BUILD_DIR/tmp/AppIcon.icns" "$RES_DIR/AppIcon.icns"
cp "$NODE_BIN" "$RES_DIR/bin/node"
chmod +x "$RES_DIR/bin/node"

# Copy Next.js standalone payload + static assets
cp -R "$APP_SRC/.next/standalone/." "$SERVER_DIR/"
mkdir -p "$SERVER_DIR/.next"
cp -R "$APP_SRC/.next/static" "$SERVER_DIR/.next/static"
if [[ -d "$APP_SRC/public" ]]; then
  cp -R "$APP_SRC/public" "$SERVER_DIR/public"
fi

# Ensure Prisma client + darwin-arm64 query engine are present
mkdir -p "$SERVER_DIR/node_modules/@prisma" "$SERVER_DIR/node_modules/.prisma"
cp -R "$APP_SRC/node_modules/@prisma/client" "$SERVER_DIR/node_modules/@prisma/"
cp -R "$APP_SRC/node_modules/.prisma/client" "$SERVER_DIR/node_modules/.prisma/"

# Copy worker, launcher, and SQLite template
cp "$BUILD_DIR/tmp/worker.cjs" "$SERVER_DIR/worker.cjs"
cp "$MACOS_DIR/launcher.cjs" "$SERVER_DIR/launcher.cjs"
cp "$BUILD_DIR/tmp/hub-template.db" "$SERVER_DIR/hub-template.db"

# Prune unnecessary files from server/node_modules to minimize bundle size
find "$SERVER_DIR/node_modules" -type f \( \
  -name "*.map" -o \
  -name "*.d.ts" -o \
  -name "*.d.mts" -o \
  -name "*.d.cts" -o \
  -name "*.md" -o \
  -name "*.markdown" -o \
  -name "LICENSE*" -o \
  -name "CHANGELOG*" -o \
  -name "HISTORY*" -o \
  -name "README*" -o \
  -name ".DS_Store" \
\) -delete 2>/dev/null || true

# Prune unused Prisma runtimes (edge, wasm, react-native, non-sqlite engines)
find "$SERVER_DIR/node_modules/@prisma/client/runtime" -type f \( \
  -name "*wasm*" -o \
  -name "*edge*" -o \
  -name "*react-native*" -o \
  -name "*binary*" -o \
  -name "*data-proxy*" \
\) -delete 2>/dev/null || true

# Remove non-darwin-arm64 Prisma engines or unused CLI binaries
find "$SERVER_DIR/node_modules/.prisma" -type f \( \
  -name "*debian*" -o \
  -name "*linux*" -o \
  -name "*windows*" -o \
  -name "*darwin.dylib*" -o \
  -name "schema-engine*" \
\) -delete 2>/dev/null || true

# Remove dev/build-only and unused packages if traced into standalone
# (images.unoptimized=true -> sharp/@img unused; native sqlite engine -> wasm/edge unused)
rm -rf \
  "$SERVER_DIR/node_modules/@next/swc-"* \
  "$SERVER_DIR/node_modules/@img" \
  "$SERVER_DIR/node_modules/sharp" \
  "$SERVER_DIR/node_modules/caniuse-lite" \
  "$SERVER_DIR/node_modules/typescript" \
  "$SERVER_DIR/node_modules/@types" \
  "$SERVER_DIR/node_modules/esbuild" \
  "$SERVER_DIR/node_modules/prisma" \
  "$SERVER_DIR/node_modules/.bin" \
  "$SERVER_DIR/node_modules/.prisma/client/"*wasm* \
  "$SERVER_DIR/node_modules/.prisma/client/"*edge* \
  "$SERVER_DIR/node_modules/.prisma/client/"*react-native* \
  "$SERVER_DIR/node_modules/.prisma/client/"*deno* \
  "$SERVER_DIR/.next/cache" \
  "$SERVER_DIR/data" \
  2>/dev/null || true

# Ad-hoc sign the app bundle
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Bundle size breakdown:"
du -sh "$APP_BUNDLE" "$CONTENTS_DIR/MacOS/OpenSourceHub" "$RES_DIR/bin/node" "$SERVER_DIR" "$SERVER_DIR/node_modules/.prisma" "$SERVER_DIR/.next"

echo "==> [7/7] Creating compressed macOS .dmg (ULMO / LZMA)..."
rm -rf "$DMG_STAGING" "$DMG_OUTPUT"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format ULMO \
  "$DMG_OUTPUT"

rm -rf "$DMG_STAGING"
echo "==> Done!"
ls -lh "$DMG_OUTPUT"
