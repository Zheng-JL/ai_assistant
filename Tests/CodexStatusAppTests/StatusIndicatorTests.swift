import AppKit
import XCTest
@testable import CodexStatusApp

final class StatusIndicatorTests: XCTestCase {
    func testActiveCountsHaveRequestedColors() async {
        await MainActor.run {
            XCTAssertEqual(StatusIndicator.running.color(for: 1), NSColor.systemGreen)
            XCTAssertEqual(StatusIndicator.unread.color(for: 1), NSColor.systemBlue)
        }
    }

    func testEmptyOrUnknownCountsAreNeutral() async {
        await MainActor.run {
            for indicator in [StatusIndicator.running, .unread] {
                XCTAssertEqual(indicator.color(for: 0), NSColor.secondaryLabelColor)
                XCTAssertEqual(indicator.color(for: nil), NSColor.secondaryLabelColor)
            }
        }
    }

    func testMenuImagesKeepColorInsteadOfTemplateTinting() async {
        await MainActor.run {
            for indicator in [StatusIndicator.running, .unread] {
                let image = indicator.image(for: 1)
                XCTAssertNotNil(image)
                XCTAssertEqual(image?.size, NSSize(width: 16, height: 16))
                XCTAssertEqual(image?.isTemplate, false)
            }
        }
    }

    func testMenuDotsRenderRequestedColorsInBothAppearances() async {
        await MainActor.run {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                guard let appearance = NSAppearance(named: name) else {
                    XCTFail("Missing system appearance")
                    continue
                }
                appearance.performAsCurrentDrawingAppearance {
                    for indicator in [StatusIndicator.running, .unread] {
                        guard let image = indicator.image(for: 1),
                              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                            XCTFail("Missing dot pixels")
                            continue
                        }
                        let bitmap = NSBitmapImageRep(cgImage: pixels)
                        var coloredPixels = 0
                        for y in 0..<bitmap.pixelsHigh {
                            for x in 0..<bitmap.pixelsWide {
                                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                      color.alphaComponent > 0.5 else { continue }
                                if indicator == .running {
                                    if color.greenComponent > color.redComponent * 1.3,
                                       color.greenComponent > color.blueComponent * 1.3 { coloredPixels += 1 }
                                } else {
                                    if color.blueComponent > color.redComponent * 1.3,
                                       color.blueComponent > color.greenComponent * 1.3 { coloredPixels += 1 }
                                }
                            }
                        }
                        XCTAssertGreaterThan(coloredPixels, 0, "\(indicator) in \(name)")
                    }
                }
            }
        }
    }

    func testAccessibilityValueDoesNotDependOnDots() async {
        await MainActor.run {
            let value = StatusIndicator.accessibilityValue(running: 2, unread: 3)
            XCTAssertEqual(value, "Codex 运行 2；已完成未读 3")
            XCTAssertFalse(value.contains("●"))
            XCTAssertTrue(StatusIndicator.accessibilityValue(running: nil, unread: nil).contains("--"))
        }
    }

}

final class WaitingIndicatorTests: XCTestCase {
    func testWaitingIsOrangeWhenPositiveAndNeutralOtherwise() async {
        await MainActor.run {
            XCTAssertEqual(StatusIndicator.waiting.color(for: 2), NSColor.systemOrange)
            XCTAssertEqual(StatusIndicator.waiting.color(for: 0), NSColor.secondaryLabelColor)
        }
    }

}

final class CompactTitleTests: XCTestCase {
    private static func color(_ title: NSAttributedString, dot index: Int) -> NSColor? {
        let text = title.string as NSString
        var location = 0, found = 0
        while found <= index {
            let range = text.range(of: "●", range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound else { return nil }
            if found == index { return title.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor }
            location = range.upperBound; found += 1
        }
        return nil
    }

    func testIdleOrClosedAppsLeaveOnlyTheIcon() async {
        await MainActor.run {
            XCTAssertEqual(StatusIndicator.compactTitle(codex: nil, claude: nil).length, 0)
            let idle = StatusIndicator.Counts(running: 0, waiting: 0, unread: 0)
            XCTAssertEqual(StatusIndicator.compactTitle(codex: idle, claude: idle).length, 0)
            XCTAssertEqual(StatusIndicator.compactTitle(codex: .init(running: 0, waiting: 0, unread: nil), claude: nil).length, 0)
        }
    }

    func testOnlyNonZeroCountsAreShownWithRequestedColors() async {
        await MainActor.run {
            let title = StatusIndicator.compactTitle(
                codex: .init(running: 2, waiting: 1, unread: 3), claude: .init(running: 1, waiting: 0, unread: nil))
            XCTAssertEqual(title.string, " Cx ●2 ●1 ●3  Cl ●1")
            XCTAssertEqual(Self.color(title, dot: 0), NSColor.systemGreen)
            XCTAssertEqual(Self.color(title, dot: 1), NSColor.systemOrange)
            XCTAssertEqual(Self.color(title, dot: 2), NSColor.systemBlue)
            XCTAssertEqual(Self.color(title, dot: 3), NSColor.systemGreen)
        }
    }

    func testUnknownRunningIsGrayQuestionMarkNotZero() async {
        await MainActor.run {
            let title = StatusIndicator.compactTitle(codex: .init(running: nil, waiting: 0, unread: 4), claude: nil)
            XCTAssertEqual(title.string, " Cx ●? ●4")
            XCTAssertEqual(Self.color(title, dot: 0), NSColor.secondaryLabelColor)
            XCTAssertEqual(Self.color(title, dot: 1), NSColor.systemBlue)
        }
    }

    func testWorstCaseWidthIsFarBelowTheOldTwoItems() async {
        await MainActor.run {
            let busy = StatusIndicator.Counts(running: 999, waiting: 999, unread: 999)
            let title = StatusIndicator.compactTitle(codex: busy, claude: busy)
            // Old layout: two fixed 245-point items. Normal use (a few digits) is much narrower still.
            XCTAssertLessThan(title.size().width + 24, 490)
            let typical = StatusIndicator.compactTitle(codex: .init(running: 2, waiting: 0, unread: 1),
                                                       claude: .init(running: 1, waiting: 0, unread: nil))
            XCTAssertLessThan(typical.size().width + 24, 150)
        }
    }
}


final class NotificationBadgeTests: XCTestCase {
    func testEveryNotificationStyleUsesARealSymbol() async {
        await MainActor.run {
            for style in [Notifier.Style.finished, .waiting, .longRunning, .context, .budget] {
                XCTAssertNotNil(NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil), style.symbol)
                XCTAssertNotNil(IconArt.badgePNG(symbol: style.symbol, color: style.color), style.symbol)
            }
        }
    }
}
