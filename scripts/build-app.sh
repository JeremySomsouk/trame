#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tag=
http_host=
if [[ ${1:-} == --release ]]; then
  tag=${2:-}
  if [[ ! $tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo 'Usage: ./scripts/build-app.sh --release vX.Y.Z' >&2
    exit 2
  fi
  shift 2
elif [[ ${1:-} == --http-host ]]; then
  http_host=$(printf '%s' "${2:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
  if [[ ${#http_host} -gt 253 || ! $http_host =~ ^$label(\.$label)+$ ]]; then
    echo 'Usage: ./scripts/build-app.sh --http-host hostname (without scheme, port or credentials)' >&2
    exit 2
  fi
  shift 2
fi

mkdir -p dist
stage=$(mktemp -d dist/.package.XXXXXX)
scratch=
trap 'rm -rf "$stage"; if [[ -n $scratch ]]; then rm -rf "$scratch"; fi' EXIT
app="$stage/Trame.app"
contents="$app/Contents"
binary="$contents/MacOS/Trame"
mkdir -p "$contents/MacOS" "$contents/Resources"

build_product() {
  local architecture=$1
  shift
  TRAME_CORE_ARCH="$architecture" ./scripts/swift-with-core.sh build --build-system native -c release --product Trame "$@" >&2 || return 1
  swift build --build-system native -c release --show-bin-path "$@"
}

if [[ -n $tag ]]; then
  # SwiftPM embeds its resource bundle fallback path verbatim in the executable.
  scratch=$(mktemp -d /private/tmp/trame-build.XXXXXXXX)
  release_args=(--scratch-path "$scratch" -Xswiftc -file-prefix-map -Xswiftc "$(pwd -P)=/Trame")
  products=$(build_product arm64 "$@" "${release_args[@]}" --arch arm64)
  intel_products=$(build_product x86_64 "$@" "${release_args[@]}" --arch x86_64)
  lipo -create "$products/Trame" "$intel_products/Trame" -output "$binary"
  strip -S "$binary"
  if LC_ALL=C grep -aqF '/Users/' "$binary"; then
    echo 'Release executable contains a home-directory path.' >&2
    exit 1
  fi
  lipo "$binary" -verify_arch arm64
  lipo "$binary" -verify_arch x86_64
else
  products=$(build_product "$(uname -m)" "$@")
  cp "$products/Trame" "$binary"
fi

ditto "$products/Trame_TrameMedia.bundle" "$contents/Resources/Trame_TrameMedia.bundle"
cp macOS/Packaging/Info.plist "$contents/Info.plist"
if [[ -n $http_host ]]; then
  # ATS exception keys are literal DNS names, including their dots.
  /usr/libexec/PlistBuddy \
    -c 'Delete :NSAppTransportSecurity:NSAllowsArbitraryLoads' \
    -c 'Add :NSAppTransportSecurity:NSExceptionDomains dict' \
    -c "Add :NSAppTransportSecurity:NSExceptionDomains:$http_host dict" \
    -c "Add :NSAppTransportSecurity:NSExceptionDomains:$http_host:NSExceptionAllowsInsecureHTTPLoads bool true" \
    "$contents/Info.plist"
fi
mkdir -p "$contents/Frameworks"
ditto "$products/VLCKit.framework" "$contents/Frameworks/VLCKit.framework"
cp Shared/Licenses/LibVLC.txt "$contents/Resources/"
cp LICENSE "$contents/Resources/LICENSE"
python3 scripts/rust-notices.py aarch64-apple-darwin "$contents/Resources/Rust-crates.txt"
cp macOS/Packaging/Trame.icns "$contents/Resources/Trame.icns"
if [[ -n $tag ]]; then
  plutil -replace CFBundleShortVersionString -string "${tag#v}" "$contents/Info.plist"
  plutil -replace CFBundleVersion -string "${tag#v}" "$contents/Info.plist"
fi

codesign --force --sign - "$app"
codesign --verify --strict "$app"

if [[ -n $tag ]]; then
  archive="Trame-$tag-macOS-universal.zip"
  ditto -c -k --keepParent --norsrc "$app" "$stage/$archive"
  mv -f "$stage/$archive" "dist/$archive"
  echo "dist/$archive"
else
  rsync -a --checksum --delete "$app/" dist/Trame.app/
  echo "dist/Trame.app"
fi
