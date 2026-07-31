#!/usr/bin/env bash
#
# Builds Whisperoid.app from the SwiftPM executable.
#
# SwiftPM cannot emit an .app bundle, so the binary is wrapped by hand. Signing
# uses a real Apple Development identity rather than an ad-hoc signature: an
# ad-hoc signature changes on every build, which invalidates the Accessibility
# and Microphone permissions granted to the previous build.
#
# Override the identity with WHISPEROID_SIGN_IDENTITY if needed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Whisperoid.app"
IDENTITY="${WHISPEROID_SIGN_IDENTITY:-Apple Development: redacted@example.com (REDACTED)}"

swift build -c "$CONFIG" --package-path "$ROOT"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
BIN="$BIN_DIR/Whisperoid"

if [[ ! -x "$BIN" ]]; then
	echo "error: built binary not found at $BIN" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Whisperoid"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM emits dependency resources (e.g. KeyboardShortcuts localisations) as
# sibling .bundle directories; they must travel with the app.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	cp -R "$bundle" "$APP/Contents/Resources/"
done
shopt -u nullglob

codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose=2 "$APP"

echo "built: $APP"
