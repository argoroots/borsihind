import SwiftUI
import StoreKit

/// Börsihind+ sheet. Two states:
/// - Not subscribed → `SubscriptionStoreView` paywall.
/// - Subscribed → confirmation card + system manage-subscription entry.
struct PaywallView: View {
    /// Read language directly from shared storage — `\.locale` env doesn't
    /// reliably propagate through `.sheet` presentation, and
    /// `SubscriptionStoreView` internally overrides locale anyway.
    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(StoreManager.self) private var store

    @State private var showManageSubscriptions = false
    /// `true` if the sheet opened in non-subscribed state — used to
    /// auto-dismiss after a successful purchase without dismissing
    /// subscribers who opened the sheet to manage their plan.
    @State private var startedAsFreeUser: Bool?

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    var body: some View {
        Group {
            if store.isSubscribed {
                subscribedView
            } else {
                paywallView
            }
        }
        // Re-assert our locale for the subtree — SubscriptionStoreView
        // otherwise leaks the device's StoreKit storefront locale.
        .environment(\.locale, locale)
        // Fresh entitlement scan so the right branch is picked even if
        // our cached `purchased` set lagged behind StoreKit.
        .task { await store.refresh() }
        .onAppear {
            if startedAsFreeUser == nil {
                startedAsFreeUser = !store.isSubscribed
            }
        }
        // Belt-and-suspenders auto-dismiss for free-user → subscribed
        // transitions. macOS 26's `onInAppPurchaseCompletion` is unreliable;
        // observing the entitlement directly always works.
        .onChange(of: store.isSubscribed) { _, isSubbed in
            if isSubbed, startedAsFreeUser == true {
                dismiss()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 820, idealHeight: 880)
        #endif
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        #endif
    }

    // MARK: - Subscribed state

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
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button(locale.t("Done"), role: .cancel) { dismiss() }
                    }
                }
            }
        }
    }

    // MARK: - Paywall (non-subscribed) state

    private var paywallView: some View {
        #if os(iOS)
        // Hide Apple's auto-close (trailing) in favor of our own leading
        // X — matches subscriber view + Settings sheet.
        NavigationStack {
            paywallStore
                .storeButton(.hidden, for: .cancellation)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if #available(iOS 26.0, macOS 26.0, *) {
                            Button(role: .close) { dismiss() }
                        } else {
                            Button(locale.t("Done"), role: .cancel) { dismiss() }
                        }
                    }
                }
        }
        #else
        paywallStore
        #endif
    }

    /// `SubscriptionStoreView` body, extracted so iOS can wrap it in a
    /// NavigationStack for the leading close button.
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
        // tvOS supports `SubscriptionStoreView` itself but not the
        // styling hooks; iOS / iPadOS / macOS get the picker chrome.
        #if !os(tvOS)
        .subscriptionStoreControlStyle(.compactPicker)
        .subscriptionStoreButtonLabel(.action)
        .storeButton(.visible, for: .restorePurchases)
        .storeButton(.visible, for: .redeemCode)
        // Required by App Review (Guideline 3.1.2): Terms + Privacy must
        // be reachable from the purchase flow. Apple's standard EULA URL
        // is the safest pattern.
        .subscriptionStorePolicyDestination(
            url: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
            for: .termsOfService
        )
        .subscriptionStorePolicyDestination(
            url: URL(string: "https://borsihind.ee/privacy.html")!,
            for: .privacyPolicy
        )
        #endif
        // Auto-dismiss only on a real completion (inner `.success`).
        // Outer `Result.success` also covers cancelled / pending.
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success) = result { dismiss() }
        }
    }

    /// iOS: in-app `manageSubscriptionsSheet`. macOS: App Store URL.
    /// Both routes lead to Apple-managed plan switch / cancel / refund.
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
            ForEach(PremiumFeature.all, id: \.titleKey) { feature in
                PremiumFeatureRow(systemImage: feature.icon,
                                  text: locale.t(feature.titleKey))
            }
        }
    }
}

