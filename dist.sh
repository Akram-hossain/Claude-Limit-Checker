#!/bin/zsh
# Package Claude Meter for distribution to other users.
#
# Prerequisites (one-time):
#   1. Join the Apple Developer Program ($99/yr) and create a
#      "Developer ID Application" certificate in Xcode/developer.apple.com,
#      installed in your Keychain.
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials claude-meter \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Usage:
#   CODESIGN_ID="Developer ID Application: Your Name (TEAMID)" ./dist.sh
#
# Without CODESIGN_ID it still produces a zip, but other Macs will show the
# Gatekeeper warning (users must right-click > Open the first time).
set -e
cd "$(dirname "$0")"

VERSION=$(defaults read "$PWD/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
APP="Claude Meter.app"
ZIP="ClaudeMeter-$VERSION.zip"

./build.sh

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "$CODESIGN_ID" ]]; then
  echo "Submitting for notarization (requires stored profile 'claude-meter')..."
  xcrun notarytool submit "$ZIP" --keychain-profile claude-meter --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with stapled ticket
  echo "Notarized and stapled."
else
  echo "NOTE: unsigned build — recipients must right-click > Open on first launch."
fi

echo "Release artifact: $PWD/$ZIP"
