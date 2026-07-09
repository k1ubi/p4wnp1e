#!/bin/bash
# Cross-compile P4wnP1_service and P4wnP1_cli for the Raspberry Pi 4B (arm64).
#
# Unlike build_support/build.sh (the original Pi Zero W / armv6 build), this
# needs no special toolchain container. The backend has no cgo dependency
# (verified: `grep -rl 'import "C"'` across the whole tree returns nothing)
# and no GOARCH=arm64-specific issues remain after the pi4b-port changes, so
# any host with Go 1.22+ installed can cross-compile directly.
#
# The WebUI (build/webapp.js, build/webapp.js.map) is *not* rebuilt here. It's
# a GopherJS-compiled JavaScript blob - architecture independent - and already
# checked into the repo prebuilt. It only needs recompiling if proto/grpc.proto
# or the web_client/*.go GopherJS sources change, which is unrelated to a
# hardware port. See PORTING.md "WebUI" section if you do need to rebuild it.
#
# Usage: run from repo root: ./build_support/pi4b/build.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

echo "compiling P4wnP1_cli and P4wnP1_service for linux/arm64 (Raspberry Pi 4B) ..."
env GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o build/P4wnP1_service ./cmd/P4wnP1_service/
env GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o build/P4wnP1_cli ./cmd/P4wnP1_cli/

echo
file build/P4wnP1_service build/P4wnP1_cli 2>/dev/null || true

echo
echo "...Results stored in ./build directory"
echo
echo "On the Pi4B port the compiled files have to be placed at the following"
echo "locations (see build_support/pi4b/image/install.sh for the full list):"
echo
echo "    /usr/local/bin/P4wnP1_cli"
echo "    /usr/local/bin/P4wnP1_service"
echo "    /usr/local/P4wnP1/www/webapp.js       (already prebuilt, unchanged)"
echo "    /usr/local/P4wnP1/www/webapp.js.map   (already prebuilt, unchanged)"
