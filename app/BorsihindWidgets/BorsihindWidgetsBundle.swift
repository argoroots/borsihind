import WidgetKit
import SwiftUI

/// Widget bundle entry point. Registers every widget the extension exposes.
/// Add new widgets here as more get built (e.g. cheapest-window widget,
/// chart widget, Live Activity).
@main
struct BorsihindWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CurrentPriceWidget()
    }
}
