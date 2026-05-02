import Foundation
import CryptoKit

/// The parameters-as-source-of-truth descriptor for an AI-generated
/// Remotion overlay.
///
/// When a `TimelineSegment` on an overlay track carries a non-nil
/// `overlaySpec`, the segment is treated as a *live* motion-graphics
/// element: the compositor plays the cached `.mov` that was rendered
/// from these exact props, but the user can double-click the segment,
/// edit the props (via `OverlayInspector`), and the app will render a
/// new `.mov` from the updated spec and swap it in. This mirrors how
/// Final Cut's title clips, Premiere's Essential Graphics and
/// DaVinci's Text+ nodes work: the render is a cache, not the source
/// of truth.
///
/// `propsJSON` is a canonical JSON string (sorted keys) so we can
/// hash spec+duration deterministically for cache lookup.
public struct OverlayRenderSpec: Codable, Equatable, Hashable, Sendable {
    /// Matches the Remotion composition id, e.g. "ChapterTitle".
    public var templateID: String
    /// Canonical (sorted-keys) JSON string carrying the template's
    /// inputProps. Kept as a string rather than `[String: Any]` so
    /// it's trivially Codable and the cache key is deterministic.
    public var propsJSON: String
    /// Duration of the overlay on the timeline, in seconds. Passed
    /// to Remotion as `--duration-in-frames` (converted via fps).
    public var durationSeconds: Double
    /// Frames-per-second the overlay should render at. Kept as a
    /// spec property (not a global) so the cache key is stable when
    /// the project's timeline fps changes.
    public var fps: Int
    /// Output video width in pixels.
    public var width: Int
    /// Output video height in pixels.
    public var height: Int

    public init(
        templateID: String,
        propsJSON: String,
        durationSeconds: Double,
        fps: Int = 30,
        width: Int = 1920,
        height: Int = 1080
    ) {
        self.templateID = templateID
        self.propsJSON = OverlayRenderSpec.canonicalize(json: propsJSON)
        self.durationSeconds = max(0.1, durationSeconds)
        self.fps = max(1, fps)
        self.width = max(16, width)
        self.height = max(16, height)
    }

    /// Bumped whenever the render *environment* changes in a way that
    /// should invalidate every previously-cached mov, even when the
    /// props are identical. Examples: fonts added/removed in the
    /// container, template rendering logic changes, ProRes profile
    /// swap. The value is folded into `cacheKey` so old movs are
    /// ignored and the client re-renders through the (freshly-deployed)
    /// cloud pipeline on the next request.
    ///
    /// Change log:
    ///   1 — original
    ///   2 — added Noto CJK + Google Fonts display catalog (2026-04)
    ///   3 — added `backdropMode` prop; text-card templates now default
    ///       to transparent outer fill instead of #0D0D0D (2026-04)
    public static let renderSchemaVersion = 3

    /// Deterministic sha256 of the spec. Used as the cache filename
    /// (`media/overlays/<cacheKey>.mov`) so identical spec+duration
    /// render once and share the `.mov` across segments and sessions.
    public var cacheKey: String {
        let payload = "v\(OverlayRenderSpec.renderSchemaVersion)|\(templateID)|\(propsJSON)|\(String(format: "%.3f", durationSeconds))|\(fps)|\(width)|\(height)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses the raw JSON and re-encodes with sorted keys so that
    /// `{"title":"X","subtitle":"Y"}` and `{"subtitle":"Y","title":"X"}`
    /// produce the same cache key. Falls back to the original string
    /// if the input isn't parseable as JSON (template might accept
    /// free-form strings).
    public static func canonicalize(json raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{}" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return trimmed
        }
        guard let reencoded = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ), let reencodedString = String(data: reencoded, encoding: .utf8) else {
            return trimmed
        }
        return reencodedString
    }
}
