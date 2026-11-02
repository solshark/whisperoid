// Weak references to Swift runtime functions that are newer than the app's
// minimum macOS but that the compiler links strongly.
//
// Swift 6.4 emits calls to swift_initBorrow for types built on the standard
// library's Ref (Builtin.Borrow), such as the macOS 27-only code in
// swift-collections 1.7. The Swift declarations of that code are correctly
// weak-linked, but the runtime function itself is linked strongly, so dyld
// refuses to load the app on any macOS before 27 with "Symbol not found:
// _swift_initBorrow" (WH-16). scripts/runtime-imports/BorrowReproducer.swift
// reproduces it without any package.
//
// A weak reference here, combined with the linker flag
// -weak_reference_mismatches weak on the app target, makes the final binary
// import the symbol weakly. It then resolves to null before macOS 27, where
// nothing can call it, since every caller is itself only available from
// macOS 27.
//
// scripts/check-runtime-imports.sh fails the release if any runtime function
// outside its allow-list is still imported strongly. Remove an entry here once
// the compiler links that function weakly by itself; the gate's self-test,
// scripts/test-runtime-imports.sh, reports when that happens.

// swift_getBorrowTypeMetadata belongs to the same feature and has the same
// defect. The app does not import it today, but the reproducer does, and so
// would any dependency that stores a Ref generically.
extern void swift_initBorrow(void) __attribute__((weak_import));
extern void swift_getBorrowTypeMetadata(void) __attribute__((weak_import));

// `used` keeps the references through dead stripping in release builds.
__attribute__((used))
static void *const whisperoid_weak_runtime_functions[] = {
    (void *)&swift_initBorrow,
    (void *)&swift_getBorrowTypeMetadata,
};
