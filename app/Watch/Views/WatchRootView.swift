import SwiftUI

/// Watch screen: two swipeable pages — current price with the graph
/// beneath it, and cheapest hours. Settings come from the phone via
/// `WatchSettingsStore`; prices are fetched on the watch via
/// `WatchPricesModel`.
struct WatchRootView: View {
    @State private var settings = WatchSettingsStore()
    @State private var prices = WatchPricesModel()
    @State private var ticker: Task<Void, Never>?
    /// Last-viewed page, restored across launches.
    @AppStorage("watch.page") private var page = 0
    /// Digital Crown position on the price page — selects a graph bar.
    @State private var crownValue: Double = 0

    @Environment(\.scenePhase) private var scenePhase

    private var state: SyncedState { settings.state }
    private var locale: Locale { state.locale }

    /// Upcoming price slots; the crown scrubs an index into this.
    private var seriesPoints: [WatchPricePoint] { prices.series(for: state) }
    /// Crown-selected bar index, clamped to the available slots.
    private var selectedIndex: Int {
        guard !seriesPoints.isEmpty else { return 0 }
        return min(max(Int(crownValue.rounded()), 0), seriesPoints.count - 1)
    }

    var body: some View {
        Group {
            if prices.hasData {
                pages
            } else if prices.hasError {
                errorState
            } else {
                ProgressView()
            }
        }
        // Glance → fetch only if stale; settings change / pull → force.
        .task { await prices.refreshIfStale(for: state) }
        .onChange(of: stateKey) { _, _ in
            crownValue = 0
            Task { await prices.refresh(for: state) }
        }
        // Reactivation → snap selection back to the current slot.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            crownValue = 0
            Task { await prices.refreshIfStale(for: state) }
        }
        .onAppear(perform: startTicker)
        .onDisappear { ticker?.cancel() }
    }

    private var pages: some View {
        TabView(selection: $page) {
            priceGraphPage.tag(0)
            pageView { windowsList }.tag(1)
        }
        .tabViewStyle(.page)
    }

    /// Page 1: price near the top, graph anchored below. Rotate the
    /// Digital Crown to move the selected bar — the header shows that
    /// slot's price and time range, and the bar is highlighted amber
    /// (same as tapping a bar on iPhone/Mac). Not wrapped in `pageView`:
    /// the crown drives bar selection here instead of scrolling.
    private var priceGraphPage: some View {
        VStack(spacing: 8) {
            priceHeader
            Spacer(minLength: 0)
            graph
                // Graph height as a fraction of the watch screen so it
                // scales proportionally across sizes, with extra breathing
                // room above it.
                .containerRelativeFrame(.vertical) { height, _ in height * 0.49 }
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
        .padding(.bottom, Self.pageDotsInset + 16)
        .focusable()
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(max(seriesPoints.count - 1, 0)),
            by: 1,
            sensitivity: .medium,
            isContinuous: false
        )
    }

    /// Shown only when a fetch failed and there's no cached data to fall
    /// back on. Pull down or tap to retry.
    private var errorState: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(locale.t("Failed to load prices"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(locale.t("Retry")) {
                    Task { await prices.refresh(for: state) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .refreshable { await prices.refresh(for: state) }
    }

    /// Bottom space reserved for the TabView page dots so content (e.g.
    /// the graph) never draws underneath them.
    private static let pageDotsInset: CGFloat = 18

    /// Scrollable, pull-to-refresh page wrapper. The content fills the
    /// viewport above the page dots (via `minHeight`) so a page can
    /// distribute rows vertically without overlapping the indicator.
    private func pageView<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geo in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity,
                           minHeight: geo.size.height - Self.pageDotsInset)
                    .padding(.horizontal, 4)
                    .padding(.bottom, Self.pageDotsInset)
            }
            .refreshable { await prices.refresh(for: state) }
        }
    }

    // MARK: - Pages

    /// Price + time range for the crown-selected slot (index 0 = now).
    @ViewBuilder
    private var priceHeader: some View {
        if seriesPoints.indices.contains(selectedIndex) {
            let point = seriesPoints[selectedIndex]
            let end = point.date.addingTimeInterval(TimeInterval(state.effectiveInterval.minutes * 60))
            VStack(spacing: 2) {
                Text(point.total.priceString(locale: locale))
                    .font(.system(size: 32, weight: .bold))
                    .monospacedDigit()
                Text(locale.t("c/kWh"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(point.date, format: Date.VerbatimFormatStyle.hourMinute24) – \(end, format: Date.VerbatimFormatStyle.hourMinute24)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var windowsList: some View {
        let windows = prices.windows(for: state)
        if windows.isEmpty {
            // All slots disabled (subscriber turned every slot off).
            Text("—").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Spacers between rows distribute them evenly down the page.
            VStack(spacing: 0) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    windowRow(window)
                    if index < windows.count - 1 { Spacer(minLength: 4) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One cheapest-window row. The selected window (synced from the
    /// phone) gets a green highlight to show which timespan is active.
    private func windowRow(_ window: LowestWindow) -> some View {
        let isSelected = window.slotIndex == state.selectedSlot
        return HStack {
            Text(window.label)
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.green)
                .frame(width: 28, alignment: .leading)
            Text("\(window.start, format: Date.VerbatimFormatStyle.hourMinute24) – \(window.end, format: Date.VerbatimFormatStyle.hourMinute24)")
                .font(.caption)
            Spacer()
            Text(window.averagePrice.priceString(locale: locale))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.green.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var graph: some View {
        if seriesPoints.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WatchPriceChart(points: seriesPoints,
                            highlight: prices.selectedWindowRange(for: state),
                            selected: selectedIndex)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    /// Re-fetch whenever synced settings that change the data change.
    private var stateKey: String {
        "\(state.planRaw)/\(state.intervalRaw)/\(state.isSubscribed)"
    }

    /// Per-minute tick so the current slot rolls forward without a fetch.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                prices.tick()
            }
        }
    }
}

#Preview {
    WatchRootView()
}
