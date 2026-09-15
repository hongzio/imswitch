#!/usr/bin/env bash
# Build Imswitch.app into ./build. No Xcode required — Command Line Tools ship
# Carbon.framework, TextInputSources.h and the Swift module map.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${IMSWITCH_VERSION:-0.1.0}"
APP="build/Imswitch.app"

# The version ends up in Info.plist. Validate it instead of trusting it: it used
# to be interpolated into a sed program, where a value with escaped slashes could
# inject arbitrary plist keys — an LSEnvironment/DYLD_INSERT_LIBRARIES pair, say
# — while leaving CFBundleShortVersionString looking perfectly normal.
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]]; then
	echo "build.sh: refusing IMSWITCH_VERSION '$VERSION' (allowed: [0-9A-Za-z.+-])" >&2
	exit 1
fi
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Deliberately no -swift-version 6: the termination handler is a
# @convention(c) closure reading a global, which strict concurrency rejects.
swiftc -O -sdk "$SDK" \
	-framework Cocoa -framework Carbon \
	-o "$APP/Contents/MacOS/imswitch" \
	Sources/*.swift

# plutil, not sed: -replace -string treats the value as data and escapes it,
# so the version cannot become markup.
cp Info.plist.in "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# --options runtime turns on the hardened runtime, which ignores
# DYLD_INSERT_LIBRARIES and enforces library validation. Ad-hoc signing gives no
# authenticity, but this at least removes dylib injection as a way in.
codesign --force --options runtime --sign - "$APP"

echo "built $APP (version ${VERSION})"
