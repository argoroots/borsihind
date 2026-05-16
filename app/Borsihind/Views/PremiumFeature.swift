import SwiftUI

/// One Börsihind+ feature: SF Symbol + localization key. The list is
/// shared between the paywall hero bullets and the free-user upsell
/// section in Settings, so both stay in sync.
struct PremiumFeature {
    let icon: String
    let titleKey: String

    static let all: [PremiumFeature] = [
        .init(icon: "clock",                  titleKey: "Custom cheapest-hour windows"),
        .init(icon: "timer",                  titleKey: "15-minute price intervals"),
        .init(icon: "eurosign",               titleKey: "Custom retailer margin"),
        .init(icon: "bell.fill",              titleKey: "Notifications for cheapest hours"),
        .init(icon: "square.grid.2x2.fill",   titleKey: "Home Screen and Lock Screen widgets"),
    ]
}

/// Single feature row — icon + text. Used in the paywall hero and in
/// Settings' free-tier upsell section.
struct PremiumFeatureRow: View {
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
