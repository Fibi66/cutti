import SwiftUI

/// Bottom-sheet cover-frame picker. A horizontal strip of thumbnails
/// sampled across the whole composed timeline; tapping a thumbnail or
/// dragging sets the tentative cover time. "完成" commits into
/// `ProjectDocument.coverTimeSeconds`.
struct CoverPickerSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ThumbnailStore.shared

    @State private var selectedTime: Double = 0

    var body: some View {
        let total = max(document.primaryDurationSeconds, 0.1)

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置封面").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }

            preview(for: selectedTime)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            strip(total: total)
                .frame(height: 60)

            Button {
                document.coverTimeSeconds = selectedTime
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color.pink))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            selectedTime = document.coverTimeSeconds ?? document.currentTime
        }
    }

    @ViewBuilder
    private func preview(for seconds: Double) -> some View {
        if let resolved = document.resolveComposedTime(seconds),
           let url = mediaURL(for: resolved.sourceVideoID),
           let img = store.thumbnail(
               for: url,
               mediaID: resolved.sourceVideoID,
               atSeconds: resolved.sourceSeconds
           )
        {
            Image(uiImage: img).resizable().scaledToFit()
        } else {
            Color(white: 0.12)
        }
    }

    private func strip(total: Double) -> some View {
        GeometryReader { geo in
            let tileCount = max(8, Int(geo.size.width / 48))
            let step = total / Double(tileCount)
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    ForEach(0..<tileCount, id: \.self) { i in
                        let t = step * Double(i)
                        thumbTile(time: t)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .onTapGesture { selectedTime = t }
                    }
                }
                // Slider cursor
                let cursorX = CGFloat(selectedTime / total) * geo.size.width
                Rectangle()
                    .fill(Color.pink)
                    .frame(width: 3, height: 60)
                    .offset(x: cursorX - 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = max(0, min(1, v.location.x / geo.size.width))
                        selectedTime = Double(f) * total
                    }
            )
        }
    }

    @ViewBuilder
    private func thumbTile(time: Double) -> some View {
        if let resolved = document.resolveComposedTime(time),
           let url = mediaURL(for: resolved.sourceVideoID),
           let img = store.thumbnail(
               for: url,
               mediaID: resolved.sourceVideoID,
               atSeconds: resolved.sourceSeconds
           )
        {
            Image(uiImage: img).resizable().scaledToFill().clipped()
        } else {
            Color(white: 0.15)
        }
    }

    private func mediaURL(for mediaID: UUID) -> URL? {
        guard let record = document.manifest.media.first(where: { $0.id == mediaID })
        else { return nil }
        if let proxy = record.derived.proxyRelativePath {
            return document.store.projectRoot.appendingPathComponent(proxy)
        }
        return URL(fileURLWithPath: record.sourcePath)
    }
}
