import Foundation
import Testing
@testable import TravelLog

@Suite("Photo import completed-cohort progress")
struct PhotoImportCohortProgressTests {
    private let date = Date(timeIntervalSince1970: 1_600_000_000)

    @Test("a large tied cohort advances exactly once across changing batch sizes")
    func largeCohort() throws {
        var progress = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
        var walked = 0
        var counted = 0
        let sizes = [200, 100, 50, 200, 100, 50, 200]
        for size in sizes {
            let end = walked + size
            let checkpoint = try progress.advance(
                dates: Array(repeating: date, count: size),
                nextDate: end == 900 ? nil : date, isAtEnd: end == 900
            )
            walked = end
            counted += checkpoint.processedIncrement
            #expect(counted == (walked == 900 ? 900 : 0))
            #expect(checkpoint.creationDate == (walked == 900 ? date : nil))
        }
        #expect(walked == 900)
    }

    @Test("completed leading cohorts commit while a trailing cohort remains replayable")
    func mixedCohortsAndRestart() throws {
        let later = date.addingTimeInterval(1)
        var progress = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
        let first = try progress.advance(
            dates: [date, date, later], nextDate: later, isAtEnd: false
        )
        #expect(first.processedIncrement == 2)
        #expect(first.creationDate == date)

        var resumed = PhotoImportCohortProgress(
            creationDate: first.creationDate, localIdentifier: first.legacyLocalIdentifier
        )
        let final = try resumed.advance(dates: [later, later], nextDate: nil, isAtEnd: true)
        #expect(final.processedIncrement == 2)
        #expect(first.processedIncrement + final.processedIncrement == 4)
        #expect(final.creationDate == later)
    }

    @Test("legacy boundary replay preserves its historical count across repeated interruption")
    func legacyRecovery() throws {
        let later = date.addingTimeInterval(1)
        var progress = PhotoImportCohortProgress(creationDate: date, localIdentifier: "legacy-id")
        let partial = try progress.advance(
            dates: [date, date], nextDate: date, isAtEnd: false
        )
        #expect(partial.processedIncrement == 0)
        #expect(partial.legacyLocalIdentifier == "legacy-id")
        var resumed = PhotoImportCohortProgress(
            creationDate: partial.creationDate, localIdentifier: partial.legacyLocalIdentifier
        )
        let completed = try resumed.advance(
            dates: [date, date, date, later], nextDate: nil, isAtEnd: true
        )
        #expect(completed.processedIncrement == 1)
        #expect(completed.creationDate == later)
        #expect(completed.legacyLocalIdentifier == nil)
    }

    @Test("nil, decreasing and changed lookahead dates fail before a new checkpoint can commit")
    func changedDates() throws {
        let later = date.addingTimeInterval(1)
        let samples: [[Date?]] = [[date, nil], [later, date]]
        for dates in samples {
            var progress = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
            #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
                try progress.advance(dates: dates, nextDate: nil, isAtEnd: true)
            }
        }
        var progress = PhotoImportCohortProgress(creationDate: nil, localIdentifier: nil)
        _ = try progress.advance(dates: [date], nextDate: later, isAtEnd: false)
        #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
            try progress.advance(dates: [date], nextDate: nil, isAtEnd: true)
        }
    }

    @Test("recovery bounds repeated invalid input and resets only at a durable boundary")
    func boundedRecovery() throws {
        var recovery = PhotoImportEnumerationRecovery(creationDate: nil, localIdentifier: nil)
        for _ in 0..<2 {
            var replay = try recovery.restart(creationDate: nil, localIdentifier: nil)
            #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
                try replay.advance(dates: [date, nil], nextDate: nil, isAtEnd: true)
            }
        }
        #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
            try recovery.restart(creationDate: nil, localIdentifier: nil)
        }
        // A committed complete cohort permits another bounded recovery.
        _ = try recovery.restart(creationDate: date, localIdentifier: nil)
        _ = try recovery.restart(creationDate: date, localIdentifier: nil)
        #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
            try recovery.restart(creationDate: date, localIdentifier: nil)
        }
    }

    @Test("completing a legacy boundary renews recovery without changing its date")
    func legacyRecoveryBudget() throws {
        var recovery = PhotoImportEnumerationRecovery(creationDate: date, localIdentifier: "legacy")
        _ = try recovery.restart(creationDate: date, localIdentifier: "legacy")
        _ = try recovery.restart(creationDate: date, localIdentifier: "legacy")
        #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
            try recovery.restart(creationDate: date, localIdentifier: "legacy")
        }
        _ = try recovery.restart(creationDate: date, localIdentifier: nil)
        _ = try recovery.restart(creationDate: date, localIdentifier: nil)
        #expect(throws: PhotoImportCohortProgress.InvalidEnumeration.self) {
            try recovery.restart(creationDate: date, localIdentifier: nil)
        }
    }
}
