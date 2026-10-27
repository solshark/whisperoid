import CoreGraphics
import Testing

@testable import WhisperoidCore

/// Covers where each overlay style places its panel. The screens are made up:
/// a laptop display with a notch and a menu bar 37 points tall, and an
/// external display to its right with no notch.
struct OverlayStyleTests {

    private static let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let laptopVisible = CGRect(x: 0, y: 70, width: 1512, height: 875)
    private static let notch: CGFloat = 32

    @Test("The stored names of the styles do not change", arguments: [
        ("classic", OverlayStyle.classic),
        ("glassCard", OverlayStyle.glassCard),
        ("glassPill", OverlayStyle.glassPill),
    ])
    func storedNamesAreStable(raw: String, style: OverlayStyle) {
        #expect(OverlayStyle(rawValue: raw) == style)
    }

    @Test("The centred styles sit in the middle of the visible screen", arguments: [
        OverlayStyle.classic, .glassCard,
    ])
    func centredStylesSitInTheMiddle(style: OverlayStyle) {
        let origin = style.panelOrigin(
            frame: Self.laptop, visibleFrame: Self.laptopVisible, topInset: Self.notch
        )
        #expect(origin.x + style.panelSize.width / 2 == Self.laptopVisible.midX)
        #expect(origin.y + style.panelSize.height / 2 == Self.laptopVisible.midY)
    }

    @Test("The pill sits just below the menu bar")
    func pillSitsBelowTheMenuBar() {
        let style = OverlayStyle.glassPill
        let origin = style.panelOrigin(
            frame: Self.laptop, visibleFrame: Self.laptopVisible, topInset: Self.notch
        )
        #expect(origin.y + style.panelSize.height == Self.laptopVisible.maxY - OverlayStyle.topMargin)
        #expect(origin.x + style.panelSize.width / 2 == Self.laptop.midX)
    }

    @Test("With the menu bar hidden the pill stays clear of the notch")
    func pillClearsTheNotchInFullScreen() {
        let style = OverlayStyle.glassPill
        let fullScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let origin = style.panelOrigin(
            frame: Self.laptop, visibleFrame: fullScreen, topInset: Self.notch
        )
        #expect(origin.y + style.panelSize.height == Self.laptop.maxY - Self.notch - OverlayStyle.topMargin)
    }

    @Test("On a second display with the Dock at the side, the pill is centred on that display")
    func pillIsCentredOnItsOwnDisplay() {
        let style = OverlayStyle.glassPill
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        // Dock on the left takes 80 points; menu bar 25 points, no notch.
        let visible = CGRect(x: 1592, y: -200, width: 2480, height: 1415)
        let origin = style.panelOrigin(frame: external, visibleFrame: visible, topInset: 0)
        #expect(origin.x + style.panelSize.width / 2 == external.midX)
        #expect(origin.y + style.panelSize.height == visible.maxY - OverlayStyle.topMargin)
    }
}
