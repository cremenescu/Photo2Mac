#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Photo2Mac — Copyright (c) 2026 Razvan Cremenescu
#
# Builds a self-contained .app + .dmg for distribution.
#
# Photo2Mac has no Homebrew dyld dependencies (Core Image / ImageIO /
# AppKit / SwiftUI are all Apple frameworks), so no install_name_tool
# walk is needed.
#
# Steps:
#  1. xcodebuild Release.
#  2. Sign Sparkle's nested helpers, then the app, with the Developer ID,
#     hardened runtime and a secure timestamp. No entitlements: the app needs
#     no runtime exception. Falls back to ad-hoc signing when the certificate
#     is not present.
#  3. Wrap into a drag-to-Applications .dmg.
#  4. Sign the .dmg, notarize it, staple the ticket and check it the way
#     Gatekeeper will on someone else's Mac. Skipped on ad-hoc builds.
#  5. Write the Sparkle appcast for this release (.dist/photo2mac-appcast.xml),
#     to be copied to cremenescu.ro/assets/. RELEASE_NOTES_HTML=<file> embeds
#     release notes in it.
#
# Usage: ./build/package.sh [version]
#   version defaults to v0.3.1-alpha
#
#   DEVELOPER_ID="-"   ad-hoc build, no Apple identity at all
#   SKIP_NOTARIZE=1    sign with the Developer ID but do not send it to Apple
#                      (local test builds only — do not publish the result)
#
# Notarization needs a stored keychain profile (default "vtun-notary"):
#   xcrun notarytool store-credentials vtun-notary \
#       --apple-id <apple-id> --team-id FU62DHV366 --password <app-password>

set -euo pipefail

VERSION="${1:-v0.3.1-alpha}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build-release"
DIST_DIR="$PROJECT_ROOT/.dist"
APP_NAME="Photo2Mac"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: Vtun Hardware SRL (FU62DHV366)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-vtun-notary}"

SIGN_MODE="adhoc"
if [ "$DEVELOPER_ID" != "-" ] && \
   security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
    SIGN_MODE="developer-id"
fi

cd "$PROJECT_ROOT"

echo "==> Cleaning previous output"
# Retry: a Finder window looking at one of these folders can drop a fresh
# .DS_Store into it while rm is still walking the tree.
rm -rf "$BUILD_DIR" "$DIST_DIR" 2>/dev/null || rm -rf "$BUILD_DIR" "$DIST_DIR"
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

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "==> Signing with $DEVELOPER_ID (hardened runtime)"
    # Sparkle.framework arrives ad-hoc signed from Xcode. Its XPC services and
    # helper tools must be re-signed with our identity, deepest first and the
    # framework last, or notarization rejects the nested code. No --deep: it
    # would strip the Downloader XPC's own entitlement. The versioned
    # directory is "B" (Sparkle's current framework version).
    SPARKLE_FW="$APP_DST/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        for item in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
            extra=()
            [ "$item" = "XPCServices/Downloader.xpc" ] && extra=(--preserve-metadata=entitlements)
            codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp \
                     ${extra[@]+"${extra[@]}"} "$SPARKLE_FW/Versions/B/$item"
        done
        codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$SPARKLE_FW"
    fi
    codesign --force --sign "$DEVELOPER_ID" --options runtime --timestamp "$APP_DST"
else
    echo "==> Developer ID not available — signing ad-hoc"
    codesign --force --deep --sign - --timestamp=none "$APP_DST"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DST"

echo "==> Creating $DMG_NAME"
DMG_STAGE="$DIST_DIR/dmg-stage"
mkdir -p "$DMG_STAGE"
cp -R "$APP_DST" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DIST_DIR/$DMG_NAME" >/dev/null
rm -rf "$DMG_STAGE"

if [ "$SIGN_MODE" = "developer-id" ]; then
    echo "==> Signing .dmg"
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DIST_DIR/$DMG_NAME"

    if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
        echo "==> SKIP_NOTARIZE=1 — signed, not notarized. Do NOT publish this .dmg."
        ls -lh "$DIST_DIR/$DMG_NAME"
        exit 0
    fi

    echo "==> Submitting to Apple notary service (this can take a few minutes)"
    if ! xcrun notarytool submit "$DIST_DIR/$DMG_NAME" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait; then
        echo "ERROR: notarization failed. Pull the log with:" >&2
        echo "  xcrun notarytool history --keychain-profile $NOTARY_PROFILE" >&2
        echo "  xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi

    echo "==> Stapling notarization ticket"
    xcrun stapler staple "$DIST_DIR/$DMG_NAME"

    echo "==> Verifying with Gatekeeper"
    spctl --assess --type open --context context:primary-signature -vv "$DIST_DIR/$DMG_NAME"

    # Sparkle appcast: generate_appcast signs the notarized DMG with the
    # EdDSA private key from the login keychain and writes the feed. The
    # enclosure points at this tag's GitHub release asset; the trailing slash
    # on the prefix is mandatory. It reads CFBundleVersion from the app inside
    # the DMG, so that must grow with every release. The file is named after
    # the SUFeedURL basename, so whatever xml it wrote is the feed.
    SPARKLE_BIN="$BUILD_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin"
    if [ -x "$SPARKLE_BIN/generate_appcast" ]; then
        echo "==> Generating Sparkle appcast"
        APPCAST_DIR="$DIST_DIR/appcast"
        rm -rf "$APPCAST_DIR"; mkdir -p "$APPCAST_DIR"
        cp "$DIST_DIR/$DMG_NAME" "$APPCAST_DIR/"
        NOTES_ARGS=()
        if [ -n "${RELEASE_NOTES_HTML:-}" ]; then
            cp "$RELEASE_NOTES_HTML" "$APPCAST_DIR/${DMG_NAME%.dmg}.html"
            NOTES_ARGS=(--embed-release-notes)
        fi
        "$SPARKLE_BIN/generate_appcast" ${NOTES_ARGS[@]+"${NOTES_ARGS[@]}"} \
            --download-url-prefix "https://github.com/cremenescu/Photo2Mac/releases/download/$VERSION/" \
            "$APPCAST_DIR"
        cp "$APPCAST_DIR"/*.xml "$DIST_DIR/photo2mac-appcast.xml"
        echo "    appcast -> $DIST_DIR/photo2mac-appcast.xml"
        echo "    Copy it to cremenescu.ro-site/public/assets/ and deploy (matches SUFeedURL)."
    else
        echo "WARN: generate_appcast not found at $SPARKLE_BIN — appcast NOT generated" >&2
    fi
fi

ls -lh "$DIST_DIR/$DMG_NAME"
echo "==> Done (sign mode: $SIGN_MODE)"
