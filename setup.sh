#!/bin/bash
set -euo pipefail

RELEASE_BASE="https://github.com/theboringhumane/macoma/releases/latest/download"
DMG_NAME="Macoma-macos-arm64.dmg"
SUPPORT="$HOME/Library/Application Support/Macarchy"
BACKUPS="$SUPPORT/Backups"

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Macoma currently requires an Apple Silicon Mac." >&2
  exit 1
fi
for tool in curl hdiutil ditto codesign shasum; do
  command -v "$tool" >/dev/null || { echo "Required macOS tool missing: $tool" >&2; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macoma-install.XXXXXX")"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == 1 ]]; then hdiutil detach "$MOUNT" -quiet || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

curl --fail --location --silent --show-error "$RELEASE_BASE/$DMG_NAME" -o "$WORK/$DMG_NAME"
curl --fail --location --silent --show-error "$RELEASE_BASE/$DMG_NAME.sha256" -o "$WORK/$DMG_NAME.sha256"
(cd "$WORK" && shasum -a 256 -c "$DMG_NAME.sha256")
hdiutil attach "$WORK/$DMG_NAME" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
MOUNTED=1

bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"; }
install_bundle() {
  local source="$1" destination="$2" expected="$3" name staging backup
  name="$(basename "$destination")"
  [[ -d "$source" ]] || { echo "DMG is missing $name" >&2; return 1; }
  [[ "$(bundle_id "$source")" == "$expected" ]] || { echo "Unexpected bundle identity for $name" >&2; return 1; }
  codesign --verify --deep --strict "$source"
  mkdir -p "$(dirname "$destination")"
  staging="$(dirname "$destination")/.$name.$$.staging"
  if ! ditto "$source" "$staging"; then
    rm -rf "$staging"
    echo "Could not stage $name; installed copy was not changed." >&2
    return 1
  fi
  if [[ -e "$destination" ]]; then
    if [[ "$(bundle_id "$destination")" != "$expected" ]]; then
      rm -rf "$staging"
      echo "Another app owns $destination; leaving it untouched." >&2
      return 1
    fi
    mkdir -p "$BACKUPS"
    backup="$BACKUPS/$(date -u +%Y%m%dT%H%M%SZ)-$name"
    mv "$destination" "$backup"
    echo "Previous $name saved to $backup"
  fi
  if ! mv "$staging" "$destination"; then
    if [[ -n "${backup:-}" ]]; then mv "$backup" "$destination"; fi
    rm -rf "$staging"
    echo "Could not install $name; previous copy was restored when available." >&2
    return 1
  fi
  echo "Installed $destination"
}

APP_DEST="$HOME/Applications/Macoma.app"
SAVER_DIR="$HOME/Library/Screen Savers"
LEGACY_SAVER="$SAVER_DIR/Macarchy.saver"
SAVER_DEST="$SAVER_DIR/Macoma.saver"
if [[ -d "$LEGACY_SAVER" ]] && [[ "$(bundle_id "$LEGACY_SAVER")" == "dev.theboring.macarchy.screensaver" ]]; then
  SAVER_DEST="$LEGACY_SAVER"
fi
install_bundle "$MOUNT/Macoma.app" "$APP_DEST" "dev.theboring.macarchy"
install_bundle "$MOUNT/Macoma.saver" "$SAVER_DEST" "dev.theboring.macarchy.screensaver"
hdiutil detach "$MOUNT" -quiet
MOUNTED=0
echo "Macoma installed. Open it from ~/Applications, then select Macoma in System Settings → Wallpaper → Screen Saver."
echo "Ad-hoc signed builds may be blocked by Gatekeeper. Do not bypass that warning unless you trust this release."
