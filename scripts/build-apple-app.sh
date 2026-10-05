#!/usr/bin/env bash
# Generates the Xcode project and builds Lists.app into apple/build.
#
# The share extension reads the same database as the app through an App Group,
# and a group needs a signing team. The team is taken from LISTS_TEAM_ID or from
# the first "Apple Development" certificate in the keychain. Without one the
# app is signed ad hoc: it works, the share extension does not.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-Debug}"

if [ -z "${LISTS_TEAM_ID:-}" ]; then
    LISTS_TEAM_ID="$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' || true)"
fi
if [ -n "$LISTS_TEAM_ID" ]; then
    export LISTS_TEAM_ID LISTS_SIGN_IDENTITY="${LISTS_SIGN_IDENTITY:-Apple Development}"
else
    echo "apple: no signing team found, building with ad hoc signing" >&2
    export LISTS_TEAM_ID="" LISTS_SIGN_IDENTITY="-"
fi

"$root/scripts/build-apple.sh"
(cd "$root/apple" && xcodegen generate --quiet)
xcodebuild -project "$root/apple/Lists.xcodeproj" -scheme Lists -configuration "$config" \
    -derivedDataPath "$root/apple/build" -quiet build
echo "apple: $root/apple/build/Build/Products/$config/Lists.app"
