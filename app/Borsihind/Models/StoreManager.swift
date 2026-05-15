import Foundation
import Observation
import StoreKit

/// Owns the Börsihind+ subscription state. StoreKit 2 throughout:
/// async/await, AsyncSequence transaction listener, JWS-verified
/// entitlements. No server roundtrip — single-user app.
///
/// Lifecycle:
/// 1. `bootstrap()` (root scene's `.task`) spawns the `Transaction.updates`
///    listener and primes products + entitlements.
/// 2. UI reads `isSubscribed` to gate premium features.
/// 3. `.subscriptionStatusTask` on the root scene fires for renewals,
///    refunds, family-sharing changes, etc. → calls `refresh()`.
@Observable
@MainActor
final class StoreManager {
    static let subscriptionGroupID = "22073931"
    static let monthlyProductID = "ee.borsihind.plus.monthly"
    static let yearlyProductID  = "ee.borsihind.plus.yearly"
    static let allProductIDs: [String] = [monthlyProductID, yearlyProductID]

    /// Products fetched from the store, in declared order.
    private(set) var products: [Product] = []
    /// Product IDs the user currently holds an active entitlement for.
    /// Includes Apple's billing-grace window.
    private(set) var purchased: Set<String> = []
    /// `false` until the first entitlement scan finishes. UI uses this
    /// to avoid flashing locked-state chrome before status is known.
    private(set) var hasResolvedSubscriptionState = false

    var isSubscribed: Bool { !purchased.isEmpty }

    private var listenerTask: Task<Void, Never>?

    /// Spawn the transaction listener and prime initial state. Idempotent.
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

    /// Fetch localized Product objects, preserving our declared order.
    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: Self.allProductIDs)
            products = Self.allProductIDs.compactMap { id in
                fetched.first { $0.id == id }
            }
        } catch {
            products = []
        }
    }

    /// Recompute `purchased` from BOTH `Transaction.currentEntitlements`
    /// AND per-product `SubscriptionInfo.status`. Union of the two paths
    /// catches active subs that the entitlement stream missed (a known
    /// macOS cold-launch hiccup).
    func refresh() async {
        var active: Set<String> = []

        // Path 1: entitlement stream.
        for await result in Transaction.currentEntitlements {
            guard case .verified(let txn) = result, txn.revocationDate == nil
            else { continue }
            active.insert(txn.productID)
        }

        // Path 2: per-product subscription status.
        if products.isEmpty { await loadProducts() }
        for product in products {
            guard let info = product.subscription,
                  let statuses = try? await info.status else { continue }
            for status in statuses {
                let isActive = status.state == .subscribed
                    || status.state == .inGracePeriod
                    || status.state == .inBillingRetryPeriod
                if isActive { active.insert(product.id) }
            }
        }

        purchased = active
        hasResolvedSubscriptionState = true
    }
}
