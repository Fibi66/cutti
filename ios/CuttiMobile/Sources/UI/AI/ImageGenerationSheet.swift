import SwiftUI
import Photos

/// Modal sheet that captures a text prompt + aspect ratio, calls the
/// shared `ImageGenerationService` (same relay used on macOS — no
/// model is hardcoded, the cloud decides), and saves the returned
/// PNG to the user's Photo Library. The user can then re-import it
/// into the timeline via the existing `+` picker so no extra media
/// browser UI is needed.
///
/// Reports back to the parent via `onFinished(toast)` so the caller
/// can flash a unified toast (success, auth error, save-denied,
/// etc.) and dismiss itself.
struct ImageGenerationSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var aspect: ImageGenerationSize = .square
    @State private var working: Bool = false
    @State private var errorMessage: String?

    /// Single callback — receives a toast string describing the
    /// outcome. The parent closes this sheet and surfaces the toast.
    let onFinished: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promptField
                    aspectPicker
                    if let err = errorMessage {
                        Text(L(err))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("生成 AI 图像")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(working ? "生成中…" : "生成") { Task { await generate() } }
                        .foregroundStyle(.pink)
                        .disabled(working || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if working { busyOverlay } }
        }
    }

    // MARK: - Pieces

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("描述你想要的画面")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            TextEditor(text: $prompt)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 140)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                .foregroundStyle(.white)
        }
    }

    private var aspectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("画面比例")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 10) {
                aspectChip(.square, label: "1:1")
                aspectChip(.landscape, label: "16:9")
                aspectChip(.portrait, label: "9:16")
            }
        }
    }

    private func aspectChip(_ value: ImageGenerationSize, label: String) -> some View {
        let selected = aspect == value
        return Button {
            aspect = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.pink : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.2)
                Text("正在生成…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
        }
    }

    // MARK: - Generation

    private func generate() async {
        errorMessage = nil
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        working = true
        defer { working = false }

        do {
            let png = try await ImageGenerationService.shared.generate(
                prompt: trimmed,
                size: aspect
            )
            try await saveToPhotos(pngData: png)
            onFinished("已保存到相册,导入视频时可选")
        } catch {
            errorMessage = "生成失败:\(error.localizedDescription)"
        }
    }

    /// Ask the Photos framework to store the PNG. Uses
    /// `.addOnly` authorization which is the narrowest scope —
    /// matches the `NSPhotoLibraryAddUsageDescription` already in
    /// Info.plist.
    private func saveToPhotos(pngData: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Swift.Error>) in
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: pngData, options: nil)
            } completionHandler: { success, err in
                if success { cont.resume() }
                else { cont.resume(throwing: err ?? SaveError.unknown) }
            }
        }
    }

    enum SaveError: Swift.Error, LocalizedError {
        case permissionDenied
        case unknown

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "未授权写入相册"
            case .unknown:          return "写入相册失败"
            }
        }
    }
}
