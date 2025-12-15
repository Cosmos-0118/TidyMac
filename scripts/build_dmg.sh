#!/usr/bin/env bash
set -euo pipefail

# Simple unsigned DMG builder for TidyMac
# Usage: ./scripts/build_dmg.sh

APP_NAME="TidyMac"
SCHEME="TidyMac"
CONFIG="Release"
DERIVED_DATA="build"
PRODUCT_PATH="$DERIVED_DATA/Build/Products/$CONFIG/$APP_NAME.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_ROOT="dmgroot"

# Clean previous outputs
rm -rf "$DERIVED_DATA" "$DMG_NAME" "$DMG_ROOT"
mkdir -p "$DERIVED_DATA"

echo "Building $APP_NAME ($CONFIG)..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath "$DERIVED_DATA" clean build

echo "Preparing DMG layout..."
mkdir -p "$DMG_ROOT"
cp -R "$PRODUCT_PATH" "$DMG_ROOT/"

echo "Creating DMG..."
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_NAME"

echo "Cleaning staging folders..."
rm -rf "$DMG_ROOT"

echo "Done. DMG at $DMG_NAME"
