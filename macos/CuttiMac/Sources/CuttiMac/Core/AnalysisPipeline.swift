import Foundation
import CuttiKit

// MARK: - Analysis progress

enum AnalysisPhase: String, Sendable {
    case queued
    case transcribing
    case analyzingScenes
    case analyzingAudio
    case requestingAI
    case complete
    case failed
}

struct AnalysisProgress: Sendable {
    let phase: AnalysisPhase
    let fractionComplete: Double
    let detail: String
    /// Set to `true` when the event represents a phase *finishing*
    /// rather than starting or making intermediate progress. The UI
    /// uses this to render the entry with a success checkmark and a
    /// distinct chat bubble, producing a log-style trail rather than
    /// a single mutating status line.
    let isPhaseComplete: Bool

    init(
        phase: AnalysisPhase,
        fractionComplete: Double,
        detail: String,
        isPhaseComplete: Bool = false
    ) {
        self.phase = phase
        self.fractionComplete = fractionComplete
        self.detail = detail
        self.isPhaseComplete = isPhaseComplete
    }
}

// MARK: - Local analysis result (before LLM)

struct LocalAnalysisResult: Sendable {
    /// Sentence-level transcript (resegmented from words).
    let transcript: [TranscriptSegment]
    /// Best available token/word-level transcript with accurate timestamps when available.
    let rawWordTranscript: [TranscriptSegment]
    let semanticTags: [String]
    let sceneBoundaries: [SceneBoundary]
    let hasTalkingHead: Bool
    let audioIssues: [AICopilotIssue]
    let silentRanges: [ClosedRange<Double>]
    /// Per-window linear RMS curve covering the source audio. Optional
    /// because `AnalysisOrchestrator`'s audio fallback path produces a
    /// degraded (empty curve) result when audio analysis fails. `nil`
    /// here means the audio task threw and was swallowed.
    let audioEnergyCurve: AudioEnergyCurve?
}

// MARK: - Pipeline protocol

/// Protocol for the full media analysis pipeline.
///
/// Implementations run local analysis (transcription, scene, audio) and
/// optionally call an LLM for edit suggestions, then produce a complete
/// `AICopilotSnapshot`.
protocol AnalysisPipelineProtocol: Sendable {
    /// The local analysis orchestrator (for direct transcription without LLM).
    var orchestrator: AnalysisOrchestrator { get }

    /// Run the full analysis pipeline for a single media record.
    ///
    /// - Parameters:
    ///   - sourceURL: Path to the original (or proxy) video file.
    ///   - analysis: The basic metadata already extracted at import time.
    ///   - onProgress: Called on each phase transition with current progress.
    /// - Returns: A populated `AICopilotSnapshot` ready to attach to the record.
    func analyze(
        sourceURL: URL,
        analysis: AnalysisSummary,
        onProgress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> AICopilotSnapshot
}

