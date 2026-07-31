#!/usr/bin/env bash
#
# Produces a distributable archive of Whisperoid.app in dist/.
#
# The archive is created with `ditto`, not `zip`: `zip` does not preserve the
# symlinks and extended attributes inside an .app bundle, which breaks the code
# signature on extraction.
#
# Gatekeeper on another Mac only accepts an app signed with a Developer ID
# Application certificate and notarised by Apple. Without one this script still
# produces a working archive, but the recipient must clear the quarantine flag
# by hand; the instructions are printed at the end.
#
# Environment:
#   WHISPEROID_SIGN_IDENTITY   codesign identity (passed through to build-app.sh)
#   WHISPEROID_NOTARY_PROFILE  notarytool keychain profile name; enables
#                              notarisation and stapling when set

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Whisperoid.app"
DIST="$ROOT/dist"

"$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
ARCHIVE="$DIST/Whisperoid-$VERSION.zip"

mkdir -p "$DIST"
rm -f "$ARCHIVE"

SIGNED_BY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

if [[ -n "${WHISPEROID_NOTARY_PROFILE:-}" ]]; then
	if [[ "$SIGNED_BY" != Developer\ ID* ]]; then
		echo "error: notarisation requires a Developer ID Application certificate." >&2
		echo "       the app is currently signed by: $SIGNED_BY" >&2
		exit 1
	fi

	echo "==> submitting for notarisation"
	ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
	xcrun notarytool submit "$ARCHIVE" \
		--keychain-profile "$WHISPEROID_NOTARY_PROFILE" --wait

	echo "==> stapling ticket"
	xcrun stapler staple "$APP"
	xcrun stapler validate "$APP"

	# Re-archive so the stapled ticket is inside the distributed copy.
	rm -f "$ARCHIVE"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

echo
echo "version:   $VERSION"
echo "signed by: $SIGNED_BY"
echo "archive:   $ARCHIVE"
echo "size:      $(du -h "$ARCHIVE" | cut -f1)"
echo

if [[ "$SIGNED_BY" == Developer\ ID* && -n "${WHISPEROID_NOTARY_PROFILE:-}" ]]; then
	echo "Notarised. The recipient can unzip and run it directly."
else
	echo "NOT notarised. Gatekeeper will refuse to open this on another Mac."
	echo "The recipient must run, once, after unzipping:"
	echo
	echo "    xattr -dr com.apple.quarantine /Applications/Whisperoid.app"
	echo
	echo "To remove that step, create a Developer ID Application certificate,"
	echo "store notarytool credentials with:"
	echo
	echo "    xcrun notarytool store-credentials whisperoid \\"
	echo "        --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>"
	echo
	echo "then re-run with WHISPEROID_NOTARY_PROFILE=whisperoid."
fi
