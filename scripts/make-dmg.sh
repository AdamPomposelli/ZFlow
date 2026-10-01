#!/bin/bash
# Builds ZFlow's installer disk image: the app beside a link to Applications,
# so installing is one drag. Uses only what ships with macOS — hdiutil and
# xattr — so it needs nothing installed and never asks to control the Finder.
#
#   scripts/make-dmg.sh <app bundle> <output .dmg> [volume name] [volume .icns]
#
# Writes <output .dmg>.sha256 beside it, for the release page.
set -euo pipefail

app=${1:?usage: make-dmg.sh <app bundle> <output .dmg> [volume name] [volume .icns]}
out=${2:?usage: make-dmg.sh <app bundle> <output .dmg> [volume name] [volume .icns]}
volname=${3:-$(basename "$app" .app)}
icon=${4:-}

[ -d "$app" ] || { echo "make-dmg: no app bundle at $app" >&2; exit 1; }

work=$(mktemp -d)
mountpoint="$work/mount"
cleanup() {
    hdiutil detach "$mountpoint" -quiet 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

staging="$work/staging"
mkdir -p "$staging"
# ditto, not cp: keeps signatures, symlinks inside frameworks, and extended
# attributes exactly as built.
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

# A writable image first, so the volume can be given its icon, then
# compressed into the image people download.
rw="$work/rw.dmg"
hdiutil create -quiet -fs APFS -volname "$volname" -srcfolder "$staging" -format UDRW "$rw"

if [ -n "$icon" ] && [ -f "$icon" ]; then
    mkdir -p "$mountpoint"
    hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$mountpoint" "$rw"
    cp "$icon" "$mountpoint/.VolumeIcon.icns"
    # The Finder shows a volume's own icon only when the root carries the
    # "has custom icon" flag: byte 8 of its FinderInfo, 0x04.
    xattr -wx com.apple.FinderInfo \
        "0000000000000000040000000000000000000000000000000000000000000000" "$mountpoint"
    hdiutil detach -quiet "$mountpoint"
fi

mkdir -p "$(dirname "$out")"
rm -f "$out" "$out.sha256"
hdiutil convert -quiet "$rw" -format ULFO -o "$out"
hdiutil verify -quiet "$out"

(cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256")
echo "Created $out ($(du -h "$out" | cut -f1 | tr -d ' '))"
