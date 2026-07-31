import KeyboardShortcuts

extension KeyboardShortcuts.Name {

    /// Toggle dictation. Registered through Carbon rather than a CGEventTap, so
    /// no Input Monitoring permission is required.
    static let toggleDictation = Self(
        "toggleDictation",
        initial: .init(.d, modifiers: [.command, .option])
    )

    /// Discards the recording without transcribing. Only enabled while
    /// recording, so Escape behaves normally the rest of the time.
    static let cancelDictation = Self(
        "cancelDictation",
        initial: .init(.escape)
    )
}
