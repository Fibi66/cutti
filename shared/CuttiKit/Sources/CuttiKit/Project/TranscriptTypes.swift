import Foundation

// MARK: - Transcript segment

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    /// Source video ID (for multi-video analysis).
    public var sourceVideoID: UUID?

    public init(
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        sourceVideoID: UUID? = nil
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.sourceVideoID = sourceVideoID
    }

    public var durationSeconds: Double { endSeconds - startSeconds }
}

// MARK: - Scene boundary

public struct SceneBoundary: Codable, Equatable, Sendable {
    public let seconds: Double
    public let label: String

    public init(seconds: Double, label: String) {
        self.seconds = seconds
        self.label = label
    }
}
