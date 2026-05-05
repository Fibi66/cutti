import AppKit
import SwiftUI

/// SwiftUI background that restores the standard macOS title-bar
/// behaviour — single-click + drag to move the window, double-click
/// to zoom (or minimize, per the user's `AppleActionOnDoubleClick`
/// system preference) — for views painted into the area where the
/// system title bar would normally sit.
///
/// We need this because the app uses `.windowStyle(.hiddenTitleBar)`
/// so the editor / dashboard topbars can paint flush from `y = 0`.
/// SwiftUI's plain `.background(Color)` is hit-testable, so it
/// swallows the double-click before NSWindow's built-in title-bar
/// tracking can react. The result was that double-clicking the
/// topbar did nothing.
///
/// Used as `.background(TitleBarDragRegion(color: …))` on the
/// topbar's HStack. The backing NSView sits BEHIND the SwiftUI
/// controls in Z order, so buttons / inputs continue to receive
/// their own clicks; only clicks on otherwise empty regions
/// (Spacer, padding) reach this view and get forwarded to the
/// host NSWindow.
struct TitleBarDragRegion: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> TitleBarDragNSView {
        let view = TitleBarDragNSView()
        view.fillColor = NSColor(color)
        return view
    }

    func updateNSView(_ nsView: TitleBarDragNSView, context: Context) {
        nsView.fillColor = NSColor(color)
    }
}

/// Backing `NSView` for `TitleBarDragRegion`. Paints a flat fill
/// colour and forwards title-bar gestures to its host window.
final class TitleBarDragNSView: NSView {
    var fillColor: NSColor = .clear {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = fillColor.cgColor
    }

    /// Accept the first click even when the app isn't yet active so
    /// users can drag / zoom from a freshly-focused window — that's
    /// what NSWindow's real title bar does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount >= 2 {
            Self.performTitleBarDoubleClick(on: window)
            return
        }
        // Single click → enter window-drag tracking. NSWindow tracks
        // the cursor internally and stops on mouseUp; nothing else for
        // us to do.
        window.performDrag(with: event)
    }

    /// Possible actions the system can take when the user
    /// double-clicks a title bar. Mirrors the values the
    /// `AppleActionOnDoubleClick` user default can take.
    enum DoubleClickAction: Equatable {
        case zoom
        case minimize
        case none
    }

    /// Mirror NSWindow's response to a title-bar double-click,
    /// honouring `AppleActionOnDoubleClick`. Split out as a static
    /// helper so the action-selection logic is unit-testable without
    /// a live window.
    static func performTitleBarDoubleClick(on window: NSWindow) {
        switch resolveDoubleClickAction() {
        case .zoom:
            window.performZoom(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .none:
            break
        }
    }

    /// Resolve the `AppleActionOnDoubleClick` preference into one of
    /// the three concrete window actions. Unknown / missing values
    /// fall back to `.zoom` because that's the system default on
    /// every supported macOS release.
    static func resolveDoubleClickAction(
        rawValue: String? = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    ) -> DoubleClickAction {
        switch rawValue?.lowercased() {
        case "minimize":
            return .minimize
        case "none", "off":
            return .none
        default:
            // "Maximize", nil, empty, or any future value — prefer
            // zoom over no-op so users aren't stuck with a dead
            // gesture if Apple renames the value.
            return .zoom
        }
    }
}
