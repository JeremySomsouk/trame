#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
subcommand=${1:?expected build, run or test}
shift
./scripts/prepare-vlc.sh macos >/dev/null
TRAME_CORE_LIB_DIR=$(./scripts/build-core.sh "${TRAME_CORE_ARCH:-$(uname -m)}")
export TRAME_CORE_LIB_DIR
# SwiftPM does not track changes to an externally built static archive.
digest=$(shasum -a 256 "$TRAME_CORE_LIB_DIR/libtrame_core.a")
exec swift "$subcommand" -Xswiftc "-DTRAME_CORE_${digest%% *}" "$@"
