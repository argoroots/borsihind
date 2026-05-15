import SwiftUI

/// Sheet/modal close button. iOS 26+ / macOS 26+ render the system X chip;
/// older OSes render a `title` button with `.cancel` role for Esc + VoiceOver.
/// Pair with `ToolbarItem(placement: .cancellationAction)`.
struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss

    /// Visible label on pre-26 OS where no system chip glyph is available.
    let title: String

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .close) { dismiss() }
        } else {
            Button(title, role: .cancel) { dismiss() }
        }
    }
}
