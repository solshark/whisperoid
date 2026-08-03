#!/usr/bin/env bash
#
# Produces a distributable disk image in dist/.
#
# The image contains the app alongside a symlink to /Applications, which is the
# conventional drag-to-install layout on macOS.
#
# Gatekeeper on another Mac only accepts an app signed with a Developer ID
# Application certificate and notarised by Apple. Without one this script still
# produces a working image, but the recipient must clear the quarantine flag by
# hand; the instructions are printed at the end.
#
# Environment:
#   WHISPEROID_SIGN_IDENTITY   codesign identity (passed through to build-app.sh)
#   WHISPEROID_NOTARY_PROFILE  notarytool keychain profile name; enables
#                              notarisation and stapling when set
#   WHISPEROID_SKIP_TESTS      skip the test gate; for iterating on packaging
#                              itself, not for producing a release

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Whisperoid.app"
DIST="$ROOT/dist"
VOLUME="Whisperoid"

# The tests gate the release. `set -e` is in force, so a failure here stops the
# script before anything is built or signed, and no disk image is produced from
# code that does not pass.
if [[ -n "${WHISPEROID_SKIP_TESTS:-}" ]]; then
	echo "warning: test gate skipped because WHISPEROID_SKIP_TESTS is set" >&2
else
	echo "==> running tests"
	swift test --package-path "$ROOT"
	echo
fi

"$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$DIST/Whisperoid-$VERSION.dmg"
SIGNED_BY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

mkdir -p "$DIST"
rm -f "$DMG"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> building disk image"
# HFS+ rather than APFS: an APFS image cannot be mounted by older macOS, and
# there is nothing here that benefits from APFS.
hdiutil create \
	-volname "$VOLUME" \
	-srcfolder "$STAGING" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	-quiet \
	"$DMG"

if [[ "$SIGNED_BY" != "-" && -n "$SIGNED_BY" ]]; then
	codesign --force --sign "${WHISPEROID_SIGN_IDENTITY:-$SIGNED_BY}" "$DMG" 2>/dev/null \
		|| echo "note: could not sign the disk image; the app inside is still signed"
fi

if [[ -n "${WHISPEROID_NOTARY_PROFILE:-}" ]]; then
	if [[ "$SIGNED_BY" != Developer\ ID* ]]; then
		echo "error: notarisation requires a Developer ID Application certificate." >&2
		echo "       the app is currently signed by: $SIGNED_BY" >&2
		exit 1
	fi

	echo "==> submitting for notarisation"
	xcrun notarytool submit "$DMG" --keychain-profile "$WHISPEROID_NOTARY_PROFILE" --wait

	echo "==> stapling ticket"
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
fi

echo
echo "version:   $VERSION"
echo "signed by: $SIGNED_BY"
echo "image:     $DMG"
echo "size:      $(du -h "$DMG" | cut -f1)"
echo

if [[ "$SIGNED_BY" == Developer\ ID* && -n "${WHISPEROID_NOTARY_PROFILE:-}" ]]; then
	echo "Notarised. The recipient can open the image and drag the app across."
else
	echo "NOT notarised. Gatekeeper will refuse to open this on another Mac."
	echo "After dragging the app to Applications, the recipient runs once:"
	echo
	echo "    sudo xattr -dr com.apple.quarantine /Applications/Whisperoid.app"
	echo
	echo "To remove that step, create a Developer ID Application certificate,"
	echo "store notarytool credentials with:"
	echo
	echo "    xcrun notarytool store-credentials whisperoid \\"
	echo "        --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>"
	echo
	echo "then re-run with WHISPEROID_NOTARY_PROFILE=whisperoid."
fi
