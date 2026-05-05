import XCTest
@testable import CuttiMac

final class RelayErrorMappingTests: XCTestCase {
    func test_unauthorizedBody_mapsToAuthRequired() {
        let body = #"{"error":"unauthorized"}"#.data(using: .utf8)!
        let mapped = OpenAIClient.parseRelayError(statusCode: 401, data: body)
        guard case .relayAuthRequired = mapped else {
            return XCTFail("Expected .relayAuthRequired, got \(String(describing: mapped))")
        }
    }

    /// The relay surfaces stale-JWT 401s as
    /// `{"error":"unauthorized","reason":"expired"}`. Pin that the
    /// shared error-mapping path treats this as `.relayAuthRequired`
    /// (same outward UX) — auto-rotation lives one layer up in
    /// `OpenAIClient.chatCompletion`'s retry loop, which intercepts
    /// this case and tries `RelaySession.rotate()` before the user
    /// ever sees the "Please sign in" prompt.
    func test_unauthorizedExpiredBody_mapsToAuthRequired() {
        let body = #"{"error":"unauthorized","reason":"expired"}"#.data(using: .utf8)!
        let mapped = OpenAIClient.parseRelayError(statusCode: 401, data: body)
        guard case .relayAuthRequired = mapped else {
            return XCTFail("Expected .relayAuthRequired (auto-rotation runs above this layer), got \(String(describing: mapped))")
        }
    }

    /// `attemptRelayJWTRotation` exists as a sibling of `parseRelayError`
    /// so every cuttiCloud caller (chat, image-gen, remotion render)
    /// can react to a 401 with the same one-shot rotate-and-retry.
    /// With no signed-in JWT the helper returns false (nothing to
    /// rotate) — surface the original error so the user is prompted
    /// to sign in.
    func test_attemptRelayJWTRotation_withNoToken_returnsFalseAndDoesNotThrow() async {
        // Test runs in a context with no RelaySession token populated.
        let rotated = await OpenAIClient.attemptRelayJWTRotation()
        XCTAssertFalse(rotated, "Without a JWT to rotate, the helper must report false instead of crashing or hanging.")
    }

    func test_bare401WithNoBody_stillMapsToAuthRequired() {
        // requireAuth middleware doesn't always ship a JSON body — a
        // bare 401 should still surface the friendly sign-in prompt.
        let mapped = OpenAIClient.parseRelayError(statusCode: 401, data: Data())
        guard case .relayAuthRequired = mapped else {
            return XCTFail("Expected .relayAuthRequired, got \(String(describing: mapped))")
        }
    }

    func test_emailNotVerifiedBody_mapsToVerifyCase() {
        let body = #"{"error":"email_not_verified","message":"…"}"#.data(using: .utf8)!
        let mapped = OpenAIClient.parseRelayError(statusCode: 403, data: body)
        guard case .relayEmailNotVerified = mapped else {
            return XCTFail("Expected .relayEmailNotVerified, got \(String(describing: mapped))")
        }
    }

    func test_quotaExceededBody_preservesCreditsAndResetAt() {
        let resetEpoch: TimeInterval = 1_735_689_600 // 2025-01-01 UTC
        let body = """
        {
          "error": "quota_exceeded",
          "credits_used": 2100,
          "credits_quota": 2000,
          "period_reset_at": \(Int(resetEpoch))
        }
        """.data(using: .utf8)!
        let mapped = OpenAIClient.parseRelayError(statusCode: 402, data: body)
        guard case let .relayQuotaExceeded(used, quota, resetAt) = mapped else {
            return XCTFail("Expected .relayQuotaExceeded, got \(String(describing: mapped))")
        }
        XCTAssertEqual(used, 2100)
        XCTAssertEqual(quota, 2000)
        XCTAssertEqual(resetAt?.timeIntervalSince1970, resetEpoch)
    }

    func test_unknownErrorCode_returnsNilSoCallerFallsThroughToGeneric() {
        let body = #"{"error":"some_future_code"}"#.data(using: .utf8)!
        XCTAssertNil(OpenAIClient.parseRelayError(statusCode: 418, data: body))
    }

    func test_nonJSONBody_on500_returnsNilNotAuthRequired() {
        let body = "Internal Server Error".data(using: .utf8)!
        XCTAssertNil(OpenAIClient.parseRelayError(statusCode: 500, data: body))
    }

    func test_displayMessage_authRequired_mentionsSignInAndSettings() {
        let msg = OpenAIClientError.relayAuthRequired.displayMessage
        XCTAssertTrue(msg.contains("Sign in") || msg.contains("登录"),
                      "Expected sign-in prompt, got: \(msg)")
    }

    func test_displayMessage_quotaExceeded_includesUsageAndCountdown_notAbsoluteDate() {
        // ~3 days from now — message should embed a relative countdown
        // ("Resets in N days" / "N 天后重置") sourced from the
        // server-provided period_reset_at, NOT a hard-coded "1st of
        // next month" string and NOT an absolute date.
        let resetSoon = Date().addingTimeInterval(3 * 86_400 + 3_600)
        let err = OpenAIClientError.relayQuotaExceeded(used: 2100, quota: 2000, resetAt: resetSoon)
        let msg = err.displayMessage
        XCTAssertTrue(msg.contains("2100"), "Expected used count in message: \(msg)")
        XCTAssertTrue(msg.contains("2000"), "Expected quota in message: \(msg)")
        XCTAssertTrue(msg.contains("Resets") || msg.contains("重置"),
                      "Expected relative reset phrase: \(msg)")
        XCTAssertFalse(msg.localizedCaseInsensitiveContains("1st of next month"),
                       "Hard-coded 1st-of-month wording must not appear: \(msg)")
        XCTAssertFalse(msg.contains("下个月 1 号"),
                       "Hard-coded 1st-of-month wording must not appear: \(msg)")
        // Catch any future regression that pipes an absolute date through
        // DateFormatter — month names should never appear in the message.
        let monthLeakHints = [
            "January", "February", "March", "April", "August",
            "September", "October", "November", "December",
            "Jan ", "Feb ", "Mar ", "Apr ", "Aug ", "Sep ", "Oct ", "Nov ", "Dec ",
            "一月", "二月", "三月", "四月", "五月", "六月",
            "七月", "八月", "九月", "十月", "十一月", "十二月",
        ]
        for hint in monthLeakHints {
            XCTAssertFalse(msg.contains(hint),
                           "Absolute month name '\(hint)' leaked into UI: \(msg)")
        }
    }

    func test_displayMessage_quotaExceeded_nilResetAt_fallbackOmitsDate() {
        let err = OpenAIClientError.relayQuotaExceeded(used: 2100, quota: 2000, resetAt: nil)
        let msg = err.displayMessage
        XCTAssertTrue(msg.contains("2100"), "Expected used count: \(msg)")
        XCTAssertTrue(msg.contains("2000"), "Expected quota: \(msg)")
        XCTAssertFalse(msg.localizedCaseInsensitiveContains("1st of next month"),
                       "Hard-coded 1st-of-month wording must not appear: \(msg)")
        XCTAssertFalse(msg.contains("Resets"),
                       "No reset phrase expected when resetAt is nil: \(msg)")
        XCTAssertFalse(msg.contains("重置"),
                       "No reset phrase expected when resetAt is nil: \(msg)")
    }

    // MARK: - Render / Image leak guards

    /// Render path — a 402 with the relay's quota_exceeded envelope must
    /// produce a friendly user-facing message, not a JSON dump. Mirrors
    /// the chat path; locks in the fix for the leak where
    /// `CloudRemotionRenderer` previously surfaced the raw response body
    /// inside `RemotionRenderError.renderFailed.stderr`.
    func test_renderRelayMessage_quotaExceeded_hidesRawJSONFromUser() {
        let body = #"{"error":"quota_exceeded","credits_used":2100,"credits_quota":2000,"worst_case_cost":75,"period_reset_at":1735689600}"#.data(using: .utf8)!
        guard let mapped = OpenAIClient.parseRelayError(statusCode: 402, data: body) else {
            return XCTFail("parseRelayError should recognize quota_exceeded body")
        }
        let err = RemotionRenderError.relayMessage(mapped.displayMessage)
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(shown.contains("2100"), "Should mention used credits: \(shown)")
        XCTAssertFalse(shown.contains("{"), "Raw JSON must not leak: \(shown)")
        XCTAssertFalse(shown.contains("worst_case_cost"), "Internal field must not leak: \(shown)")
        XCTAssertFalse(shown.contains("Remotion render"), "Developer-prefix must not wrap relayMessage: \(shown)")
        XCTAssertFalse(shown.contains("exit 402"), "HTTP status must not leak: \(shown)")
    }

    /// Image path — same guarantee for `ImageGenerationService` cloud path.
    func test_imageRelayMessage_quotaExceeded_hidesRawJSONFromUser() {
        let body = #"{"error":"quota_exceeded","credits_used":2100,"credits_quota":2000}"#.data(using: .utf8)!
        guard let mapped = OpenAIClient.parseRelayError(statusCode: 402, data: body) else {
            return XCTFail("parseRelayError should recognize quota_exceeded body")
        }
        let err = ImageGenerationError.relayMessage(mapped.displayMessage)
        let shown = err.errorDescription ?? ""
        XCTAssertTrue(shown.contains("2100"), "Should mention used credits: \(shown)")
        XCTAssertFalse(shown.contains("{"), "Raw JSON must not leak: \(shown)")
        XCTAssertFalse(shown.contains("Image generation failed"), "Developer-prefix must not wrap relayMessage: \(shown)")
        XCTAssertFalse(shown.contains("(402)"), "HTTP status must not leak: \(shown)")
    }

    /// `OpenAIClientError` now conforms to `LocalizedError`, so callers
    /// using `error.localizedDescription` (banner messages, action-chat
    /// failure rows, SwiftUI alerts) all get the friendly displayMessage
    /// text — not the default
    /// "The operation couldn’t be completed. (CuttiMac.OpenAIClientError error N.)"
    func test_localizedDescription_returnsDisplayMessage_notSwiftEnumDump() {
        let err: Error = OpenAIClientError.relayQuotaExceeded(used: 100, quota: 200, resetAt: nil)
        // localizedDescription bridges through NSError; with
        // LocalizedError conformance it returns errorDescription.
        let shown = err.localizedDescription
        XCTAssertTrue(shown.contains("100"), "Expected friendly quota message via localizedDescription, got: \(shown)")
        XCTAssertFalse(shown.contains("OpenAIClientError"), "Type name must not leak: \(shown)")
        XCTAssertFalse(shown.contains("operation couldn"), "Default NSError fallback must not show: \(shown)")
    }

    /// `.invalidResponse` must NEVER include the raw response body, even
    /// when the body looks like JSON or contains internal fields. This
    /// is the catch-all for non-relay-shaped 5xx / unknown responses.
    func test_invalidResponse_neverLeaksRawBody() {
        let err = OpenAIClientError.invalidResponse(
            statusCode: 500,
            body: #"{"internal_request_id":"abc-123","stack":"…"}"#
        )
        let shown = err.localizedDescription
        XCTAssertFalse(shown.contains("internal_request_id"), "Internal field leaked: \(shown)")
        XCTAssertFalse(shown.contains("{"), "Raw JSON leaked: \(shown)")
        XCTAssertFalse(shown.contains("500"), "HTTP status leaked: \(shown)")
    }
}
