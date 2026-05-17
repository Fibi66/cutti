import SwiftUI
import CuttiKit

/// Container that owns the stack + ViewModel lifecycle for a single project.
///
/// Uses `.id(projectID)` at the call site to ensure a fresh instance
/// is created when the user switches projects, avoiding stale state.
struct EditorSessionContainer: View {
    let projectID: UUID
    let projectName: String
    let registry: ProjectRegistry
    let onBack: () -> Void

    @StateObject private var viewModel: MediaCoreViewModel

    init(
        projectID: UUID,
        projectName: String,
        registry: ProjectRegistry,
        onBack: @escaping () -> Void
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.registry = registry
        self.onBack = onBack

        let root = registry.projectRoot(for: projectID)

        // Build stack for this project. If bootstrap fails, fall back to minimal VM.
        if let stack = try? AppleSiliconPhaseOneStack.make(projectRoot: root) {
            _viewModel = StateObject(wrappedValue: stack.makeViewModel())
        } else {
            _viewModel = StateObject(
                wrappedValue: MediaCoreViewModel(playbackCore: AVPlaybackCore())
            )
        }
    }

    var body: some View {
        EditorWithBackButton(
            viewModel: viewModel,
            projectName: projectName,
            canGoBack: !viewModel.isAnalyzing && !viewModel.isExporting && !viewModel.isImporting,
            onBack: onBack
        )
        // Stop the project's video the moment SwiftUI tears down this
        // container — both on "back to dashboard" (activeProjectID set
        // to nil) and on `.id(projectID)`-driven swap to a different
        // project's container. Without this, the `MediaCoreViewModel`
        // can outlive the view briefly (held by in-flight Tasks /
        // observers), and even after it's released the AVPlayer's
        // audio pipeline continues until something explicitly pauses
        // it — leaving the previous clip's audio droning on under the
        // dashboard or the next project. Pausing here stops the
        // audio synchronously regardless of when the VM finally
        // deallocates.
        .onDisappear {
            viewModel.player?.pause()
        }
    }
}

/// Wraps ContentView and adds a back-to-dashboard button in the command bar area.
private struct EditorWithBackButton: View {
    @ObservedObject var viewModel: MediaCoreViewModel
    let projectName: String
    let canGoBack: Bool
    let onBack: () -> Void

    @State private var showExportSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Combined project + import/export bar — styled after the
            // Obsidian reference topbar: subtle wordmark on the left,
            // dim 'Project' label, project name in primary text,
            // outline Import + amber Export on the right.
            HStack(spacing: 10) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        T("Projects")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(EditorShellStyle.textSecondary)
                .disabled(!canGoBack)
                .help(canGoBack ? L("Back to dashboard") : L("Finish current task first"))

                Rectangle()
                    .fill(EditorShellStyle.borderSubtle)
                    .frame(width: 1, height: 16)

                Text(projectName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EditorShellStyle.textPrimary)
                    .lineLimit(1)

                AIProviderChip()

                Spacer()

                Button {
                    ContentView.presentImportPanel(viewModel: viewModel)
                } label: {
                    Label { T("Import") } icon: { Image(systemName: "plus") }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(EditorShellStyle.textPrimary)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(EditorShellStyle.backgroundSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(EditorShellStyle.borderDefault, lineWidth: 1)
                )

                Button {
                    showExportSettings = true
                } label: {
                    Label { viewModel.isExporting ? T("Exporting…") : T("Export") } icon: { Image(systemName: "square.and.arrow.up") }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(viewModel.canExport && !viewModel.isExporting
                            ? EditorShellStyle.accentSolid
                            : EditorShellStyle.accentSolid.opacity(0.35))
                )
                .disabled(!viewModel.canExport || viewModel.isExporting)
            }
            .padding(.leading, EditorShellStyle.trafficLightInset)
            .padding(.trailing, EditorShellStyle.panelPadding)
            .padding(.vertical, 8)
            .background(TitleBarDragRegion(color: EditorShellStyle.backgroundApp))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(EditorShellStyle.borderSubtle)
                    .frame(height: 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)

            ContentView(viewModel: viewModel, showExportSettings: $showExportSettings)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

}
