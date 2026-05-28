#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Photo2Mac — Copyright (c) 2026 Razvan Cremenescu
#
# Builds a self-contained .app + .dmg for distribution.
#
# Photo2Mac has no Homebrew dyld dependencies (Core Image / ImageIO /
# AppKit / SwiftUI are all Apple frameworks), so no install_name_tool
# walk is needed. Just Release build + ad-hoc codesign + .dmg.
#
# Usage: ./build/package.sh [version]
#   version defaults to v0.1.0-alpha

set -euo pipefail

VERSION="${1:-v0.1.0-alpha}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build-release"
DIST_DIR="$PROJECT_ROOT/.dist"
APP_NAME="Photo2Mac"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

cd "$PROJECT_ROOT"

echo "==> Cleaning previous output"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "==> Regenerating Xcode project"
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
fi
rm -rf "${APP_NAME}.xcodeproj"
xcodegen generate

echo "==> Building Release"
xcodebuild \
    -project "${APP_NAME}.xcodeproj" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build >/dev/null

APP_SRC="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
APP_DST="$DIST_DIR/${APP_NAME}.app"

if [[ ! -d "$APP_SRC" ]]; then
    echo "ERROR: app bundle not produced at $APP_SRC" >&2
    exit 1
fi

echo "==> Copying .app to $DIST_DIR"
cp -R "$APP_SRC" "$APP_DST"

echo "==> Verifying no Homebrew/local dependencies"
LEAKS="$(otool -L "$APP_DST/Contents/MacOS/${APP_NAME}" | grep -E '/opt/homebrew/|/usr/local/' || true)"
if [[ -n "$LEAKS" ]]; then
    echo "ERROR: bundle linked to non-system dylibs:" >&2
    echo "$LEAKS" >&2
    exit 1
fi

echo "==> Re-signing ad-hoc"
codesign --force --deep --sign - --timestamp=none "$APP_DST"
codesign --verify --deep --strict "$APP_DST"

echo "==> Creating $DMG_NAME"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$APP_DST" \
    -ov \
    -format UDZO \
    "$DIST_DIR/$DMG_NAME" >/dev/null

ls -lh "$DIST_DIR/$DMG_NAME"

echo "==> Done."
echo
echo "Next:"
echo "  gh release create $VERSION \"$DIST_DIR/$DMG_NAME\" \\"
echo "      --title \"$VERSION — short description\" --notes-file CHANGELOG.md"
