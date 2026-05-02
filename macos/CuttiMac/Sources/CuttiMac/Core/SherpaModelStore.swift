import Foundation

/// Persists the sherpa-onnx speaker-diarization model files to
/// `~/Library/Application Support/cutti/models/sherpa/` and downloads
/// them on first use. The models are kept out of the app bundle so
/// - we don't bloat the installer with ~47MB of ONNX weights, and
/// - users who never touch the "Detect speakers" feature never pay
///   the download cost.
///
/// Both models originate from sherpa-onnx's official GitHub releases.
/// We deliberately pin the filenames so upgrades are explicit.
@MainActor
final class SherpaModelStore: ObservableObject {

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double)   // 0.0…1.0
        case ready
        case failed(String)
    }

    static let shared = SherpaModelStore()

    @Published private(set) var state: State = .notDownloaded

    /// Local path to pyannote-segmentation-3-0 ONNX (after extraction).
    let segmentationModelPath: URL
    /// Local path to the 3D-Speaker embedding ONNX.
    let embeddingModelPath: URL

    private let modelsDir: URL
    private let segmentationArchiveURL: URL
    private let embeddingArchiveURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")

        let dir = appSupport
            .appendingPathComponent("cutti", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("sherpa", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        self.modelsDir = dir
        self.segmentationModelPath = dir.appendingPathComponent("segmentation.onnx")
        self.embeddingModelPath = dir.appendingPathComponent("embedding.onnx")

        // URLs pinned to sherpa-onnx model releases. Tarball URL needs
        // post-download extraction; the embedding ONNX is raw.
        self.segmentationArchiveURL = URL(string:
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/" +
            "speaker-segmentation-models/" +
            "sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
        )!
        self.embeddingArchiveURL = URL(string:
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/" +
            "speaker-recongition-models/" +
            "3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx"
        )!

        if isOnDisk {
            self.state = .ready
        }
    }

    /// Returns true only when both model files are present on disk.
    var isReady: Bool { isOnDisk }

    private var isOnDisk: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: segmentationModelPath.path)
            && fm.fileExists(atPath: embeddingModelPath.path)
    }

    /// Ensure both models are on disk. Idempotent; returns immediately
    /// when the files already exist. Safe to call from any callsite —
    /// concurrent calls coalesce because we check `isReady` first and
    /// the second caller will see the completed state.
    func ensureReady() async throws {
        if isReady {
            state = .ready
            return
        }

        state = .downloading(progress: 0)

        do {
            // 1. Segmentation tarball → extract → move ONNX.
            if !FileManager.default.fileExists(atPath: segmentationModelPath.path) {
                try await fetchSegmentation()
            }

            state = .downloading(progress: 0.2)

            // 2. Embedding raw ONNX.
            if !FileManager.default.fileExists(atPath: embeddingModelPath.path) {
                try await fetchEmbedding()
            }

            state = isOnDisk ? .ready : .failed("Model files missing after download.")
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func fetchSegmentation() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sherpa-seg-\(UUID().uuidString).tar.bz2")
        let (downloadedURL, _) = try await URLSession.shared.download(from: segmentationArchiveURL)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.moveItem(at: downloadedURL, to: tmp)

        // Extract: `tar -xjf <file> -C <dir>` produces a directory
        // named "sherpa-onnx-pyannote-segmentation-3-0" containing
        // `model.onnx`. We copy that single file to its permanent
        // location and blow away the rest.
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sherpa-seg-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xjf", tmp.path, "-C", extractDir.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw SherpaModelStoreError.extractionFailed
        }

        let onnx = extractDir
            .appendingPathComponent("sherpa-onnx-pyannote-segmentation-3-0")
            .appendingPathComponent("model.onnx")
        guard FileManager.default.fileExists(atPath: onnx.path) else {
            throw SherpaModelStoreError.extractionFailed
        }
        try? FileManager.default.removeItem(at: segmentationModelPath)
        try FileManager.default.moveItem(at: onnx, to: segmentationModelPath)
    }

    private func fetchEmbedding() async throws {
        let (downloadedURL, _) = try await URLSession.shared.download(from: embeddingArchiveURL)
        try? FileManager.default.removeItem(at: embeddingModelPath)
        try FileManager.default.moveItem(at: downloadedURL, to: embeddingModelPath)
    }
}

enum SherpaModelStoreError: Error, LocalizedError {
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .extractionFailed:
            return "Failed to extract the speaker-segmentation model archive."
        }
    }
}
