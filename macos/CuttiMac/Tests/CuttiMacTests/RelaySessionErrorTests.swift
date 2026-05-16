import XCTest
@testable import CuttiMac

/// Pins the user-facing wording for `RelaySessionError.server`.
///
/// Regression guard: when the worker returned a 401 with
/// `{"error":"invalid_credentials"}` for a mistyped sign-in password,
/// the sheet used to surface the generic "Cutti is temporarily
/// unavailable…" / "服务不可用" message because `errorDescription`
/// ignored the body. Auth endpoints must surface a specific friendly
/// message instead; unknown / 5xx bodies still fall back to the
/// generic wording, and the raw body / HTTP status must never leak.
final class RelaySessionErrorTests: XCTestCase {
    func test_invalidCredentialsBody_mapsToIncorrectPasswordMessage() {
        let err = RelaySessionError.server(
            status: 401,
            message: #"{"error":"invalid_credentials"}"#
        )
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(
            shown.contains("incorrect") || shown.contains("不正确"),
            "Expected 'Email or password is incorrect.' wording, got: \(shown)"
        )
        XCTAssertFalse(
            shown.contains("temporarily unavailable") || shown.contains("服务"),
            "Generic fallback must not appear for invalid_credentials: \(shown)"
        )
    }

    func test_invalidEmailBody_mapsToInvalidEmailMessage() {
        let err = RelaySessionError.server(
            status: 400,
            message: #"{"error":"invalid_email"}"#
        )
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(
            shown.contains("valid email") || shown.contains("有效的邮箱"),
            "Expected 'Please enter a valid email address.' wording, got: \(shown)"
        )
    }

    func test_invalidRequestBody_mapsToRequiredFieldsMessage() {
        let err = RelaySessionError.server(
            status: 400,
            message: #"{"error":"invalid_request"}"#
        )
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(
            shown.contains("required") || shown.contains("不能为空"),
            "Expected 'Email and password are required.' wording, got: \(shown)"
        )
    }

    func test_unknownBody_fallsBackToGenericMessage() {
        let err = RelaySessionError.server(
            status: 500,
            message: #"{"error":"some_future_code","internal_id":"abc-123"}"#
        )
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(
            shown.contains("temporarily unavailable") || shown.contains("服务暂时不可用"),
            "Unknown server errors should surface the generic message: \(shown)"
        )
        // Never leak raw body / HTTP status / internal fields.
        XCTAssertFalse(shown.contains("{"), "Raw JSON must not leak: \(shown)")
        XCTAssertFalse(shown.contains("500"), "HTTP status must not leak: \(shown)")
        XCTAssertFalse(shown.contains("internal_id"), "Internal field must not leak: \(shown)")
    }

    func test_emptyBody_fallsBackToGenericMessage() {
        let err = RelaySessionError.server(status: 502, message: "")
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(
            shown.contains("temporarily unavailable") || shown.contains("服务暂时不可用"),
            "Bare upstream failures should still surface the generic message: \(shown)"
        )
    }

    func test_localizedDescription_bridgesThroughNSError() {
        // The iOS auth sheets read `(error as NSError).localizedDescription`
        // directly — verify the friendly wording survives that bridge so
        // both platforms get the same fix.
        let err: Error = RelaySessionError.server(
            status: 401,
            message: #"{"error":"invalid_credentials"}"#
        )
        let shown = (err as NSError).localizedDescription
        XCTAssertTrue(
            shown.contains("incorrect") || shown.contains("不正确"),
            "NSError.localizedDescription must carry the friendly wording, got: \(shown)"
        )
    }
}
