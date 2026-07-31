import KeyboardShortcuts

extension KeyboardShortcuts.Name {

    /// Toggle dictation. Registered through Carbon rather than a CGEventTap, so
    /// no Input Monitoring permission is required.
    ///
    /// This combination is not a macOS symbolic hotkey, but it is AppKit's
    /// built-in "Look Up in Dictionary" shortcut inside text views. A Carbon
    /// hotkey takes precedence, so that lookup is shadowed while the app runs.
    static let toggleDictation = Self(
        "toggleDictation",
        initial: .init(.d, modifiers: [.command, .control])
    )

    /// Discards the recording without transcribing. Only enabled while
    /// recording, so Escape behaves normally the rest of the time.
    static let cancelDictation = Self(
        "cancelDictation",
        initial: .init(.escape)
    )
}
