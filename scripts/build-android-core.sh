#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Write lib/<abi> entries for one APK. Rely only on the NDK and rustup targets.
out=${1:?expected an absolute output directory}
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}}
if [[ ! -d "$sdk" && -d /opt/homebrew/share/android-commandlinetools ]]; then
  sdk=/opt/homebrew/share/android-commandlinetools
fi
ndk=${ANDROID_NDK_HOME:-"$sdk/ndk/27.1.12297006"}
case $(uname -s) in Darwin) host=darwin-x86_64 ;; Linux) host=linux-x86_64 ;; *) exit 2 ;; esac
bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
if [[ ! -x "$bin/clang" ]]; then echo 'Install NDK 27.1.12297006 or set ANDROID_NDK_HOME.' >&2; exit 1; fi
for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  case $abi in
    arm64-v8a) target=aarch64-linux-android ;;
    armeabi-v7a) target=armv7-linux-androideabi ;;
    x86_64) target=x86_64-linux-android ;;
    x86) target=i686-linux-android ;;
  esac
  clang_target=${target/armv7-linux/armv7a-linux}
  key=$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')
  env "CARGO_TARGET_${key}_LINKER=$bin/${clang_target}26-clang" \
    RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/builder -C link-arg=-Wl,-z,max-page-size=16384" \
    cargo build --locked --manifest-path Core/Cargo.toml --release --target "$target" --target-dir .build/rust
  mkdir -p "$out/$abi"
  "$bin/llvm-strip" --strip-unneeded -o "$out/$abi/libtrame_core.so" ".build/rust/$target/release/libtrame_core.so"
done
