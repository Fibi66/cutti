import SwiftUI

/// Mac App Store StoreKit subscription sheet, restyled for the dark
/// Settings theme. macOS 14 deployment target so we can't use
/// `SubscriptionStoreView` directly; this is a hand-rolled equivalent.
struct SettingsStoreKitSheet: View {
    let dismiss: () -> Void
    @ObservedObject private var store = SubscriptionManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    T("Subscribe")
                        .font(SettingsTheme.ui(15, weight: .semibold))
                        .foregroundStyle(SettingsTheme.text)
                    T("Pick a plan to unlock AI features billed through your App Store account.")
                        .font(SettingsTheme.caption)
                        .foregroundStyle(SettingsTheme.textDim)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            // Body
            VStack(spacing: 8) {
                if store.isLoading && store.products.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 30)
                } else if store.products.isEmpty {
                    SettingsCard(padding: 16) {
                        T("Subscription products are not available on this build yet.")
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.textDim)
                    }
                } else {
                    ForEach(store.products, id: \.id) { product in
                        SettingsCard(padding: 14) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(product.displayName)
                                        .font(SettingsTheme.bodyMedium)
                                        .foregroundStyle(SettingsTheme.text)
                                    Text(product.description)
                                        .font(SettingsTheme.caption)
                                        .foregroundStyle(SettingsTheme.textDim)
                                }
                                Spacer()
                                Text(product.displayPrice)
                                    .font(SettingsTheme.monoTabular)
                                    .foregroundStyle(SettingsTheme.text)
                                SettingsButton(
                                    "Subscribe",
                                    variant: .primary,
                                    size: .medium
                                ) {
                                    Task { await store.purchase(product) }
                                }
                            }
                        }
                    }
                }

                if let err = store.lastError {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsTheme.red)
                        Text(err)
                            .font(SettingsTheme.caption)
                            .foregroundStyle(SettingsTheme.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            // Footer
            VStack(spacing: 0) {
                Rectangle()
                    .fill(SettingsTheme.borderSoft)
                    .frame(height: 1)
                HStack(spacing: 8) {
                    SettingsButton(
                        "Restore Purchases",
                        variant: .ghost,
                        size: .medium
                    ) {
                        Task { await store.restorePurchases() }
                    }
                    Spacer()
                    SettingsButton(
                        "Done",
                        variant: .secondary,
                        size: .medium,
                        action: dismiss
                    )
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(SettingsTheme.panel2)
            }
        }
        .frame(width: 480)
        .background(SettingsTheme.bg)
        .task { await store.loadProducts() }
        .settingsThemed()
    }
}
