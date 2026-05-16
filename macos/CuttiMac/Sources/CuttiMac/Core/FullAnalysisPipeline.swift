import Foundation
import CuttiKit

/// Full analysis pipeline that connects local analysis services with the
/// LLM editor to produce a complete `AICopilotSnapshot`.
///
/// Implements `AnalysisPipelineProtocol` and can be injected into the
/// view model / app stack.
struct FullAnalysisPipeline: AnalysisPipelineProtocol {
    let orchestrator: AnalysisOrchestrator

    init(
        orchestrator: AnalysisOrchestrator = AnalysisOrchestrator()
    ) {
        self.orchestrator = orchestrator
    }

    func analyze(
        sourceURL: URL,
        analysis: AnalysisSummary,
        onProgress: @escaping @Sendable (AnalysisProgress) -> Void
    ) async throws -> AICopilotSnapshot {
        let pipelineT0 = Date()
        // Step 1: Run local analysis (transcription + scene + audio)
        let localResult = try await orchestrator.analyze(
            sourceURL: sourceURL,
            analysis: analysis,
            onProgress: onProgress
        )

        // Step 2: Resolve OpenAI config at request time (not frozen at init).
        // `fromEnvironment()` is @MainActor because it reads RelaySession.
        let config = await OpenAIConfiguration.fromEnvironment()

        if let config, !localResult.transcript.isEmpty {
            onProgress(AnalysisProgress(
                phase: .requestingAI,
                fractionComplete: 0.8,
                detail: "Requesting AI edit suggestions…"
            ))

            let client = OpenAIClient(configuration: config)
            let llmEditor = LLMEditorService(client: client)

            do {
                let llmT0 = Date()
                print("⏱️  [llm-edit] kickoff (\(localResult.transcript.count) sentences)")
                let editDecision = try await llmEditor.selectSegments(localResult.transcript)
                let llmElapsed = Date().timeIntervalSince(llmT0)
                print("⏱️  [llm-edit] done in \(String(format: "%.2f", llmElapsed))s")

                // Log AI edit decisions to terminal
                print("\n📋 === AI Edit Decision ===")
                print("✅ KEEP (\(editDecision.keepIndices.count) segments):")
                for idx in editDecision.keepIndices.sorted() {
                    if idx < localResult.transcript.count {
                        let seg = localResult.transcript[idx]
                        print("  [\(idx)] \(String(format: "%.1f", seg.startSeconds))s–\(String(format: "%.1f", seg.endSeconds))s: \(seg.text)")
                    }
                }
                print("\n❌ CUT (\(editDecision.cuts.count) segments):")
                for cut in editDecision.cuts {
                    if cut.index < localResult.transcript.count {
                        let seg = localResult.transcript[cut.index]
                        print("  [\(cut.index)] \(String(format: "%.1f", seg.startSeconds))s–\(String(format: "%.1f", seg.endSeconds))s: \(seg.text)")
                        print("       Reason: \(cut.reason)")
                    }
                }
                print("========================\n")

                // Resolve the AI-planning bubble to a ✓ before
                // emitting `.complete`, so the chat panel shows the
                // step finishing with an elapsed time instead of a
                // perpetual spinner that the final-summary sweep
                // would otherwise have to clean up.
                onProgress(AnalysisProgress(
                    phase: .requestingAI,
                    fractionComplete: 0.95,
                    detail: "Done in \(AnalysisOrchestrator.formatElapsed(llmElapsed))",
                    isPhaseComplete: true
                ))

                onProgress(AnalysisProgress(
                    phase: .complete,
                    fractionComplete: 1.0,
                    detail: "Analysis complete."
                ))

                print("⏱️  pipeline total: \(String(format: "%.2f", Date().timeIntervalSince(pipelineT0)))s")

                // Chapter generation is intentionally NOT part of the
                // one-click first cut. Users can run it explicitly from
                // the timeline via "Generate chapter bar" when they want
                // chapters; baking it into every analyze call added a
                // second LLM round-trip + progress-bar overlay that most
                // users did not ask for.
                return CopilotSnapshotBuilder.fromAnalysisAndEdit(
                    local: localResult,
                    editDecision: editDecision
                )
            } catch {
                // LLM failure is non-fatal — return local-only snapshot with error info
                print("⚠️  LLM editor failed: \(error)")
                print("⏱️  pipeline total: \(String(format: "%.2f", Date().timeIntervalSince(pipelineT0)))s (LLM failed)")
                onProgress(AnalysisProgress(
                    phase: .complete,
                    fractionComplete: 1.0,
                    detail: "Analysis complete (AI suggestions unavailable: \(error.localizedDescription))."
                ))
                return CopilotSnapshotBuilder.fromLocalAnalysis(localResult)
            }
        }

        // No OpenAI config or empty transcript — return local-only snapshot
        onProgress(AnalysisProgress(
            phase: .complete,
            fractionComplete: 1.0,
            detail: "Analysis complete."
        ))
        print("⏱️  pipeline total: \(String(format: "%.2f", Date().timeIntervalSince(pipelineT0)))s (no LLM step)")
        return CopilotSnapshotBuilder.fromLocalAnalysis(localResult)
    }
}
