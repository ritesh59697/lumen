#!/bin/bash
#
# Builds a release .dmg for Apple Silicon.
#
# Two things here are not just plumbing:
#
#   1. AppleDouble stripping. FFmpegKit ships its frameworks with `._*`
#      resource-fork files inside them. Those sit unsealed in each framework
#      root, which breaks the code signature ("unsealed contents present in
#      the root directory of an embedded framework") and can make macOS
#      refuse the app outright rather than merely warn about it. They are
#      metadata artifacts, safe to delete.
#
#   2. arm64 only. whisper_ggml_plus excludes ggml's x86 sources in its
#      podspec, so an Intel slice cannot link. See macos/Podfile.
#
set -euo pipefail

VERSION="$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')"
APP_SRC="build/macos/Build/Products/Release/lumen.app"

# Unversioned filename on purpose. The landing page links to
# releases/latest/download/Lumen-arm64.dmg, which resolves to the newest
# release — but only if the asset name stays constant. Putting the version
# in the filename would silently break that link on every release. The
# version still ships inside the app bundle and in the release tag.
DMG="dist/Lumen-arm64.dmg"
STAGE="$(mktemp -d)/dmg"

cleanup() { rm -rf "$(dirname "$STAGE")"; }
trap cleanup EXIT

echo "==> Building release (arm64)"
flutter build macos --release

[ -d "$APP_SRC" ] || { echo "Build produced no app bundle"; exit 1; }

echo "==> Staging"
mkdir -p "$STAGE" dist
cp -R "$APP_SRC" "$STAGE/Lumen.app"

echo "==> Stripping AppleDouble files from bundled frameworks"
find "$STAGE/Lumen.app" -name '._*' -delete
# Also drop the extended attributes that regenerate them on copy.
xattr -cr "$STAGE/Lumen.app"

echo "==> Re-signing"
# Ad-hoc: without a paid Apple Developer certificate the app cannot be
# notarized, so users get a Gatekeeper prompt on first launch and must
# right-click -> Open. A valid signature still matters — it keeps macOS
# from refusing the app for a *broken* signature, which is a harder failure.
codesign --force --deep --sign - "$STAGE/Lumen.app"

echo "==> Verifying signature"
codesign --verify --deep --strict "$STAGE/Lumen.app"

ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "Lumen" \
  -srcfolder "$STAGE" \
  -ov -format UDZO -imagekey zlib-level=9 \
  "$DMG" >/dev/null

hdiutil verify "$DMG" >/dev/null

echo
echo "Built $DMG — version $VERSION ($(du -h "$DMG" | cut -f1))"
echo
echo "Attach this file to the GitHub release as-is. The landing page links to"
echo "releases/latest/download/Lumen-arm64.dmg, so the name must not change."
