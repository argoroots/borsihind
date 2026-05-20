import SwiftUI

/// Watch screen: three swipeable pages — current price, cheapest hours,
/// and the price graph. Settings come from the phone via
/// `WatchSettingsStore`; prices are fetched on the watch via
/// `WatchPricesModel`.
struct WatchRootView: View {
    @State private var settings = WatchSettingsStore()
    @State private var prices = WatchPricesModel()
    @State private var ticker: Task<Void, Never>?
    /// Last-viewed page, restored across launches.
    @AppStorage("watch.page") private var page = 0

    private var state: SyncedState { settings.state }
    private var locale: Locale { state.locale }

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
        .onChange(of: stateKey) { _, _ in Task { await prices.refresh(for: state) } }
        .onAppear(perform: startTicker)
        .onDisappear { ticker?.cancel() }
    }

    private var pages: some View {
        TabView(selection: $page) {
            pageView(title: locale.t("Current price")) { currentPrice }.tag(0)
            pageView(title: locale.t("Cheapest hours")) { windowsList }.tag(1)
            pageView(title: locale.t("Graph")) { graph }.tag(2)
        }
        .tabViewStyle(.page)
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

    /// One titled, scrollable, pull-to-refresh page wrapper.
    private func pageView<Content: View>(title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                content()
            }
            .padding(.horizontal, 4)
        }
        .refreshable { await prices.refresh(for: state) }
    }

    // MARK: - Pages

    private var currentPrice: some View {
        VStack(spacing: 2) {
            if let total = prices.currentTotal(for: state) {
                Text(total.priceString(locale: locale))
                    .font(.system(size: 32, weight: .bold))
                    .monospacedDigit()
                Text(locale.t("c/kWh"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let range = prices.currentRange(for: state) {
                    Text("\(range.start, format: Date.VerbatimFormatStyle.hourMinute24) – \(range.end, format: Date.VerbatimFormatStyle.hourMinute24)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var windowsList: some View {
        let windows = prices.windows(for: state)
        if windows.isEmpty {
            // All slots disabled (subscriber turned every slot off).
            Text("—").foregroundStyle(.secondary).padding(.top, 12)
        } else {
            VStack(spacing: 6) {
                ForEach(windows) { window in
                    HStack {
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
                }
            }
        }
    }

    @ViewBuilder
    private var graph: some View {
        let points = prices.series(for: state)
        if points.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 12)
        } else {
            WatchPriceChart(points: points,
                            highlight: prices.selectedWindowRange(for: state))
                .frame(height: 140)
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
