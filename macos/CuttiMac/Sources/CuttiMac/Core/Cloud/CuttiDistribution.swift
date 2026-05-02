import Foundation

/// Where this copy of Cutti came from. Determines which purchase flow
/// the UI should expose — Mac App Store copies only see StoreKit;
/// direct-download copies send the user to the web pricing page to
/// subscribe (which requires a signed-in web account).
enum CuttiDistribution {
    case appStore
    case direct

    /// Runtime detection. Mac App Store builds always ship with a
    /// `_MASReceipt/receipt` file inside the app bundle; direct-distribution
    /// builds (Developer ID / unsigned / debug) never do.
    static let current: CuttiDistribution = {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return .direct }
        return FileManager.default.fileExists(atPath: receiptURL.path) ? .appStore : .direct
    }()

    /// URL of the pricing landing page. User picks monthly/yearly there.
    /// The page itself requires a signed-in web account before it will
    /// start a Stripe Checkout session.
    static var landingURL: URL {
        URL(string: relayBaseURL + "/pricing")!
    }

    /// Public sign-up page. Direct-download builds open this in the user's
    /// browser instead of presenting an in-app form, so we can layer on
    /// terms-of-service, email verification, etc. without shipping app
    /// updates.
    static var signupURL: URL {
        URL(string: relayBaseURL + "/signup")!
    }

    /// Canonical relay origin. No runtime override — a greenfield app with
    /// one production backend. Local dev can change this string and rebuild.
    private static let relayBaseURL = "https://api.cutti.app"
}
