import SwiftUI
import CuttiKit

// MARK: - RequestKey view compatibility

extension ProxyThumbnailService.RequestKey {
    /// View-level alias for `canLoad`; keeps existing call-sites compiling.
    var canLoadPoster: Bool { canLoad }
}

struct PosterThumbnailView: View {
    /// Stable type alias so the smoke-test surface (`PosterThumbnailView.PosterLoadToken`,
    /// `posterLoadToken(for:projectRoot:)`) keeps compiling without duplicating logic.
    typealias PosterLoadToken = ProxyThumbnailService.RequestKey

    let record: MediaAssetRecord
    let projectRoot: URL?
    let size: CGSize

    @State private var image: NSImage?

    init(
        record: MediaAssetRecord,
        projectRoot: URL?,
        size: CGSize = CGSize(width: 112, height: 64)
    ) {
        self.record = record
        self.projectRoot = projectRoot
        self.size = size
    }

    /// Returns a `PosterLoadToken` (i.e. `ProxyThumbnailService.RequestKey`) for the
    /// given record and optional project root. Always delegates to the service-owned
    /// factory so key construction logic is never duplicated in the view layer.
    static func posterLoadToken(
        for record: MediaAssetRecord,
        projectRoot: URL?
    ) -> PosterLoadToken {
        ProxyThumbnailService.requestKey(for: record, projectRoot: projectRoot)
    }

    var body: some View {
        let loadToken = Self.posterLoadToken(for: record, projectRoot: projectRoot)

        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "film")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text(MediaRecordPresentation.statusText(for: record.status))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.06))
        )
        .task(id: loadToken) {
            await loadPoster(for: loadToken)
        }
    }

    @MainActor
    private func loadPoster(for loadToken: PosterLoadToken) async {
        image = nil

        guard loadToken.canLoadPoster else {
            return
        }

        let loaded = await ProxyThumbnailService.shared.image(for: record, projectRoot: projectRoot)

        guard !Task.isCancelled else {
            return
        }

        image = loaded
    }
}
