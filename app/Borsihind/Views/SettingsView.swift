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
                #if !os(tvOS)
                notificationsSection
                #endif
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
                    DismissButton(title: locale.t("Done"))
                }
            }
        }
        #if os(macOS)
        // Mac-only minimum window size. On iPhone, forcing a minWidth
        // wider than the screen pushed the leading toolbar X off the edge.
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
            } else {
                premiumLabeledRow(locale.t("Seller margin"))
                premiumLabeledRow(locale.t("Interval"))
            }
        } header: {
            Text(locale.t("Pricing"))
        } footer: {
            Text(locale.t("Pricing explanation"))
        }
    }

    private var cheapestHoursSection: some View {
        Section {
            if store.isSubscribed {
                // Slots stay in fixed storage order — user reorders
                // implicitly by changing each row's hours value.
                slotRow(hours: $slot1Hours, deadline: $slot1Deadline)
                slotRow(hours: $slot2Hours, deadline: $slot2Deadline)
                slotRow(hours: $slot3Hours, deadline: $slot3Deadline)
                slotRow(hours: $slot4Hours, deadline: $slot4Deadline)
            } else {
                // Slot 1 deadline is the only free-tier control. Hours
                // are pinned to 1h via `.constant(1)`.
                slotRow(hours: .constant(1), deadline: $slot1Deadline, lengthLocked: true)
                premiumLockedRow
                premiumLockedRow
                premiumLockedRow
            }
        } header: {
            // Sub-label "Must end before" tags the right-column picker.
            // `.textCase(nil)` keeps it readable — Form headers are
            // force-uppercased by default.
            HStack(alignment: .firstTextBaseline) {
                Text(locale.t("Cheapest hours"))
                Spacer()
                Text(locale.t("Must end before"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        } footer: {
            Text(locale.t("Cheapest hours explanation"))
        }
    }

    #if !os(tvOS)
    private var notificationsSection: some View {
        Section {
            if store.isSubscribed {
                Picker(locale.t("Notify before"), selection: $notifyLeadMinutes) {
                    Text(locale.t("Off")).tag(-1)
                    Text(locale.t("At start")).tag(0)
                    Text(locale.t("5 minutes")).tag(5)
                    Text(locale.t("10 minutes")).tag(10)
                    Text(locale.t("15 minutes")).tag(15)
                    Text(locale.t("30 minutes")).tag(30)
                    Text(locale.t("1 hour")).tag(60)
                }
            } else {
                premiumLockedRow
            }
        } header: {
            Text(locale.t("Notifications"))
        } footer: {
            Text(locale.t("Notifications explanation"))
        }
    }
    #endif

    /// Always-visible subscription entry. Opens the paywall in management
    /// mode for subscribers, in purchase mode otherwise.
    private var subscriptionSection: some View {
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
    }

    /// Footnote at the bottom of the Form. Borderless row (chrome stripped
    /// via `.listRowBackground(.clear)` + zero insets) so it reads as a
    /// disclaimer rather than a settings row. Tap resets `disclaimerShown`.
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

    /// One cheapest-hours slot row: length on the left, deadline on the
    /// right. Both are `Menu`-as-Picker so the row's content is plain
    /// text + chevron — same visual weight as the Plan / Interval rows
    /// above, so heights match.
    @ViewBuilder
    private func slotRow(hours: Binding<Int>, deadline: Binding<Int>,
                         lengthLocked: Bool = false) -> some View {
        // Deadline is meaningless when the slot is Off — disable the
        // picker so the row reads as "no deadline applicable".
        let deadlineEnabled = hours.wrappedValue > 0

        LabeledContent {
            // Right side = value position; iOS Form Pickers render the
            // current value in secondary (gray), so we match. Hours 0...23
            // are all valid (0 = midnight); `-1` is the Off sentinel.
            menuPicker(
                title: deadline.wrappedValue < 0
                    ? locale.t("Off")
                    : String(format: "%02d:00", deadline.wrappedValue),
                selection: deadline,
                style: deadlineEnabled ? .value : .disabled
            ) {
                Text(locale.t("Off")).tag(-1)
                ForEach(0..<24) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
        } label: {
            // Left side = title position; primary text so it reads like
            // the rows above.
            menuPicker(
                title: hoursLabel(hours.wrappedValue),
                selection: hours,
                style: lengthLocked ? .disabled : .title
            ) {
                Text(locale.t("Off")).tag(0)
                ForEach(1...6, id: \.self) { n in
                    Text(hoursLabel(n)).tag(n)
                }
            }
        }
    }

    /// Localized hour-count label. Singular vs. plural form, plus the
    /// "Off" placeholder for `0`. Settings-only; the cards on the main
    /// screen still use the compact `Nh` badge.
    private func hoursLabel(_ n: Int) -> String {
        switch n {
        case 0: return locale.t("Off")
        case 1: return locale.t("1 hour")
        default:
            return locale.t("%@ hours").replacingOccurrences(of: "%@", with: String(n))
        }
    }

    private enum MenuPickerStyle {
        case title     // primary text — left side of a row
        case value     // secondary text — right side of a row (matches Form Picker default)
        case disabled  // muted, not interactive

        var foreground: AnyShapeStyle {
            switch self {
            case .title:    AnyShapeStyle(.primary)
            case .value:    AnyShapeStyle(.secondary)
            case .disabled: AnyShapeStyle(.tertiary)
            }
        }

        var enabled: Bool {
            self != .disabled
        }
    }

    /// Text-button styled menu picker. Renders as `[value ▾]` with the
    /// supplied foreground style — `.buttonStyle(.plain)` is required or
    /// the system auto-tints the label blue regardless of the
    /// `foregroundStyle` modifier.
    @ViewBuilder
    private func menuPicker<Content: View>(
        title: String,
        selection: Binding<Int>,
        style: MenuPickerStyle,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            Picker("", selection: selection, content: content)
                .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(style.foreground)
        }
        .buttonStyle(.plain)
        .disabled(!style.enabled)
    }

    /// Labeled premium-locked row: label on the left, "Börsihind+" tag on
    /// the right. Used in the pricing section for the gated Margin / Interval.
    private func premiumLabeledRow(_ label: String) -> some View {
        Button {
            requestPaywall()
        } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                Text("Börsihind+")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Centered-only premium-locked row used by the cheapest-hours and
    /// notifications sections. Separator pinned to the leading edge so it
    /// lines up with the editable rows above.
    private var premiumLockedRow: some View {
        Button {
            requestPaywall()
        } label: {
            Text("Börsihind+")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        #endif
    }
}
