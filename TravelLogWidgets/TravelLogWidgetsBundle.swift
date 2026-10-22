//
//  TravelLogWidgetsBundle.swift
//  TravelLogWidgets
//
//  Created by Konstantinos Fragkoulis on 6/5/26.
//

import WidgetKit
import SwiftUI

@main
struct TravelLogWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TravelStatsWidget()
        CurrentTripWidget()
        StatsAccessoryWidget()
        UpcomingTripWidget()
    }
}
