#!/usr/bin/env bash
# Mounts a disk image made by scripts/release-macos.sh and checks what is published, not the
# app it was packed from.
#
#   scripts/check-dmg.sh <dmg> adhoc|notarized [launch]
#
# adhoc: the app in the image passes `codesign --verify`; Gatekeeper refuses such a build by
# design, so it is not asked. notarized: the image and the app are accepted by Gatekeeper
# (`spctl`) and the image carries a stapled ticket. Both: the image holds Lists.app and the link
# to /Applications, and the version of the app is the one in the name of the image.
#
# launch: the app is started from the mounted image with `scripts/check-launch.sh … release`,
# which uses the data folder of the account: meant for a build machine, not for a Mac with
# Lists installed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dmg="${1:?usage: check-dmg.sh <dmg> adhoc|notarized [launch]}"
mode="${2:?usage: check-dmg.sh <dmg> adhoc|notarized [launch]}"
launch="${3:-}"
case "$mode" in
adhoc | notarized) ;;
*) echo "dmg: the mode is adhoc or notarized" >&2; exit 2 ;;
esac

mount="$(mktemp -d "${TMPDIR:-/tmp}/lists-dmg-XXXXXX")"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
trap 'hdiutil detach -quiet "$mount" || hdiutil detach -quiet -force "$mount"; rmdir "$mount"' EXIT
app="$mount/Lists.app"

fail() { echo "dmg: $1" >&2; exit 1; }
[ -d "$app" ] || fail "no Lists.app in $dmg"
[ "$(readlink "$mount/Applications")" = /Applications ] || fail "no link to /Applications in $dmg"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$(basename "$dmg")" == "Lists-$version-macos-"* ]] || fail "the app in $dmg has version $version"
codesign --verify --deep --strict "$app" || fail "the signature of the app in $dmg does not verify"

if [ "$mode" = notarized ]; then
    xcrun stapler validate -q "$dmg" || fail "$dmg has no stapled notarization ticket"
    spctl --assess --type open --context context:primary-signature -v "$dmg" ||
        fail "Gatekeeper refuses $dmg"
    spctl --assess --type execute -v "$app" || fail "Gatekeeper refuses the app in $dmg"
fi
echo "dmg: $mode, version $version: $dmg"

if [ "$launch" = launch ]; then
    "$root/scripts/check-launch.sh" "$app" release
fi
