import SwiftUI
import StoreKit

/// Börsihind+ subscription sheet. Renders one of two states:
/// - **Not subscribed** → `SubscriptionStoreView` paywall with marketing
///   block, tier picker, restore + redeem buttons, and Apple's mandatory
///   auto-renewal disclosure.
/// - **Subscribed** → confirmation + system Manage-Subscription button so
///   the user can switch tiers, cancel, or request refunds via Apple's
///   own UI.
struct PaywallView: View {
    /// Read the app language directly from `@AppStorage` — `\.locale` from
    /// the env doesn't always propagate through `.sheet` presentation
    /// (and StoreKit's `SubscriptionStoreView` internally overrides it),
    /// so the env-based path leaves the paywall stuck on the device's
    /// storefront locale even when the user has switched the app to EN.
    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(StoreManager.self) private var store

    @State private var showManageSubscriptions = false

    var body: some View {
        Group {
            if store.isSubscribed {
                subscribedView
            } else {
                paywallView
            }
        }
        // Re-assert our `locale` (from app's language setting) for the
        // entire subtree. SubscriptionStoreView otherwise leaks the
        // device's StoreKit storefront locale into the closure, which
        // could leave our marketing text stuck in Estonian even when the
        // user has switched the app to English.
        .environment(\.locale, locale)
        // Force a fresh entitlement scan whenever the sheet appears so the
        // right branch is picked even if our local `purchased` set lagged
        // behind StoreKit (happens on macOS after a cold launch).
        .task { await store.refresh() }
        // macOS: minimum window size for the paywall sheet — without this
        // SubscriptionStoreView packs tight and the marketing block feels
        // cramped above the tier picker. iOS / iPadOS sheets are already
        // full-height by default.
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 820, idealHeight: 880)
        #endif
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        #endif
    }

    // MARK: - Subscriber state

    private var subscribedView: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                heroIcon
                Text("Börsihind+")
                    .font(.largeTitle.bold())
                Text(locale.t("You have Börsihind+"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                featureBullets
                    .padding(.top, 8)

                Spacer()

                Button {
                    openManageSubscription()
                } label: {
                    Text(locale.t("Edit subscription"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
            .toolbar {
                // Mirrors the system close button SubscriptionStoreView
                // gives the non-subscriber state — same shape on iOS, native
                // close on macOS.
                ToolbarItem(placement: .cancellationAction) {
                    DismissButton(title: locale.t("Done"))
                }
            }
        }
    }

    // MARK: - Paywall (non-subscriber) state

    private var paywallView: some View {
        #if os(iOS)
        // Hide Apple's auto-close (which sits trailing) in favor of our own
        // leading-placed system X chip, matching subscriber view + Settings.
        NavigationStack {
            paywallStore
                .storeButton(.hidden, for: .cancellation)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        DismissButton(title: locale.t("Done"))
                    }
                }
        }
        #else
        paywallStore
        #endif
    }

    /// Just the SubscriptionStoreView body — extracted so the iOS wrapper
    /// can nest it in a NavigationStack for the leading close button.
    private var paywallStore: some View {
        SubscriptionStoreView(productIDs: StoreManager.allProductIDs) {
            VStack(spacing: 16) {
                heroIcon
                Text("Börsihind+")
                    .font(.largeTitle.bold())
                featureBullets
                    .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        // tvOS supports SubscriptionStoreView itself but not these styling
        // hooks. iOS / iPadOS / macOS get the picker + auxiliary buttons.
        #if !os(tvOS)
        .subscriptionStoreControlStyle(.compactPicker)
        .subscriptionStoreButtonLabel(.action)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .redeemCode)
        // Required by App Review (Guideline 3.1.2): Terms of Use (EULA) and
        // Privacy Policy must be reachable from the purchase flow. Use the
        // URL-based destination — Apple's default in-app webview behavior,
        // which reviewers see in hundreds of subscription apps and is the
        // safest pattern for compliance.
        .subscriptionStorePolicyDestination(
            url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
            for: .termsOfService
        )
        .subscriptionStorePolicyDestination(
            url: URL(string: "https://borsihind.ee/privacy.html")!,
            for: .privacyPolicy
        )
        #endif
        // Auto-close on successful purchase or restore.
        .onInAppPurchaseCompletion { _, result in
            if case .success = result { dismiss() }
        }
    }

    /// iOS uses the in-app `manageSubscriptionsSheet`; macOS opens the
    /// system-wide App Store subscriptions page in the App Store app.
    /// Both routes lead to the same Apple-managed UI for plan switching,
    /// cancellation, and refunds.
    private func openManageSubscription() {
        #if os(iOS)
        showManageSubscriptions = true
        #else
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            openURL(url)
        }
        #endif
    }

    // MARK: - Shared building blocks

    private var heroIcon: some View {
        Image("Logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var featureBullets: some View {
        VStack(alignment: .leading, spacing: 12) {
            PaywallBullet(systemImage: "clock",
                          text: locale.t("2h, 3h and 4h cheapest windows"))
            PaywallBullet(systemImage: "timer",
                          text: locale.t("15-minute price intervals"))
            PaywallBullet(systemImage: "eurosign",
                          text: locale.t("Custom retailer margin"))
            PaywallBullet(systemImage: "square.grid.2x2.fill",
                          text: locale.t("Home Screen and Lock Screen widgets"))
        }
    }
}

/// Single feature row in the paywall hero.
private struct PaywallBullet: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .font(.headline)
                .frame(width: 24, alignment: .center)
            Text(text)
                .font(.body)
                .multilineTextAlignment(.leading)
        }
    }
}

