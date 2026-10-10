# Omarchy appearance source

The palette definitions in `themes/` are copied from
[`omacom/omarchy` at `77bfaca408d2993018d928e72cf84561480e5188`](https://github.com/omacom/omarchy/tree/77bfaca408d2993018d928e72cf84561480e5188),
the `quattro` branch as inspected on 2026-10-11. This is an exact development
revision, not a claim that the app follows the latest stable release. The
upstream MIT license is preserved in `LICENSE`; `SOURCE.json` records each
imported palette's source URL and SHA-256 checksum.

`Resources/Desktop/themes.json` contains 23 palettes. The 16 ANSI entries follow
the upstream Ghostty template: background, red, green, yellow, blue, magenta,
cyan, foreground, muted, the six bright accents, and bright foreground.
Selection and cursor colors follow `bin/omarchy-theme-color` and the template.
All imported palettes define these values; no arbitrary theme scripts are run.

`Resources/Desktop/wallpapers.json` contains metadata for 96 static images
(56,852,174 source bytes). It includes pinned HTTPS URLs, dimensions, expected
byte lengths, and Git blob hashes. **No upstream wallpaper image or preview is
bundled.** The app downloads selected images, or previews explicitly requested
with Load Previews, directly from that revision. It verifies the Git blob hash
and image dimensions before showing an image. The cache is limited to 64 MiB,
individual network responses to 8 MiB, imports to 32 MiB, and decoded inputs to
80 megapixels / 20,000 pixels per side. Thumbnails are generated locally.

The root MIT notice does not establish rights for every third-party photograph
or illustration. No per-image artwork license was verified. Source links are
provided for provenance; a source hash is not a copyright permission. Do not
describe these images as a redistributable Macoma artwork pack. The upstream
71 MP4 background intros are excluded: they are short theme/boot transitions,
not the normal static wallpaper picker.

Wallpaper application uses the public, main-thread AppKit
[`NSWorkspace.setDesktopImageURL`](https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:))
API. It targets all currently connected `NSScreen` objects, using display UUIDs
for the restore journal. The API does not select or enumerate other Spaces;
multi-Space behavior has not been qualified. Native dynamic HEIC schedules,
video wallpaper playback, and lock-screen replacement are not implemented.

Initialization and theme selection do not download images or modify the desktop.
An Apply action snapshots each display's wallpaper URL, crop/scaling options and
fill color, writes a recovery journal, then applies prepared local JPEG files.
A partial error triggers rollback of every attempted display. macOS does not
provide an atomic wallpaper transaction: if rollback also fails, the error names
unresolved displays and preserves their recovery state. Restore survives view
recreation and app relaunch and refuses to overwrite a subsequent external
wallpaper or crop change. Reapplying the same image preserves the original
restore receipt.

The evictable download cache is under `~/Library/Caches/Macarchy/Wallpapers`.
Applied images, imported images and the restore journal are retained under
`~/Library/Application Support/Macarchy/Appearance`; these files are not evicted
while macOS may still reference them as wallpaper.

Run `bash Tests/Appearance/run.sh` for deterministic palette, catalog and fake
desktop transaction checks. `--network` also fetches one small pinned WebP,
verifies and decodes it, and converts it to JPEG in an isolated temporary
directory. Neither command changes the actual desktop. Screens, Spaces,
reconnection, and live apply/restore still require end-to-end qualification.
