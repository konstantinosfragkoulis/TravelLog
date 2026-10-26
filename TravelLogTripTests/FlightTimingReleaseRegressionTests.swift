import Foundation
import Testing
@testable import TravelLog

@MainActor
struct FlightTimingReleaseRegressionTests {
    private typealias Times = FlightTimeOverrides.Times

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "FlightTimingReleaseRegressionTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSince1970: 1_900_000_000 + hours * 3600)
    }

    @Test("saved clock dates remain distinguishable across a multi-year history window")
    func savedTimesRetainTheirYear() throws {
        let formatter = ISO8601DateFormatter()
        let departure2025 = try #require(formatter.date(from: "2025-06-01T08:00:00Z"))
        let departure2026 = try #require(formatter.date(from: "2026-06-01T08:00:00Z"))
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        #expect(FlightDetailSheet.timeText(departure2025, zone: zone, includingYear: true)
                != FlightDetailSheet.timeText(departure2026, zone: zone, includingYear: true))
        #expect(FlightDetailSheet.timeText(departure2025.addingTimeInterval(4 * 3600), zone: zone, includingYear: true)
                != FlightDetailSheet.timeText(departure2026.addingTimeInterval(4 * 3600), zone: zone, includingYear: true))
    }

    @Test("cleared flight times stay cleared when an older backup is restored and exported again")
    func clearSurvivesOlderBackupAndRoundTrip() throws {
        let (defaults, name) = try makeDefaults()
        let (restored, restoredName) = try makeDefaults()
        let (ubiquitous, ubiquitousName) = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: name)
            restored.removePersistentDomain(forName: restoredName)
            ubiquitous.removePersistentDomain(forName: ubiquitousName)
        }
        let id = UUID()
        let saved = Times(departure: at(20), arrival: at(22))
        FlightTimeOverrides.set(saved, for: id, defaults: defaults)
        let olderBackup = BackupPreferences.current(defaults: defaults, ubiquitous: ubiquitous)
        FlightTimeOverrides.clear(id, defaults: defaults)
        BackupPreferences.restore(olderBackup, defaults: defaults, ubiquitous: ubiquitous)
        #expect(FlightTimeOverrides.times(for: id, defaults: defaults) == nil)

        let exported = BackupPreferences.current(defaults: defaults, ubiquitous: ubiquitous)
        #expect(exported.flightTimeOverrides?.contains(id.uuidString) == true)
        BackupPreferences.restore(exported, defaults: restored, ubiquitous: ubiquitous)
        BackupPreferences.restore(olderBackup, defaults: restored, ubiquitous: ubiquitous)
        #expect(FlightTimeOverrides.times(for: id, defaults: restored) == nil)
        FlightTimeOverrides.set(saved, for: id, defaults: restored)
        #expect(FlightTimeOverrides.times(for: id, defaults: restored) == saved)
        #expect(restored.stringArray(forKey: FlightTimeOverrides.defaultsKey)?.count == 1)
    }

    @Test("invalid restored entries do not act as clear tombstones")
    func invalidEntriesDoNotClear() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let times = Times(departure: at(20), arrival: at(22))
        defaults.set([FlightTimeOverrides.entry(id: id, times: times), "\(id.uuidString) junk"],
                     forKey: FlightTimeOverrides.defaultsKey)
        #expect(FlightTimeOverrides.times(for: id, defaults: defaults) == times)
    }

    @Test("connecting-airport search matches invariant IATA codes and Istanbul casing")
    func invariantAirportSearch() {
        let airport = AirportRecord(code: "IST", lat: 41, lon: 28, name: "İstanbul Airport",
                                    city: "İstanbul", iso: "TR", svc: true)
        let index = FlightStops.SearchIndex([airport])
        for query in ["IST", "ist", "Istanbul", "istanbul", "İstanbul"] {
            #expect(FlightStops.search(query, in: index).first?.code == "IST")
        }
    }
}
