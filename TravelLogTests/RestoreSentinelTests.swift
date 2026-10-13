//
//  RestoreSentinelTests.swift
//  TravelLogTests
//
//  Pins the backup-restore detection rule: the sentinel file
//  is excluded from backups, UserDefaults is not — so "flag says created,
//  file missing" is the restore signal that re-arms the Spotlight-token and
//  calendar-selection latches.
//

import Testing
@testable import TravelLog

struct RestoreSentinelTests {

    @Test("the evaluation matrix distinguishes incomplete setup from a restore")
    func evaluationMatrix() {
        // A present file with no completion flag is a half-complete setup;
        // production retries exclusion + flagging idempotently.
        #expect(RestoreSentinel.evaluate(fileExists: true, flagSet: true) == .normal)
        #expect(RestoreSentinel.evaluate(fileExists: true, flagSet: false) == .incompleteSetup)
        // No file, no flag → genuine first run.
        #expect(RestoreSentinel.evaluate(fileExists: false, flagSet: false) == .firstRun)
        // No file, flag set → the backup carried the flag but not the
        // excluded file: restored.
        #expect(RestoreSentinel.evaluate(fileExists: false, flagSet: true) == .restored)
    }
}
