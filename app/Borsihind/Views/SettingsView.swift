import SwiftUI

/// Modal preferences sheet: language, plan, margin, interval, cheapest-hours
/// slots, notifications, and the subscription management entry. Reads the
/// language directly from `@AppStorage` so labels update live without
/// waiting for the locale environment to propagate through the sheet.
struct SettingsView: View {
    @Binding var interval: Interval
    @Binding var plan: Plan
    @Binding var marginal: Double
    @Binding var slot1Hours: Int
    @Binding var slot1Deadline: Int
    @Binding var slot2Hours: Int
    @Binding var slot2Deadline: Int
    @Binding var slot3Hours: Int
    @Binding var slot3Deadline: Int
    @Binding var slot4Hours: Int
    @Binding var slot4Deadline: Int
    /// `-1` = Off, `0` = at slot start, else minutes before.
    @Binding var notifyLeadMinutes: Int
    /// Parent's paywall presenter, called after dismissing the sheet.
    var onRequestPaywall: () -> Void

    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue
    /// Tapping the disclaimer footnote resets this so the first-launch alert
    /// reappears next cold start (debug aid).
    @AppStorage("disclaimerShown") private var disclaimerShown: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(StoreManager.self) private var store

    private var locale: Locale {
        (Language(rawValue: languageRaw) ?? .et).locale
    }

    private var language: Binding<Language> {
        Binding(
            get: { Language(rawValue: languageRaw) ?? .et },
            set: { languageRaw = $0.rawValue }
        )
    }

    /// Dismiss this sheet, then present the paywall. macOS needs a frame
    /// of delay so the dismiss animation releases the sheet stack before
    /// the next sheet tries to mount.
    private func requestPaywall() {
        dismiss()
        #if os(macOS)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            onRequestPaywall()
        }
        #else
        onRequestPaywall()
        #endif
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                languageSection
                pricingSection
                cheapestHoursSection
                if store.isSubscribed {
                    notificationsSection
                }
                subscriptionSection
                disclaimerSection
            }
            .formStyle(.grouped)
            .navigationTitle(locale.t("Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380)
        #endif
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section {
            Picker(locale.t("Language"), selection: language) {
                ForEach(Language.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
        }
    }

    /// Free users see only the Plan picker. Margin + Interval are
    /// Börsihind+ features and surface via the bottom upsell section.
    private var pricingSection: some View {
        Section {
            Picker(locale.t("Grid service plan"), selection: $plan) {
                ForEach(Plan.allCases) { p in
                    Text(p.label).tag(p)
                }
            }

            if store.isSubscribed {
                LabeledContent(locale.t("Seller margin")) {
                    TextField("", value: $marginal,
                              format: .number.precision(.fractionLength(2...4)).locale(locale))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .frame(maxWidth: 100)
                }
                Picker(locale.t("Interval"), selection: $interval) {
                    ForEach(Interval.allCases) { i in
                        Text(locale.t(i.labelKey)).tag(i)
                    }
                }
            }
        } header: {
            Text(locale.t("Pricing"))
        } footer: {
            Text(locale.t("Pricing explanation"))
        }
    }

    /// All slots in one Section. Each slot's Length row carries a small
    /// numbered icon on the leading edge so the rows are unambiguously
    /// attributable to that slot.
    private var cheapestHoursSection: some View {
        Section {
            if store.isSubscribed {
                slotRows(index: 0, hours: $slot1Hours, deadline: $slot1Deadline)
                slotRows(index: 1, hours: $slot2Hours, deadline: $slot2Deadline)
                slotRows(index: 2, hours: $slot3Hours, deadline: $slot3Deadline)
                slotRows(index: 3, hours: $slot4Hours, deadline: $slot4Deadline)
            } else {
                slotRows(index: 0, hours: .constant(1), deadline: $slot1Deadline,
                         lengthLocked: true)
            }
        } header: {
            Text(locale.t("Cheapest hours"))
        } footer: {
            Text(locale.t("Cheapest hours explanation"))
        }
    }

    /// Two rows for one slot. Length row carries the numbered icon;
    /// deadline row's label is indented to align with "Length".
    @ViewBuilder
    private func slotRows(index: Int,
                          hours: Binding<Int>,
                          deadline: Binding<Int>,
                          lengthLocked: Bool = false) -> some View {
        Picker(selection: hours) {
            Text(locale.t("Off")).tag(0)
            ForEach(1...6, id: \.self) { n in
                Text(hoursLabel(n)).tag(n)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "\(index + 1).circle.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                Text(locale.t("Length"))
            }
        }
        .disabled(lengthLocked)

        Picker(selection: deadline) {
            Text(locale.t("Off")).tag(-1)
            ForEach(0..<24) { hour in
                Text(String(format: "%02d:00", hour)).tag(hour)
            }
        } label: {
            HStack(spacing: 12) {
                // Invisible spacer matching the slot-icon footprint above
                // so "Must end before" aligns with "Length".
                Image(systemName: "\(index + 1).circle.fill")
                    .font(.title3)
                    .hidden()
                Text(locale.t("Must end before"))
            }
        }
        .disabled(hours.wrappedValue == 0)
    }

    /// Subscriber-only. Free users get the feature surfaced via the
    /// bottom upsell section instead.
    private var notificationsSection: some View {
        Section {
            Picker(locale.t("Notify before"), selection: $notifyLeadMinutes) {
                Text(locale.t("Off")).tag(-1)
                Text(locale.t("At start")).tag(0)
                Text(locale.t("5 minutes")).tag(5)
                Text(locale.t("10 minutes")).tag(10)
                Text(locale.t("15 minutes")).tag(15)
                Text(locale.t("30 minutes")).tag(30)
                Text(locale.t("1 hour")).tag(60)
            }
        } header: {
            Text(locale.t("Notifications"))
        } footer: {
            Text(locale.t("Notifications explanation"))
        }
    }

    /// Subscribers see a simple chevron row (taps into manage-plan).
    /// Free users see the feature list + a Subscribe row, both routing
    /// to the paywall.
    @ViewBuilder
    private var subscriptionSection: some View {
        if store.isSubscribed {
            Section {
                Button {
                    requestPaywall()
                } label: {
                    HStack {
                        Text("Börsihind+")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            Section {
                // Feature list — one row in the grouped card.
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(PremiumFeature.all, id: \.titleKey) { feature in
                        PremiumFeatureRow(systemImage: feature.icon,
                                          text: locale.t(feature.titleKey))
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

                // Subscribe row. Leading spacer matches the icon slot in
                // `PremiumFeatureRow` (24pt width + 12pt spacing) so the
                // "Subscribe" text aligns with the feature labels above
                // instead of with the icons.
                Button {
                    requestPaywall()
                } label: {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 24)
                        Text(locale.t("Subscribe"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.subheadline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Börsihind+")
            }
        }
    }

    /// Borderless footnote at the bottom of the Form. Tap resets
    /// `disclaimerShown` so the first-launch alert reappears next cold start.
    private var disclaimerSection: some View {
        Section {
            Text(locale.t("All prices shown in the app include VAT and are in cents per kilowatt-hour."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture { disclaimerShown = false }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Row builders

    /// Localized hour-count label: singular / plural / Off. Settings-only;
    /// the main-screen cards still use the compact `Nh` badge.
    private func hoursLabel(_ n: Int) -> String {
        switch n {
        case 0: return locale.t("Off")
        case 1: return locale.t("1 hour")
        default:
            return locale.t("%@ hours").replacingOccurrences(of: "%@", with: String(n))
        }
    }
}
