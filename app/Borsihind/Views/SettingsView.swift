import SwiftUI

/// Modal preferences sheet. Lets the user pick the UI language, data
/// interval (15 min vs. 1 h), grid service plan, and seller margin. The
/// language picker reads `@AppStorage` directly so its labels update live
/// without waiting for the locale environment to propagate through the sheet.
struct SettingsView: View {
    @Binding var interval: Interval
    @Binding var plan: Plan
    @Binding var marginal: Double
    /// Per-window "must end before HH:00" deadlines. `0` = no constraint.
    /// Four user-editable cheapest-hours slots. Each slot is a (hours,
    /// deadline) pair: hours 1...6 picks window length, deadline 1...23
    /// (or 0 for off) sets the "must end before HH:00" cutoff.
    @Binding var slot1Hours: Int
    @Binding var slot1Deadline: Int
    @Binding var slot2Hours: Int
    @Binding var slot2Deadline: Int
    @Binding var slot3Hours: Int
    @Binding var slot3Deadline: Int
    @Binding var slot4Hours: Int
    @Binding var slot4Deadline: Int
    /// User-defined slot order (comma-separated slot ids 0...3). Updated
    /// when the user drags a row to a new position.
    @Binding var slotOrderRaw: String
    /// Notification lead time: `-1` = Off, `0` = at slot start, otherwise
    /// minutes before slot start.
    @Binding var notifyLeadMinutes: Int
    /// Called when the user taps the locked margin row. Parent dismisses
    /// the sheet (or stacks it) and presents the paywall.
    var onRequestPaywall: () -> Void

    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue
    /// Mirrors `ContentView`'s flag — tapping the disclaimer row resets it so
    /// the first-launch alert reappears on the next cold start (debug aid).
    @AppStorage("disclaimerShown") private var disclaimerShown: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(StoreManager.self) private var store

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

    /// Hand off to the parent's paywall presenter. Dismisses the Settings
    /// sheet first, then on macOS waits a frame for the dismiss animation
    /// to release the sheet stack — without this, the new paywall sheet
    /// races the dismissing settings sheet and silently fails to appear.
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

    /// Sortable wrapper around a slot's hours + deadline bindings. `id` is
    /// the stable storage slot index — SwiftUI uses it to track row
    /// identity across re-sorts when the user changes a row's length.
    private struct SlotBindingPair: Identifiable {
        let id: Int
        let hours: Binding<Int>
        let deadline: Binding<Int>
    }

    /// All four slot bindings keyed by slot id, used as a lookup source
    /// for the user-ordered list.
    private var allSlotBindings: [SlotBindingPair] {
        [
            .init(id: 0, hours: $slot1Hours, deadline: $slot1Deadline),
            .init(id: 1, hours: $slot2Hours, deadline: $slot2Deadline),
            .init(id: 2, hours: $slot3Hours, deadline: $slot3Deadline),
            .init(id: 3, hours: $slot4Hours, deadline: $slot4Deadline),
        ]
    }

    /// Slot bindings in the user-defined order (drag-to-reorder in the
    /// list). Falls back to the natural order for invalid stored strings.
    private var orderedSlotBindings: [SlotBindingPair] {
        let order = parseSlotOrder(slotOrderRaw)
        let all = allSlotBindings
        var result: [SlotBindingPair] = order.compactMap { id in all.first { $0.id == id } }
        for binding in all where !result.contains(where: { $0.id == binding.id }) {
            result.append(binding)
        }
        return result
    }

    /// Same as the parsing helper in `ContentView` — duplicated here so
    /// `SettingsView` doesn't reach across files for a private static.
    private func parseSlotOrder(_ raw: String) -> [Int] {
        var seen = Set<Int>()
        return raw.split(separator: ",").compactMap { piece -> Int? in
            guard let n = Int(piece), (0...3).contains(n), !seen.contains(n) else { return nil }
            seen.insert(n)
            return n
        }
    }

    /// Apply a SwiftUI `.onMove` reorder to the persisted slot order.
    private func moveSlots(from source: IndexSet, to destination: Int) {
        var ids = orderedSlotBindings.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        slotOrderRaw = ids.map(String.init).joined(separator: ",")
    }

    /// One slot row in the cheapest-hours section. Renders two pickers
    /// inline — a length picker (1h…6h, or just 1h if `lengthLocked`)
    /// and a deadline picker (Off / 01:00…23:00). For free users on
    /// slots 1...3, the whole row collapses to a centered "Börsihind+"
    /// upsell.
    @ViewBuilder
    private func slotRow(hours: Binding<Int>, deadline: Binding<Int>,
                         locked: Bool, lengthLocked: Bool) -> some View {
        if locked {
            premiumLockedRow
        } else {
            HStack(spacing: 12) {
                // Leading drag-affordance glyph. The standard SF Symbol
                // for "reorderable list row" — three horizontal lines.
                // Doesn't itself capture a drag gesture; the actual
                // reorder is driven by SwiftUI's `editMode = .active`
                // handle that appears at the trailing edge on iOS. The
                // leading glyph makes the affordance discoverable even
                // when the system handle is subtle / absent (e.g. macOS).
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .font(.subheadline)

                Picker("", selection: hours) {
                    Text(locale.t("Off")).tag(0)
                    ForEach(1...6, id: \.self) { n in
                        Text("\(n)h").tag(n)
                    }
                }
                .labelsHidden()
                .disabled(lengthLocked)

                Picker("", selection: deadline) {
                    Text(locale.t("Off")).tag(0)
                    ForEach(1..<24) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Locked-row template used by the cheapest-hours section for every
    /// free-user-gated row: just "Börsihind+" centered, tap routes to the
    /// paywall. No row label — the visible context is enough since the
    /// rows sit under the section header.
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
        // Force the row separator to start at the row's leading edge so
        // it matches the editable slot rows above (whose drag-handle glyph
        // already anchors the separator to x=0). Without this, SwiftUI
        // infers the separator inset from the row's first content — which
        // here is the centered text, leaving a visible gap on the left.
        // The alignment guide isn't available on tvOS — fortunately tvOS
        // doesn't render List separators the same way, so the guard is
        // harmless visually.
        #if !os(tvOS)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                    Section {
                        Picker(locale.t("Language"), selection: language) {
                            ForEach(Language.allCases) { lang in
                                Text(lang.label).tag(lang)
                            }
                        }
                    }

                    // Plan, margin, interval together — all three affect
                    // what's shown in the price breakdown / chart. Interval
                    // last (granularity preference, set once and forgotten).
                    Section {
                        Picker(locale.t("Grid service plan"), selection: $plan) {
                            ForEach(Plan.allCases) { p in
                                Text(p.label).tag(p)
                            }
                        }

                        if store.isSubscribed {
                            LabeledContent(locale.t("Seller margin")) {
                                TextField("", value: $marginal, format: .number.precision(.fractionLength(2...4)).locale(locale))
                                    .multilineTextAlignment(.trailing)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                    .frame(maxWidth: 100)
                            }
                        } else {
                            // Locked row — looks like other settings rows but
                            // tapping triggers the paywall via the parent.
                            Button {
                                requestPaywall()
                            } label: {
                                HStack {
                                    Text(locale.t("Seller margin"))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("Börsihind+")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if store.isSubscribed {
                            Picker(locale.t("Interval"), selection: $interval) {
                                ForEach(Interval.allCases) { i in
                                    Text(locale.t(i.labelKey)).tag(i)
                                }
                            }
                        } else {
                            // 15-min granularity is gated; free users see the
                            // row but it shows the locked interval (1h) and
                            // routes to the paywall.
                            Button {
                                requestPaywall()
                            } label: {
                                HStack {
                                    Text(locale.t("Interval"))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("Börsihind+")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Cheapest-hours: 4 user-configurable slots, each with
                    // its own window length (1...6h) and optional "must end
                    // before HH:00" deadline. Slot 1 is free (length locked
                    // at 1h, deadline editable); slots 2-4 require
                    // Börsihind+ and render as centered upsell rows for
                    // non-subscribers. Rows are sorted by current length so
                    // the layout always reads 1h → 6h, matching the main
                    // screen's card order.
                    Section {
                        if store.isSubscribed {
                            // `editMode = .active` keeps the drag handles
                            // visible permanently so the user doesn't need
                            // to find an Edit button to reorder. No
                            // `.onDelete` is provided, so only the move
                            // grip appears — no red delete chip.
                            ForEach(orderedSlotBindings) { binding in
                                slotRow(hours: binding.hours,
                                        deadline: binding.deadline,
                                        locked: false, lengthLocked: false)
                            }
                            .onMove(perform: moveSlots)
                            #if os(iOS)
                            .environment(\.editMode, .constant(.active))
                            #endif
                        } else {
                            // Free tier: slot 1 first (length pinned to 1h),
                            // then 3 locked upsell rows.
                            slotRow(
                                hours: .constant(1),
                                deadline: $slot1Deadline,
                                locked: false,
                                lengthLocked: true
                            )
                            premiumLockedRow
                            premiumLockedRow
                            premiumLockedRow
                        }
                    } header: {
                        // Section title on the left, sub-label for the
                        // right-side deadline picker on the right. The
                        // `.textCase(nil)` keeps the sub-label readable
                        // — Form headers otherwise get force-uppercased.
                        HStack(alignment: .firstTextBaseline) {
                            Text(locale.t("Cheapest hours"))
                            Spacer()
                            Text(locale.t("Must end before"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    } footer: {
                        // Plain footer description explaining the feature.
                        // Scrolls with the section and gives the user a
                        // hint on what the deadline column controls.
                        Text(locale.t("Cheapest hours explanation"))
                    }

                    // Notifications — single picker that combines on/off
                    // with the lead time. Premium-only, matching the
                    // cheapest-hours gating. tvOS doesn't support local
                    // notifications, so we hide the entire section there.
                    #if !os(tvOS)
                    Section {
                        if store.isSubscribed {
                            Picker(locale.t("Notify before"),
                                   selection: $notifyLeadMinutes) {
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
                    #endif

                    // Subscription row — visible to everyone. For
                    // subscribers it opens the paywall in management mode
                    // (switch tier / cancel). For non-subscribers it opens
                    // the same paywall so they can start a subscription.
                    // `SubscriptionStoreView` handles both states natively.
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
                            // Inside the label so the empty Spacer area is
                            // part of the hit region — outside the label,
                            // the modifier doesn't widen taps.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                // Disclaimer renders as a borderless row at the bottom of
                // the Form so it scrolls with the rest of the content
                // instead of sticking to the screen bottom. `.listRowBackground(.clear)`
                // and `.listRowInsets(.init())` strip the grouped-section
                // chrome so it reads as a footnote, not a settings row.
                // Tap resets `disclaimerShown` so the first-launch alert
                // reappears on the next cold start.
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
        // macOS-only minimum window size for the sheet. On iPhone the
        // 420pt minWidth was forcing the NavigationStack wider than the
        // screen (393pt on most devices), which shifted the leading
        // toolbar item — our close button — tight against the left edge.
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 380)
        #endif
    }
}
