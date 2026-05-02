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

    func test_displayMessage_quotaExceeded_includesUsageAndIsDateFree() {
        let reset = Date(timeIntervalSince1970: 1_735_689_600)
        let err = OpenAIClientError.relayQuotaExceeded(used: 2100, quota: 2000, resetAt: reset)
        let msg = err.displayMessage
        XCTAssertTrue(msg.contains("2100"), "Expected used count in message: \(msg)")
        XCTAssertTrue(msg.contains("2000"), "Expected quota in message: \(msg)")
        // We deliberately don't format the server-provided resetAt into the
        // user-visible string (timezone / locale footguns). The message should
        // refer to "next month" generically instead.
        XCTAssertFalse(msg.contains("2025"), "Reset date should not leak into UI: \(msg)")
    }
}
