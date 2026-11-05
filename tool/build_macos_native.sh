#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-${HOME}/Library/Caches/LoongPass/native-macos}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"

libraries=()
for architecture in ${ARCHS:-$(uname -m)}; do
  case "$architecture" in
    arm64) rust_target=aarch64-apple-darwin ;;
    x86_64) rust_target=x86_64-apple-darwin ;;
    *) printf 'Unsupported macOS architecture %s\n' "$architecture" >&2; exit 1 ;;
  esac
  cargo build --locked --release \
    --manifest-path "$project_root/native/switch/Cargo.toml" \
    --target "$rust_target"
  libraries+=("$CARGO_TARGET_DIR/$rust_target/release/libloongpass_zcode_switch_candidate.a")
done

library_directory="$project_root/macos/ZcodeNative/lib"
mkdir -p "$library_directory"
temporary_library="$(mktemp "$library_directory/.loongpass-native.XXXXXX")"
trap 'rm -f "$temporary_library"' EXIT
xcrun lipo -create "${libraries[@]}" -output "$temporary_library"
mv "$temporary_library" "$library_directory/libloongpass_zcode_switch_candidate.a"
