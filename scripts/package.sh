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
#   WHISPEROID_SIGN_IDENTITY   required: the codesign identity's full name, or
#                              "-" for ad-hoc; signs the app (see build-app.sh)
#                              and the disk image
#   WHISPEROID_NOTARY_PROFILE  notarytool keychain profile name; enables
#                              notarisation and stapling when set. Black
#                              Meridian's own releases leave it unset: the
#                              studio's release_dmg lane notarises the image.
#   WHISPEROID_SKIP_TESTS      skip the test gate; for iterating on packaging
#                              itself, not for producing a release

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Whisperoid.app"
DIST="$ROOT/dist"
VOLUME="Whisperoid"

# Checked before the test gate, so a missing identity fails in seconds rather
# than after the tests.
if [[ -z "${WHISPEROID_SIGN_IDENTITY:-}" ]]; then
	echo "error: name the signing identity in WHISPEROID_SIGN_IDENTITY; see scripts/build-app.sh" >&2
	exit 1
fi
IDENTITY="$WHISPEROID_SIGN_IDENTITY"

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
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
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

# Signed by the app's identity, under the app's bundle ID rather than the
# file name, with a secure timestamp, which notarisation requires. A failure
# stops the script: an unsigned image of a signed app is not a release.
if [[ "$IDENTITY" != "-" ]]; then
	echo "==> signing disk image"
	codesign --force --timestamp --identifier "$BUNDLE_ID" --sign "$IDENTITY" "$DMG"
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
elif [[ "$SIGNED_BY" == Developer\ ID* ]]; then
	echo "Signed with Developer ID, not yet notarised. Notarise and staple it before"
	echo "distributing it: re-run with WHISPEROID_NOTARY_PROFILE set, or, for Black"
	echo "Meridian's releases, let the release_dmg lane do it, which it does next."
else
	echo "NOT notarised. Gatekeeper will refuse to open this on another Mac."
	echo "After dragging the app to Applications, the recipient runs once:"
	echo
	echo "    sudo xattr -dr com.apple.quarantine /Applications/Whisperoid.app"
	echo
	echo "To remove that step, sign with a Developer ID Application certificate and"
	echo "store notarytool credentials from an App Store Connect API key with:"
	echo
	echo "    xcrun notarytool store-credentials whisperoid \\"
	echo "        --key <path to AuthKey_KEYID.p8> --key-id <key ID> --issuer <issuer ID>"
	echo
	echo "then re-run with WHISPEROID_NOTARY_PROFILE=whisperoid."
fi
