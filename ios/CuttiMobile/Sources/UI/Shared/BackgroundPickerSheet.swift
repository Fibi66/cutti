import SwiftUI
import CuttiKit

/// Background picker for the aspect-ratio letterbox area around the
/// video. Options: blurred player fill, or any of 10 preset colors
/// (incl. black / white / soft gradients). Persists only in session
/// memory via `ProjectDocument.background`.
struct BackgroundPickerSheet: View {
    @EnvironmentObject var document: ProjectDocument
    @Environment(\.dismiss) private var dismiss

    private let palette: [(String, RGBAColor)] = [
        ("黑", .init(red: 0, green: 0, blue: 0, alpha: 1)),
        ("白", .init(red: 1, green: 1, blue: 1, alpha: 1)),
        ("灰", .init(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)),
        ("米色", .init(red: 0.95, green: 0.92, blue: 0.84, alpha: 1)),
        ("浅粉", .init(red: 1.0, green: 0.78, blue: 0.86, alpha: 1)),
        ("浅蓝", .init(red: 0.74, green: 0.88, blue: 1.0, alpha: 1)),
        ("浅绿", .init(red: 0.78, green: 0.93, blue: 0.82, alpha: 1)),
        ("黄", .init(red: 1.0, green: 0.92, blue: 0.5, alpha: 1)),
        ("珊瑚", .init(red: 1.0, green: 0.56, blue: 0.44, alpha: 1)),
        ("深蓝", .init(red: 0.12, green: 0.18, blue: 0.42, alpha: 1)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("背景").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
            }

            blurTile

            Text("颜色")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            colorGrid
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
    }

    private var blurTile: some View {
        Button {
            document.background = .blur
        } label: {
            HStack {
                Image(systemName: "drop.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                colors: [.pink.opacity(0.6), .blue.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("模糊").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("用视频画面填充背景").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                if isBlurSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.pink)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }

    private var colorGrid: some View {
        let cols = [GridItem](repeating: GridItem(.flexible(), spacing: 10), count: 5)
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(palette, id: \.0) { entry in
                let c = entry.1
                let selected = isColorSelected(c)
                Button {
                    document.background = .color(c)
                } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selected ? Color.pink : Color.white.opacity(0.18),
                                                  lineWidth: selected ? 2 : 1)
                            )
                            .frame(height: 48)
                        Text(L(entry.0))
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? .pink : .white.opacity(0.7))
                    }
                }
            }
        }
    }

    private var isBlurSelected: Bool {
        if case .blur = document.background { return true }
        return false
    }

    private func isColorSelected(_ c: RGBAColor) -> Bool {
        if case .color(let cur) = document.background {
            return abs(cur.red - c.red) < 0.01
                && abs(cur.green - c.green) < 0.01
                && abs(cur.blue - c.blue) < 0.01
        }
        return false
    }
}
