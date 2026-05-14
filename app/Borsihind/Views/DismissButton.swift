import SwiftUI

/// Sheet/modal close button used across Settings and the Paywall.
///
/// Renders one of two variants based on the runtime OS:
/// - **iOS 26+ / macOS 26+** → `Button(role: .close)` → system X close chip
/// - Older → text "Done" / "Valmis" button with `.cancel` role for the
///   right Esc-key and VoiceOver semantics.
///
/// Always pair with `ToolbarItem(placement: .cancellationAction)` so the
/// button lands in the platform's modal-cancel slot (leading on iOS).
struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss

    /// Localized "Done" / "Valmis" label, used on pre-26 OS where the
    /// system has no chip glyph to fall back to. Injected (not read from
    /// env) so callers' locale logic stays the single source of truth.
    let title: String

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            // System X close chip. VoiceOver reads Apple's localized
            // "Close" / "Sulge" by default.
            Button(role: .close) { dismiss() }
        } else {
            // Pre-26: text button with `.cancel` role so the system
            // treats it as the modal's cancel action (Esc on macOS,
            // VoiceOver "cancel" announcement).
            Button(title, role: .cancel) { dismiss() }
        }
    }
}
