import Foundation
import CuttiKit

/// iOS-scoped persistence for editor UI state that doesn't belong in
/// the shared `EditorSessionState` (per BOUNDARIES.md: no predictive
/// sharing — macOS has no call site for aspect-ratio / background /
/// per-segment visual preset today). Stored next to the project
/// manifest as `ios-session.json`.
struct IOSSessionState: Codable, Equatable {
    var aspectRatio: String
    var coverTimeSeconds: Double?
    var visualEffects: [String: String]
    var background: Background
    var textOverlays: [TextOverlay]?
    /// Per-segment "exit transition" duration in seconds. When set to
    /// a positive value on segment N, the last T seconds of N fade
    /// toward black and the first T seconds of N+1 fade up from black
    /// — a symmetric cross-fade-to-black. Keyed by segment UUID
    /// string. Optional for JSON back-compat with pre-transition
    /// ios-session.json files.
    var transitions: [String: Double]?
    /// Authored chapter list. Persisted optional for JSON back-compat
    /// with pre-chapters ios-session.json files.
    var chapters: [VideoChapter]?
    /// BCP-47 locale used to display the bilingual translation in the
    /// transcript editor. Optional for JSON back-compat.
    var transcriptDisplayLocale: String?

    enum Background: Codable, Equatable {
        case color(r: Double, g: Double, b: Double, a: Double)
        case blur
    }

    /// Simple time-boxed text overlay rendered in-canvas. iOS-only for
    /// now — the shared `OverlayRenderSpec` is richer (templates / AI
    /// B-roll) and touching it cross-platform would drag in a bigger
    /// diff than this feature deserves.
    struct TextOverlay: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var startSeconds: Double
        var endSeconds: Double
        /// Normalized 0…1 (origin bottom-left of canvas, matching
        /// CoreImage's coordinate space).
        var positionX: Double
        var positionY: Double
        /// Font size relative to canvas short side (0…1). 0.06 ≈
        /// comfortable caption size on a 1080×1920 canvas.
        var fontSizeRel: Double
        var colorR: Double
        var colorG: Double
        var colorB: Double
        /// PostScript font name (e.g. "AvenirNext-Bold"). nil =
        /// system bold. Optional for JSON back-compat with pre-picker
        /// overlays. The rasterizer falls back to the default if the
        /// font isn't installed on this device.
        var fontName: String?
        var italic: Bool?
        /// When false, suppresses the heavy black stroke so the text
        /// reads cleaner over uniform backgrounds. Defaults to true
        /// (stroke on) when absent.
        var strokeEnabled: Bool?
    }

    static let `default` = IOSSessionState(
        aspectRatio: ProjectDocument.AspectRatio.portrait9x16.rawValue,
        coverTimeSeconds: nil,
        visualEffects: [:],
        background: .color(r: 0, g: 0, b: 0, a: 1),
        textOverlays: [],
        transitions: [:],
        chapters: [],
        transcriptDisplayLocale: nil
    )
}

enum IOSSessionStore {
    private static func url(for projectRoot: URL) -> URL {
        projectRoot.appending(path: "ios-session.json")
    }

    static func load(projectRoot: URL) -> IOSSessionState {
        let u = url(for: projectRoot)
        guard let data = try? Data(contentsOf: u) else { return .default }
        return (try? JSONDecoder().decode(IOSSessionState.self, from: data)) ?? .default
    }

    static func save(_ state: IOSSessionState, projectRoot: URL) {
        let u = url(for: projectRoot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: u, options: .atomic)
    }
}
