#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case ${1:?expected macos or android} in
  macos)
    version=3.7.3
    url="https://download.videolan.org/pub/cocoapods/prod/VLCKit-3.7.3-319ed2c0-79128878.tar.xz"
    digest=019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d ;;
  android)
    version=3.7.8
    url="https://repo.maven.apache.org/maven2/org/videolan/android/libvlc-all/$version/libvlc-all-$version.aar"
    digest=ee3392ee90b8dc36bee683191aed1c77a250e8329b8688630d05f8f9486ed726 ;;
  *) exit 2 ;;
esac

cache="$PWD/.build/vlc/$1-$version"
if [[ ! -d $cache ]]; then
  mkdir -p .build/vlc
  stage=$(mktemp -d "$PWD/.build/vlc/prepare.XXXXXXXX")
  trap 'rm -rf "$stage"' EXIT
  curl -fsSL --retry 3 "$url" -o "$stage/archive"
  (cd "$stage" && echo "$digest  archive" | shasum -a 256 -c - >&2)
  mkdir "$stage/package"
  if [[ $1 == macos ]]; then
    tar -xf "$stage/archive" -C "$stage" 'VLCKit - binary package/VLCKit.xcframework'
    mv "$stage/VLCKit - binary package/VLCKit.xcframework" "$stage/package/"
    framework="$stage/package/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
    install_name_tool -id '@rpath/VLCKit.framework/Versions/A/VLCKit' "$framework/VLCKit"
    codesign --force --sign - "$framework"
  else
    unzip -q "$stage/archive" -d "$stage/package"
  fi
  # Rename the completed directory as one unit, including for concurrent builds.
  python3 - "$stage/package" "$cache" <<'PY'
import os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError:
    if not os.path.isdir(sys.argv[2]):
        raise
PY
fi
echo "$cache"
