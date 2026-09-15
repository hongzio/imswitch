#!/usr/bin/env bash
# Build Imswitch.app into ./build. No Xcode required — Command Line Tools ship
# Carbon.framework, TextInputSources.h and the Swift module map.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${IMSWITCH_VERSION:-0.1.0}"
APP="build/Imswitch.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Deliberately no -swift-version 6: the termination handler is a
# @convention(c) closure reading a global, which strict concurrency rejects.
swiftc -O -sdk "$SDK" \
	-framework Cocoa -framework Carbon \
	-o "$APP/Contents/MacOS/imswitch" \
	Sources/*.swift

sed "s/@VERSION@/${VERSION}/g" Info.plist.in > "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"

echo "built $APP (version ${VERSION})"
