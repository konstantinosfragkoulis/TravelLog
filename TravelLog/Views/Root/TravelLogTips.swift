import SwiftUI
import TipKit

// Eligibility that depends on a particular row stays at its visible anchor.
// TipKit persists learning and limits each tip to one presentation.
nonisolated struct DismissTripTip: Tip {
    @Parameter
    static var hasLearnedCorrection: Bool = false

    var title: Text { Text(String(localized: "tip.dismiss.title", defaultValue: "Not a trip?")) }
    var message: Text? { Text(String(localized: "tip.dismiss.message", defaultValue: "Touch and hold this trip, then choose “This Wasn't a Trip” to mark it as part of everyday life.")) }
    var image: Image? { Image(systemName: "hand.tap") }
    var options: [any TipOption] { MaxDisplayCount(1) }
}

nonisolated struct MergeTripsTip: Tip {
    var title: Text { Text(String(localized: "tip.merge.title", defaultValue: "One journey, two trips?")) }
    var message: Text? { Text(String(localized: "tip.merge.message", defaultValue: "Touch and hold this trip, then choose a neighboring trip to merge them.")) }
    var image: Image? { Image(systemName: "arrow.triangle.merge") }
    var rules: [Rule] {
        #Rule(DismissTripTip.$hasLearnedCorrection) { $0 == true }
    }
    var options: [any TipOption] { MaxDisplayCount(1) }
}

nonisolated struct SplitTripTip: Tip {
    var title: Text { Text(String(localized: "tip.split.title", defaultValue: "Two journeys in one trip?")) }
    var message: Text? { Text(String(localized: "tip.split.message", defaultValue: "Touch and hold a stop, then choose “Split Trip Here” to start a separate trip at that stop.")) }
    var image: Image? { Image(systemName: "scissors") }
    var options: [any TipOption] { MaxDisplayCount(1) }
}
