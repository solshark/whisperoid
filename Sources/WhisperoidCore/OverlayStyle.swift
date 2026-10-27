import CoreGraphics

/// How the dictation overlay is drawn, and where on the screen it sits.
///
/// The raw values are what Settings stores, so they must not change.
public enum OverlayStyle: String, CaseIterable, Sendable, Identifiable {
    /// Ribbons over a soft pool of shade in the middle of the screen.
    case classic
    /// A small glass card in the middle of the screen.
    case glassCard
    /// A glass capsule below the menu bar, which grows into a card only when
    /// there is a warning to read.
    case glassPill

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .classic: "Classic"
        case .glassCard: "Glass card"
        case .glassPill: "Glass pill"
        }
    }

    /// Size of the transparent panel that holds the overlay.
    ///
    /// The glass styles draw their shape inside it and change size within it,
    /// so it is large enough for the biggest state each can show. The panel
    /// ignores the mouse, so the empty part of it is never in the way.
    public var panelSize: CGSize {
        switch self {
        case .classic: CGSize(width: 560, height: 220)
        case .glassCard: CGSize(width: 400, height: 220)
        case .glassPill: CGSize(width: 420, height: 160)
        }
    }

    /// Space between the top of the usable screen and the top of the pill.
    static let topMargin: CGFloat = 8

    /// Where the panel's lower-left corner goes, in screen coordinates.
    ///
    /// - Parameters:
    ///   - frame: The whole screen.
    ///   - visibleFrame: The screen less the menu bar and the Dock.
    ///   - topInset: The screen's top safe-area inset, which is the height of
    ///     the camera housing on a display with a notch and zero otherwise.
    public func panelOrigin(frame: CGRect, visibleFrame: CGRect, topInset: CGFloat) -> CGPoint {
        let size = panelSize
        switch self {
        case .classic, .glassCard:
            return CGPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        case .glassPill:
            // Below the menu bar while it is shown. When it is hidden, as in a
            // full-screen app, the visible frame reaches the top edge, and on a
            // display with a notch the camera housing would cover the pill.
            let top = min(visibleFrame.maxY, frame.maxY - topInset) - Self.topMargin
            // Centred on the screen rather than the visible frame, so a Dock
            // on the left or right does not push it off the menu bar's centre.
            return CGPoint(x: frame.midX - size.width / 2, y: top - size.height)
        }
    }
}
