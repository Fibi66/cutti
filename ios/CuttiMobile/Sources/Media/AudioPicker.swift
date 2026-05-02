import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// System document picker limited to audio files — Files, Music,
/// iCloud Drive, etc. Writes the picked file to a temp location and
/// hands the URL to `onPicked`.
struct AudioPicker: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIDocumentPickerViewController

    let onPicked: (URL) -> Void
    let onCancel: () -> Void
    var includeVideo: Bool = false

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.audio, .mp3, .wav, .mpeg4Audio, UTType("com.apple.m4a-audio") ?? .audio]
        if includeVideo {
            types.append(contentsOf: [.movie, .video, .mpeg4Movie, .quickTimeMovie])
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ c: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: AudioPicker
        init(_ p: AudioPicker) { self.parent = p }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let src = urls.first else { parent.onCancel(); return }
            // `asCopy: true` gives us a temp URL we already own — hand
            // it straight to the caller. Caller deletes after import.
            parent.onPicked(src)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
