import SwiftUI

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
    @AppStorage("lowest") private var lowestRaw: String = ""
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

    private var lowestWindows: [LowestWindow] {
        vm.lowestWindows(interval: effectiveInterval, marginal: effectiveMargin)
    }

    private var highlightRange: ClosedRange<Int>? {
        guard let h = selectedLowest,
              let win = lowestWindows.first(where: { $0.hours == h })
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
                onRequestPaywall: { showPaywall = true }
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .task { await reload() }
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
            Task { await reload() }
        }
        .onChange(of: intervalRaw) { _, _ in
            selectedDate = nil
            Task { await reload() }
        }
        .onChange(of: store.isSubscribed) { _, _ in
            // Subscription flipped → effective interval/margin may change.
            selectedDate = nil
            Task { await reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                selectedDate = nil    // refocus → snap back to current bar
                Task {
                    // Re-scan entitlements so a subscription bought on
                    // another device (or a fresh-launch desync) is reflected
                    // immediately when the user comes back to the app.
                    await store.refresh()
                    await reload()
                }
            }
        }
        .onAppear {
            vm.startAutoRefresh(
                plan: { Plan(rawValue: planRaw) ?? .v1 },
                // Free users always fetch the 1-hour dataset; 15-min is gated.
                interval: { effectiveInterval }
            )
            vm.startMinuteTicker()
        }
        .onDisappear {
            vm.stopAutoRefresh()
            vm.stopMinuteTicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
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
        // Single `pad` gap on phone — double-pad eats too much vertical real
        // estate the pager needs for 4 cards + page dots.
        let chartGap = pad
        // Bottom padding inside each pager page so the page indicator sits
        // below the content instead of overlapping it.
        let dotStrip: CGFloat = 48

        return VStack(spacing: chartGap) {
            // Top: price + breakdown at natural height so it doesn't bleed
            // into the pager below.
            VStack(alignment: .leading, spacing: pad / 2) {
                priceHeader
                breakdown
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)

            // Bottom: header + swipeable pager. Header lives OUTSIDE the
            // TabView because `.page` style centers each page vertically and
            // would push an inline title off-screen.
            VStack(spacing: 8) {
                Text(phonePage == 0 ? locale.t("Cheapest hours") : "")
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                TabView(selection: $phonePage) {
                    cardsColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.bottom, dotStrip)
                        .tag(0)

                    chart
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 12)
                        .padding(.bottom, dotStrip)
                        .tag(1)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(pad)
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
        if let dot = s.firstIndex(of: ".") {
            let after = s.distance(from: s.index(after: dot), to: s.endIndex)
            return min(4, max(2, after))
        }
        return 2
    }

    private var cardsColumn: some View {
        VStack(spacing: 8) {
            ForEach(lowestWindows) { window in
                LowestWindowCard(
                    window: window,
                    isSelected: selectedLowest == window.hours,
                    // 1h is free; 2h/3h/4h require Börsihind+. While the
                    // subscription state is still resolving on launch, treat
                    // every card as unlocked (`isReady = false` hides the
                    // inner data anyway), so we don't flash "Börsihind+"
                    // tags before the real status is known.
                    isLocked: store.hasResolvedSubscriptionState
                        && window.hours > 1
                        && !store.isSubscribed,
                    isReady: store.hasResolvedSubscriptionState,
                    nowAverage: vm.nowAverage(
                        forHours: window.hours,
                        interval: effectiveInterval,
                        marginal: effectiveMargin
                    ),
                    onTap: {
                        if window.hours > 1 && !store.isSubscribed {
                            showPaywall = true
                        } else {
                            let key = String(window.hours)
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
        return "\(entry.date.formatted(Self.hourMinuteFormat)) – \(endDate.formatted(Self.hourMinuteFormat))"
    }

    /// Verbatim 24-hour HH:mm so 13:00 never renders as "01:00" regardless
    /// of locale or region settings. Same pattern as LowestWindowCard.
    private static let hourMinuteFormat = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )

    private func reload() async {
        await vm.load(
            plan: Plan(rawValue: planRaw) ?? .v1,
            interval: effectiveInterval
        )
    }
}

#Preview {
    ContentView()
}
