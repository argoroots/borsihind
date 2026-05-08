import Foundation
import Observation
import StoreKit

/// Owns the Börsihind+ subscription state. StoreKit 2 throughout — async/await,
/// AsyncSequence-based transaction listener, JWS-verified entitlements (no
/// server roundtrip needed for a single-user, no-shared-state app like ours).
///
/// Flow:
///   1. App start → `bootstrap()` spawns the `Transaction.updates` listener
///      and refreshes current entitlements + product list.
///   2. UI reads `isSubscribed` to gate premium features.
///   3. `.subscriptionStatusTask(for:)` on the root scene (in BorsihindApp)
///      fires whenever the system reports a status change (renewal, refund,
///      family-sharing transfer, etc.) and calls `refresh()`.
@Observable
@MainActor
final class StoreManager {
    /// Subscription Group ID from App Store Connect. Used by
    /// `SubscriptionStoreView` and `subscriptionStatusTask(for:)`.
    static let subscriptionGroupID = "22073931"

    /// Product IDs declared in App Store Connect (and mirrored in the local
    /// .storekit configuration file for sim testing).
    static let monthlyProductID = "ee.borsihind.plus.monthly"
    static let yearlyProductID  = "ee.borsihind.plus.yearly"
    static let allProductIDs: [String] = [monthlyProductID, yearlyProductID]

    /// Products fetched from the store, ordered as declared above.
    private(set) var products: [Product] = []

    /// Product IDs the user currently holds an active entitlement for.
    /// During Apple's billing-grace window, an expired-but-retrying
    /// subscription stays in here — `currentEntitlements` handles that for us.
    private(set) var purchased: Set<String> = []

    /// `false` until the first entitlement scan finishes. UI uses this to
    /// avoid flashing locked-state chrome (e.g. "Börsihind+" tags on the
    /// cheapest-hour cards) before the real subscription status is known.
    private(set) var hasResolvedSubscriptionState = false

    /// True iff any Börsihind+ product is in `purchased`.
    var isSubscribed: Bool { !purchased.isEmpty }

    private var listenerTask: Task<Void, Never>?

    /// Spawn the long-lived transaction listener and prime initial state.
    /// Call once from the App scene's `.task` modifier.
    func bootstrap() {
        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let txn) = result else { continue }
                await self?.refresh()
                await txn.finish()
            }
        }
        Task { await loadProducts() }
        Task { await refresh() }
    }

    /// Fetch the localized Product objects for our IDs. Idempotent — safe to
    /// call again on locale change or retry after a network failure.
    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: Self.allProductIDs)
            // Preserve our declared order rather than the API's order.
            products = Self.allProductIDs.compactMap { id in
                fetched.first { $0.id == id }
            }
        } catch {
            products = []
        }
    }

    /// Recompute `purchased` by checking BOTH `Transaction.currentEntitlements`
    /// (the standard path, fast and in-memory) AND the per-product
    /// `Product.SubscriptionInfo.status` (a live-status API that on macOS
    /// occasionally surfaces an active subscription that the entitlement
    /// stream missed during a fresh launch). Union of both gives us the
    /// most reliable "is the user subscribed right now" answer.
    /// Flips `hasResolvedSubscriptionState` to true on first completion so
    /// gated UI knows it can stop waiting.
    func refresh() async {
        var active: Set<String> = []

        // Path 1: transactions the user holds an entitlement for.
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result, txn.revocationDate == nil
            else { continue }
            active.insert(txn.productID)
        }

        // Path 2: per-product subscription status. Catches active subs that
        // the entitlement stream hasn't reported yet on macOS cold launch.
        if products.isEmpty { await loadProducts() }
        for product in products {
            guard let info = product.subscription else { continue }
            if let statuses = try? await info.status {
                for status in statuses {
                    let isActive = status.state == .subscribed
                        || status.state == .inGracePeriod
                        || status.state == .inBillingRetryPeriod
                    if isActive { active.insert(product.id) }
                }
            }
        }

        purchased = active
        hasResolvedSubscriptionState = true
    }
}
