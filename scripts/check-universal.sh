#!/usr/bin/env bash
# Checks that every binary of Lists.app runs on Apple silicon and on Intel (#375):
# the app, the share extension and the helper of quick entry.
# Usage: check-universal.sh path/to/Lists.app
set -euo pipefail

app="${1:?usage: check-universal.sh path/to/Lists.app}"
for binary in "$app/Contents/MacOS/Lists" \
    "$app/Contents/PlugIns/ListsShare.appex/Contents/MacOS/ListsShare" \
    "$app/Contents/Library/LoginItems/ListsHelper.app/Contents/MacOS/ListsHelper"; do
    # One architecture per call: lipo refuses -verify_arch with several.
    for arch in arm64 x86_64; do
        if ! lipo "$binary" -verify_arch "$arch"; then
            echo "universal: $binary holds $(lipo -archs "$binary"), not arm64 and x86_64" >&2
            exit 1
        fi
    done
done
echo "universal: $app runs on arm64 and x86_64"
