#!/usr/bin/env bash
#
# Fails when a binary imports a Swift runtime function strongly that is not
# known to exist on the app's minimum macOS.
#
# The compiler weak-links Swift declarations that are newer than the deployment
# target, but not always the runtime functions it calls on their behalf. Swift
# 6.4 links _swift_initBorrow strongly, and dyld then refuses to load the app on
# any macOS before 27 (WH-16). Nothing on the build machine notices, since its
# own runtime has the function, so the binary is checked here instead.
#
# Usage: scripts/check-runtime-imports.sh <Mach-O binary>
#
# The allowed functions are listed in scripts/runtime-imports/allowed.txt.
# Only C runtime entry points (_swift_*) are checked: mangled Swift symbols
# carry availability, and the compiler weak-links those correctly.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWED="$ROOT/scripts/runtime-imports/allowed.txt"
BIN="${1:-}"

if [[ -z "$BIN" || ! -f "$BIN" ]]; then
	echo "usage: $0 <Mach-O binary>" >&2
	exit 2
fi

# `nm -um` prints one undefined symbol per line, for example
#   (undefined) external _swift_retain (from libswiftCore)
#   (undefined) weak external _swift_initBorrow (from libswiftCore)
# Weak imports are fine: they resolve to null on an older macOS.
strong="$(nm -um "$BIN" \
	| sed -n -E 's/^ *\(undefined\) external (_swift_[A-Za-z0-9_]+) \(from libswift[A-Za-z0-9_]*\)$/\1/p' \
	| sort -u)"

# Every Swift binary imports _swift_retain and friends. An empty list means the
# output format changed and this gate can no longer see anything.
if [[ -z "$strong" ]]; then
	echo "error: no strong Swift runtime imports found in $BIN; the nm output format may have changed" >&2
	exit 1
fi

unknown="$(comm -23 <(printf '%s\n' "$strong") <(grep -v -E '^(#|$)' "$ALLOWED" | sort -u))"

if [[ -n "$unknown" ]]; then
	echo "error: $BIN imports Swift runtime functions strongly that are not known" >&2
	echo "       to exist on the minimum macOS; dyld will refuse to load it there:" >&2
	printf '         %s\n' $unknown >&2
	echo "       Weak-link them in Sources/WeakRuntimeImports, or, if the minimum" >&2
	echo "       macOS has them, add them to scripts/runtime-imports/allowed.txt." >&2
	exit 1
fi

echo "runtime imports: $(printf '%s\n' "$strong" | wc -l | tr -d ' ') strong Swift runtime functions, all allowed"
