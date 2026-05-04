import AppKit
import SwiftUI

/// Subscription page. Plan badge card → monthly credits row with progress
/// bar + reset countdown → pack credits row. Replaces the legacy
/// `SubscriptionSettingsRow` private struct from the old SettingsView.
///
/// Per the redesign brief, the standalone "Buy more pack credits" button
/// is omitted (no backend support yet). The "Manage" button on the plan
/// card opens StoreKit (App Store builds) or the web checkout (direct
/// builds), reusing `CuttiDistribution.current`.
struct SubscriptionSection: View {
    @ObservedObject private var session = RelaySession.shared
    @State private var showStoreKitSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Subscription",
                sub: "Your Cutti Cloud plan and credit balance."
            )

            SettingsCard(padding: nil) {
                planRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                rowDivider

                monthlyCreditsRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                if let credits = session.credits, credits.balancePack > 0 || credits.packTotalGranted > 0 {
                    rowDivider
                    packCreditsRow
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }

            if let err = session.lastError, !err.isEmpty {
                Text(err)
                    .font(SettingsTheme.caption)
                    .foregroundStyle(SettingsTheme.red)
                    .padding(.top, 10)
            }

            Spacer(minLength: 0)
        }
        .task { if session.isSignedIn { await session.refreshMe() } }
        .sheet(isPresented: $showStoreKitSheet) {
            SettingsStoreKitSheet(dismiss: { showStoreKitSheet = false })
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(SettingsTheme.borderSoft)
            .frame(height: 1)
    }

    // MARK: - Plan row

    private var planRow: some View {
        HStack(spacing: 14) {
            planBadge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(planTitleString)
                        .font(SettingsTheme.bodyMedium)
                        .foregroundStyle(SettingsTheme.text)
                    if let tone = subscriptionStatusTone {
                        SettingsStatusDot(tone: tone, label: subscriptionStatusLabel)
                    }
                }
                if let renewalString = planRenewalString {
                    Text(renewalString)
                        .font(SettingsTheme.monoSmall)
                        .foregroundStyle(SettingsTheme.textDim)
                }
            }
            Spacer(minLength: 0)
            SettingsButton(
                manageButtonTitle,
                variant: .secondary,
                size: .medium
            ) {
                handleManageTap()
            }
        }
    }

    private var planBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [SettingsTheme.accent, SettingsTheme.accentDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Text(planBadgeText)
                .font(SettingsTheme.mono(11, weight: .bold))
                .foregroundStyle(Color(.sRGB, red: 0.04, green: 0.04, blue: 0.05, opacity: 1))
        }
        .frame(width: 38, height: 38)
    }

    // MARK: - Monthly credits row

    @ViewBuilder
    private var monthlyCreditsRow: some View {
        if let credits = session.credits {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        T("Monthly credits")
                            .font(SettingsTheme.bodyRegular)
                            .foregroundStyle(SettingsTheme.text)
                        if let countdown = resetCountdownText(for: credits) {
                            Text(countdown)
                                .font(SettingsTheme.captionFaint)
                                .foregroundStyle(SettingsTheme.textFaint)
                        }
                    }
                    Spacer()
                    HStack(spacing: 0) {
                        Text(credits.remaining.formatted())
                            .font(SettingsTheme.monoTabular)
                            .foregroundStyle(SettingsTheme.text)
                        Text(" / \(credits.quota.formatted())")
                            .font(SettingsTheme.monoTabular)
                            .foregroundStyle(SettingsTheme.textFaint)
                    }
                }
                HStack(spacing: 10) {
                    SettingsProgressBar(value: credits.percentUsed)
                    Text("\(Int(credits.percentUsed * 100))%")
                        .font(SettingsTheme.mono(10.5))
                        .foregroundStyle(SettingsTheme.textFaint)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
        } else {
            HStack {
                T("Monthly credits")
                    .font(SettingsTheme.bodyRegular)
                    .foregroundStyle(SettingsTheme.textDim)
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Pack credits row

    private var packCreditsRow: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(SettingsTheme.violet.opacity(0.15))
                Image(systemName: "bag.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(SettingsTheme.violet)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                T("Pack credits")
                    .font(SettingsTheme.bodyRegular)
                    .foregroundStyle(SettingsTheme.text)
                T("One-time purchase · never expires")
                    .font(SettingsTheme.captionFaint)
                    .foregroundStyle(SettingsTheme.textFaint)
            }
            Spacer()
            Text((session.credits?.balancePack ?? 0).formatted())
                .font(SettingsTheme.mono(14, weight: .semibold))
                .foregroundStyle(SettingsTheme.violet)
        }
    }

    // MARK: - Plan derivations

    /// 3-character all-caps badge text. Falls back to "FREE".
    private var planBadgeText: String {
        let plan = session.subscription?.plan ?? "free"
        let trimmed = plan.uppercased()
        return String(trimmed.prefix(3))
    }

    private var planTitleString: String {
        if let plan = session.subscription?.plan, !plan.isEmpty {
            return plan.capitalized + " " + L("plan_suffix")
        }
        return L("Free plan")
    }

    /// Renewal-only string (no fabricated pricing). Hidden when the
    /// server doesn't surface a renewal date (free plan / pre-1.0
    /// servers).
    private var planRenewalString: String? {
        guard let renewalAt = session.subscription?.renewalAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(renewalAt))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return L("renews_on_%@", f.string(from: date))
    }

    private var subscriptionStatusTone: SettingsStatusTone? {
        guard let status = session.subscription?.status else { return nil }
        switch status {
        case "active": return .green
        case "grace":  return .amber
        default:       return nil
        }
    }

    private var subscriptionStatusLabel: LocalizedStringKey {
        switch session.subscription?.status {
        case "active": return "Active"
        case "grace":  return "Grace period"
        default:       return ""
        }
    }

    private var manageButtonTitle: LocalizedStringKey {
        if session.subscription?.status == "active" {
            return "Manage"
        } else {
            return "Subscribe"
        }
    }

    /// "Resets in N days" / "Resets today". Returns nil when the server
    /// doesn't surface a reset date — we never invent one.
    private func resetCountdownText(for credits: RelaySession.Credits) -> String? {
        guard let epoch = credits.periodResetAt else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(epoch))
        let now = Date()
        if resetDate <= now {
            return L("Resets today")
        }
        let days = Calendar.current.dateComponents([.day], from: now, to: resetDate).day ?? 0
        if days <= 0 {
            return L("Resets today")
        }
        if days == 1 {
            return L("Resets in 1 day")
        }
        return L("Resets in %d days", days)
    }

    // MARK: - Manage tap

    private func handleManageTap() {
        switch CuttiDistribution.current {
        case .appStore:
            showStoreKitSheet = true
        case .direct:
            NSWorkspace.shared.open(CuttiDistribution.landingURL)
        }
    }
}
