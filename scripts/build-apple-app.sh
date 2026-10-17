#!/usr/bin/env bash
# Generates the Xcode project and builds Lists.app into apple/build.
# Usage: build-apple-app.sh [Debug|Release] [extra xcodebuild settings…]
#
# The share extension reads the same database as the app through an App Group,
# and a group needs a signing team. The certificate is the one named by
# LISTS_SIGN_IDENTITY ("Apple Development" by default), the team is taken from
# LISTS_TEAM_ID or from that certificate. Without one, or with
# LISTS_SIGN_IDENTITY=-, the app is signed ad hoc: it works, the share
# extension does not.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-Debug}"
shift || true

identity="${LISTS_SIGN_IDENTITY:-Apple Development}"
if [ "$identity" != "-" ] && [ -z "${LISTS_TEAM_ID:-}" ]; then
    LISTS_TEAM_ID="$(security find-certificate -c "$identity" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' || true)"
fi
if [ "$identity" != "-" ] && [ -n "${LISTS_TEAM_ID:-}" ]; then
    export LISTS_TEAM_ID LISTS_SIGN_IDENTITY="$identity"
else
    echo "apple: no signing team found, building with ad hoc signing" >&2
    export LISTS_TEAM_ID="" LISTS_SIGN_IDENTITY="-"
fi

"$root/scripts/build-apple.sh"
(cd "$root/apple" && xcodegen generate --quiet)
# The project is generated and not tracked, so the pins of the Swift packages are kept in
# apple/Package.resolved and put where Xcode reads them; a build that would resolve other
# versions stops instead.
swiftpm="$root/apple/Lists.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$swiftpm"
cp "$root/apple/Package.resolved" "$swiftpm/Package.resolved"
xcodebuild -project "$root/apple/Lists.xcodeproj" -scheme Lists -configuration "$config" \
    -derivedDataPath "$root/apple/build" -onlyUsePackageVersionsFromResolvedFile -quiet "$@" build
echo "apple: $root/apple/build/Build/Products/$config/Lists.app"
