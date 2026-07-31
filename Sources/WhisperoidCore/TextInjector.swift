import AppKit
import Foundation

/// How transcribed text reaches its destination.
///
/// The app deliberately writes to the clipboard and confirms visually rather
/// than synthesising keystrokes into the focused application. That decision
/// keeps the microphone as the only permission the app ever requests, and
/// avoids macOS Secure Input silently discarding synthetic events.
///
/// The protocol remains so an injecting implementation can be added later
/// without changing the call site.
public protocol TextInjector: Sendable {
    func inject(_ text: String) throws
}

public struct ClipboardInjector: TextInjector {

    public init() {}

    public func inject(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
