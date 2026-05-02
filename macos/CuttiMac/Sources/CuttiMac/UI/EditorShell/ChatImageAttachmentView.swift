import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inline image attachment shown under a chat bubble. Tap opens a
/// fullscreen viewer; right-click exposes Save as… / Show in Finder /
/// Copy. Loads the image off the main thread so big PNGs don't stall
/// the chat scroll.
struct ChatImageAttachmentView: View {
    let url: URL
    let onOpen: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(EditorShellStyle.borderSubtle, lineWidth: 1)
                    )
            } else {
                // Skeleton while decoding.
                RoundedRectangle(cornerRadius: 8)
                    .fill(EditorShellStyle.backgroundSurface)
                    .frame(width: 220, height: 140)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .help(L("Click to open full size · right-click for Save / Show in Finder"))
        .contextMenu {
            Button { onOpen() } label: { T("Open full size") }
            Button { saveAs() } label: { T("Save as…") }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: { T("Show in Finder") }
            Button { copyToPasteboard() } label: { T("Copy image") }
        }
        .task(id: url.path) {
            thumbnail = await Self.loadThumbnail(at: url)
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        if let type = UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            NSSound.beep()
        }
    }

    private func copyToPasteboard() {
        guard let image = NSImage(contentsOf: url) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Decode off-main to keep the chat scroll responsive on large
    /// FLUX outputs (≈ 1792×1024 PNGs are ~1–2 MB decoded).
    private static func loadThumbnail(at url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
    }
}

/// Fullscreen-ish modal viewer. Uses a plain SwiftUI sheet with the
/// image scaled to fit. Save / Show in Finder / Copy are exposed as
/// toolbar buttons as well as via right-click.
struct ChatImageFullscreenView: View {
    let url: URL
    let onDismiss: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    saveAs()
                } label: {
                    Label { T("Save") } icon: { Image(systemName: "square.and.arrow.down") }
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label { T("Finder") } icon: { Image(systemName: "folder") }
                }
                Button {
                    copyToPasteboard()
                } label: {
                    Label { T("Copy") } icon: { Image(systemName: "doc.on.doc") }
                }
                Button(action: onDismiss) { T("Done") }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(EditorShellStyle.chromeBackground)

            Divider()

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .padding(40)
                }
            }
            .frame(minWidth: 480, minHeight: 320)
            .background(Color.black.opacity(0.55))
        }
        .frame(minWidth: 600, minHeight: 480)
        .task(id: url.path) {
            image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        if let type = UTType(filenameExtension: url.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            NSSound.beep()
        }
    }

    private func copyToPasteboard() {
        guard let image else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }
}
