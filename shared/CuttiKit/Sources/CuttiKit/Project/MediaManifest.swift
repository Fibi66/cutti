import Foundation

public enum MediaStatus: String, Codable, Sendable {
    case queued
    case analyzing
    case transcoding
    case ready
    case failed
    case missing
}

/// Coarse type of an imported asset. Images (`.image`) behave like
/// "infinite-source" stills — they have no intrinsic duration and skip
/// transcode / proxy / waveform / AI analysis. Videos (`.video`) keep
/// the legacy behavior. Default is `.video` so manifests from before
/// this field was introduced decode unchanged.
public enum MediaKind: String, Codable, Equatable, Sendable {
    case video
    case image
}

public struct SourceFingerprint: Codable, Equatable, Sendable {
    public let fileSize: Int64
    public let modifiedAt: Date
    public let sha256Prefix: String
    public init(
        fileSize: Int64,
        modifiedAt: Date,
        sha256Prefix: String
    ) {
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.sha256Prefix = sha256Prefix
    }

}

public struct AnalysisSummary: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
    public let nominalFPS: Double
    public let hasAudio: Bool
    public init(
        durationSeconds: Double,
        width: Int,
        height: Int,
        nominalFPS: Double,
        hasAudio: Bool
    ) {
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.nominalFPS = nominalFPS
        self.hasAudio = hasAudio
    }

}

public struct DerivedAssetState: Codable, Equatable, Sendable {
    public var proxyRelativePath: String?
    public var thumbnailsReady: Bool
    public var waveformsReady: Bool
    public init(
        proxyRelativePath: String? = nil,
        thumbnailsReady: Bool,
        waveformsReady: Bool
    ) {
        self.proxyRelativePath = proxyRelativePath
        self.thumbnailsReady = thumbnailsReady
        self.waveformsReady = waveformsReady
    }

}

public struct MediaAssetRecord: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var sourcePath: String
    public var fingerprint: SourceFingerprint
    public var status: MediaStatus
    public var analysis: AnalysisSummary?
    public var derived: DerivedAssetState
    public var errorMessage: String?
    public var usedFallbackTranscoder: Bool
    public var copilot: AICopilotSnapshot? = nil
    /// Introduced when still-image import was added. Legacy manifests
    /// predate this field — `init(from:)` uses `decodeIfPresent` and
    /// falls back to `.video` so old projects load unchanged.
    public var kind: MediaKind = .video
    public init(
        id: UUID,
        sourcePath: String,
        fingerprint: SourceFingerprint,
        status: MediaStatus,
        analysis: AnalysisSummary? = nil,
        derived: DerivedAssetState,
        errorMessage: String? = nil,
        usedFallbackTranscoder: Bool,
        copilot: AICopilotSnapshot? = nil,
        kind: MediaKind = .video
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.fingerprint = fingerprint
        self.status = status
        self.analysis = analysis
        self.derived = derived
        self.errorMessage = errorMessage
        self.usedFallbackTranscoder = usedFallbackTranscoder
        self.copilot = copilot
        self.kind = kind
    }

}

// Custom Codable so `kind`'s default actually rescues missing keys in
// legacy manifests. Swift's synthesized `Decodable` ignores property
// initializers, so a plain `var kind: MediaKind = .video` would still
// make decoding throw `keyNotFound` on pre-image-feature JSON.
extension MediaAssetRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourcePath, fingerprint, status, analysis, derived
        case errorMessage, usedFallbackTranscoder, copilot, kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.sourcePath = try c.decode(String.self, forKey: .sourcePath)
        self.fingerprint = try c.decode(SourceFingerprint.self, forKey: .fingerprint)
        self.status = try c.decode(MediaStatus.self, forKey: .status)
        self.analysis = try c.decodeIfPresent(AnalysisSummary.self, forKey: .analysis)
        self.derived = try c.decode(DerivedAssetState.self, forKey: .derived)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        self.usedFallbackTranscoder = try c.decode(Bool.self, forKey: .usedFallbackTranscoder)
        self.copilot = try c.decodeIfPresent(AICopilotSnapshot.self, forKey: .copilot)
        self.kind = (try c.decodeIfPresent(MediaKind.self, forKey: .kind)) ?? .video
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourcePath, forKey: .sourcePath)
        try c.encode(fingerprint, forKey: .fingerprint)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(analysis, forKey: .analysis)
        try c.encode(derived, forKey: .derived)
        try c.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try c.encode(usedFallbackTranscoder, forKey: .usedFallbackTranscoder)
        try c.encodeIfPresent(copilot, forKey: .copilot)
        try c.encode(kind, forKey: .kind)
    }
}

public extension MediaAssetRecord {
    /// Upper bound on valid source-time positions for a segment that
    /// references this record, in seconds. Returns `nil` when the
    /// source is unbounded (still images — a single pixel buffer that
    /// can back any segment duration). Callers doing bounds checks
    /// should SKIP enforcement when this returns nil, since "infinite
    /// source" is a legitimate state rather than a missing fingerprint.
    public var sourceUpperBoundSeconds: Double? {
        switch kind {
        case .video:
            return analysis?.durationSeconds
        case .image:
            return nil
        }
    }

    /// Whether this record is a candidate for the AI analysis /
    /// transcription / scene-detection pipelines. Stills never are.
    public var isAnalyzable: Bool { kind == .video }
}

public struct MediaManifest: Equatable, Sendable {
    public var media: [MediaAssetRecord] = []
    /// User-edited display names for diarized speakers, keyed by the
    /// stringified speaker ID (Int → String so the JSON stays a flat
    /// `{ "0": "Alice", "1": "Bob" }` map). Project-scoped because
    /// speaker IDs span all source clips. Optional + decodeIfPresent so
    /// legacy manifests continue to load.
    public var speakerNames: [String: String]? = nil
    /// User-picked accent colors per speaker, stored as `#RRGGBB` hex
    /// strings keyed by stringified speaker ID. Same shape/contract as
    /// `speakerNames`.
    public var speakerColors: [String: String]? = nil
    /// User-picked label font size per speaker, in points. Drives the
    /// on-screen speaker badge next to the subtitle. Absent ⇒ default
    /// size. Same key shape as `speakerColors`.
    public var speakerLabelSizes: [String: Double]? = nil

    public init(
        media: [MediaAssetRecord] = [],
        speakerNames: [String: String]? = nil,
        speakerColors: [String: String]? = nil,
        speakerLabelSizes: [String: Double]? = nil
    ) {
        self.media = media
        self.speakerNames = speakerNames
        self.speakerColors = speakerColors
        self.speakerLabelSizes = speakerLabelSizes
    }
}

extension MediaManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case media, speakerNames, speakerColors, speakerLabelSizes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.media = (try? c.decode([MediaAssetRecord].self, forKey: .media)) ?? []
        self.speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames)
        self.speakerColors = try c.decodeIfPresent([String: String].self, forKey: .speakerColors)
        self.speakerLabelSizes = try c.decodeIfPresent([String: Double].self, forKey: .speakerLabelSizes)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(media, forKey: .media)
        try c.encodeIfPresent(speakerNames, forKey: .speakerNames)
        try c.encodeIfPresent(speakerColors, forKey: .speakerColors)
        try c.encodeIfPresent(speakerLabelSizes, forKey: .speakerLabelSizes)
    }
}
