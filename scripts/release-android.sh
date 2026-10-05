#!/usr/bin/env bash
# Builds the signed release APK into dist/Lists-<version>-android.apk.
#
# The keystore comes from LISTS_RELEASE_KEYSTORE and its password from
# LISTS_RELEASE_PASSWORD. On the maintainer's Mac both have defaults: the file
# $HOME/.local/share/lists/release.jks and the macOS Keychain item with service
# org.evsyukov.lists.release and account lists.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export LISTS_RELEASE_KEYSTORE="${LISTS_RELEASE_KEYSTORE:-$HOME/.local/share/lists/release.jks}"
if [ ! -f "$LISTS_RELEASE_KEYSTORE" ]; then
    echo "android: release keystore not found: $LISTS_RELEASE_KEYSTORE" >&2
    exit 1
fi
if [ -z "${LISTS_RELEASE_PASSWORD:-}" ]; then
    LISTS_RELEASE_PASSWORD="$(security find-generic-password -s org.evsyukov.lists.release -a lists -w)"
    export LISTS_RELEASE_PASSWORD
fi

"$root/scripts/build-android.sh"
(cd "$root/android" && ./gradlew --no-daemon --quiet assembleRelease)

version="$(sed -n 's/^ *versionName = "\(.*\)"/\1/p' "$root/android/app/build.gradle.kts")"
mkdir -p "$root/dist"
cp "$root/android/app/build/outputs/apk/release/app-release.apk" "$root/dist/Lists-$version-android.apk"
echo "android: $root/dist/Lists-$version-android.apk"
