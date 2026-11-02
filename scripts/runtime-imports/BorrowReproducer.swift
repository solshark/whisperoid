// Reproduces WH-16 without any package: built for macOS 14 with Swift 6.4, a
// type that holds a Ref (available from macOS 27 only) makes the compiler link
// the runtime function _swift_initBorrow strongly, so the binary does not load
// before macOS 27. Used by scripts/test-runtime-imports.sh.

@available(macOS 27, *)
public struct Holder<T>: ~Escapable {
    public let ref: Ref<T>

    @_lifetime(borrow value)
    public init(_ value: borrowing T) {
        ref = Ref(value)
    }
}

@main
struct BorrowReproducer {
    static func main() {
        if #available(macOS 27, *) {
            let value = 5
            let holder = Holder(value)
            _ = holder
        }
        print("ok")
    }
}
