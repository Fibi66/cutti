import XCTest
@testable import CuttiMac

/// Verifies the `AppleActionOnDoubleClick` parser used by the
/// title-bar drag region. We can't unit-test NSWindow drag /
/// zoom forwarding without a live window, but the preference
/// mapping is the only piece of logic that has any branches —
/// and it's the one that dictates whether double-click does the
/// "right thing" for users who've changed the system setting.
final class TitleBarDragRegionTests: XCTestCase {
    func test_resolveDoubleClickAction_defaultIsZoom() {
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: nil),
            .zoom
        )
    }

    func test_resolveDoubleClickAction_maximizeMapsToZoom() {
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "Maximize"),
            .zoom
        )
    }

    func test_resolveDoubleClickAction_minimizeMapsToMinimize() {
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "Minimize"),
            .minimize
        )
    }

    func test_resolveDoubleClickAction_noneMapsToNone() {
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "None"),
            .none
        )
    }

    func test_resolveDoubleClickAction_offTreatedAsNone() {
        // Older macOS releases used "Off" as the disable value; we
        // honour it for users who upgraded with that legacy key.
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "Off"),
            .none
        )
    }

    func test_resolveDoubleClickAction_isCaseInsensitive() {
        // System Preferences writes "Minimize" but Catalyst /
        // third-party tooling has been observed writing lowercase.
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "minimize"),
            .minimize
        )
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "MAXIMIZE"),
            .zoom
        )
    }

    func test_resolveDoubleClickAction_unknownFallsBackToZoom() {
        // Future-proofing: if Apple introduces a new value we don't
        // recognise, prefer the standard zoom action over a dead
        // gesture.
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: "FullScreen"),
            .zoom
        )
        XCTAssertEqual(
            TitleBarDragNSView.resolveDoubleClickAction(rawValue: ""),
            .zoom
        )
    }
}
