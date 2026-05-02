import XCTest
@testable import CuttiMac

final class ProxyFallbackPolicyTests: XCTestCase {
    
    // MARK: - FFmpegProxyFallback.isEligible tests
    
    func testIsEligibleAcceptsUnsupportedExportPreset() {
        let failure = "Export failed: Unsupported Apple-native export preset"
        XCTAssertTrue(FFmpegProxyFallback.isEligible(primaryFailure: failure))
    }
    
    func testIsEligibleAcceptsCannotDecode() {
        let failure = "Cannot decode video stream"
        XCTAssertTrue(FFmpegProxyFallback.isEligible(primaryFailure: failure))
    }
    
    func testIsEligibleRejectsDiskFull() {
        let failure = "Disk full"
        XCTAssertFalse(FFmpegProxyFallback.isEligible(primaryFailure: failure))
    }
    
    func testIsEligibleRejectsUserCancelled() {
        let failure = "User cancelled"
        XCTAssertFalse(FFmpegProxyFallback.isEligible(primaryFailure: failure))
    }
    
    func testIsEligibleRejectsGenericError() {
        let failure = "Some other error"
        XCTAssertFalse(FFmpegProxyFallback.isEligible(primaryFailure: failure))
    }
    
    // MARK: - AVProxyTranscoder eligibility classification
    
    func testAVProxyTranscoderHandlesRepeatedTranscodeToSameDestination() async throws {
        let transcoder = AVProxyTranscoder()
        let tempDir = try TemporaryDirectory()
        
        // Get the fixture path from the bundle
        guard let fixtureURL = Bundle.module.url(
            forResource: "sample-h264-640x360",
            withExtension: "mp4"
        ) else {
            XCTFail("Could not find fixture file sample-h264-640x360.mp4")
            return
        }
        
        let destinationURL = tempDir.url.appending(path: "output.mov")
        
        // First transcode
        let result1 = await transcoder.transcode(sourceURL: fixtureURL, destinationURL: destinationURL)
        if case .success = result1 {
            // Success - expected
        } else {
            XCTFail("First transcode should succeed, got: \(result1)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path()), "Destination file should exist after first transcode")
        
        // Second transcode to the same destination - should succeed by removing existing file
        let result2 = await transcoder.transcode(sourceURL: fixtureURL, destinationURL: destinationURL)
        if case .success = result2 {
            // Success - expected
        } else {
            XCTFail("Second transcode to same destination should succeed, got: \(result2)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path()), "Destination file should exist after second transcode")
    }
    
    // MARK: - FFmpegProxyFallback transcoding
    
    func testFFmpegProxyFallbackConformsToProxyTranscoding() {
        let fallback = FFmpegProxyFallback()
        XCTAssertNotNil(fallback as ProxyTranscoding)
    }

    func testFFmpegArguments_emitMovProResOutput() {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.mp4")
        let destinationURL = URL(fileURLWithPath: "/tmp/output.mov")

        let arguments = FFmpegProxyFallback.makeArguments(
            sourceURL: sourceURL,
            destinationURL: destinationURL
        )

        // Codec selection
        XCTAssertTrue(arguments.contains("prores_ks"), "Expected prores_ks video codec")
        // Scale filter — must appear as consecutive -vf / filter-string pair
        if let vfFlagIndex = arguments.firstIndex(of: "-vf") {
            XCTAssertEqual(
                arguments[vfFlagIndex + 1],
                "scale=1280:720:force_original_aspect_ratio=decrease",
                "Expected proxy scale filter immediately after -vf flag"
            )
        } else {
            XCTFail("Expected -vf flag in arguments")
        }
        // ProRes profile flag and value — must appear as consecutive elements
        if let profileFlagIndex = arguments.firstIndex(of: "-profile:v") {
            XCTAssertEqual(
                arguments[profileFlagIndex + 1], "2",
                "Expected profile value 2 (ProRes 422) immediately after -profile:v flag"
            )
        } else {
            XCTFail("Expected -profile:v flag in arguments")
        }
        // Pixel format
        XCTAssertTrue(arguments.contains("yuv422p10le"), "Expected yuv422p10le pixel format")
        // Audio codec
        XCTAssertTrue(arguments.contains("pcm_s16le"), "Expected pcm_s16le audio codec")
        // Destination
        XCTAssertTrue(arguments.contains(destinationURL.path), "Expected destination path in arguments")
    }
}
