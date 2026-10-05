#!/usr/bin/env bash
# Builds the Rust core for Android and generates the Kotlin bindings.
# Needs: an Android NDK under $ANDROID_HOME/ndk, the Rust targets
# aarch64-linux-android and x86_64-linux-android, and cargo-ndk.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    ANDROID_NDK_HOME="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -1)"
fi
[ -d "${ANDROID_NDK_HOME:-}" ] || { echo "android: no NDK found under $ANDROID_HOME/ndk" >&2; exit 1; }
export ANDROID_NDK_HOME

app="$root/android/app/src/main"
(cd "$root/core" && cargo ndk -t arm64-v8a -t x86_64 --platform 26 -o "$app/jniLibs" build --release)

# Bindings are read from an unstripped host build, as on the Apple side.
case "$(uname -s)" in
    Darwin) hostlib="liblists_core.dylib" ;;
    *) hostlib="liblists_core.so" ;;
esac
(cd "$root/core" && cargo build && cargo run --quiet --features cli --bin uniffi-bindgen -- \
    generate --library "target/debug/$hostlib" --language kotlin --no-format --out-dir "$app/java")
echo "android: core is in $app/jniLibs, bindings in $app/java/uniffi"
