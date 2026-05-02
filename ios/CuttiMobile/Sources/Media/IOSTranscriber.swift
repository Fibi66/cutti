import Foundation
import AVFoundation
import Speech
import os
import CuttiKit

private let tLog = Logger(subsystem: "app.cutti.ios", category: "Transcriber")

private func tPrint(_ msg: String) {
    tLog.log("\(msg, privacy: .public)")
    NSLog("[Transcriber] %@", msg)
}

/// iOS-native speech transcription backed by `SFSpeechRecognizer`.
/// Takes a single AV asset URL and returns a list of `SubtitleEntry`
/// relative to the clip's start. No network, no OpenAI needed.
///
/// macOS has its own `SpeechTranscriptionService` (symbol name is the
/// same, different package) — this is the iOS-side implementation
/// built against Speech.framework which is only available on iOS /
/// visionOS targets.
enum IOSTranscriber {

    struct Options: Sendable {
        /// BCP-47 tag. Nil = on-device default (system preferred locale).
        var locale: Locale? = nil
        /// When true, requires on-device recognition (no network hop).
        /// On-device support is locale-dependent; we fall back to
        /// server recognition when unavailable.
        var preferOnDevice: Bool = true
    }

    enum TranscribeError: LocalizedError {
        case authDenied
        case unsupportedLocale
        case recognizerUnavailable
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .authDenied:           return "请允许语音识别权限。"
            case .unsupportedLocale:    return "系统不支持当前语言的语音识别。"
            case .recognizerUnavailable:return "语音识别暂时不可用。"
            case .recognitionFailed(let m): return "识别失败：\(m)"
            }
        }
    }

    /// Request Speech authorization. Must be called once before use.
    ///
    /// Intentionally *not* `@MainActor`. Speech.framework invokes the
    /// completion callback on an arbitrary background queue; if this
    /// function were main-isolated, the continuation's resume closure
    /// would inherit that isolation and trip the Swift concurrency
    /// queue-assertion (EXC_BREAKPOINT / SIGTRAP in libdispatch) the
    /// first time the user kicked off transcription. Bridge the
    /// callback from a nonisolated context and let the caller hop
    /// back to whatever actor it needs.
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    /// Transcribe a single file. Returns subtitle entries relative to
    /// the file's timeline origin (0 = start of the passed URL).
    static func transcribe(
        fileURL: URL,
        options: Options = .init()
    ) async throws -> [SubtitleEntry] {
        tPrint("transcribe begin url=\(fileURL.lastPathComponent) locale=\(options.locale?.identifier ?? "default")")
        let auth = await requestAuthorization()
        tPrint("auth status=\(auth.rawValue)")
        guard auth == .authorized else { throw TranscribeError.authDenied }

        let locale = options.locale ?? Locale(identifier: "zh-CN")
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            tPrint("unsupported locale=\(locale.identifier)")
            throw TranscribeError.unsupportedLocale
        }
        guard recognizer.isAvailable else {
            tPrint("recognizer not available locale=\(locale.identifier) onDevice=\(recognizer.supportsOnDeviceRecognition)")
            throw TranscribeError.recognizerUnavailable
        }

        let req = SFSpeechURLRecognitionRequest(url: fileURL)
        req.shouldReportPartialResults = false
        // Prefer on-device recognition on real hardware, but the iOS
        // simulator doesn't ship with the local speech models and
        // returns kAFAssistantErrorDomain 1101 ("Local speech
        // recognition service failed") for every request when
        // requiresOnDeviceRecognition is true. Fall back to server
        // recognition there so 智能字幕 works end-to-end in dev
        // without devs needing a physical device to test.
        #if targetEnvironment(simulator)
        req.requiresOnDeviceRecognition = false
        #else
        req.requiresOnDeviceRecognition = options.preferOnDevice
            && recognizer.supportsOnDeviceRecognition
        #endif
        tPrint("recognizer ready onDevice=\(req.requiresOnDeviceRecognition) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")

        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: req) { result, error in
                if let error = error {
                    let ns = error as NSError
                    tPrint("recognition error domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) info=\(ns.userInfo)")
                    cont.resume(throwing: TranscribeError.recognitionFailed("[\(ns.domain) \(ns.code)] \(ns.localizedDescription)"))
                    return
                }
                guard let result = result, result.isFinal else { return }
                let entries = result.bestTranscription.segments.map { seg in
                    SubtitleEntry(
                        id: UUID(),
                        relativeStart: seg.timestamp,
                        relativeDuration: seg.duration,
                        text: seg.substring
                    )
                }
                tPrint("recognition done entries=\(entries.count)")
                cont.resume(returning: entries)
            }
        }
    }
}
