import AppKit
import Carbon.HIToolbox

/// A global shortcut, stored as Carbon key code and modifier mask.
///
/// The display string is captured when the shortcut is recorded rather than
/// derived from the key code later. Translating a key code back to a character
/// requires the current keyboard layout and gets the answer wrong whenever the
/// layout differs from the one in use at recording time.
struct Hotkey: Equatable, Codable, Sendable {

    let carbonKeyCode: UInt32
    let carbonModifiers: UInt32
    let display: String

    init(carbonKeyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }

        self.carbonKeyCode = UInt32(event.keyCode)
        self.carbonModifiers = carbon
        self.display = Self.label(for: event)
    }

    var hasModifiers: Bool { carbonModifiers != 0 }

    /// Rendered in the order macOS uses in menus.
    var description: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + display
    }

    /// True when macOS has already reserved this combination system-wide.
    var isTakenBySystem: Bool {
        var raw: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&raw) == noErr,
              let entries = raw?.takeRetainedValue() as? [[String: Any]]
        else { return false }

        for entry in entries {
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? Int
            else { continue }

            if UInt32(code) == carbonKeyCode, UInt32(modifiers) == carbonModifiers {
                return true
            }
        }
        return false
    }

    private static func label(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let characters = event.charactersIgnoringModifiers ?? ""
        return characters.isEmpty ? "?" : characters.uppercased()
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Identifies a bindable action and its factory-default shortcut.
struct HotkeyName: Hashable, Sendable {

    let key: String
    let initial: Hotkey?
    /// Whether a shortcut with no modifiers is acceptable. Only true for
    /// bindings that are registered temporarily, since an unmodified key
    /// registered globally would fire during ordinary typing.
    let allowsBareKey: Bool

    static let toggleDictation = HotkeyName(
        key: "toggleDictation",
        initial: Hotkey(
            carbonKeyCode: UInt32(kVK_ANSI_D),
            carbonModifiers: UInt32(cmdKey | controlKey),
            display: "D"
        ),
        allowsBareKey: false
    )

    static let cancelDictation = HotkeyName(
        key: "cancelDictation",
        initial: Hotkey(carbonKeyCode: UInt32(kVK_Escape), carbonModifiers: 0, display: "⎋"),
        allowsBareKey: true
    )

    // Identity is the storage key alone; the other fields are fixed properties
    // of the action rather than part of what identifies it.
    static func == (lhs: HotkeyName, rhs: HotkeyName) -> Bool { lhs.key == rhs.key }

    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

/// Registers global shortcuts through Carbon.
///
/// `RegisterEventHotKey` needs no Accessibility or Input Monitoring permission,
/// unlike a CGEventTap.
///
/// The C event callback deliberately does not use `MainActor.assumeIsolated`.
/// Running on the main thread is not the same as running on the main actor's
/// executor, and on macOS 26 with Swift 6.3 that check reads an invalid
/// executor reference and faults. This replaced the KeyboardShortcuts package,
/// which crashed for exactly that reason.
@MainActor
final class HotkeyCenter {

    static let shared = HotkeyCenter()

    /// Suspends every registered shortcut, used while recording a new one so
    /// that pressing an existing binding records it instead of triggering it.
    var isEnabled = true

    private struct Binding {
        let name: HotkeyName
        var handler: () -> Void
        var reference: EventHotKeyRef?
        var isEnabled: Bool
    }

    private static let signature: OSType = 0x5748_4B59  // 'WHKY'

    private var bindings: [UInt32: Binding] = [:]
    private var identifiers: [HotkeyName: UInt32] = [:]
    private var nextIdentifier: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let defaults = UserDefaults.standard

    private init() {
        installEventHandler()
    }

    // MARK: - Registration

    func onKeyUp(for name: HotkeyName, handler: @escaping () -> Void) {
        let identifier = identifier(for: name)
        bindings[identifier] = Binding(
            name: name,
            handler: handler,
            reference: nil,
            isEnabled: true
        )
        applyRegistration(for: identifier)
    }

    func setEnabled(_ enabled: Bool, for name: HotkeyName) {
        guard let identifier = identifiers[name] else { return }
        bindings[identifier]?.isEnabled = enabled
        applyRegistration(for: identifier)
    }

    func shortcut(for name: HotkeyName) -> Hotkey? {
        if let data = defaults.data(forKey: storageKey(name)),
           let stored = try? JSONDecoder().decode(Hotkey.self, from: data)
        {
            return stored
        }
        if defaults.object(forKey: clearedKey(name)) != nil { return nil }
        return name.initial
    }

    func setShortcut(_ shortcut: Hotkey?, for name: HotkeyName) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: storageKey(name))
            defaults.removeObject(forKey: clearedKey(name))
        } else {
            defaults.removeObject(forKey: storageKey(name))
            // Recorded separately so that clearing a shortcut is not
            // indistinguishable from never having set one, which would
            // resurrect the factory default on the next launch.
            defaults.set(true, forKey: clearedKey(name))
        }

        if let identifier = identifiers[name] {
            applyRegistration(for: identifier)
        }
    }

    // MARK: - Carbon plumbing

    private func identifier(for name: HotkeyName) -> UInt32 {
        if let existing = identifiers[name] { return existing }
        let identifier = nextIdentifier
        nextIdentifier += 1
        identifiers[name] = identifier
        return identifier
    }

    private func storageKey(_ name: HotkeyName) -> String { "hotkey.\(name.key)" }
    private func clearedKey(_ name: HotkeyName) -> String { "hotkey.\(name.key).cleared" }

    private func applyRegistration(for identifier: UInt32) {
        guard var binding = bindings[identifier] else { return }

        if let reference = binding.reference {
            UnregisterEventHotKey(reference)
            binding.reference = nil
        }

        if binding.isEnabled, let shortcut = shortcut(for: binding.name) {
            var reference: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
            let status = RegisterEventHotKey(
                shortcut.carbonKeyCode,
                shortcut.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr {
                binding.reference = reference
            } else {
                Log.error("hotkey: registration failed for \(binding.name.key) (status \(status))")
            }
        }

        bindings[identifier] = binding
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyReleased)
        )
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec, nil, &eventHandler)
    }

    fileprivate func fire(_ identifier: UInt32) {
        guard isEnabled,
              let binding = bindings[identifier],
              binding.isEnabled
        else { return }
        binding.handler()
    }
}

/// Carbon C callback. It must not touch actor-isolated state directly, so it
/// only extracts the identifier and hops onto the main actor.
private let hotkeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let identifier = hotKeyID.id
    Task { @MainActor in
        HotkeyCenter.shared.fire(identifier)
    }
    return noErr
}
