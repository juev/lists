#!/usr/bin/env bash
# Checks that every place that carries the version agrees, and, when a version
# is given (with or without a leading "v"), that it is that one.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
expected="${1:-}"
expected="${expected#v}"

core="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/core/Cargo.toml" | head -1)"
web="$(sed -n 's/^version = "\(.*\)"/\1/p' "$root/web/Cargo.toml" | head -1)"
apple="$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$root/apple/project.yml")"
android="$(sed -n 's/^ *versionName = "\(.*\)"/\1/p' "$root/android/app/build.gradle.kts")"

status=0
for pair in "core/Cargo.toml=$core" "web/Cargo.toml=$web" "apple/project.yml=$apple" \
    "android/app/build.gradle.kts=$android"; do
    file="${pair%%=*}"
    version="${pair#*=}"
    if [ -z "$version" ] || [ "$version" != "${expected:-$core}" ]; then
        echo "version: $file has '$version', expected '${expected:-$core}'" >&2
        status=1
    fi
done

# The lockfiles carry the version of the crates too: a bump without a build
# leaves them behind, and `cargo build --locked` in the Dockerfile stops on it.
lock_version() { sed -n "/^name = \"$2\"\$/{n;s/^version = \"\(.*\)\"/\1/p;}" "$root/$1"; }
for pair in "core/Cargo.lock (lists-core)=$(lock_version core/Cargo.lock lists-core)" \
    "web/Cargo.lock (lists-core)=$(lock_version web/Cargo.lock lists-core)" \
    "web/Cargo.lock (lists-web)=$(lock_version web/Cargo.lock lists-web)"; do
    file="${pair%%=*}"
    version="${pair#*=}"
    if [ "$version" != "$core" ]; then
        echo "version: $file has '$version', expected '$core'; run cargo build" >&2
        status=1
    fi
done

# The build number goes up with every release, on both platforms alike: Android
# refuses to install an APK whose versionCode is lower than the installed one.
android_code() { sed -n 's/^ *versionCode = \([0-9]*\)$/\1/p'; }
apple_code() { sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p'; }
code="$(android_code < "$root/android/app/build.gradle.kts")"
apple_build="$(apple_code < "$root/apple/project.yml")"
if [ -z "$code" ] || [ "$code" != "$apple_build" ]; then
    echo "version: versionCode is '$code', CURRENT_PROJECT_VERSION is '$apple_build'; they must be the same number" >&2
    status=1
fi
tags="$(git -C "$root" tag --list 'v*')"
if [ -z "$tags" ]; then
    echo "version: no release tags in this clone, the build number is not compared with them" >&2
fi
for tag in $tags; do
    released="$(git -C "$root" show "$tag:android/app/build.gradle.kts" | android_code)"
    [ -n "$released" ] || continue
    if [ "${tag#v}" = "$core" ]; then
        if [ "$released" != "$code" ]; then
            echo "version: $tag has versionCode $released, the sources $code" >&2
            status=1
        fi
    elif [ -n "$code" ] && [ "$released" -ge "$code" ]; then
        echo "version: $tag already has versionCode $released; raise it above that" >&2
        status=1
    fi
done

# The install instructions name the image of this version, so that a new
# server syncs with the apps of the same release. A pre-release keeps them on
# the last release.
target="${expected:-$core}"
if [ "$target" != "${target%%-*}" ]; then
    [ "$status" -eq 0 ] && echo "version: $core"
    exit "$status"
fi
while IFS= read -r line; do
    file="${line%%:*}"
    version="${line##*:}"
    if [ "$version" != "${expected:-$core}" ]; then
        echo "version: $file names image '$version', expected '${expected:-$core}'" >&2
        status=1
    fi
done < <(cd "$root" && grep -o 'ghcr\.io/juev/lists:[0-9][^ `"]*' README.md docs/self-hosting.md)
readme="$(sed -n 's/^Version \(.*\)\. .*/\1/p' "$root/README.md")"
example="$(sed -n 's/^LISTS_VERSION=//p' "$root/.env.example")"
for pair in "README.md=$readme" ".env.example=$example"; do
    file="${pair%%=*}"
    version="${pair#*=}"
    if [ "$version" != "${expected:-$core}" ]; then
        echo "version: $file has '$version', expected '${expected:-$core}'" >&2
        status=1
    fi
done
[ "$status" -eq 0 ] && echo "version: $core"
exit "$status"
