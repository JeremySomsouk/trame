#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case ${1:-$(uname -m)} in
  arm64) target=aarch64-apple-darwin ;;
  x86_64) target=x86_64-apple-darwin ;;
  *) echo 'Expected arm64 or x86_64.' >&2; exit 2 ;;
esac
# Rust panic locations can include absolute paths to sources and Cargo dependencies.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${HOME}=/builder"
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --lib --manifest-path Core/Cargo.toml \
  --target-dir .build/rust --target "$target" >&2
echo "$PWD/.build/rust/$target/release"
