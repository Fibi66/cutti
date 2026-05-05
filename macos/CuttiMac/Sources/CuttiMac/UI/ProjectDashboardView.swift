import AppKit
import AVFoundation
import SwiftUI
import CuttiKit

/// Dashboard view showing all projects as a grid of cards.
/// Users can create new projects, open existing ones, rename and delete.
struct ProjectDashboardView: View {
    @ObservedObject var registry: ProjectRegistry
    let onOpenProject: (UUID) -> Void

    @State private var promptText = ""
    @State private var promptMode: ProjectPromptMode?
    @State private var statsCache: [UUID: ProjectRegistry.ProjectStats] = [:]
    @State private var thumbnailCache: [UUID: NSImage] = [:]
    @State private var focusPromptField = false

    private let columns = [
        GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 20)
    ]

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cutti")
                            .font(.system(size: 28, weight: .bold))
                        T("AI-Powered Video Editor")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: presentCreateProjectPrompt) {
                        Label { T("New Project") } icon: { Image(systemName: "plus") }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.leading, max(40, EditorShellStyle.trafficLightInset))
                .padding(.trailing, 40)
                .padding(.vertical, 24)
                .background(TitleBarDragRegion(color: EditorShellStyle.chromeBackground))

                Divider()

                if registry.projects.isEmpty {
                    Spacer()
                    emptyState
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(sortedProjects) { project in
                                projectCard(project)
                            }
                        }
                        .padding(40)
                    }
                }
            }
            .background(EditorShellStyle.appBackground)
            .disabled(promptMode != nil)

            if let promptMode {
                promptBackdrop

                ProjectNamePromptCard(
                    mode: promptMode,
                    text: $promptText,
                    shouldBecomeFirstResponder: $focusPromptField,
                    canSubmit: isPromptNameValid,
                    onSubmit: submitPrompt,
                    onCancel: cancelPrompt
                )
                .frame(width: 420)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: promptMode != nil)
        .task {
            refreshStats()
        }
    }

    /// Projects sorted by last opened (most recent first).
    private var sortedProjects: [ProjectInfo] {
        registry.projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            T("No Projects Yet")
                .font(.title2.weight(.semibold))

            T("Create a new project to start editing your videos with AI.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                presentCreateProjectPrompt()
            } label: {
                Label { T("Create Your First Project") } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private var promptBackdrop: some View {
        Color.black.opacity(0.45)
            .ignoresSafeArea()
            .onTapGesture {
                cancelPrompt()
            }
    }

    // MARK: - Project Card

    private func projectCard(_ project: ProjectInfo) -> some View {
        let stats = statsCache[project.id]

        return Button {
            openProject(project.id)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail
                ZStack {
                    EditorShellStyle.stageBackground

                    if let thumb = thumbnailCache[project.id] {
                        Image(nsImage: thumb)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 160)
                .clipped()

                // Info
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Label {
                            Text(String(format: L("%d clips"), stats?.mediaCount ?? 0))
                        } icon: {
                            Image(systemName: "film")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                }
                .padding(12)
            }
            .background(EditorShellStyle.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(EditorShellStyle.subtleBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { openProject(project.id) } label: { T("Open") }
            Button {
                presentRenameProjectPrompt(for: project)
            } label: { T("Rename…") }
            Divider()
            Button(role: .destructive) {
                deleteProject(project.id)
            } label: { T("Delete") }
        }
    }

    // MARK: - Actions

    private func createProject(named name: String) {
        guard !name.isEmpty, let project = try? registry.createProject(name: name) else { return }
        cancelPrompt()
        refreshStats()
        onOpenProject(project.id)
    }

    private func openProject(_ id: UUID) {
        try? registry.updateLastOpened(id: id)
        onOpenProject(id)
    }

    private func deleteProject(_ id: UUID) {
        try? registry.deleteProject(id: id)
        statsCache.removeValue(forKey: id)
        thumbnailCache.removeValue(forKey: id)
    }

    private func renameProject(_ id: UUID, to name: String) {
        guard !name.isEmpty else { return }
        try? registry.renameProject(id: id, newName: name)
        cancelPrompt()
    }

    private func presentCreateProjectPrompt() {
        promptText = ""
        promptMode = .create
        focusPromptSoon()
    }

    private func presentRenameProjectPrompt(for project: ProjectInfo) {
        promptText = project.name
        promptMode = .rename(project.id)
        focusPromptSoon()
    }

    private var isPromptNameValid: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitPrompt() {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        switch promptMode {
        case .create:
            createProject(named: name)
        case .rename(let id):
            renameProject(id, to: name)
        case nil:
            break
        }
    }

    private func cancelPrompt() {
        promptMode = nil
        promptText = ""
        focusPromptField = false
    }

    private func focusPromptSoon() {
        focusPromptField = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
            focusPromptField = true
        }
    }

    private func refreshStats() {
        for project in registry.projects {
            statsCache[project.id] = registry.loadStats(for: project.id)
            loadThumbnail(for: project)
        }
    }

    private func loadThumbnail(for project: ProjectInfo) {
        let stats = statsCache[project.id]
        guard let proxyPath = stats?.firstProxyRelativePath else { return }
        let root = registry.projectRoot(for: project.id)
        let proxyURL = root.appending(path: proxyPath)
        guard FileManager.default.fileExists(atPath: proxyURL.path) else { return }

        Task.detached {
            let asset = AVURLAsset(url: proxyURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)

            if let (cgImage, _) = try? await generator.image(at: .zero) {
                let nsImage = NSImage(cgImage: cgImage, size: .zero)
                await MainActor.run {
                    thumbnailCache[project.id] = nsImage
                }
            }
        }
    }
}

private enum ProjectPromptMode {
    case create
    case rename(UUID)

    var iconName: String {
        switch self {
        case .create:
            return "plus.circle.fill"
        case .rename:
            return "pencil.circle.fill"
        }
    }

    var windowTitle: String {
        switch self {
        case .create:
            return L("Create New Project")
        case .rename:
            return L("Rename Project")
        }
    }

    var descriptionText: String {
        switch self {
        case .create:
            return L("Enter a name for the new project.")
        case .rename:
            return L("Enter the new project name.")
        }
    }

    var buttonTitle: String {
        switch self {
        case .create:
            return L("Create")
        case .rename:
            return L("Rename")
        }
    }
}

private struct ProjectNamePromptCard: View {
    let mode: ProjectPromptMode
    @Binding var text: String
    @Binding var shouldBecomeFirstResponder: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(EditorShellStyle.agentWorking)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.windowTitle)
                        .font(.title3.weight(.semibold))
                    Text(mode.descriptionText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                T("Project Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ProjectNameField(
                    text: $text,
                    shouldBecomeFirstResponder: $shouldBecomeFirstResponder,
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )
                .frame(height: 38)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(EditorShellStyle.panelInsetBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(EditorShellStyle.subtleBorder, lineWidth: 1)
                )
            }

            HStack {
                Button(action: onCancel) { T("Cancel") }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: onSubmit) { Text(mode.buttonTitle) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(24)
        .background(EditorShellStyle.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(EditorShellStyle.subtleBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }
}

private struct ProjectNameField: NSViewRepresentable {
    @Binding var text: String
    @Binding var shouldBecomeFirstResponder: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, shouldBecomeFirstResponder: $shouldBecomeFirstResponder, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.placeholderString = L("Project name…")
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if shouldBecomeFirstResponder, let window = nsView.window, window.firstResponder !== nsView.currentEditor() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            nsView.selectText(nil)
            DispatchQueue.main.async {
                shouldBecomeFirstResponder = false
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var shouldBecomeFirstResponder: Bool
        let onSubmit: () -> Void
        let onCancel: () -> Void

        init(
            text: Binding<String>,
            shouldBecomeFirstResponder: Binding<Bool>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            _text = text
            _shouldBecomeFirstResponder = shouldBecomeFirstResponder
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}
