import AppKit
import KeyboardShortcuts
import SwiftUI

/// A shortcut capture field.
///
/// This replaces `KeyboardShortcuts.Recorder`, which cannot be shipped in a
/// signed application. That view reads localised strings through SwiftPM's
/// generated `Bundle.module`, which resolves resources against
/// `Bundle.main.bundleURL` — the `.app` directory itself. Placing a resource
/// bundle there leaves "unsealed contents present in the bundle root" and the
/// signature will not verify, while placing it anywhere else makes the accessor
/// fall back to a path hardcoded into the build machine's directory and call
/// `fatalError` on every other computer.
///
/// Only the recorder view was affected; registration and lookup do not touch
/// that accessor, so the rest of the library is used unchanged.
struct ShortcutRecorder: NSViewRepresentable {

    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView(name: name)
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.refreshTitle()
    }
}

final class ShortcutRecorderView: NSButton {

    private let name: KeyboardShortcuts.Name

    private var isRecording = false {
        didSet {
            // Suspend every registered shortcut while capturing, so pressing a
            // combination that is already bound triggers dictation instead of
            // being recorded.
            KeyboardShortcuts.isEnabled = !isRecording
            refreshTitle()
        }
    }

    init(name: KeyboardShortcuts.Name) {
        self.name = name
        super.init(frame: .zero)

        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard !isRecording else {
            cancelRecording()
            return
        }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    private func cancelRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    func refreshTitle() {
        if isRecording {
            title = "Press keys…"
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            title = shortcut.description
        } else {
            title = "Record Shortcut"
        }
    }

    // MARK: - Capture

    // Combinations containing Command arrive as key equivalents and never reach
    // keyDown, so both paths are needed.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event) else {
            super.keyDown(with: event)
            return
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Escape abandons the capture; Delete clears the binding entirely.
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            cancelRecording()
            return true
        }
        if event.keyCode == 51, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            KeyboardShortcuts.setShortcut(nil, for: name)
            cancelRecording()
            return true
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return false }

        // A bare key with no modifiers would fire constantly while typing.
        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard !shortcut.modifiers.intersection(relevant).isEmpty else {
            NSSound.beep()
            return true
        }

        guard !shortcut.isTakenBySystem else {
            NSSound.beep()
            return true
        }

        KeyboardShortcuts.setShortcut(shortcut, for: name)
        cancelRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { isRecording = false }
        return super.resignFirstResponder()
    }
}
