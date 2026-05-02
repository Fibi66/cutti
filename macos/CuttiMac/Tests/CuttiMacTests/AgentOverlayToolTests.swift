import XCTest
@testable import CuttiMac

final class AgentOverlayToolTests: XCTestCase {

    func test_parse_acceptsStringPropsJSON() {
        let args: [String: Any] = [
            "template_id": "ChapterTitle",
            "props_json": #"{"title":"Hello","theme":"dark"}"#,
            "duration_seconds": 3.0,
            "composed_time": 12.5,
        ]

        let req = GenerateOverlayRequest.parse(from: args)

        XCTAssertEqual(req?.templateID, "ChapterTitle")
        XCTAssertEqual(req?.propsJSON, #"{"title":"Hello","theme":"dark"}"#)
        XCTAssertEqual(req?.durationSeconds, 3.0)
        XCTAssertEqual(req?.composedTime, 12.5)
    }

    /// OpenAI function-calling sometimes returns `props_json` as a
    /// nested object despite the schema marking it a string. The parser
    /// should coerce that shape into a JSON-encoded string so the
    /// downstream renderer contract stays uniform.
    func test_parse_acceptsObjectPropsJSONByReEncoding() {
        let args: [String: Any] = [
            "template_id": "ChapterTitle",
            "props_json": ["title": "Hi", "theme": "accent"],
            "composed_time": 0,
        ]

        let req = GenerateOverlayRequest.parse(from: args)

        XCTAssertNotNil(req)
        let decoded = try? JSONSerialization.jsonObject(
            with: Data(req!.propsJSON.utf8)
        ) as? [String: String]
        XCTAssertEqual(decoded?["title"], "Hi")
        XCTAssertEqual(decoded?["theme"], "accent")
    }

    func test_parse_clampsDurationAndComposedTime() {
        let args: [String: Any] = [
            "template_id": "ChapterTitle",
            "props_json": "{}",
            "duration_seconds": 999,
            "composed_time": -5,
        ]

        let req = GenerateOverlayRequest.parse(from: args)

        XCTAssertEqual(req?.durationSeconds, 30, "upper-clamped to sanity ceiling")
        XCTAssertEqual(req?.composedTime, 0, "never negative")
    }

    func test_parse_returnsNilWithoutTemplateOrProps() {
        XCTAssertNil(GenerateOverlayRequest.parse(from: [
            "props_json": "{}",
            "composed_time": 0,
        ]))
        XCTAssertNil(GenerateOverlayRequest.parse(from: [
            "template_id": "ChapterTitle",
            "composed_time": 0,
        ]))
    }

    func test_catalog_advertisesChapterTitle() {
        XCTAssertTrue(RemotionOverlayCatalog.supportedTemplateIDs.contains("ChapterTitle"))
        XCTAssertTrue(RemotionOverlayCatalog.systemPromptDescription.contains("ChapterTitle"))
    }

    // MARK: - defaultProjectDirectory

    func test_defaultProjectDirectory_honorsEnvOverride() throws {
        let key = "CUTTI_REMOTION_DIR"
        let original = ProcessInfo.processInfo.environment[key]
        setenv(key, "/custom/remotion", 1)
        defer {
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }

        let url = LocalRemotionRenderer.defaultProjectDirectory()
        XCTAssertEqual(url.path, "/custom/remotion")
    }

    func test_defaultProjectDirectory_fallsBackToRepoRelativePath() {
        let key = "CUTTI_REMOTION_DIR"
        let original = ProcessInfo.processInfo.environment[key]
        unsetenv(key)
        defer {
            if let original {
                setenv(key, original, 1)
            }
        }

        let url = LocalRemotionRenderer.defaultProjectDirectory()
        XCTAssertEqual(url.lastPathComponent, "remotion")
        // Walk-up always produces an absolute path.
        XCTAssertTrue(url.path.hasPrefix("/"))
    }
}
