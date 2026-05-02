import SwiftUI
import PhotosUI
import CuttiKit

/// Thin SwiftUI wrapper around `PHPickerViewController` limited to
/// videos. Writes the picked file to a temporary location and calls
/// `onPicked` with the local URL. Callers are responsible for moving
/// or copying the file before the closure returns — the picker
/// deletes the temp file shortly after.
struct VideoPicker: UIViewControllerRepresentable {
    typealias UIViewControllerType = PHPickerViewController

    let onPicked: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(
            _ picker: PHPickerViewController,
            didFinishPicking results: [PHPickerResult]
        ) {
            guard let result = results.first else {
                parent.onCancel()
                return
            }
            let provider = result.itemProvider
            // Prefer a file-based representation so we can copy the
            // actual backing file with its original container format.
            let typeIdentifier = provider.registeredTypeIdentifiers
                .first { $0.hasPrefix("public.") && $0.contains("movie") || $0.contains("mpeg-4") }
                ?? "public.movie"

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
                guard let self else { return }
                guard let url, error == nil else {
                    DispatchQueue.main.async { self.parent.onCancel() }
                    return
                }
                // PHPicker deletes the source shortly after this
                // callback returns; copy it to a stable temp file we
                // own so the importer can work with it.
                let tmp = FileManager.default.temporaryDirectory
                    .appending(path: "picked-\(UUID().uuidString).\(url.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: url, to: tmp)
                    DispatchQueue.main.async { self.parent.onPicked(tmp) }
                } catch {
                    DispatchQueue.main.async { self.parent.onCancel() }
                }
            }
        }
    }
}
