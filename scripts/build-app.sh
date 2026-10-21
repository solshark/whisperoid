#!/usr/bin/env bash
#
# Builds and signs Whisperoid.app from the SwiftPM executable.
#
# SwiftPM cannot emit an .app bundle, so the binary is wrapped by hand.
#
# The signing identity is always named by whoever builds: this script never
# picks one from the keychain, where it could pick another team's certificate.
# Prefer a real certificate to an ad-hoc signature: an ad-hoc signature changes
# on every build, which invalidates the permissions macOS granted to the
# previous build and makes the microphone prompt reappear each time.
#
# Environment:
#   CONFIG                     debug | release (default: release)
#   WHISPEROID_SIGN_IDENTITY   required: the codesign identity's full name, as
#                              `security find-identity -v -p codesigning`
#                              lists it, or "-" for an ad-hoc signature
#   WHISPEROID_KEEP_RECORDINGS 1 builds the debugging variant that keeps every
#                              recording and its transcript on disk; see
#                              RecordingArchive. Never distribute such a build.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Whisperoid.app"
ENTITLEMENTS="$ROOT/Resources/Whisperoid.entitlements"

if [[ -z "${WHISPEROID_SIGN_IDENTITY:-}" ]]; then
	echo "error: name the signing identity in WHISPEROID_SIGN_IDENTITY, for example" >&2
	echo "         WHISPEROID_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\"" >&2
	echo "       \`security find-identity -v -p codesigning\` lists the identities available." >&2
	echo "       Use \"-\" for an ad-hoc signature; macOS then asks for the microphone" >&2
	echo "       again after every build." >&2
	exit 1
fi
IDENTITY="$WHISPEROID_SIGN_IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
	echo "warning: ad-hoc signature; macOS will ask for the microphone again after every build" >&2
fi

# Built with xcodebuild rather than `swift build`.
#
# MLX, which runs the optional transcript cleanup, ships Metal shaders. SwiftPM
# on the command line cannot compile Metal at all, so a `swift build` product
# links and launches but dies on first use with "Failed to load the default
# metallib". xcodebuild drives this package directly — there is no .xcodeproj —
# and produces the shaders.
#
# -skipPackagePluginValidation is required because mlx-swift ships a CudaBuild
# plugin, and Xcode refuses to run package plugins unattended without it.
#
# `swift build` still works and is what the test suite runs under; it simply
# cannot produce a shippable app.
case "$CONFIG" in
	release) XCCONFIG="Release" ;;
	debug) XCCONFIG="Debug" ;;
	*) echo "error: CONFIG must be release or debug, got '$CONFIG'" >&2; exit 1 ;;
esac

DERIVED="$ROOT/.build/xcode"

CONDITIONS=()
if [[ "${WHISPEROID_KEEP_RECORDINGS:-}" == "1" ]]; then
	CONDITIONS=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) KEEP_RECORDINGS')
	echo "warning: building the debugging variant that keeps every recording on disk" >&2
fi

xcodebuild build \
	-scheme Whisperoid \
	-destination 'platform=macOS' \
	-derivedDataPath "$DERIVED" \
	-configuration "$XCCONFIG" \
	-skipPackagePluginValidation \
	-skipMacroValidation \
	${CONDITIONS[@]+"${CONDITIONS[@]}"} \
	>/dev/null

BIN_DIR="$DERIVED/Build/Products/$XCCONFIG"
BIN="$BIN_DIR/Whisperoid"

if [[ ! -x "$BIN" ]]; then
	echo "error: built binary not found at $BIN" >&2
	exit 1
fi

# MLX finds its Metal shaders by walking the loaded bundles and looking for
# mlx-swift_Cmlx.bundle inside each one's Resources directory. The generic
# .bundle copy below therefore places it correctly, and nothing further is
# needed — but if the shaders were never compiled the app builds happily and
# only fails at the moment the user first tries cleanup, so it is checked here.
METALLIB="$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ ! -f "$METALLIB" ]]; then
	echo "error: MLX Metal library not found at $METALLIB" >&2
	echo "       install the Metal compiler with: xcodebuild -downloadComponent MetalToolchain" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Whisperoid"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Shown in About, so the variant is never mistaken for a release.
if [[ "${WHISPEROID_KEEP_RECORDINGS:-}" == "1" ]]; then
	version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version-recordings" "$APP/Contents/Info.plist"
fi

# Referenced by CFBundleIconFile. Regenerate with scripts/make-icon.swift.
if [[ -f "$ROOT/Resources/Whisperoid.icns" ]]; then
	cp "$ROOT/Resources/Whisperoid.icns" "$APP/Contents/Resources/Whisperoid.icns"
else
	echo "warning: Resources/Whisperoid.icns missing; the app will have no icon" >&2
fi

# MIT and Apache 2.0 both require their notices to accompany binary
# distribution, so this has to be inside the bundle, not only in the repository.
# Regenerate with scripts/make-notices.py.
if [[ -f "$ROOT/Resources/THIRD-PARTY-NOTICES.txt" ]]; then
	cp "$ROOT/Resources/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt"
else
	echo "error: Resources/THIRD-PARTY-NOTICES.txt missing; run scripts/make-notices.py" >&2
	exit 1
fi

# SwiftPM emits dependency resources (e.g. KeyboardShortcuts localisations) as
# sibling .bundle directories; they must travel with the app.
#
# They go in Contents/Resources, which is the only placement a signed bundle
# permits: anything at the top level of the .app leaves "unsealed contents
# present in the bundle root" and the signature will not verify, symlinks
# included.
#
# Note that SwiftPM's generated Bundle.module accessor cannot find them there.
# It looks in Bundle.main.bundleURL — the .app directory itself — and otherwise
# falls back to a path hardcoded into the build machine's directory. Any
# dependency reading resources through that accessor will therefore work on this
# machine and call fatalError everywhere else. See Sources/Whisperoid/
# ShortcutRecorder.swift, which exists to avoid exactly that.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
	name="$(basename "$bundle")"
	rm -rf "$APP/Contents/Resources/$name"
	cp -R "$bundle" "$APP/Contents/Resources/$name"
	# Drop any signature carried over from a previous build; these are
	# resource-only bundles and the app signature seals them.
	rm -rf "$APP/Contents/Resources/$name/_CodeSignature"
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
