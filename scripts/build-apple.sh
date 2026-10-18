#!/usr/bin/env bash
# Builds the Rust core for macOS and generates the Swift bindings into apple/Generated.
# The static library is universal: Apple silicon and Intel (#375).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/apple/Generated"
targets=(aarch64-apple-darwin x86_64-apple-darwin)
export MACOSX_DEPLOYMENT_TARGET="14.0"

installed="$(cd "$root/core" && rustup target list --installed)"
for target in "${targets[@]}"; do
    if ! grep -qx "$target" <<<"$installed"; then
        (cd "$root/core" && rustup target add "$target")
    fi
    cargo build --manifest-path "$root/core/Cargo.toml" --release --target "$target"
done

# Bindings are read from an unstripped debug build: the release profile strips
# the metadata symbols the generator looks for.
cargo build --manifest-path "$root/core/Cargo.toml"
rm -rf "$out"
mkdir -p "$out/lib"
# The generator runs `cargo metadata` in the current directory.
(cd "$root/core" && cargo run --quiet --features cli --bin uniffi-bindgen -- \
    generate --library target/debug/liblists_core.dylib --language swift --out-dir "$out")

# Swift finds a C module only under this exact file name.
mv "$out/lists_coreFFI.modulemap" "$out/module.modulemap"
libs=()
for target in "${targets[@]}"; do
    libs+=("$root/core/target/$target/release/liblists_core.a")
done
lipo -create -output "$out/lib/liblists_core.a" "${libs[@]}"
# One architecture per call: lipo refuses -verify_arch with several.
for arch in arm64 x86_64; do
    lipo "$out/lib/liblists_core.a" -verify_arch "$arch"
done
echo "apple: core and bindings are in $out"
