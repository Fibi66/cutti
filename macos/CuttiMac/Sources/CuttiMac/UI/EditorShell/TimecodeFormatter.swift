import Foundation

enum TimecodeFormatter {
    /// Formats elapsed wall-clock time as `HH:MM:SS:FF`.
    ///
    /// This shell-layer helper intentionally keeps the hours/minutes/seconds fields based on
    /// elapsed seconds and derives only the frame field from the sub-second remainder multiplied
    /// by the provided frame rate. It is a lightweight display formatter, not an exact drop-frame
    /// timecode implementation.
    static func string(seconds: Double, fps: Double) -> String {
        let safeSeconds = max(0, seconds.isFinite ? seconds : 0)
        let frameRate = safeFrameRate(from: fps)
        let frameDisplayCount = displayFrameCount(for: frameRate)
        let totalSeconds = Int(safeSeconds.rounded(.down))
        let fractionalSeconds = safeSeconds - Double(totalSeconds)
        let frames = frameCount(
            for: fractionalSeconds,
            fps: frameRate,
            frameDisplayCount: frameDisplayCount
        )
        let secondsPart = totalSeconds % 60
        let minutesPart = (totalSeconds / 60) % 60
        let hoursPart = totalSeconds / 3600

        return String(format: "%02d:%02d:%02d:%02d", hoursPart, minutesPart, secondsPart, frames)
    }

    private static func safeFrameRate(from fps: Double) -> Double {
        guard fps.isFinite else { return 1 }
        return max(1, fps)
    }

    private static func displayFrameCount(for fps: Double) -> Int {
        max(1, Int(fps.rounded()))
    }

    private static func frameCount(for fractionalSeconds: Double, fps: Double, frameDisplayCount: Int) -> Int {
        let scaledFrames = fractionalSeconds * fps
        let adjustedFrames = scaledFrames + scaledFrames.ulp.squareRoot()
        let unclampedFrames = Int(adjustedFrames.rounded(.down))
        return min(unclampedFrames, frameDisplayCount - 1)
    }
}
