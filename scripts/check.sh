#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
simulator_id=${STEER_SIMULATOR_ID:-$(xcrun simctl list devices available | sed -nE '/iPhone/s/.*\(([0-9A-F-]{36})\) \((Booted|Shutdown)\).*/\1/p' | head -n 1)}

if [ -z "$simulator_id" ]; then
    echo "No available iOS Simulator found." >&2
    exit 1
fi

"$root/scripts/check-git.sh"
"$root/scripts/check-upload.sh"
node --test "$root"/companion/test/*.test.mjs

cd "$root/ios"
xcodegen generate
xcodebuild -project Steer.xcodeproj -scheme Steer \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -skipPackageUpdates \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
