import XCTest
@testable import CuttiMac

/// Regression coverage for the actor-isolation crash where
/// `RelayClient.configurationFromDefaults()` and
/// `OpenAIConfiguration.fromEnvironment()` were called from a non-MainActor
/// task (e.g. inside `FullAnalysisPipeline.analyze`) and trapped on
/// `MainActor.assumeIsolated`.
///
/// After the fix, the bearer-token snapshot is held in a lock-protected
/// nonisolated container, so these entry points must be safe to invoke
/// from `Task.detached`, background actors, and `MainActor` alike — all
/// returning a non-nil relay configuration.
final class RelayClientConfigurationTests: XCTestCase {
    func test_configurationFromDefaults_isSafeFromDetachedTask() async {
        let config = await Task.detached(priority: .userInitiated) {
            RelayClient.configurationFromDefaults()
        }.value

        XCTAssertEqual(config.relayBaseURL, RelayClient.relayBaseURL)
        XCTAssertEqual(config.model, RelayClient.defaultModel)
        // Token may be empty (no signed-in user in the test bundle) or
        // a "dev:"/"jwt:" prefixed string — never crash, always shape-valid.
        if !config.apiKey.isEmpty {
            XCTAssertTrue(
                config.apiKey.hasPrefix("jwt:") || config.apiKey.hasPrefix("dev:"),
                "Unexpected token prefix: \(config.apiKey.prefix(8))"
            )
        }
    }

    func test_fromEnvironment_isSafeFromDetachedTask() async {
        let config = await Task.detached(priority: .userInitiated) {
            OpenAIConfiguration.fromEnvironment()
        }.value

        XCTAssertNotNil(config, "fromEnvironment must always return a relay config")
        XCTAssertEqual(config?.relayBaseURL, RelayClient.relayBaseURL)
    }

    func test_currentBearerToken_isSafeFromManyConcurrentReaders() async {
        // 64 parallel reads from detached tasks; previously this would
        // trap inside `MainActor.assumeIsolated`. Now it must complete
        // cleanly with consistent results.
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    RelaySession.currentBearerToken()
                }
            }
            for await _ in group { /* drain — no crash is the assertion */ }
        }
    }

    func test_currentUserID_isSafeFromDetachedTask() async {
        // Mirrors `CuttiDistribution.relayURL(carryUID:)` which used
        // to wrap this read in `MainActor.assumeIsolated`.
        _ = await Task.detached { RelaySession.currentUserID() }.value
    }
}
