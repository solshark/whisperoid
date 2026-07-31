#!/usr/bin/env bash
#
# Builds and signs Whisperoid.app from the SwiftPM executable.
#
# SwiftPM cannot emit an .app bundle, so the binary is wrapped by hand. Signing
# uses a real certificate rather than an ad-hoc signature: an ad-hoc signature
# changes on every build, which invalidates the permissions macOS granted to the
# previous build and forces the microphone prompt to reappear each time.
#
# Environment:
#   CONFIG                     debug | release (default: release)
#   WHISPEROID_SIGN_IDENTITY   codesign identity to use

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Whisperoid.app"
ENTITLEMENTS="$ROOT/Resources/Whisperoid.entitlements"

# Prefer Developer ID when present: it is the only identity that Gatekeeper
# accepts on a Mac other than this one.
default_identity() {
	local developer_id
	developer_id="$(security find-identity -v -p codesigning 2>/dev/null \
		| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')"
	if [[ -n "$developer_id" ]]; then
		echo "$developer_id"
	else
		echo "Apple Development: redacted@example.com (REDACTED)"
	fi
}

IDENTITY="${WHISPEROID_SIGN_IDENTITY:-$(default_identity)}"

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
	# Drop any signature carried over from a previous build; these are
	# resource-only bundles and the app signature seals them.
	rm -rf "$APP/Contents/Resources/$(basename "$bundle")/_CodeSignature"
done
shopt -u nullglob

# The nested .bundle directories hold no Mach-O code, only localisations and
# JSON, so they are sealed as resources by the app signature. Signing them
# individually fails: swift-crypto's bundle has no Info.plist and codesign
# rejects it as a bundle.
codesign --force --options runtime --timestamp \
	--entitlements "$ENTITLEMENTS" \
	--sign "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP"

echo "identity: $IDENTITY"
echo "built:    $APP"
