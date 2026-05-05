import AppKit
import XCTest
import AVFoundation
import CuttiKit
@testable import CuttiMac

/// Verifies the apply-time revalidation logic added in PR 5: when the
/// project state shifts between proposal time and the user clicking
/// Apply (specifically: the source media record referenced by an
/// `insertSourceClip` action is removed), the proposal is marked stale
/// instead of silently committing a dangling segment.
@MainActor
final class HookTeaserApplyRevalidationTests: XCTestCase {

    private let sourceID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    private func makeVM() -> MediaCoreViewModel {
        let spy = SpyPlaybackCore()
        return MediaCoreViewModel(
            playbackCore: spy,
            projectRoot: URL(fileURLWithPath: "/project")
        )
    }

    private func makeRecord() -> MediaAssetRecord {
        MediaAssetRecord(
            id: sourceID,
            sourcePath: "/tmp/podcast.mov",
            fingerprint: SourceFingerprint(fileSize: 1000, modifiedAt: Date(), sha256Prefix: "abc"),
            status: .ready,
            analysis: AnalysisSummary(durationSeconds: 60, width: 1920, height: 1080, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(thumbnailsReady: true, waveformsReady: true),
            errorMessage: nil,
            usedFallbackTranscoder: false,
            kind: .video
        )
    }

    private func makeHookProposal(toolCallID: String = "tc-1") -> ProposedBatch {
        let batch = AIActionBatch(
            actions: [.insertSourceClip(
                sourceVideoID: sourceID,
                sourceStart: 5.0,
                sourceEnd: 10.0,
                composedInsertAt: 0,
                fadeInSeconds: 0.15,
                fadeOutSeconds: 0.4
            )],
            explanation: "Add opening hook teaser"
        )
        // ProposedBatch.init is internal to the kit module — use the
        // public `make(...)` factory by feeding it a synthetic dry-run
        // result. Simulate the apply-time state we want for the test:
        // empty timeline before, one new hook segment after.
        let hookSeg = TimelineSegment(
            id: UUID(),
            sourceVideoID: sourceID,
            range: TimeRange(startSeconds: 5.0, endSeconds: 10.0),
            text: "",
            subtitles: []
        )
        let dryRun = AIActionExecutor.Result(
            segments: [hookSeg],
            appliedCount: 1,
            skippedCount: 0,
            subtitleStyle: nil,
            showSubtitles: nil,
            warnings: []
        )
        return ProposedBatch.make(
            toolCallID: toolCallID,
            batch: batch,
            before: [],
            dryRun: dryRun
        )
    }

    /// PR 5 BLOCKING fix from rubber-duck: when the source asset is
    /// removed between proposal creation and Apply, the proposal must
    /// not commit a dangling segment.
    func test_applyProposal_marksStale_whenSourceRecordRemoved() {
        let vm = makeVM()
        vm.records = [makeRecord()]
        vm.timelineSegments = []
        let proposal = makeHookProposal()
        vm.pendingProposals = [proposal]

        // Simulate the user removing the source asset between
        // proposal creation and Apply.
        vm.records = []

        vm.applyProposal(id: proposal.id)

        let decided = vm.pendingProposals.first { $0.id == proposal.id }
        XCTAssertEqual(decided?.decision, .stale,
                       "proposal must go stale when source record vanished")
        // Timeline must remain empty — no dangling segment was inserted.
        XCTAssertTrue(vm.timelineSegments.isEmpty,
                      "no segment may be committed when revalidation fails")
    }

    /// Sanity check: apply still works when source record is intact.
    /// Guards against the new revalidation accidentally rejecting
    /// otherwise-valid proposals.
    func test_applyProposal_succeeds_whenSourceStillPresent() {
        let vm = makeVM()
        vm.records = [makeRecord()]
        vm.timelineSegments = []
        let proposal = makeHookProposal()
        vm.pendingProposals = [proposal]

        vm.applyProposal(id: proposal.id)

        let decided = vm.pendingProposals.first { $0.id == proposal.id }
        XCTAssertEqual(decided?.decision, .applied,
                       "proposal must apply cleanly when records still match")
        XCTAssertEqual(vm.timelineSegments.count, 1,
                       "executor must have inserted the hook segment")
    }
}
