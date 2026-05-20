import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Root screen. Picks one of three layouts:
/// - iPhone → `phoneLayout` (price+breakdown on top, pager below)
/// - iPad portrait / narrow Mac → `compactLayout` (50/50 top + full-width chart)
/// - iPad landscape / wide Mac → `wideLayout` (left column + chart)
///
/// Owns `PricesViewModel`, persists user choices via `@AppStorage`, and
/// orchestrates the slot-boundary refresh pipeline.
struct ContentView: View {
    // MARK: - Persisted state

    @AppStorage("plan") private var planRaw: String = Plan.v1.rawValue
    @AppStorage("interval") private var intervalRaw: String = Interval.fifteenMin.rawValue
    @AppStorage("marginal") private var marginal: Double = 0
    /// Selected cheapest-hours slot index (0...3). `""` = none selected.
    @AppStorage("lowest") private var lowestRaw: String = "0"

    /// Four user-editable cheapest-hours slots. `hours = 0` disables a slot.
    /// `deadline = -1` means no "must end before" constraint; otherwise
    /// it's the hour of day (0...23, where 0 = midnight).
    @AppStorage("slot.1.hours") private var slot1Hours: Int = 1
    @AppStorage("slot.1.deadline") private var slot1Deadline: Int = -1
    @AppStorage("slot.2.hours") private var slot2Hours: Int = 2
    @AppStorage("slot.2.deadline") private var slot2Deadline: Int = -1
    @AppStorage("slot.3.hours") private var slot3Hours: Int = 3
    @AppStorage("slot.3.deadline") private var slot3Deadline: Int = -1
    @AppStorage("slot.4.hours") private var slot4Hours: Int = 4
    @AppStorage("slot.4.deadline") private var slot4Deadline: Int = -1

    /// Notification lead time. `-1` = Off, `0` = at start, else minutes before.
    @AppStorage("notify.leadMinutes") private var notifyLeadMinutes: Int = -1
    /// iPhone pager page (0 = cheapest cards, 1 = chart).
    @AppStorage("phonePage") private var phonePage: Int = 0
    /// True once the first-launch disclaimer alert has been acknowledged.
    @AppStorage("disclaimerShown") private var disclaimerShown: Bool = false
    /// Language — read here only to forward to the watch.
    @AppStorage("language", store: .shared) private var languageRaw: String = Language.et.rawValue

    // MARK: - Local state

    @State private var vm = PricesViewModel()
    @State private var showSettings = false
    @State private var showPaywall = false
    @State private var showDisclaimer = false
    /// `nil` = follow the current first bar; otherwise pinned to a tapped bar.
    @State private var selectedDate: Date?

    // MARK: - Environment

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(StoreManager.self) private var store

    // MARK: - Constants

    /// One spacing constant used app-wide. Tweak to scale all gaps together.
    private static let pad: CGFloat = 32
    /// Minimum left-column width for the wide layout.
    private static let leftColumnMinWidth: CGFloat = 210

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    // MARK: - Bindings + derived state

    private var plan: Binding<Plan> {
        Binding(
            get: { Plan(rawValue: planRaw) ?? .v1 },
            set: { planRaw = $0.rawValue }
        )
    }

    private var interval: Binding<Interval> {
        Binding(
            get: { Interval(rawValue: intervalRaw) ?? .fifteenMin },
            set: { intervalRaw = $0.rawValue }
        )
    }

    private var selectedLowest: Int? { Int(lowestRaw) }

    /// Free users get 0 (margin is a premium feature). Stored value is
    /// preserved so it returns intact on re-subscription.
    private var effectiveMargin: Double { store.isSubscribed ? marginal : 0 }

    /// 15-min granularity is premium; free users always see 1h.
    private var effectiveInterval: Interval {
        store.isSubscribed ? interval.wrappedValue : .oneHour
    }

    /// Slot config used for cheapest-window computation. Free users get a
    /// single 1h slot; subscribers get all four in fixed storage order.
    private var effectiveSlots: [CheapestSlot] {
        let storage = [
            CheapestSlot(id: 0, hours: clampedHours(slot1Hours), deadline: slot1Deadline),
            CheapestSlot(id: 1, hours: clampedHours(slot2Hours), deadline: slot2Deadline),
            CheapestSlot(id: 2, hours: clampedHours(slot3Hours), deadline: slot3Deadline),
            CheapestSlot(id: 3, hours: clampedHours(slot4Hours), deadline: slot4Deadline),
        ]
        return store.isSubscribed
            ? storage
            : [CheapestSlot(id: 0, hours: 1, deadline: slot1Deadline)]
    }

    /// Clamp to `[0, 6]` defensively. `0` = slot is off.
    private func clampedHours(_ h: Int) -> Int { min(max(h, 0), 6) }

    /// Single watchable summarising all four slots — one `.onChange`
    /// covers every slot edit, keeps the body's type checker happy.
    private var slotConfigSignature: String {
        "\(slot1Hours)/\(slot1Deadline)/\(slot2Hours)/\(slot2Deadline)"
        + "/\(slot3Hours)/\(slot3Deadline)/\(slot4Hours)/\(slot4Deadline)"
    }

    private var lowestWindows: [LowestWindow] {
        vm.lowestWindows(interval: effectiveInterval, marginal: effectiveMargin,
                         slots: effectiveSlots)
    }

    private var highlightRange: ClosedRange<Int>? {
        guard let idx = selectedLowest,
              let win = lowestWindows.first(where: { $0.slotIndex == idx })
        else { return nil }
        return win.startIndex...win.endIndex
    }

    /// Pinned tap target, falling back to the current (first) visible bar.
    private var current: PriceEntry? {
        if let d = selectedDate,
           let pinned = vm.prices.first(where: { $0.date == d }) {
            return pinned
        }
        return vm.prices.first
    }

    private var currentTotal: Double {
        (current?.componentSum ?? 0) + effectiveMargin
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
                .safeAreaPadding(.bottom)

            gearButton
                .padding(.leading, 16)
                .padding(.bottom, 24)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .task { await fetchIfStaleAndRecompute() }
        .task {
            if !disclaimerShown { showDisclaimer = true }
        }
        .alert(locale.t("Disclaimer"), isPresented: $showDisclaimer) {
            Button(locale.t("OK"), role: .cancel) { disclaimerShown = true }
        } message: {
            Text(locale.t("All prices shown in the app include VAT and are in cents per kilowatt-hour."))
        }
        // Plan / Interval = different upstream JSON → force fetch.
        .onChange(of: planRaw)     { _, _ in selectedDate = nil; Task { await forceFetchAndRecompute() } }
        .onChange(of: intervalRaw) { _, _ in selectedDate = nil; Task { await forceFetchAndRecompute() } }
        // Subscription flip changes `effectiveInterval` → upstream URL
        // changes too, so we must force-fetch.
        .onChange(of: store.isSubscribed) { _, _ in selectedDate = nil; Task { await forceFetchAndRecompute() } }
        // Local-only settings.
        .onChange(of: lowestRaw)           { _, _ in Task { await recompute() } }
        .onChange(of: marginal)            { _, _ in Task { await recompute() } }
        // All 8 slot bindings collapsed into one watched signature so
        // the body's type-checker stays happy.
        .onChange(of: slotConfigSignature) { _, _ in Task { await recompute() } }
        .onChange(of: notifyLeadMinutes)   { _, _ in Task { await rescheduleNotifications() } }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            selectedDate = nil
            Task {
                await store.refresh()
                await fetchIfStaleAndRecompute()
            }
        }
        .onAppear {
            vm.startMinuteTicker { Task { await recompute() } }
            #if os(iOS)
            BackgroundRefresh.handler = { await forceFetchAndRecompute() }
            BackgroundRefresh.scheduleNext()
            WatchConnectivityProvider.shared.activate()
            #endif
        }
        .onDisappear { vm.stopMinuteTicker() }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        // Widget deep link: `borsihind://paywall` opens the paywall sheet.
        .onOpenURL { url in
            if url.scheme == "borsihind", url.host == "paywall" {
                showPaywall = true
            }
        }
    }

    private var settingsSheet: some View {
        SettingsView(
            interval: interval,
            plan: plan,
            marginal: $marginal,
            slot1Hours: $slot1Hours,
            slot1Deadline: $slot1Deadline,
            slot2Hours: $slot2Hours,
            slot2Deadline: $slot2Deadline,
            slot3Hours: $slot3Hours,
            slot3Deadline: $slot3Deadline,
            slot4Hours: $slot4Hours,
            slot4Deadline: $slot4Deadline,
            notifyLeadMinutes: $notifyLeadMinutes,
            onRequestPaywall: { showPaywall = true }
        )
    }

    // MARK: - Layout dispatcher

    @ViewBuilder
    private var content: some View {
        // ScrollView hosts `.refreshable`; the inner content is sized to
        // the geometry so it never actually scrolls.
        GeometryReader { geo in
            ScrollView {
                Group {
                    if vm.isLoading && vm.prices.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.errorMessage != nil, vm.prices.isEmpty {
                        Text(locale.t("Failed to load prices"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isPhone {
                        phoneLayout(in: geo.size)
                    } else if geo.size.width < geo.size.height {
                        compactLayout(in: geo.size)
                    } else {
                        wideLayout(in: geo.size)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .refreshable { await forceFetchAndRecompute() }
        }
    }

    private var gearButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gear")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(locale.t("Settings"))
        #if !os(tvOS)
        .keyboardShortcut(",", modifiers: .command)
        #endif
    }

    // MARK: - Layouts

    /// iPhone: 50/50 vertical — price + breakdown on top, swipeable pager
    /// (cheapest cards / chart) below.
    private func phoneLayout(in size: CGSize) -> some View {
        let pad = Self.pad
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: pad / 2) {
                priceHeader
                breakdown
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, pad)
            .padding(.top, pad)

            // Header lives outside the TabView so `.page` style doesn't
            // vertically center it off-screen.
            VStack(spacing: 8) {
                Text(phonePage == 0 ? locale.t("Cheapest hours") : "")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                TabView(selection: $phonePage) {
                    cardsColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                        .tag(0)

                    chart
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                        .tag(1)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, pad)
            .padding(.top, pad)
        }
    }

    /// iPad portrait / narrow Mac: top row 50/50 (breakdown + cards),
    /// full-width chart below.
    private func compactLayout(in size: CGSize) -> some View {
        let pad = Self.pad
        let chartGap = pad * 2
        let half = max(0, (size.height - 40 - chartGap - 2 * pad) / 2)

        return VStack(spacing: chartGap) {
            HStack(alignment: .top, spacing: pad) {
                VStack(alignment: .leading, spacing: pad) {
                    priceHeader
                    breakdown
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    Text(locale.t("Cheapest hours"))
                        .textCase(.uppercase)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    cardsColumn
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: half, alignment: .top)

            chart
                .frame(maxWidth: .infinity, maxHeight: half)
        }
        .padding(.horizontal, pad)
        .padding(.top, pad / 2)
        .padding(.bottom, pad)
    }

    /// iPad landscape / wide Mac: narrow left column (sections stacked),
    /// rest of the window is chart.
    private func wideLayout(in size: CGSize) -> some View {
        let pad = Self.pad
        let chartGap = pad * 2
        let leftWidth = max(Self.leftColumnMinWidth, min(300, size.width / 5))
        return HStack(alignment: .top, spacing: chartGap) {
            leftColumn
                .frame(width: leftWidth)

            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(pad)
    }

    /// Two stacked half-height sections: price+breakdown then cheapest cards.
    private var leftColumn: some View {
        let pad = Self.pad
        let sectionGap = pad * 2
        return GeometryReader { geo in
            let half = max(0, (geo.size.height - sectionGap) / 2)
            VStack(spacing: sectionGap) {
                VStack(alignment: .leading, spacing: pad) {
                    priceHeader
                    breakdown
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: half, alignment: .center)

                VStack(alignment: .leading, spacing: 8) {
                    Text(locale.t("Cheapest hours"))
                        .textCase(.uppercase)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    cardsColumn
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: half, alignment: .center)
            }
        }
    }

    // MARK: - Subviews

    /// "Current price" when the live first bar is shown; "Selected price"
    /// when the user has tapped a future bar.
    private var priceHeaderTitle: String {
        let isCurrent = current?.date == vm.prices.first?.date
        return locale.t(isCurrent ? "Current price" : "Selected price")
    }

    private var priceHeader: some View {
        VStack(spacing: 8) {
            Text(priceHeaderTitle)
                .textCase(.uppercase)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text(currentTotal.priceString(locale: locale))
                    .font(.system(size: 36, weight: .bold))
                    .monospacedDigit()
                if let c = current {
                    Text(timeRangeLabel(for: c))
                        .font(.headline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            BreakdownRow(locale.t("Electricity price"),    current?.electricity ?? 0)
            BreakdownRow(locale.t("Transmission fee"),     current?.transmission ?? 0)
            BreakdownRow(locale.t("Renewable energy tax"), current?.renewable ?? 0)
            BreakdownRow(locale.t("Supply security fee"),  current?.supplySecurity ?? 0)
            BreakdownRow(locale.t("Excise"),               current?.excise ?? 0)
            // Margin can carry up to 4 decimals to mirror the user's input.
            BreakdownRow(locale.t("Seller margin"),        effectiveMargin,
                         fractionDigits: marginalDigits, showDivider: false)
        }
    }

    /// Decimal places for the margin row. 2-4 to mirror what the user typed.
    private var marginalDigits: Int {
        guard store.isSubscribed else { return 2 }
        let s = String(marginal)
        guard let dot = s.firstIndex(of: ".") else { return 2 }
        let after = s.distance(from: s.index(after: dot), to: s.endIndex)
        return min(4, max(2, after))
    }

    private var cardsColumn: some View {
        VStack(spacing: 8) {
            ForEach(lowestWindows) { window in
                LowestWindowCard(
                    window: window,
                    isSelected: selectedLowest == window.slotIndex,
                    // Slot 0 free; 1-3 premium. Don't flash locked
                    // chrome while subscription state is still loading.
                    isLocked: store.hasResolvedSubscriptionState
                        && window.slotIndex > 0
                        && !store.isSubscribed,
                    isReady: store.hasResolvedSubscriptionState,
                    nowAverage: vm.nowAverage(forHours: window.hours,
                                              interval: effectiveInterval,
                                              marginal: effectiveMargin),
                    onTap: {
                        if window.slotIndex > 0 && !store.isSubscribed {
                            showPaywall = true
                        } else {
                            let key = String(window.slotIndex)
                            lowestRaw = (lowestRaw == key) ? "" : key
                        }
                    }
                )
            }
        }
    }

    private var chart: some View {
        PriceChart(
            prices: vm.prices,
            marginal: effectiveMargin,
            interval: effectiveInterval,
            highlightRange: highlightRange,
            selectedDate: $selectedDate
        )
    }

    // MARK: - Refresh pipeline

    private func timeRangeLabel(for entry: PriceEntry) -> String {
        let endDate = entry.date.addingTimeInterval(TimeInterval(effectiveInterval.minutes * 60))
        let fmt = Date.VerbatimFormatStyle.hourMinute24
        return "\(entry.date.formatted(fmt)) – \(endDate.formatted(fmt))"
    }

    /// Re-derive everything from cached data (drops past slots, finds
    /// cheapest, reschedules notifications, rewrites widget snapshot,
    /// pushes state to the watch). No network.
    private func recompute() async {
        vm.bumpNow()
        updateWidgetSnapshot()
        await rescheduleNotifications()
        pushWatchState()
    }

    /// Push settings + subscription state to the paired watch.
    private func pushWatchState() {
        #if os(iOS)
        WatchConnectivityProvider.shared.push(SyncedState(
            planRaw: planRaw,
            intervalRaw: intervalRaw,
            marginal: marginal,
            slotHours: [slot1Hours, slot2Hours, slot3Hours, slot4Hours],
            slotDeadlines: [slot1Deadline, slot2Deadline, slot3Deadline, slot4Deadline],
            selectedSlot: selectedLowest ?? -1,
            languageRaw: languageRaw,
            isSubscribed: store.isSubscribed
        ))
        #endif
    }

    /// Fetch if last successful fetch ≥ 3 h ago, then recompute.
    private func fetchIfStaleAndRecompute() async {
        await vm.loadIfStale(plan: Plan(rawValue: planRaw) ?? .v1,
                             interval: effectiveInterval)
        await recompute()
    }

    /// Force-fetch + recompute. Pull-to-refresh, plan/interval change,
    /// BGAppRefreshTask wake.
    private func forceFetchAndRecompute() async {
        await vm.load(plan: Plan(rawValue: planRaw) ?? .v1,
                      interval: effectiveInterval)
        await recompute()
    }

    /// Premium-only. Wipes pending notifications when Off or unsubscribed.
    private func rescheduleNotifications() async {
        guard store.isSubscribed, notifyLeadMinutes >= 0 else {
            await NotificationScheduler.removeAll()
            return
        }
        await NotificationScheduler.reschedule(
            slots: lowestWindows,
            leadMinutes: notifyLeadMinutes,
            locale: locale
        )
    }

    /// Write the App Group snapshot and reload widget timelines.
    private func updateWidgetSnapshot() {
        SharedStorage.isSubscribed = store.isSubscribed
        guard let snap = vm.snapshot(slots: effectiveSlots,
                                     selectedSlotID: selectedLowest,
                                     marginal: effectiveMargin)
        else { return }
        SharedStorage.writeSnapshot(snap)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

#Preview {
    ContentView()
}
