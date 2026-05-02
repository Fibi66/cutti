import SwiftUI
import CuttiKit

struct MediaBrowserSidebar: View {
    let records: [MediaAssetRecord]
    let projectRoot: URL?
    @Binding var selectedRecordID: UUID?
    @Binding var searchQuery: String
    let onSelect: (UUID) -> Void
    let onDelete: ((UUID) -> Void)?

    /// Compact list is the only layout now — narrower than the old
    /// list mode so more clips fit in the right-column panel without
    /// horizontal clipping. Values chosen to still let 16:9 thumbs
    /// read cleanly at a glance.
    private static let thumbnailSize = CGSize(width: 80, height: 45)
    private static let rowSpacing: CGFloat = 8
    private static let detailSpacing: CGFloat = 3
    private static let rowPadding: CGFloat = 8

    /// Whether the search field is currently revealed. Collapsed into
    /// a magnifying-glass icon by default to keep the panel clean.
    @FocusState private var isSearchFieldFocused: Bool

    private var filteredRecords: [MediaAssetRecord] {
        MediaBrowserQuery.filter(records: records, query: searchQuery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(filteredRecords) { record in
                        row(for: record)
                            .padding(Self.rowPadding)
                            .background(background(for: record.id))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture {
                                guard shouldDispatchShellSelection(
                                    currentSelection: selectedRecordID,
                                    tappedID: record.id
                                ) else {
                                    return
                                }
                                selectedRecordID = record.id
                                onSelect(record.id)
                            }
                            .draggable("media:\(record.id.uuidString)") {
                                // Drag preview: thumbnail + title so the
                                // user sees which clip they're pulling
                                // onto the timeline.
                                HStack(spacing: 6) {
                                    Image(systemName: "film")
                                    Text(MediaRecordPresentation.title(for: record))
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(EditorShellStyle.accentSolid.opacity(0.9))
                                .foregroundStyle(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    onDelete?(record.id)
                                } label: {
                                    Label { T("Delete") } icon: { Image(systemName: "trash") }
                                }
                            }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(EditorShellStyle.panelBackground)
    }

    /// Top strip: magnifying-glass toggle on the right. Clicking it
    /// slides out a compact search field; clicking again (or clearing
    /// the query) collapses it back to the icon.
    @ViewBuilder
    private var searchBar: some View {
        EmptyView()
    }

    @ViewBuilder
    private func row(for record: MediaAssetRecord) -> some View {
        HStack(alignment: .center, spacing: Self.rowSpacing) {
            PosterThumbnailView(
                record: record,
                projectRoot: projectRoot,
                size: Self.thumbnailSize
            )

            details(for: record)

            Spacer(minLength: 0)
        }
    }

    private func details(for record: MediaAssetRecord) -> some View {
        VStack(alignment: .leading, spacing: Self.detailSpacing) {
            Text(MediaRecordPresentation.title(for: record))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(EditorShellStyle.textPrimary)

            // Duration + metadata in monospaced digits so aligned
            // timecodes read as a neat column when rows are stacked.
            Text(MediaRecordPresentation.metadataLine(for: record))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(EditorShellStyle.textTertiary)
                .lineLimit(1)

            // Only surface the lifecycle chip for problem states — users
            // don't care that a clip is "Analyzing" or "Ready"; the
            // video tile speaks for itself. Failures and missing files
            // are the exception: those we *must* call out.
            if record.status == .failed || record.status == .missing {
                StatusChipView(status: record.status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func background(for id: UUID) -> some ShapeStyle {
        // Obsidian style: rows stay transparent in the default state
        // so the panel reads as a clean list. Selected rows pop with a
        // subtle panel-3 fill (no amber) — the amber accent is reserved
        // for primary actions + playhead so it stays meaningful.
        selectedRecordID == id
            ? AnyShapeStyle(EditorShellStyle.backgroundSelected)
            : AnyShapeStyle(Color.clear)
    }
}
