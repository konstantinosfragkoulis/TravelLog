//
//  ClassificationPromptSnapshot.swift
//  TravelLog
//

import Foundation

/// Everything a Stage 2 classification prompt renders, captured once from
/// required reads. The apply unit rebuilds it from its own validated reads
/// and compares the two values, so model output is discarded only when an
/// input the model saw changed. Each field is a pure function of stored
/// values: places in UUID order, distances on the mean-radius sphere
/// (`CLLocation.distance(from:)` reuses state from earlier calls, so a pair
/// measured twice can round to different kilometres), and dates in the time
/// zone captured when the batch was prepared.
nonisolated struct ClassificationPromptSnapshot: Sendable, Equatable {

    struct Place: Sendable, Equatable {
        let name: String
        let administrativeArea: String?
        let country: String?
        let radiusKm: Int
    }

    struct Line: Sendable, Equatable {
        /// The numbered stay's index, or nil for a settled context stay.
        let index: Int?
        let locality: String?
        /// Island, else metro.
        let region: String?
        let country: String?
        let durationMinutes: Int
        let category: StayCategory
        let isAirport: Bool
        /// Whole kilometres from home; nil when no home is configured.
        let homeDistanceKm: Int?
        let kmFromPrevious: Int?
        let start: Date
        let end: Date
        let overnight: Bool
    }

    let homes: [Place]
    let temporaryHomes: [Place]
    let routinePlaces: [String]
    /// The batch's timeline span in chronological order.
    let lines: [Line]
    /// The numbered logical stays, by index.
    let ids: [UUID]
    let timeZone: TimeZone

    /// Whole kilometres for a stored home distance; nil when no home is configured.
    static func homeDistanceKm(_ km: Double) -> Int? {
        if km >= Double.greatestFiniteMagnitude / 2 || km.isNaN || km.isInfinite { return nil }
        return Int(km)
    }

    /// The first field that differs from `other`, for diagnostics. Names
    /// fields and positions only, never place names.
    func firstDifference(from other: Self) -> String? {
        if timeZone != other.timeZone { return "timeZone" }
        if ids != other.ids { return "numbered stays" }
        if homes != other.homes { return "homes" }
        if temporaryHomes != other.temporaryHomes { return "temporaryHomes" }
        if routinePlaces != other.routinePlaces { return "routinePlaces" }
        guard lines.count == other.lines.count else { return "lines.count \(lines.count) -> \(other.lines.count)" }
        for (position, (a, b)) in zip(lines, other.lines).enumerated() where a != b {
            let fields: [(String, Bool)] = [
                ("index", a.index == b.index), ("locality", a.locality == b.locality),
                ("region", a.region == b.region), ("country", a.country == b.country),
                ("duration", a.durationMinutes == b.durationMinutes), ("category", a.category == b.category),
                ("airport", a.isAirport == b.isAirport), ("homeDistance", a.homeDistanceKm == b.homeDistanceKm),
                ("kmFromPrevious", a.kmFromPrevious == b.kmFromPrevious), ("start", a.start == b.start),
                ("end", a.end == b.end), ("overnight", a.overnight == b.overnight)]
            return "line \(position) " + fields.filter { !$0.1 }.map(\.0).joined(separator: ",")
        }
        return nil
    }

    /// The prompt text. `calendarHints` maps a numbered stay's id to the
    /// occasion rendered as `CALENDAR: "…"` (instructions rule 6).
    func rendered(calendarHints: [UUID: String] = [:]) -> String {
        // Transliterate prompt place tokens to Latin so native-script names cannot trigger unsupportedLanguageOrLocale;
        // stored and displayed names remain unchanged.
        func latin(_ value: String?) -> String? { value?.toLatinAsciiStrict }
        var output: [String] = []
        for home in homes {
            output.append("Home: \(latin(home.name) ?? "") (\(latin(home.administrativeArea) ?? "?"), \(latin(home.country) ?? "?")), radius \(home.radiusKm)km")
        }
        if homes.isEmpty { output.append("Home: not configured") }
        for home in temporaryHomes {
            output.append("Temporary home: \(latin(home.name) ?? "") (\(latin(home.administrativeArea) ?? "?"), \(latin(home.country) ?? "?")), radius \(home.radiusKm)km")
        }
        if !routinePlaces.isEmpty {
            output.append("Routine places: \(routinePlaces.map { latin($0) ?? "" }.joined(separator: ", "))")
        }
        output.append("")

        /// Locality plus island/metro identity: "Chora (Cephalonia), Greece".
        /// Bare localities carry no island/metro context, which rule 4's
        /// island-hopping judgment needs.
        func placeString(_ line: Line) -> String {
            let locality = latin(line.locality) ?? "Unknown"
            if let region = latin(line.region), region != locality {
                return "\(locality) (\(region)), \(latin(line.country) ?? "?")"
            }
            return "\(locality), \(latin(line.country) ?? "?")"
        }
        func date(_ value: Date) -> String { FMPromptFormat.numericDateAndShortTime(value, timeZone: timeZone) }

        /// Consecutive same-category runs of ≥3 settled stays (weeks at home
        /// between trips) collapse to a single line so the span stays bounded
        /// no matter how much time separates two unclassified stays.
        func appendContextLines(_ run: ArraySlice<Line>) {
            var i = run.startIndex
            while i < run.endIndex {
                var j = i
                while j + 1 < run.endIndex && run[j + 1].category == run[i].category { j += 1 }
                let sub = run[i...j]
                if sub.count >= 3 && run[i].category != .unclassified {
                    output.append("  (context) \(run[i].category.rawValue) ×\(sub.count), until \(date(run[j].end))")
                } else {
                    for line in sub {
                        let label = line.category == .unclassified
                            ? "not yet classified"
                            : line.category.rawValue + (line.isAirport ? " (airport)" : "")
                        output.append("  (context) \(placeString(line)) | \(line.durationMinutes)min | \(label)")
                    }
                }
                i = j + 1
            }
        }

        output.append("Timeline (chronological). Classify the \(ids.count) numbered stay(s) [0]…[\(ids.count - 1)]; '(context)' lines are already settled — do NOT classify them:")
        var runStart = lines.startIndex
        for (position, line) in lines.enumerated() {
            guard let index = line.index else { continue }
            appendContextLines(lines[runStart..<position])
            runStart = position + 1
            let home = line.homeDistanceKm.map { "\($0)km from home" } ?? "no home configured"
            let previous = line.kmFromPrevious.map { " | \($0)km from prev" } ?? ""
            output.append("[\(index)] \(placeString(line)) | \(line.durationMinutes)min | \(home)\(previous) | \(date(line.start))"
                + (line.overnight ? " | overnight" : "") + (line.isAirport ? " | AIRPORT" : ""))
        }
        appendContextLines(lines[runStart...])

        return TripClassifier.classificationPrompt(output.joined(separator: "\n"), ids: ids, hints: calendarHints)
    }
}
