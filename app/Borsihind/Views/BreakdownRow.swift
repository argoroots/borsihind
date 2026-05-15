import SwiftUI

/// One row in the price-breakdown table: label left, value right, optional
/// hairline divider underneath.
struct BreakdownRow: View {
    let label: String
    let value: Double
    let fractionDigits: Int
    let showDivider: Bool

    @Environment(\.locale) private var locale

    init(_ label: String, _ value: Double, fractionDigits: Int = 2, showDivider: Bool = true) {
        self.label = label
        self.value = value
        self.fractionDigits = fractionDigits
        self.showDivider = showDivider
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale)))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 6)

            if showDivider {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 1)
            }
        }
    }
}
