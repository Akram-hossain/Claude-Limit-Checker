#!/bin/zsh
# Build Claude Meter.app — a menu bar meter for Claude usage limits.
set -e
cd "$(dirname "$0")"

APP="Claude Meter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# Universal binary: runs on Apple Silicon and Intel Macs
clang ClaudeMeter.m -fobjc-arc -O2 \
  -arch arm64 -arch x86_64 \
  -framework Cocoa -framework Security -framework ServiceManagement \
  -o "$APP/Contents/MacOS/ClaudeMeter"

cp Info.plist "$APP/Contents/Info.plist"

# For local use: ad-hoc signature. For distribution, set CODESIGN_ID to your
# "Developer ID Application: ..." identity (see dist.sh).
codesign --force --options runtime --sign "${CODESIGN_ID:--}" "$APP"

echo "Built: $PWD/$APP"
