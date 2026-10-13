import Foundation

/// A checkpoint advances only past complete creation-date cohorts. Partial
/// cohorts replay after interruption; their pings and acceptance count are
/// already durable, but their processed count has not yet been committed.
nonisolated struct PhotoImportCohortCheckpoint: Sendable {
    let processedIncrement: Int
    let creationDate: Date?
    let legacyLocalIdentifier: String?
}

nonisolated struct PhotoImportCohortProgress {
    enum InvalidEnumeration: Error { case changedDates }

    private var completedDate: Date?
    private var legacyIdentifier: String?
    private let legacyDate: Date?
    private var pendingDate: Date?
    private var pendingCount = 0
    private var expectedNextDate: Date?

    init(creationDate: Date?, localIdentifier: String?) {
        completedDate = creationDate
        legacyIdentifier = localIdentifier
        legacyDate = localIdentifier == nil ? nil : creationDate
    }

    /// Dates come from one bounded slice and its one-element lookahead.
    /// Reject inconsistent input without assuming which PhotoKit edits can
    /// surface through an existing fetch result.
    mutating func advance(
        dates: [Date?], nextDate: Date?, isAtEnd: Bool
    ) throws -> PhotoImportCohortCheckpoint {
        guard !dates.isEmpty else { throw InvalidEnumeration.changedDates }
        if let expectedNextDate, dates[0] != expectedNextDate {
            throw InvalidEnumeration.changedDates
        }
        var processed = 0
        for value in dates {
            guard let date = value else { throw InvalidEnumeration.changedDates }
            if let pendingDate {
                guard date >= pendingDate else { throw InvalidEnumeration.changedDates }
                if date > pendingDate { processed += completePendingCohort() }
            } else if let completedDate {
                guard date > completedDate || date == legacyDate else {
                    throw InvalidEnumeration.changedDates
                }
            }
            pendingDate = date
            pendingCount += 1
        }
        if isAtEnd {
            processed += completePendingCohort()
        } else {
            guard let nextDate, let pendingDate, nextDate >= pendingDate else {
                throw InvalidEnumeration.changedDates
            }
            if nextDate > pendingDate { processed += completePendingCohort() }
        }
        expectedNextDate = nextDate
        return PhotoImportCohortCheckpoint(
            processedIncrement: processed,
            creationDate: completedDate,
            legacyLocalIdentifier: legacyIdentifier
        )
    }

    private mutating func completePendingCohort() -> Int {
        guard let date = pendingDate else { return 0 }
        // Old checkpoints counted an unknowable subset of this cohort,
        // sometimes repeatedly. Preserve that baseline during recovery.
        let increment = date == legacyDate ? 0 : pendingCount
        completedDate = date
        legacyIdentifier = nil
        pendingDate = nil
        pendingCount = 0
        return increment
    }
}

/// A refetch replays only the unfinished cohort. Bound retries at the same
/// durable boundary even when replay commits additional accepted pings.
nonisolated struct PhotoImportEnumerationRecovery {
    private var creationDate: Date?
    private var localIdentifier: String?
    private var restartsWithoutProgress = 0
    private static let maximumRestartsWithoutProgress = 2

    init(creationDate: Date?, localIdentifier: String?) {
        self.creationDate = creationDate
        self.localIdentifier = localIdentifier
    }

    mutating func restart(
        creationDate: Date?, localIdentifier: String?
    ) throws -> PhotoImportCohortProgress {
        let advancedDate = creationDate.map { date in
            self.creationDate.map { date > $0 } ?? true
        } ?? false
        let completedLegacyBoundary = creationDate == self.creationDate
            && self.localIdentifier != nil && localIdentifier == nil
        if advancedDate || completedLegacyBoundary {
            restartsWithoutProgress = 0
        }
        guard restartsWithoutProgress < Self.maximumRestartsWithoutProgress else {
            throw PhotoImportCohortProgress.InvalidEnumeration.changedDates
        }
        restartsWithoutProgress += 1
        self.creationDate = creationDate
        self.localIdentifier = localIdentifier
        return PhotoImportCohortProgress(
            creationDate: creationDate, localIdentifier: localIdentifier
        )
    }
}
