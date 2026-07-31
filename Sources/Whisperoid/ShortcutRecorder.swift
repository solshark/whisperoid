import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A shortcut capture field.
struct ShortcutRecorder: NSViewRepresentable {

    let name: HotkeyName

    func makeNSView(context: Context) -> ShortcutRecorderView {
        ShortcutRecorderView(name: name)
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.refreshTitle()
    }
}

final class ShortcutRecorderView: NSButton {

    private let name: HotkeyName

    private var isRecording = false {
        didSet {
            // Suspend every registered shortcut while capturing, so pressing a
            // combination that is already bound records it rather than firing
            // the action it is bound to.
            HotkeyCenter.shared.isEnabled = !isRecording
            refreshTitle()
        }
    }

    init(name: HotkeyName) {
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
            endRecording()
            return
        }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    private func endRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    func refreshTitle() {
        if isRecording {
            title = "Press keys…"
        } else if let shortcut = HotkeyCenter.shared.shortcut(for: name) {
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
        let bareModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty

        // Escape abandons the capture; Delete clears the binding entirely.
        if event.keyCode == UInt16(kVK_Escape), bareModifiers {
            endRecording()
            return true
        }
        if event.keyCode == UInt16(kVK_Delete), bareModifiers {
            HotkeyCenter.shared.setShortcut(nil, for: name)
            endRecording()
            return true
        }

        guard let shortcut = Hotkey(event: event) else { return false }

        guard shortcut.hasModifiers || name.allowsBareKey else {
            // An unmodified key registered globally would fire while typing.
            NSSound.beep()
            return true
        }
        guard !shortcut.isTakenBySystem else {
            NSSound.beep()
            return true
        }

        HotkeyCenter.shared.setShortcut(shortcut, for: name)
        endRecording()
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { isRecording = false }
        return super.resignFirstResponder()
    }
}
