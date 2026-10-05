#!/usr/bin/env bash
# Builds Lists.app in Release and packs it into dist/Lists-<version>-macos-arm64.dmg.
#
# With a "Developer ID Application" certificate in the keychain the app and the
# disk image are signed with it, with the hardened runtime and a timestamp.
# When LISTS_NOTARY_KEY (path to an App Store Connect API key, .p8),
# LISTS_NOTARY_KEY_ID and LISTS_NOTARY_ISSUER_ID are set as well, the image is
# notarized and stapled. Without the certificate the build is signed ad hoc:
# Gatekeeper refuses it until the quarantine flag is removed, and the share
# extension does not work.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "${LISTS_SIGN_IDENTITY:-}" ]; then
    identities="$(security find-identity -v -p codesigning)"
    if [[ "$identities" == *'"Developer ID Application'* ]]; then
        LISTS_SIGN_IDENTITY="Developer ID Application"
    else
        LISTS_SIGN_IDENTITY="-"
    fi
fi
export LISTS_SIGN_IDENTITY

settings=()
if [ "$LISTS_SIGN_IDENTITY" != "-" ]; then
    # What notarization asks for: hardened runtime, a secure timestamp, and no
    # get-task-allow entitlement.
    settings=(ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi
"$root/scripts/build-apple-app.sh" Release ${settings[@]+"${settings[@]}"}

app="$root/apple/build/Build/Products/Release/Lists.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="$root/dist/Lists-$version-macos-arm64.dmg"

codesign --verify --deep --strict "$app"
if [ "$LISTS_SIGN_IDENTITY" != "-" ]; then
    for bundle in "$app" "$app/Contents/PlugIns/ListsShare.appex"; do
        signature="$(codesign --display --verbose=2 "$bundle" 2>&1)"
        if [[ "$signature" != *"(runtime)"* ]]; then
            echo "macos: $bundle is signed without the hardened runtime" >&2
            exit 1
        fi
    done
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Lists.app"
ln -s /Applications "$stage/Applications"
mkdir -p "$root/dist"
hdiutil create -quiet -volname "Lists" -srcfolder "$stage" -fs HFS+ -format ULMO -ov "$dmg"

if [ "$LISTS_SIGN_IDENTITY" = "-" ]; then
    echo "macos: ad hoc build, not notarized: $dmg"
    exit 0
fi
codesign --sign "$LISTS_SIGN_IDENTITY" --timestamp "$dmg"

if [ -z "${LISTS_NOTARY_KEY:-}" ]; then
    echo "macos: signed, not notarized (LISTS_NOTARY_KEY is not set): $dmg"
    exit 0
fi
result="$(xcrun notarytool submit "$dmg" --key "$LISTS_NOTARY_KEY" --key-id "$LISTS_NOTARY_KEY_ID" \
    --issuer "$LISTS_NOTARY_ISSUER_ID" --wait --output-format json)"
status="$(printf '%s' "$result" | plutil -extract status raw -o - -)"
if [ "$status" != "Accepted" ]; then
    echo "macos: notarization ended with '$status': $result" >&2
    exit 1
fi
xcrun stapler staple "$dmg"
echo "macos: signed and notarized: $dmg"
