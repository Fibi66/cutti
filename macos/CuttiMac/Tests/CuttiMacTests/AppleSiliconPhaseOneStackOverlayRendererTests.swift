import XCTest
import CuttiKit
@testable import CuttiMac

/// Coverage for `AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer`,
/// which decides whether the macOS app routes overlay/animation renders
/// to:
///
///   - `CloudRemotionRenderer`   — Cutti subscription stack
///                                 (proprietary skill + Azure Container
///                                 Apps render farm)
///   - `LocalRemotionRenderer`   — dev-only fallback that shells out to
///                                 `npx remotion render` against the
///                                 checked-in `remotion/` directory
///   - `nil`                      — BYOK; the caller must surface the
///                                 "Cutti Cloud only" banner instead of
///                                 generating an animation.
///
/// The selection is non-trivial because BYOK users may still have a
/// stale subscription JWT in the keychain (they switched away from
/// `.cuttiCloud` after subscribing earlier). The factory must NOT
/// route their renders through `api.cutti.app` regardless of token
/// state — otherwise the user pays no Cutti credits but the cutti
/// backend still incurs the render cost.
@MainActor
final class AppleSiliconPhaseOneStackOverlayRendererTests: XCTestCase {

    // MARK: - BYOK gate (the regression guard)

    func test_byok_returnsNil_evenWithStaleJWT() {
        // Simulates the dangerous "subscribed earlier, switched to BYOK"
        // path. Before the fix this returned a CloudRemotionRenderer
        // because the factory only checked token presence.
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .custom },
            bearerToken: { "stale-jwt-from-previous-subscription" },
            devToken: { nil }
        )
        XCTAssertNil(renderer,
                     "BYOK must never route to the cutti backend, even with a stale JWT.")
    }

    func test_byok_returnsNil_withDevTokenSet() {
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .custom },
            bearerToken: { nil },
            devToken: { "dev-token-from-someones-machine" }
        )
        XCTAssertNil(renderer,
                     "BYOK must opt out of the relay even when a dev token is configured.")
    }

    func test_byok_returnsNil_withNoCredentials() {
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .custom },
            bearerToken: { nil },
            devToken: { nil }
        )
        XCTAssertNil(renderer,
                     "BYOK without creds must still return nil — the local renderer is dev-only.")
    }

    // MARK: - Cutti Cloud routing

    func test_cuttiCloud_jwtPresent_usesCloudRenderer() {
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .cuttiCloud },
            bearerToken: { "real-jwt" },
            devToken: { nil }
        )
        XCTAssertNotNil(renderer)
        XCTAssertTrue(renderer is CloudRemotionRenderer,
                      "Subscription users with a JWT must use the cloud renderer.")
    }

    func test_cuttiCloud_devTokenPresent_usesCloudRenderer() {
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .cuttiCloud },
            bearerToken: { nil },
            devToken: { "dev-token" }
        )
        XCTAssertNotNil(renderer)
        XCTAssertTrue(renderer is CloudRemotionRenderer,
                      "Dev token must also route to the cloud renderer (relay accepts it).")
    }

    func test_cuttiCloud_jwtTakesPriorityOverDevToken() {
        // Both present: JWT wins (mirrors the existing "jwt:" / "dev:"
        // prefix order in the factory). This is the prefix the relay
        // disambiguates with, so a regression that flipped priority
        // would silently send subscribed users on the dev path.
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .cuttiCloud },
            bearerToken: { "real-jwt" },
            devToken: { "dev-token" }
        )
        XCTAssertTrue(renderer is CloudRemotionRenderer)
    }

    func test_cuttiCloud_noCredentials_fallsBackToLocal() {
        // Dev / unauthenticated path. Note: in a packaged .app this
        // renderer can't actually find the `remotion/` directory at
        // runtime, but the factory has always returned it for parity
        // with `swift run` / Xcode workflows. Pinning the contract so
        // we notice if it ever changes.
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .cuttiCloud },
            bearerToken: { nil },
            devToken: { nil }
        )
        XCTAssertTrue(renderer is LocalRemotionRenderer,
                      "Dev runs without creds should still get a (local) renderer.")
    }

    func test_cuttiCloud_emptyStringTokens_treatedAsAbsent() {
        // The legacy implementation uses `?? ""` then `!isEmpty`; pin
        // the empty-string-as-absent behavior so a future refactor
        // can't accidentally let an empty Authorization header reach
        // the relay.
        let renderer = AppleSiliconPhaseOneStack.makeDefaultOverlayRenderer(
            aiProvider: { .cuttiCloud },
            bearerToken: { "" },
            devToken: { "" }
        )
        XCTAssertTrue(renderer is LocalRemotionRenderer)
    }
}
