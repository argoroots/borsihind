import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Root screen of the app. Picks one of three layouts based on device and
/// window aspect ratio:
///
/// - **iPhone** → `phoneLayout`: top half = price + breakdown, bottom half =
///   a swipeable pager (cheapest hours / chart) with persistent page index.
/// - **iPad portrait / narrow Mac** → `compactLayout`: 50/50 top split
///   (price+breakdown · cheapest hours) with a full-width chart below.
/// - **iPad landscape / wide Mac** → `wideLayout`: left column with the two
///   sections stacked, chart taking the rest of the window.
///
/// Owns the `PricesViewModel`, persists user choices via `@AppStorage`, and
/// orchestrates auto-refresh + the minute ticker that advances "current bar".
struct ContentView: View {
    @AppStorage("plan") private var planRaw: String = Plan.v1.rawValue
    @AppStorage("interval") private var intervalRaw: String = Interval.fifteenMin.rawValue
    @AppStorage("marginal") private var marginal: Double = 0
    /// Selected cheapest window in hours, persisted across launches.
    /// Default is `"1"` so new users see the 1-hour window highlighted in
    /// the chart on first launch — that's the free-tier feature and the
    /// fastest "this is what the app does" demo. Setting it to `""` clears
    /// the highlight (toggling the same card off).
    /// Selected slot index (0...3) — drives the green highlight on the
    /// chart. `""` clears the highlight. Defaults to slot 0 so new users
    /// see their first cheapest-hours card highlighted on launch.
    @AppStorage("lowest") private var lowestRaw: String = "0"
    /// Four user-editable cheapest-hours slots. Each slot has a window
    /// length (1...6) and an optional "must end before HH:00" deadline
    /// (`0` = no constraint). Defaults give the original 1h/2h/3h/4h
    /// windows with no deadlines so existing screenshots / demos still
    /// match what users see on first launch.
    @AppStorage("slot.1.hours") private var slot1Hours: Int = 1
    @AppStorage("slot.1.deadline") private var slot1Deadline: Int = 0
    @AppStorage("slot.2.hours") private var slot2Hours: Int = 2
    @AppStorage("slot.2.deadline") private var slot2Deadline: Int = 0
    @AppStorage("slot.3.hours") private var slot3Hours: Int = 3
    @AppStorage("slot.3.deadline") private var slot3Deadline: Int = 0
    @AppStorage("slot.4.hours") private var slot4Hours: Int = 4
    @AppStorage("slot.4.deadline") private var slot4Deadline: Int = 0
    /// User-defined slot order. Comma-separated list of slot ids 0...3.
    /// `@AppStorage` can't hold `[Int]` natively, so we round-trip through
    /// a string. The Settings sheet rewrites this whenever the user drags
    /// a row; the main screen reads it back to display cards in the same
    /// order. Defaults to natural 0,1,2,3.
    @AppStorage("slot.order") private var slotOrderRaw: String = "0,1,2,3"
    /// Notification lead time in minutes. `-1` = Off (no notifications).
    /// `0` = fire at slot start. `5/10/15/30/60` = N minutes before.
    /// Free users see this gated behind Börsihind+.
    @AppStorage("notify.leadMinutes") private var notifyLeadMinutes: Int = -1
    /// Which iPhone pager page was last shown — 0 = cheapest hours, 1 = chart.
    /// Persisted so the user returns to the same page across launches.
    @AppStorage("phonePage") private var phonePage: Int = 0
    /// Set true once the first-launch disclaimer alert has been acknowledged.
    @AppStorage("disclaimerShown") private var disclaimerShown: Bool = false

    /// Drives the first-launch disclaimer alert. Bound to `disclaimerShown`
    /// so dismissal flips the flag and the alert never reappears.
    @State private var showDisclaimer: Bool = false

    @State private var vm = PricesViewModel()
    @State private var showSettings = false
    /// `nil` = follow the current first bar; otherwise pinned to a tapped bar.
    @State private var selectedDate: Date?
    /// Drives the Börsihind+ paywall sheet. Set when the user taps a locked
    /// feature (2/3/4h cheapest cards or the Settings margin row).
    @State private var showPaywall = false

    /// One spacing constant used app-wide: window padding, gaps between
    /// sections, gaps between columns. Tweak to scale all spacing together.
    private static let pad: CGFloat = 32
    /// True only on iPhone — used to switch to the scrollable single-column
    /// layout, since iPhone screens are too narrow for the 50/50 split.
    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    /// Min width for the left column in the wide layout so its labels and
    /// values don't get cramped on narrow windows.
    private static let leftColumnMinWidth: CGFloat = 200
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.locale) private var locale
    /// Subscription state — gates Börsihind+ features (2/3/4h windows, custom
    /// margin, widgets). Free users see the controls but tapping them opens
    /// the paywall.
    @Environment(StoreManager.self) private var store

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

    /// Selected slot index 0...3, or nil when no slot is selected (empty
    /// string in `lowestRaw`).
    private var selectedLowest: Int? { Int(lowestRaw) }

    /// Effective margin used in all calculations. Free users see 0 — we keep
    /// their stored value untouched so it returns intact when they subscribe.
    private var effectiveMargin: Double { store.isSubscribed ? marginal : 0 }

    /// Effective interval used in all calculations. 15-min granularity is a
    /// Börsihind+ feature; free users always see 1h regardless of stored
    /// preference (preference is preserved for return-when-subscribed).
    private var effectiveInterval: Interval {
        store.isSubscribed ? interval.wrappedValue : .oneHour
    }

    /// Slot config used for cheapest-window computation. Free users get a
    /// single 1h slot with their stored deadline (the only setting they can
    /// touch); subscribers get all four user-edited slots, returned in the
    /// user-defined order. The stored values for slots 2-4 remain intact
    /// when they subscribe later.
    private var effectiveSlots: [CheapestSlot] {
        let storage = [
            CheapestSlot(id: 0, hours: clampedHours(slot1Hours), deadline: slot1Deadline),
            CheapestSlot(id: 1, hours: clampedHours(slot2Hours), deadline: slot2Deadline),
            CheapestSlot(id: 2, hours: clampedHours(slot3Hours), deadline: slot3Deadline),
            CheapestSlot(id: 3, hours: clampedHours(slot4Hours), deadline: slot4Deadline),
        ]
        if !store.isSubscribed {
            return [CheapestSlot(id: 0, hours: 1, deadline: slot1Deadline)]
        }
        // Apply the user-defined order, then append any slot ids missing
        // from the stored order (defensive — handles corrupt or
        // incomplete strings) so the result always has all 4 slots.
        let order = Self.parseSlotOrder(slotOrderRaw)
        var result: [CheapestSlot] = order.compactMap { id in storage.first { $0.id == id } }
        for slot in storage where !result.contains(where: { $0.id == slot.id }) {
            result.append(slot)
        }
        return result
    }

    /// Parse a comma-separated slot-order string ("2,0,1,3") into a unique
    /// list of slot ids. Invalid / out-of-range / duplicate entries are
    /// dropped.
    static func parseSlotOrder(_ raw: String) -> [Int] {
        var seen = Set<Int>()
        return raw.split(separator: ",").compactMap { piece -> Int? in
            guard let n = Int(piece), (0...3).contains(n), !seen.contains(n) else {
                return nil
            }
            seen.insert(n)
            return n
        }
    }

    /// Defensive clamp in case stored values got into an invalid range
    /// (e.g. user downgraded after editing on a newer build). `0` is a
    /// valid value — means the slot is turned off and produces no card.
    private func clampedHours(_ h: Int) -> Int { min(max(h, 0), 6) }

    private var lowestWindows: [LowestWindow] {
        // Order follows the user-defined arrangement in Settings — the
        // view-model already iterates `effectiveSlots` in that order, so
        // no extra sort here.
        vm.lowestWindows(interval: effectiveInterval, marginal: effectiveMargin,
                         slots: effectiveSlots)
    }

    private var highlightRange: ClosedRange<Int>? {
        guard let idx = selectedLowest,
              let win = lowestWindows.first(where: { $0.slotIndex == idx })
        else { return nil }
        return win.startIndex...win.endIndex
    }

    /// The bar whose data is shown on the left side. Pinned to `selectedDate`
    /// if set and still in range; otherwise falls through to the current
    /// (first visible) bar.
    private var current: PriceEntry? {
        if let d = selectedDate,
           let pinned = vm.prices.first(where: { $0.date == d }) {
            return pinned
        }
        return vm.prices.first
    }

    private var currentTotal: Double {
        guard let c = current else { return 0 }
        return c.componentSum + effectiveMargin
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
                .safeAreaPadding(.bottom)   // keep readable content above the home indicator

            // Floating gear in the bottom-left corner on every platform.
            gearButton
                .padding(.leading, 16)       // 16 outer + 8 inner = ~24pt
                .padding(.bottom, 24)        // higher off the bottom edge
        }
        .ignoresSafeArea(.container, edges: .bottom)   // gear can sit flush in the corner
        .sheet(isPresented: $showSettings) {
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
                slotOrderRaw: $slotOrderRaw,
                notifyLeadMinutes: $notifyLeadMinutes,
                onRequestPaywall: { showPaywall = true }
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .task { await refreshAll() }
        .task {
            // First-launch disclaimer. Once acknowledged the flag is
            // persisted, so this branch never fires again.
            if !disclaimerShown { showDisclaimer = true }
        }
        .alert(
            locale.t("Disclaimer"),
            isPresented: $showDisclaimer
        ) {
            Button(locale.t("OK"), role: .cancel) {
                disclaimerShown = true
            }
        } message: {
            Text(locale.t("All prices shown in the app include VAT and are in cents per kilowatt-hour."))
        }
        .onChange(of: planRaw) { _, _ in
            selectedDate = nil
            Task { await refreshAll() }
        }
        .onChange(of: intervalRaw) { _, _ in
            selectedDate = nil
            Task { await refreshAll() }
        }
        .onChange(of: store.isSubscribed) { _, _ in
            // Subscription flipped → effective interval/margin may change.
            selectedDate = nil
            Task { await refreshAll() }
        }
        .onChange(of: lowestRaw) { _, _ in
            // User picked a different cheapest-window tier → push the new
            // selection into the widget snapshot. No network needed.
            updateWidgetSnapshot()
        }
        .onChange(of: marginal) { _, _ in
            // Margin edit changes every total → keep widget in sync.
            updateWidgetSnapshot()
        }
        .onChange(of: notifyLeadMinutes) { _, _ in
            // User changed the notification lead time → reschedule (or
            // wipe if they picked Off). No network needed.
            Task { await rescheduleNotifications() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                selectedDate = nil    // refocus → snap back to current bar
                Task {
                    // Re-scan entitlements so a subscription bought on
                    // another device (or a fresh-launch desync) is reflected
                    // immediately when the user comes back to the app.
                    await store.refresh()
                    await refreshAll()
                }
            }
        }
        .onAppear {
            // Minute ticker drives the in-app chart slide. On every slot
            // boundary (15-min or 1-h, depending on the user's interval),
            // it triggers the full refresh pipeline — replaces the prior
            // unconditional 15-min auto-refresh.
            vm.startMinuteTicker {
                Task { await refreshAll() }
            }
            #if os(iOS)
            // Hand the background-refresh task a handler that runs the
            // same refresh pipeline. Schedule the first background wake.
            BackgroundRefresh.handler = { await refreshAll() }
            BackgroundRefresh.scheduleNext()
            #endif
        }
        .onDisappear {
            vm.stopMinuteTicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        // Deep link from the widget. Tapping a free-tier widget opens the
        // app with `borsihind://paywall`; we present the paywall sheet.
        .onOpenURL { url in
            if url.scheme == "borsihind", url.host == "paywall" {
                showPaywall = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        // Aspect-ratio at the very top of `content` so the layout choice
        // sees the actual outer size rather than a child slot.
        GeometryReader { geo in
            VStack(spacing: 0) {
                Group {
                    if vm.isLoading && vm.prices.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.errorMessage != nil, vm.prices.isEmpty {
                        Text(locale.t("Failed to load prices"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isPhone {
                        // iPhone → top: price + breakdown, bottom: swipeable
                        // pager (cheapest hours / chart) with page dots.
                        phoneLayout(in: geo.size)
                    } else if geo.size.width < geo.size.height {
                        compactLayout(in: geo.size)
                    } else {
                        wideLayout(in: geo.size)
                    }
                }
            }
        }
    }

    /// Settings (gear) button — used floating on iPad/Mac and inline at the
    /// bottom of the iPhone scroll content.
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

    // MARK: - iPhone (split: price/breakdown on top, swipeable pager on bottom)

    /// iPhone layout: top half = price + breakdown, bottom half = a horizontal
    /// pager swipeable between the cheapest-hours cards (page 1) and the chart
    /// (page 2). Page dots show at the bottom of the pager.
    private func phoneLayout(in size: CGSize) -> some View {
        let pad = Self.pad

        // 50/50 vertical split. Both halves use `maxHeight: .infinity` and
        // share the available space evenly. Bottom-edge padding is dropped
        // so the TabView's page-indicator dots sit near the screen bottom
        // and visually align with the floating gear button (in body's
        // ZStack at `.padding(.bottom, 24)`).
        return VStack(spacing: 0) {
            // Top half — price + breakdown, vertically centered in its slot.
            VStack(alignment: .leading, spacing: pad / 2) {
                priceHeader
                breakdown
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, pad)
            .padding(.top, pad)

            // Bottom half — header + swipeable pager. Header lives OUTSIDE
            // the TabView because `.page` style vertically centers each
            // page's content and would push an inline title off-screen.
            VStack(spacing: 8) {
                Text(phonePage == 0 ? locale.t("Cheapest hours") : "")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                TabView(selection: $phonePage) {
                    cardsColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // `.padding(.top, 8)` keeps the selected card's
                        // rounded green background from being clipped at
                        // the TabView page's top edge.
                        // `.padding(.bottom, 32)` reserves room above the
                        // page-indicator dots so the last card doesn't
                        // overlap them.
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

    // MARK: - iPad portrait (compact 50/50)

    private func compactLayout(in size: CGSize) -> some View {
        let pad = Self.pad
        let chartGap = pad * 2          // 2× spacing between top section and chart
        let disclaimerEstimate: CGFloat = 40
        let half = max(0, (size.height - disclaimerEstimate - chartGap - 2 * pad) / 2)

        return VStack(spacing: chartGap) {
            // Top half: left = price + breakdown, right = cheapest cards
            // (with their section title). Both columns are top-aligned so
            // their headers line up regardless of the second column's height.
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

            // Bottom half: full-width chart.
            chart
                .frame(maxWidth: .infinity, maxHeight: half)
        }
        .padding(.horizontal, pad)
        .padding(.top, pad / 2)
        .padding(.bottom, pad)
    }

    // MARK: - iPad / Mac (wide)

    private func wideLayout(in size: CGSize) -> some View {
        let pad = Self.pad
        let chartGap = pad * 2          // 2× spacing between left column and chart
        // Proportional left-column width: 1/5 of the window, clamped.
        // Grows smoothly as the window resizes.
        let leftWidth = max(Self.leftColumnMinWidth, min(300, size.width / 5))
        return HStack(alignment: .top, spacing: chartGap) {
            leftColumn
                .frame(width: leftWidth)

            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(pad)
    }

    /// Left column for the wide layout. Two equal-height sections (current
    /// price+breakdown, and cheapest hours), each with its content vertically
    /// centered within its half. Minimum gap between sections matches the
    /// chart-vs-other-section gap (pad × 2).
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

    /// Title above the big price number. `Current price` when the displayed
    /// bar is the live first slot; `Selected price` when the user has tapped
    /// a future bar in the chart.
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
                Text(currentTotal.formatted(.number.precision(.fractionLength(2)).locale(locale)))
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
            // Margin is the only row that can carry more than 2 decimals —
            // matches whatever precision the user typed in Settings.
            BreakdownRow(locale.t("Seller margin"),        effectiveMargin,
                         fractionDigits: marginalDigits, showDivider: false)
        }
    }

    /// Decimals used for the seller-margin breakdown row only. Minimum 2;
    /// up to 4 to mirror what the user typed. Other rows are always 2.
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
                    // Slot 0 is free; slots 1...3 require Börsihind+. While
                    // the subscription state is still resolving on launch,
                    // treat every card as unlocked (`isReady = false` hides
                    // the inner data anyway) so we don't flash "Börsihind+"
                    // tags before the real status is known.
                    isLocked: store.hasResolvedSubscriptionState
                        && window.slotIndex > 0
                        && !store.isSubscribed,
                    isReady: store.hasResolvedSubscriptionState,
                    nowAverage: vm.nowAverage(
                        forHours: window.hours,
                        interval: effectiveInterval,
                        marginal: effectiveMargin
                    ),
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

    // MARK: - Helpers

    private func timeRangeLabel(for entry: PriceEntry) -> String {
        let endDate = entry.date.addingTimeInterval(TimeInterval(effectiveInterval.minutes * 60))
        let fmt = Date.VerbatimFormatStyle.hourMinute24
        return "\(entry.date.formatted(fmt)) – \(endDate.formatted(fmt))"
    }

    /// Single canonical "refresh everything" entry point. Called from app
    /// launch, scene-foreground, slot-boundary ticks, BGAppRefreshTask
    /// wakes, manual reloads, and settings changes that invalidate the
    /// cache. Always runs the same three steps so the in-app chart, the
    /// widget snapshot, and scheduled notifications stay in sync from
    /// one source of truth.
    private func refreshAll() async {
        await vm.load(
            plan: Plan(rawValue: planRaw) ?? .v1,
            interval: effectiveInterval
        )
        updateWidgetSnapshot()
        await rescheduleNotifications()
    }

    /// Hand the latest cheapest-window slots to the notification
    /// scheduler. Only premium users get notifications; free users (or
    /// any user with the picker set to Off) get any pending entries
    /// wiped so nothing fires unexpectedly after a subscription lapse.
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

    /// Push the latest visible state to the App Group so the widget process
    /// can render up-to-date data without re-fetching from the network.
    /// Cheap — runs synchronously on the main actor against a UserDefaults.
    private func updateWidgetSnapshot() {
        SharedStorage.isSubscribed = store.isSubscribed
        guard let bar = vm.prices.first else { return }

        // Free users are pinned to slot 0's 1h (longer windows are gated);
        // premium users get the hours of their selected slot, defaulting to
        // the first non-off slot when nothing is selected or the chosen
        // slot is currently turned off.
        let slots = effectiveSlots
        let activeHours = { (id: Int) -> Int? in
            slots.first(where: { $0.id == id })?.hours
        }
        let pickedHours = selectedLowest.flatMap(activeHours) ?? 0
        let hours = pickedHours > 0
            ? pickedHours
            : (slots.first(where: { $0.hours > 0 })?.hours ?? 1)

        // The widget always renders 1-hour granularity regardless of the
        // user's selected interval. Compute the cheapest N consecutive
        // hours directly on the hour-aggregated data so the highlight
        // aligns exactly to the visible bar boundaries.
        let (hourlyStart, hourlyTotals) = widgetHourlyTotals()
        let (cheapestIdx, cheapestAvg) = cheapestHourWindow(in: hourlyTotals, span: hours)
        let cheapestStart = cheapestIdx.flatMap { idx in
            hourlyStart?.addingTimeInterval(TimeInterval(idx * 3600))
        }

        SharedStorage.writeSnapshot(.init(
            currentTotal: bar.componentSum + effectiveMargin,
            currentStart: bar.date,
            currentEnd: bar.date.addingTimeInterval(TimeInterval(effectiveInterval.minutes * 60)),
            cheapestHours: hours,
            cheapestStart: cheapestStart,
            cheapestAverage: cheapestAvg,
            hourlyTotals: hourlyTotals,
            hourlyStart: hourlyStart,
            cheapestHighlightStart: cheapestIdx,
            writtenAt: Date()
        ))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Sliding-window minimum over hourly aggregates. Returns the start
    /// index and the window's average c/kWh, or `(nil, nil)` when there
    /// isn't a full N-hour run available.
    private func cheapestHourWindow(in totals: [Double], span: Int) -> (idx: Int?, avg: Double?) {
        guard span > 0, totals.count >= span else { return (nil, nil) }
        var lowestSum = Double.infinity
        var lowestIdx = 0
        for i in 0...(totals.count - span) {
            let sum = totals[i..<(i + span)].reduce(0, +)
            if sum < lowestSum {
                lowestSum = sum
                lowestIdx = i
            }
        }
        return (lowestIdx, lowestSum / Double(span))
    }

    /// Hour-aggregated total prices (margin + VAT included) for the widget.
    /// If the active interval is 1h, this passes through; on 15-min the
    /// four slots per hour are averaged. No cap — Nord Pool publishes
    /// tomorrow at ~14:00, so the chart can carry up to ~48 hours.
    private func widgetHourlyTotals() -> (start: Date?, totals: [Double]) {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: vm.prices) { entry in
            cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: entry.date))
                ?? entry.date
        }
        let sortedKeys = grouped.keys.sorted()
        let totals = sortedKeys.map { key -> Double in
            let entries = grouped[key, default: []]
            let sum = entries.reduce(0.0) { $0 + $1.componentSum + effectiveMargin }
            return sum / Double(max(entries.count, 1))
        }
        return (sortedKeys.first, totals)
    }
}

#Preview {
    ContentView()
}
