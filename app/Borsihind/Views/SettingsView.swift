import SwiftUI

/// Modal preferences sheet. Lets the user pick the UI language, data
/// interval (15 min vs. 1 h), grid service plan, and seller margin. The
/// language picker reads `@AppStorage` directly so its labels update live
/// without waiting for the locale environment to propagate through the sheet.
struct SettingsView: View {
    @Binding var interval: Interval
    @Binding var plan: Plan
    @Binding var marginal: Double

    @AppStorage("language") private var languageRaw: String = Language.et.rawValue
    /// Mirrors `ContentView`'s flag — tapping the disclaimer row resets it so
    /// the first-launch alert reappears on the next cold start (debug aid).
    @AppStorage("disclaimerShown") private var disclaimerShown: Bool = false

    @Environment(\.dismiss) private var dismiss

    /// Compute locale directly from `@AppStorage` so the picker updates strings
    /// live, regardless of whether the parent's `\.locale` env reaches us
    /// through the sheet.
    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    private var language: Binding<Language> {
        Binding(
            get: { Language(rawValue: languageRaw) ?? .et },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Picker(locale.t("Language"), selection: language) {
                            ForEach(Language.allCases) { lang in
                                Text(lang.label).tag(lang)
                            }
                        }
                    }

                    // Interval, plan and seller margin together — all three
                    // affect what's shown in the price breakdown / chart.
                    Section {
                        Picker(locale.t("Interval"), selection: $interval) {
                            ForEach(Interval.allCases) { i in
                                Text(locale.t(i.labelKey)).tag(i)
                            }
                        }

                        Picker(locale.t("Grid service plan"), selection: $plan) {
                            ForEach(Plan.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }

                        LabeledContent(locale.t("Seller margin")) {
                            TextField("", value: $marginal, format: .number.precision(.fractionLength(0...4)).locale(locale))
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .frame(maxWidth: 100)
                        }
                    }
                }
                .formStyle(.grouped)

                // Disclaimer is OUTSIDE the Form so it doesn't inherit
                // grouped-section chrome. Plain Text + onTapGesture instead
                // of a Button so iOS / macOS don't paint any tap-feedback
                // background. Tap resets `disclaimerShown` so the first-
                // launch alert reappears on the next cold start.
                Text(locale.t("All prices shown in the app include VAT and are in cents per kilowatt-hour."))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .onTapGesture { disclaimerShown = false }
            }
            // Match the disclaimer's container background to the Form's
            // grouped chrome so there's no white seam between the Form area
            // and the disclaimer below it.
            #if os(iOS)
            .background(Color(.systemGroupedBackground))
            #endif
            .navigationTitle(locale.t("Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // iOS 26 / macOS 26 — `Button(role: .close)` in
                // `.cancellationAction` placement renders the platform's
                // native close chip (X on iOS, native close on macOS).
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380)
    }
}
