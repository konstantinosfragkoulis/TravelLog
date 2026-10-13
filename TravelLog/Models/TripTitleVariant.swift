//
//  TripTitleVariant.swift
//  TravelLog
//

import Foundation
import SwiftData

/// One localized rendering of a trip's canonical AI-generated title.
///
/// Rows are keyed logically by `(trip, languageTag, sourceTitle)` by the
/// service layer. No unique constraint is declared because SwiftData-backed
/// CloudKit stores do not support uniqueness constraints; cross-device
/// convergence is handled deterministically by the title-variant services.
/// Every scalar is defaulted and both sides of the relationship are optional,
/// keeping the V15→V16 migration CloudKit-compatible and lightweight.
@Model
final class TripTitleVariant {

    var id: UUID = UUID()
    var languageTag: String = ""
    var title: String = ""
    var sourceTitle: String = ""
    var sourceRevision: UUID?
    var generationVersion: Int = 1
    var updatedAt: Date = Date.now

    @Relationship
    var trip: Trip?

    init(
        id: UUID = UUID(),
        languageTag: String = "",
        title: String = "",
        sourceTitle: String = "",
        sourceRevision: UUID? = nil,
        generationVersion: Int = 1,
        updatedAt: Date = .now,
        trip: Trip? = nil
    ) {
        self.id = id
        self.languageTag = languageTag
        self.title = title
        self.sourceTitle = sourceTitle
        self.sourceRevision = sourceRevision
        self.generationVersion = generationVersion
        self.updatedAt = updatedAt
        self.trip = trip
    }
}
