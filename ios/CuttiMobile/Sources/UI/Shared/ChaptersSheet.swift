import SwiftUI
import CuttiKit

/// Bottom-sheet editor for the project's chapter list. Mirrors the
/// macOS `ChapterBarOverlay` editing affordances (add at playhead,
/// rename, delete) without porting the live-drag boundary handles —
/// those need a deeper port and are tracked separately.
struct ChaptersSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    @State private var renamingID: UUID?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach(document.chapters) { chapter in
                        row(chapter)
                    }
                    .onDelete { offsets in
                        for i in offsets {
                            document.deleteChapter(id: document.chapters[i].id)
                        }
                    }
                    if document.chapters.isEmpty {
                        Text("还没有章节。点击底部按钮在播放头新增。")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .listStyle(.plain)

                Button {
                    _ = document.addChapterAtPlayhead()
                } label: {
                    Label("在播放头新增章节", systemImage: "plus.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .background(Color.pink)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.foregroundStyle(.white)
                }
            }
            .alert("重命名章节", isPresented: Binding(
                get: { renamingID != nil },
                set: { if !$0 { renamingID = nil } }
            )) {
                TextField("章节标题", text: $renameText)
                Button("取消", role: .cancel) { renamingID = nil }
                Button("保存") {
                    if let id = renamingID { document.renameChapter(id: id, title: renameText) }
                    renamingID = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ chapter: VideoChapter) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(chapter.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(format(chapter.startSeconds)) – \(format(chapter.endSeconds))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                renameText = chapter.title
                renamingID = chapter.id
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.white.opacity(0.04))
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
