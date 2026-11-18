#!/bin/bash
# Runs the unit tests (Swift Testing). Works with the Command Line Tools alone: the native build
# system does not add the Testing framework's folder by itself, so it is passed here.
set -euo pipefail
cd "$(dirname "$0")"
DEV=$(xcode-select -p)
FW="$DEV/Library/Developer/Frameworks"
[ -d "$FW/Testing.framework" ] || FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"
swift test --build-system native \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" -Xlinker -rpath -Xlinker "$FW" "$@"
