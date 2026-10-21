#!/bin/zsh

set -euo pipefail

# Resolve all source and output paths from the script location so builds are reproducible.
ROOT_DIR="${0:A:h}"
BUILD_ROOT="/tmp/codex-quota-build"
APP_NAME="Codex Quota.app"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
ARCHITECTURE="$(uname -m)"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-InputHoldSwitcher Local Code Signing}"

# Keep compiler intermediates outside the repository and replace only this app's output bundle.
rm -rf "$BUILD_ROOT" "$APP_BUNDLE"
mkdir -p "$BUILD_ROOT" "$MACOS_DIR"

# Compile the zero-dependency AppKit executable for the current Mac architecture.
xcrun swiftc \
  -swift-version 5 \
  -O \
  -whole-module-optimization \
  -target "$ARCHITECTURE-apple-macosx13.0" \
  -framework AppKit \
  -framework Foundation \
  -framework ServiceManagement \
  -framework UserNotifications \
  -o "$MACOS_DIR/CodexQuota" \
  "$ROOT_DIR"/Sources/CodexQuota/*.swift

# Copy static bundle metadata without introducing generated project files.
/usr/bin/ditto "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

# Prefer the user's stable local identity and fall back to ad-hoc signing only when unavailable.
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "$SIGNING_IDENTITY"; then
  SIGNING_IDENTITY="-"
fi
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign "$SIGNING_IDENTITY" \
  "$APP_BUNDLE"

# Fail the build when bundle metadata or the resulting code signature is invalid.
/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
