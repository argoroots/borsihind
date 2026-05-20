import WidgetKit
import SwiftUI

/// Widget bundle entry point. Add new widgets here as they get built.
@main
struct BorsihindWidgetBundle: WidgetBundle {
    var body: some Widget {
        CurrentPriceWidget()
    }
}
