#!/usr/bin/env bash
#
# Self-test of scripts/check-runtime-imports.sh and of the weak-import shim.
#
# Builds scripts/runtime-imports/BorrowReproducer.swift for macOS 14 twice:
#
#   - as it is, which must FAIL the gate on _swift_initBorrow. This is the
#     negative control: a gate that cannot fail proves nothing.
#   - linked with Sources/WeakRuntimeImports and the same linker flag as the
#     app, which must PASS, proving that the shim the app ships with works with
#     the current compiler.
#
# When the plain build no longer imports _swift_initBorrow strongly, the
# compiler has been fixed: the shim and this test can then go.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/scripts/check-runtime-imports.sh"
SOURCE="$ROOT/scripts/runtime-imports/BorrowReproducer.swift"
SHIM="$ROOT/Sources/WeakRuntimeImports/WeakRuntimeImports.c"
TARGET="arm64-apple-macos14.0"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SWIFTC=(xcrun swiftc -O -parse-as-library -target "$TARGET" -enable-experimental-feature Lifetimes)

"${SWIFTC[@]}" "$SOURCE" -o "$WORK/plain" 2>/dev/null

if ! nm -um "$WORK/plain" | grep -q -E '^ *\(undefined\) external _swift_initBorrow '; then
	echo "error: the compiler no longer links _swift_initBorrow strongly." >&2
	echo "       Remove it from Sources/WeakRuntimeImports, and this test with it" >&2
	echo "       once the shim is empty." >&2
	exit 1
fi

if "$GATE" "$WORK/plain" >"$WORK/plain.log" 2>&1; then
	echo "error: negative control: the gate passed a binary that imports _swift_initBorrow strongly" >&2
	exit 1
fi
if ! grep -q '_swift_initBorrow' "$WORK/plain.log"; then
	echo "error: negative control: the gate failed, but not on _swift_initBorrow:" >&2
	cat "$WORK/plain.log" >&2
	exit 1
fi

xcrun clang -c -target "$TARGET" "$SHIM" -o "$WORK/shim.o"
"${SWIFTC[@]}" "$SOURCE" "$WORK/shim.o" \
	-Xlinker -weak_reference_mismatches -Xlinker weak \
	-o "$WORK/patched" 2>/dev/null

if ! "$GATE" "$WORK/patched"; then
	echo "error: the reproducer linked with the shim still fails the gate" >&2
	exit 1
fi

echo "runtime-imports self-test: gate rejects the plain reproducer, accepts it with the shim"
