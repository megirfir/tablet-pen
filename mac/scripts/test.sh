#!/bin/sh
# Runs the Swift tests. With only Command Line Tools (no Xcode), Swift Testing lives outside
# the default search paths, so add them explicitly.
cd "$(dirname "$0")/.."
D="$(xcode-select -p)"
if [ -d "$D/Library/Developer/Frameworks/Testing.framework" ]; then
  F="$D/Library/Developer/Frameworks"; L="$D/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F"$F" -Xswiftc -I"$L" -Xlinker -F"$F" -Xlinker -L"$L" \
    -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
