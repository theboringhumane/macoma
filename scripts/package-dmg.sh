#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Macoma.app"
SAVER="$BUILD/Macoma.saver"

for bundle in "$APP" "$SAVER"; do
  if [[ ! -d "$bundle" ]]; then
    echo "Missing release bundle: $bundle (run scripts/build.py first)" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$bundle"
done

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCH="$(uname -m)"
if [[ "$ARCH" != arm64 ]]; then
  echo "Expected an arm64 build host, got $ARCH" >&2
  exit 1
fi

ROOT_DIR="$(mktemp -d "$BUILD/dmg-root.XXXXXX")"
trap 'rm -rf "$ROOT_DIR"' EXIT
ditto "$APP" "$ROOT_DIR/Macoma.app"
ditto "$SAVER" "$ROOT_DIR/Macoma.saver"
ln -s /Applications "$ROOT_DIR/Applications"
cat > "$ROOT_DIR/README.txt" <<'EOF'
Macoma for Apple Silicon

Drag Macoma.app to Applications, then open it and choose Install Screensaver.
Alternatively, run this command in Terminal to install both bundles for your
current user (no administrator password required):

curl -fsSL https://raw.githubusercontent.com/theboringhumane/macoma/main/setup.sh | bash

This release is ad-hoc signed and not notarized. Gatekeeper may block launch.
Trusted public distribution requires a Developer ID certificate and Apple
notarization.
EOF

DMG="$BUILD/Macoma-macos-arm64.dmg"
hdiutil create -quiet -volname "Macoma $VERSION" -srcfolder "$ROOT_DIR" -ov -format UDZO "$DMG"
(cd "$BUILD" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Created $DMG"
echo "Created $DMG.sha256"
