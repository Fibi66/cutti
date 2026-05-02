import AVFoundation
import Foundation

struct AVProxyTranscoder: ProxyTranscoding {
    
    func transcode(sourceURL: URL, destinationURL: URL) async -> TranscodeResult {
        let asset = AVURLAsset(url: sourceURL)
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AppleSiliconProxySettings.exportPreset
        ) else {
            let failureMessage = "Export failed: Unsupported Apple-native export preset"
            if FFmpegProxyFallback.isEligible(primaryFailure: failureMessage) {
                return .fallbackEligibleFailure(failureMessage)
            } else {
                return .failure(failureMessage)
            }
        }
        
        // Remove existing destination file if present
        if FileManager.default.fileExists(atPath: destinationURL.path()) {
            do {
                try FileManager.default.removeItem(at: destinationURL)
            } catch {
                return .failure("Export failed: Could not remove existing file: \(error.localizedDescription)")
            }
        }
        
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = AppleSiliconProxySettings.outputFileType
        
        await exportSession.export()
        
        switch exportSession.status {
        case .completed:
            return .success
            
        case .failed, .cancelled:
            let errorDescription = exportSession.error?.localizedDescription ?? "Unknown error"
            let failureMessage = "Export failed: \(errorDescription)"
            
            // Check if this failure is eligible for ffmpeg fallback
            if FFmpegProxyFallback.isEligible(primaryFailure: failureMessage) {
                return .fallbackEligibleFailure(failureMessage)
            } else {
                return .failure(failureMessage)
            }
            
        default:
            return .failure("Export ended in unexpected state: \(exportSession.status.rawValue)")
        }
    }
}
