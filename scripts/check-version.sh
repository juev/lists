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
[ "$status" -eq 0 ] && echo "version: $core"
exit "$status"
