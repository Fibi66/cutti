import Foundation
import XCTest
@testable import CuttiMac

final class BugReportServiceTests: XCTestCase {
    // MARK: - Path sanitization

    func test_sanitize_replacesUsernamePathWithPlaceholder() {
        let raw = "Crash in /Users/alice/Movies/projects/foo/.cutti.proj/manifest.json"
        let cleaned = BugReportDiagnostics.sanitize(raw)
        XCTAssertEqual(
            cleaned,
            "Crash in /Users/<user>/Movies/projects/foo/.cutti.proj/manifest.json"
        )
    }

    func test_sanitize_replacesMultipleDifferentUsernames() {
        let raw = "/Users/alice/foo and /Users/bob/bar"
        let cleaned = BugReportDiagnostics.sanitize(raw)
        XCTAssertEqual(cleaned, "/Users/<user>/foo and /Users/<user>/bar")
    }

    func test_sanitize_leavesNonUserPathsAlone() {
        let raw = "/private/tmp/foo and /System/Library/x"
        let cleaned = BugReportDiagnostics.sanitize(raw)
        XCTAssertEqual(cleaned, raw)
    }

    func test_sanitize_handlesEmpty() {
        XCTAssertEqual(BugReportDiagnostics.sanitize(""), "")
    }

    // MARK: - Validation

    func test_validate_rejectsTooShortDescription() {
        let report = BugReport(description: "short", reproSteps: "", contactEmail: "", diagnostics: nil)
        XCTAssertThrowsError(try BugReportService.validate(report)) { error in
            guard case BugReportError.validation = error else {
                return XCTFail("Expected validation error, got \(error)")
            }
        }
    }

    func test_validate_acceptsTenCharDescription() {
        let report = BugReport(
            description: "1234567890",
            reproSteps: "",
            contactEmail: "",
            diagnostics: nil
        )
        XCTAssertNoThrow(try BugReportService.validate(report))
    }

    func test_validate_rejectsHugeDescription() {
        let huge = String(repeating: "x", count: BugReportService.maxDescriptionBytes + 1)
        let report = BugReport(description: huge, reproSteps: "", contactEmail: "", diagnostics: nil)
        XCTAssertThrowsError(try BugReportService.validate(report))
    }

    func test_validate_rejectsObviouslyInvalidEmail() {
        let report = BugReport(
            description: "this is a real description of a problem",
            reproSteps: "",
            contactEmail: "not an email at all",
            diagnostics: nil
        )
        XCTAssertThrowsError(try BugReportService.validate(report))
    }

    func test_validate_acceptsEmptyEmail() {
        let report = BugReport(
            description: "this is a real description of a problem",
            reproSteps: "",
            contactEmail: "",
            diagnostics: nil
        )
        XCTAssertNoThrow(try BugReportService.validate(report))
    }

    // MARK: - Encoding

    func test_encode_sortedKeysAndValidJSON() throws {
        let diag = BugReportDiagnostics(
            appName: "cutti",
            appVersion: "1.0.40",
            appBuild: "100",
            osVersion: "macOS 14.5",
            hardwareModel: "MacBookPro18,3",
            physicalMemoryGB: 32,
            locale: "en_US",
            timezone: "America/Los_Angeles",
            submittedAt: "2026-05-02T12:00:00Z"
        )
        let report = BugReport(
            description: "this is a real description",
            reproSteps: "",
            contactEmail: "",
            diagnostics: diag
        )
        let data = try BugReportService.encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["description"])
        XCTAssertNotNil(json?["diagnostics"])
        let diagJSON = json?["diagnostics"] as? [String: Any]
        XCTAssertEqual(diagJSON?["appVersion"] as? String, "1.0.40")
        XCTAssertEqual(diagJSON?["physicalMemoryGB"] as? Int, 32)
        // Account ID is intentionally not in the body — relay derives
        // it from the JWT to keep public GitHub issues clean.
        XCTAssertNil(diagJSON?["signedInUserID"])
    }

    func test_encode_sanitizesPathInDescription() throws {
        let report = BugReport(
            description: "crashes when I open /Users/alice/Desktop/clip.mov",
            reproSteps: "",
            contactEmail: "",
            diagnostics: nil
        )
        let data = try BugReportService.encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let desc = json?["description"] as? String
        XCTAssertEqual(desc, "crashes when I open /Users/<user>/Desktop/clip.mov")
    }

    func test_encode_omitsDiagnosticsWhenNil() throws {
        let report = BugReport(
            description: "this is a real description",
            reproSteps: "",
            contactEmail: "",
            diagnostics: nil
        )
        let data = try BugReportService.encode(report)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // `diagnostics` may be absent or NSNull — both are acceptable
        // signals to the server that the user opted out.
        if let d = json?["diagnostics"], !(d is NSNull) {
            XCTFail("Expected diagnostics to be absent or null, got \(d)")
        }
    }

    // MARK: - Diagnostics

    func test_diagnosticsCurrent_populatesAllFields() {
        let diag = BugReportDiagnostics.current()
        XCTAssertFalse(diag.appName.isEmpty)
        XCTAssertFalse(diag.appVersion.isEmpty)
        XCTAssertFalse(diag.osVersion.isEmpty)
        XCTAssertFalse(diag.locale.isEmpty)
        XCTAssertFalse(diag.timezone.isEmpty)
        XCTAssertFalse(diag.submittedAt.isEmpty)
        // Memory should be a sensible number on any test runner.
        XCTAssertGreaterThan(diag.physicalMemoryGB, 0)
    }

    // MARK: - Preview JSON

    func test_previewJSON_isPrettyPrintedAndStable() {
        let diag = BugReportDiagnostics(
            appName: "cutti",
            appVersion: "1.0.40",
            appBuild: "100",
            osVersion: "macOS 14.5",
            hardwareModel: "MacBookPro18,3",
            physicalMemoryGB: 32,
            locale: "en_US",
            timezone: "UTC",
            submittedAt: "2026-05-02T12:00:00Z"
        )
        let report = BugReport(
            description: "this is a real description",
            reproSteps: "step",
            contactEmail: "",
            diagnostics: diag
        )
        let preview = BugReportService.previewJSON(for: report)
        XCTAssertTrue(preview.contains("\"appVersion\" : \"1.0.40\""))
        XCTAssertTrue(preview.contains("\"description\" : \"this is a real description\""))
        // Pretty-printed JSON is multi-line.
        XCTAssertTrue(preview.contains("\n"))
    }
}
