import Foundation

/// Kind of a timeline track. The current single-track model is equivalent
/// to one `.video` track carrying both picture and its original audio (A/V
/// muxed); adding a separate `.audio` track unlocks BGM/narration mixing,
/// and `.overlay` unlocks picture-in-picture / B-roll.
public enum TrackKind: String, Codable, Equatable, Sendable {
    /// Primary video track. Contributes picture and (by default) the
    /// original clip audio via AVMutableAudioMix.
    case video
    /// Independent audio track — BGM, narration, sound effects. Does
    /// NOT contribute picture even if the source is a video file.
    case audio
    /// Secondary video track layered on top of the primary track
    /// (picture-in-picture, B-roll cutaways).
    case overlay
}

/// A strip of `TimelineSegment`s that share a track identity (muted/solo
/// state, a user-visible name, a kind). Segments are rendered in sequence
/// with no gaps — i.e. each `Track` behaves like the existing
/// `timelineSegments` array, just scoped to one lane of the composition.
public struct Track: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: TrackKind
    public var name: String
    public var isMuted: Bool
    public var isSolo: Bool
    /// When true the track is locked for editing — clicks, drags,
    /// trims, deletes, splits, and effect changes on its segments are
    /// ignored. Visibility / audio routing are unaffected.
    public var isLocked: Bool
    public var segments: [TimelineSegment]

    public init(
        id: UUID = UUID(),
        kind: TrackKind,
        name: String,
        isMuted: Bool = false,
        isSolo: Bool = false,
        isLocked: Bool = false,
        segments: [TimelineSegment] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.isLocked = isLocked
        self.segments = segments
    }
}

/// The composition the user is editing. Has exactly one primary video
/// track (convention: `tracks[0].kind == .video`) and zero or more
/// additional audio / overlay tracks. The primary video track is the one
/// every pre-multitrack code path reads/writes through the
/// `MediaCoreViewModel.timelineSegments` compatibility shim.
public struct Project: Equatable, Sendable {
    public var tracks: [Track]
    /// Voice-enhancer settings applied at export time. When
    /// `enabled == true` the exporter runs the final audio through
    /// `VoiceEnhancer.process` and remuxes it back into the output
    /// file so the user gets a cleaner podcast-ready voice track.
    public var voiceEnhancer: VoiceEnhancer.Settings = .disabled

    public init(
        tracks: [Track] = [Project.makePrimaryVideoTrack()],
        voiceEnhancer: VoiceEnhancer.Settings = .disabled
    ) {
        self.tracks = tracks
        self.voiceEnhancer = voiceEnhancer
    }

    /// The track every legacy call site implicitly talks to.
    public static func makePrimaryVideoTrack(segments: [TimelineSegment] = []) -> Track {
        Track(kind: .video, name: "V1 (Main)", segments: segments)
    }

    /// Convenience: construct a project with a single primary video
    /// track seeded from a legacy `[TimelineSegment]`. Used by the
    /// compatibility shim when older call sites assign to
    /// `timelineSegments` and we need to materialize a project.
    public static func legacy(segments: [TimelineSegment]) -> Project {
        Project(tracks: [makePrimaryVideoTrack(segments: segments)])
    }

    /// Index of the primary video track. Guaranteed to exist; the
    /// initializer seeds one when the tracks array is empty.
    public var primaryVideoTrackIndex: Int {
        tracks.firstIndex(where: { $0.kind == .video }) ?? 0
    }

    public var primaryVideoTrack: Track {
        tracks[primaryVideoTrackIndex]
    }

    /// Read-only view of the primary video track's segments — the single
    /// source of truth every non-multitrack code path reads.
    public var primarySegments: [TimelineSegment] {
        get { primaryVideoTrack.segments }
        set {
            let idx = primaryVideoTrackIndex
            if idx < tracks.count {
                tracks[idx].segments = newValue
            } else {
                tracks.append(Project.makePrimaryVideoTrack(segments: newValue))
            }
        }
    }

    /// All `.audio`-kind tracks in project order. Used by the composition
    /// builder/exporter to emit separate AVMutableCompositionTrack lanes.
    public var audioTracks: [Track] {
        tracks.filter { $0.kind == .audio }
    }

    /// All `.overlay`-kind tracks in project order, bottom-to-top.
    public var overlayTracks: [Track] {
        tracks.filter { $0.kind == .overlay }
    }
}
