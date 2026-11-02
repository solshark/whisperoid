#!/usr/bin/env bash
#
# Fails when the app's binary is not built the way a release should be:
#
#   - it carries profiling or coverage data (__llvm_prf_* or __llvm_cov*
#     sections), which Xcode adds to a package build unless told not to;
#   - LC_BUILD_VERSION records an SDK other than the one this Mac builds with,
#     so macOS would run the app with that older SDK's behaviour;
#   - LC_BUILD_VERSION's minimum macOS differs from LSMinimumSystemVersion in
#     the app's Info.plist, so the declared minimum is not the one compiled in.
#
# scripts/build-app.sh explains the first two. Run after it, with the same SDK.
#
# Usage: scripts/check-release-binary.sh <Whisperoid.app>

set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
	echo "usage: $0 <app bundle>" >&2
	exit 2
fi

PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
BIN="$APP/Contents/MacOS/$EXECUTABLE"

# "27.0" and "27" are the same version; vtool prints one, plists the other.
normalise() {
	local version="$1"
	while [[ "$version" == *.0 ]]; do
		version="${version%.0}"
	done
	echo "$version"
}

failed=0

profiling="$(size -m "$BIN" | sed -n -E 's/^[[:space:]]*Section (__llvm_(prf|cov)[a-z_]*):.*/\1/p' | sort -u)"
if [[ -n "$profiling" ]]; then
	echo "error: $BIN carries profiling or coverage data:" >&2
	printf '         %s\n' $profiling >&2
	echo "       build with CLANG_COVERAGE_MAPPING=NO; see scripts/build-app.sh" >&2
	failed=1
fi

build_version="$(vtool -show-build "$BIN")"
minos="$(awk '$1 == "minos" { print $2; exit }' <<<"$build_version")"
sdk="$(awk '$1 == "sdk" { print $2; exit }' <<<"$build_version")"
if [[ -z "$minos" || -z "$sdk" ]]; then
	echo "error: no LC_BUILD_VERSION found in $BIN" >&2
	exit 1
fi

expected_sdk="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "$(normalise "$sdk")" != "$(normalise "$expected_sdk")" ]]; then
	echo "error: $BIN records SDK $sdk, but this Mac builds with SDK $expected_sdk." >&2
	echo "       macOS would run the app with the behaviour of SDK $sdk. Build it with" >&2
	echo "       scripts/build-app.sh, which sets SDKROOT and always links afresh." >&2
	failed=1
fi

declared_min="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")"
if [[ "$(normalise "$minos")" != "$(normalise "$declared_min")" ]]; then
	echo "error: $BIN is built for macOS $minos, but Info.plist declares $declared_min" >&2
	echo "       (LSMinimumSystemVersion). Keep Package.swift's platforms and the plist in step." >&2
	failed=1
fi

if [[ "$failed" -ne 0 ]]; then
	exit 1
fi

echo "release binary: no profiling data, SDK $sdk, minimum macOS $minos"
