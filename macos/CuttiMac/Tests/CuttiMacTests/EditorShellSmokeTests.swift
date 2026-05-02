import AVKit
import SwiftUI
import XCTest
import CuttiKit
@testable import CuttiMac

@MainActor
final class EditorShellSmokeTests: XCTestCase {
    private func makeRecord(
        status: MediaStatus = .ready,
        proxyRelativePath: String? = "media/proxies/BrowserClip.mp4"
    ) -> MediaAssetRecord {
        MediaAssetRecord(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            sourcePath: "/tmp/BrowserClip.mp4",
            fingerprint: SourceFingerprint(fileSize: 10, modifiedAt: .distantPast, sha256Prefix: "abc"),
            status: status,
            analysis: AnalysisSummary(durationSeconds: 8, width: 1280, height: 720, nominalFPS: 30, hasAudio: true),
            derived: DerivedAssetState(proxyRelativePath: proxyRelativePath, thumbnailsReady: false, waveformsReady: false),
            errorMessage: nil,
            usedFallbackTranscoder: false
        )
    }

    func test_commandBar_browser_and_copilotChrome_canBeConstructed() {
        let record = makeRecord()

        _ = AICopilotPromptField(
            text: .constant(""),
            isAnalyzing: false,
            hasAPIKey: true,
            onSubmit: { _ in },
            onSettingsTap: {}
        )

        _ = AgentActivityStrip(
            status: .init(
                title: "AI copilot is idle",
                detail: "Import media or run analysis to unlock tags and suggestions.",
                tone: .idle
            )
        )

        // Exercise the .working branch so the ProgressView path is compiled and reachable.
        _ = AgentActivityStrip(
            status: .init(
                title: "Analysing clips",
                detail: "Running scene detection on 3 assets…",
                tone: .working
            )
        )

        _ = EditorCommandBar(
            canExport: false,
            isExporting: false,
            onImport: {},
            onExport: {}
        )

        _ = SettingsView()

        _ = ProjectDashboardView(
            registry: ProjectRegistry(baseDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)),
            onOpenProject: { _ in }
        )

        _ = MediaBrowserSidebar(
            records: [record],
            projectRoot: URL(fileURLWithPath: "/project"),
            selectedRecordID: .constant(Optional(record.id)),
            searchQuery: .constant(""),
            onSelect: { _ in },
            onDelete: { _ in }
        )
    }

    func test_viewerStage_and_inspector_canBeConstructed() {
        let record = makeRecord()

        _ = ViewerStage(
            player: AVPlayer(),
            selectedRecord: record,
            selectedRecordMessage: nil,
            playheadSeconds: .constant(0),
            durationSeconds: .constant(8),
            playbackRate: .constant(1.0),
            isLooping: .constant(false),
            subtitleText: nil,
            showSubtitles: true,
            subtitleStyle: .constant(.default),
            subtitleSelected: .constant(false),
            onSetPlaybackRate: { _ in },
            onToggleLoop: {}
        )

        _ = InspectorSidebar(
            record: record,
            isExpanded: .constant(true),
            onRelink: {}
        )
    }

    func test_timelineDock_canBeConstructed() {
        let record = makeRecord()

        _ = TimelineDock(
            records: [record],
            selectedRecordID: record.id,
            projectRoot: URL(fileURLWithPath: "/project"),
            playheadSeconds: .constant(2),
            durationSeconds: 8,
            segments: [],
            player: nil,
            selectedSegmentIDs: [],
            primarySelectedSegmentID: nil,
            selectedOverlaySegmentID: .constant(nil),
            showSubtitles: .constant(true),
            subtitleStyle: .constant(.default),
            onSeek: { _ in },
            onSegmentTap: { _, _ in },
            onClearSelection: {},
            onSelectAllSegments: {},
            onMoveSegment: { _, _ in },
            onBeginTrim: { _ in },
            onLiveTrim: { _, _, _ in },
            onEndTrim: { _ in },
            onSplitAtPlayhead: { _ in },
            onMergeSelectedSegments: {},
            onDeleteSelectedSegments: {},
            onDeleteSegment: { _ in },
            onAddFullSource: {},
            onSetSelectedSpeed: { _ in },
            onSetSegmentSpeed: { _, _ in },
            onSetVolume: { _, _ in },
            onRotate: { _ in },
            onFlipH: { _ in },
            onFlipV: { _ in },
            onSetColor: { _, _, _, _ in },
            onSetAudioFade: { _, _, _ in },
            onResetEffects: { _ in },
            onEditSubtitleText: { _, _ in },
            selectedSubtitleID: nil,
            onSelectSubtitle: { _ in },
            onMoveSubtitle: { _, _ in },
            onResizeSubtitle: { _, _, _ in },
            onAddSubtitle: { _ in },
            onDeleteSubtitle: { _ in }
        )
    }

    func test_contentView_canBeConstructed_withInjectedWorkspaceViewModel() {
        let viewModel = MediaCoreViewModel(
            playbackCore: AVPlaybackCore(),
            projectRoot: URL(fileURLWithPath: "/project")
        )

        _ = ContentView(viewModel: viewModel)
    }

    func test_posterThumbnailLoadToken_changesWhenPosterInputsChange() {
        let record = makeRecord(status: .analyzing, proxyRelativePath: nil)

        let initialToken = PosterThumbnailView.posterLoadToken(
            for: record,
            projectRoot: nil
        )

        let readyToken = PosterThumbnailView.posterLoadToken(
            for: makeRecord(status: .ready, proxyRelativePath: nil),
            projectRoot: nil
        )
        XCTAssertNotEqual(initialToken, readyToken)

        let proxyToken = PosterThumbnailView.posterLoadToken(
            for: makeRecord(status: .ready, proxyRelativePath: "media/proxies/Updated.mp4"),
            projectRoot: nil
        )
        XCTAssertNotEqual(readyToken, proxyToken)

        let rootToken = PosterThumbnailView.posterLoadToken(
            for: makeRecord(status: .ready, proxyRelativePath: "media/proxies/Updated.mp4"),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        XCTAssertNotEqual(proxyToken, rootToken)
    }

    func test_posterThumbnailLoadToken_preservesProxyOnlyPlaceholderBehavior() {
        let queuedToken = PosterThumbnailView.posterLoadToken(
            for: makeRecord(status: .queued, proxyRelativePath: "media/proxies/BrowserClip.mp4"),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        XCTAssertFalse(queuedToken.canLoadPoster)

        let missingProxyToken = PosterThumbnailView.posterLoadToken(
            for: makeRecord(status: .ready, proxyRelativePath: nil),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        XCTAssertFalse(missingProxyToken.canLoadPoster)

        let readyToken = PosterThumbnailView.posterLoadToken(
            for: makeRecord(status: .ready, proxyRelativePath: "media/proxies/BrowserClip.mp4"),
            projectRoot: URL(fileURLWithPath: "/project")
        )
        XCTAssertTrue(readyToken.canLoadPoster)
    }

    func test_shouldDispatchShellSelection_returnsFalse_forAlreadySelectedRecord() {
        let record = makeRecord()

        XCTAssertFalse(
            shouldDispatchShellSelection(
                currentSelection: record.id,
                tappedID: record.id
            )
        )
    }

    func test_shouldDispatchShellSelection_returnsTrue_forNewSelection() {
        let record = makeRecord()
        let anotherRecordID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!

        XCTAssertTrue(
            shouldDispatchShellSelection(
                currentSelection: nil,
                tappedID: record.id
            )
        )
        XCTAssertTrue(
            shouldDispatchShellSelection(
                currentSelection: record.id,
                tappedID: anotherRecordID
            )
        )
    }
}
