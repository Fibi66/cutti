import Foundation
import StoreKit

/// Thin StoreKit 2 wrapper. Surfaces the two products (monthly / yearly)
/// Cutti sells on the Mac App Store, handles purchase / restore, and
/// hands every signed transaction to `RelaySession` so the backend can
/// verify with Apple's keys and mint a JWT.
///
/// **State**: Apple developer account exists but no ASC app / in-app
/// products yet. Product IDs below are placeholders — fill them in ASC
/// (Subscriptions group) then update the constants.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    /// Product identifiers configured in App Store Connect. Keep these
    /// stable across builds — renaming means existing subscribers have
    /// to restore purchases. See `StoreKitConfig.storekit` test file
    /// (also to be added) for local-testing variants.
    enum ProductID {
        static let monthly = "app.cutti.mac.subscription.monthly"
        static let yearly  = "app.cutti.mac.subscription.yearly"
        static let all: [String] = [monthly, yearly]
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String? = nil

    private var updatesTask: Task<Void, Never>?

    private init() {
        startTransactionListener()
    }

    deinit { updatesTask?.cancel() }

    /// Fetch product metadata from the App Store so SubscriptionView can
    /// display localized price strings. Safe to call multiple times.
    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await Product.products(for: ProductID.all)
            self.products = fetched.sorted { lhs, rhs in lhs.price < rhs.price }
        } catch {
            self.lastError = "Couldn't load products: \(error.localizedDescription)"
        }
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    /// Launch the system purchase sheet. On success the signed
    /// `JWSTransaction` is forwarded to `RelaySession` which exchanges
    /// it for a JWT.
    func purchase(_ product: Product) async {
        lastError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                try await handleVerified(verification)
            case .userCancelled:
                break
            case .pending:
                lastError = "Purchase pending approval."
            @unknown default:
                break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-run StoreKit's sync + walk current entitlements. Mirrors the
    /// classic "Restore Purchases" button users expect on macOS apps.
    func restorePurchases() async {
        lastError = nil
        do {
            try await AppStore.sync()
            for await entitlement in Transaction.currentEntitlements {
                try await handleVerified(entitlement)
            }
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func startTransactionListener() {
        updatesTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                await self?.handleTransactionUpdate(update)
            }
        }
    }

    private func handleTransactionUpdate(_ verification: VerificationResult<Transaction>) async {
        do {
            try await handleVerified(verification)
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Forwards a verified transaction's signed JWS to the relay and
    /// finishes the StoreKit transaction on success.
    private func handleVerified(_ verification: VerificationResult<Transaction>) async throws {
        switch verification {
        case .unverified(_, let error):
            throw error
        case .verified(let transaction):
            // `jwsRepresentation` is the signed JWS that the relay's
            // `/v1/auth/apple` endpoint verifies against Apple's JWKS.
            let jws = verification.jwsRepresentation
            let environment: String = {
                #if DEBUG
                return "sandbox"
                #else
                return "production"
                #endif
            }()
            try await RelaySession.shared.exchangeAppleTransaction(
                signedTransactionInfo: jws,
                bundleId: "app.cutti.mac",
                environment: environment
            )
            await transaction.finish()
        }
    }
}
