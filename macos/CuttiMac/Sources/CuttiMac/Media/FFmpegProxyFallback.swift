import Foundation

struct FFmpegProxyFallback: ProxyTranscoding {
    
    /// Determines if a primary transcoder failure is eligible for ffmpeg fallback.
    /// Only allows explicit classes of AVFoundation failures that ffmpeg might handle.
    static func isEligible(primaryFailure: String) -> Bool {
        let lowercased = primaryFailure.lowercased()
        
        // Allow only specific failure classes that ffmpeg might resolve
        let eligiblePatterns = [
            "unsupported apple-native export preset",
            "cannot decode"
        ]
        
        return eligiblePatterns.contains { pattern in
            lowercased.contains(pattern)
        }
    }

    /// Builds the ffmpeg argument list for a ProRes 422 / PCM editing proxy (.mov).
    ///
    /// - Note: **Resolution asymmetry with primary transcoder.**
    ///   The Apple-native primary path (`AVProxyTranscoder`) preserves the source
    ///   resolution because `AVAssetExportSession` respects the asset dimensions.
    ///   This fallback path deliberately scales to a 1280×720 ceiling so that
    ///   ffmpeg-produced proxies stay at a predictable, edit-friendly size even for
    ///   very-high-resolution sources (e.g. 4K/6K RAW) where ffmpeg ProRes encode
    ///   times and file sizes would otherwise be unacceptably large.
    ///   If you need resolution parity, raise a follow-up ticket before changing the
    ///   scale filter — the decision was intentional, not an oversight.
    static func makeArguments(sourceURL: URL, destinationURL: URL) -> [String] {
        [
            "ffmpeg",
            "-i", sourceURL.path,
            "-vf", "scale=1280:720:force_original_aspect_ratio=decrease",
            "-c:v", "prores_ks",
            "-profile:v", "2",          // ProRes 422
            "-pix_fmt", "yuv422p10le",
            "-c:a", "pcm_s16le",
            "-y",                        // Overwrite output file if it exists
            destinationURL.path
        ]
    }
    
    func transcode(
        sourceURL: URL,
        destinationURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> TranscodeResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = FFmpegProxyFallback.makeArguments(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Use terminationHandler + withCheckedContinuation so the cooperative
        // thread is not blocked. The OS calls terminationHandler on a private
        // background thread once the process exits.
        // Cancellation: hook withTaskCancellationHandler so an abort signal
        // tears down the ffmpeg subprocess instead of waiting for it.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    if finishedProcess.terminationStatus == 0 {
                        // Synthesise a final 1.0 sample so progress UIs
                        // wrap up cleanly. ffmpeg stderr parsing for live
                        // progress is out of scope for this fallback.
                        progress(1.0)
                        continuation.resume(returning: .success)
                    } else {
                        let errorData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(returning: .failure(
                            "FFmpeg failed with status \(finishedProcess.terminationStatus): \(errorOutput)"
                        ))
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failure(
                        "FFmpeg execution failed: \(error.localizedDescription)"
                    ))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
