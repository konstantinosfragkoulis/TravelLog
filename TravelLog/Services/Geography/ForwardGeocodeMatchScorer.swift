//
//  ForwardGeocodeMatchScorer.swift
//  TravelLog
//

import Foundation

/// Pure semantic validation for `MKLocalSearch` results.
///
/// MapKit intentionally performs fuzzy discovery, which is useful in a map
/// picker but unsafe as automatic evidence that a calendar event is travel.
/// This scorer therefore requires two things before a result is trusted:
///
/// 1. every distinctive query token (and numeric identifier) is represented
///    in the result's name/address/geography; and
/// 2. the match has independent support outside a bare name echo — a matching
///    address/geographic field, or a categorized POI whose name matches.
///
/// The type contains no MapKit values so its decisions are deterministic,
/// Sendable, and replayable from privacy-safe derived fixtures.
nonisolated enum ForwardGeocodeMatchScorer {

    static let acceptanceThreshold = 60

    struct Candidate: Sendable, Equatable {
        let rank: Int
        let name: String?
        let address: String?
        let mapLocality: String?
        let mapRegion: String?
        let pointOfInterestCategory: String?
        let reverseLocality: String?
        let reverseSubLocality: String?
        let reverseAdministrativeArea: String?
        let reverseMetro: String?
        let reverseIsland: String?
        let reverseCountry: String?

        init(
            rank: Int,
            name: String? = nil,
            address: String? = nil,
            mapLocality: String? = nil,
            mapRegion: String? = nil,
            pointOfInterestCategory: String? = nil,
            reverseLocality: String? = nil,
            reverseSubLocality: String? = nil,
            reverseAdministrativeArea: String? = nil,
            reverseMetro: String? = nil,
            reverseIsland: String? = nil,
            reverseCountry: String? = nil
        ) {
            self.rank = rank
            self.name = name
            self.address = address
            self.mapLocality = mapLocality
            self.mapRegion = mapRegion
            self.pointOfInterestCategory = pointOfInterestCategory
            self.reverseLocality = reverseLocality
            self.reverseSubLocality = reverseSubLocality
            self.reverseAdministrativeArea = reverseAdministrativeArea
            self.reverseMetro = reverseMetro
            self.reverseIsland = reverseIsland
            self.reverseCountry = reverseCountry
        }
    }

    enum Disposition: String, Sendable, Equatable {
        case accepted
        case rejectedGenericQuery
        case rejectedNoCandidates
        case rejectedLowConfidence
    }

    enum Feature: String, Sendable, Equatable, Comparable {
        case allDistinctiveTokensCovered
        case exactAddressPhrase
        case exactNamePhrase
        case fullAddressCoverage
        case fullGeographicCoverage
        case fullNameCoverage
        case genericQuery
        case knownPointOfInterest
        case missingDistinctiveTokens
        case partialGeographicCoverage
        case partialNameCoverage
        case semanticCategoryAgreement

        static func < (lhs: Feature, rhs: Feature) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Privacy-safe decision diagnostics. It deliberately retains only
    /// ranks, counts, score, and feature names — never the query or result
    /// text that may have originated in a private calendar event.
    struct Assessment: Sendable, Equatable {
        let disposition: Disposition
        let score: Int
        let candidateRank: Int?
        let queryCandidateIndex: Int?
        let distinctiveTokenCount: Int
        let features: [Feature]

        var isAccepted: Bool { disposition == .accepted }
    }

    private struct PreparedQuery {
        let originalIndex: Int
        let matchTokens: [String]
        let distinctiveTokens: Set<String>
        let identifiers: Set<String>
        let semanticTokens: Set<String>

        var requiredTokens: Set<String> {
            distinctiveTokens.union(identifiers)
        }
    }

    private struct PairAssessment {
        let assessment: Assessment
        let accepted: Bool
    }

    /// Calendar boilerplate that does not identify a geographic destination.
    /// A phrase containing only these words and room/reference identifiers is
    /// rejected before network search. A real venue survives when it includes
    /// identity words (`Conference Room, Hotel Grande Bretagne`).
    private static let genericCalendarTokens: Set<String> = [
        "board", "building", "call", "client", "conference", "customer",
        "dial", "facetime", "flight", "google", "headquarters", "home",
        "hq", "main", "meet", "meeting", "office", "offsite", "online",
        "remote", "room", "site", "tbd", "teams", "video", "virtual",
        "webex", "zoom",
    ]

    private static let connectorTokens: Set<String> = [
        "a", "an", "and", "at", "by", "for", "from", "in", "near",
        "of", "on", "the", "to", "with",
    ]

    /// Place/address type words can corroborate a category but cannot identify
    /// a result on their own (`Hotel`, `Airport`, and `Street` are not places).
    private static let semanticTokens: Set<String> = [
        "airport", "apartment", "avenue", "bar", "beach", "brewery", "bus",
        "cafe", "castle", "drive", "ferry", "harbor", "harbour", "hostel",
        "hotel", "inn", "landmark", "lane", "marina", "motel", "museum",
        "park", "plaza", "port", "pub", "resort", "restaurant", "road",
        "square", "station", "street", "taverna", "terminal", "theater",
        "theatre", "tower", "train", "villa", "way",
    ]

    private static let canonicalAliases: [String: String] = [
        "apartments": "apartment",
        "airports": "airport",
        "avenues": "avenue",
        "bars": "bar",
        "beaches": "beach",
        "cafes": "cafe",
        "drives": "drive",
        "harbors": "harbor",
        "harbours": "harbour",
        "hotels": "hotel",
        "lanes": "lane",
        "museums": "museum",
        "parks": "park",
        "plazas": "plaza",
        "ports": "port",
        "restaurants": "restaurant",
        "roads": "road",
        "squares": "square",
        "stations": "station",
        "streets": "street",
        "terminals": "terminal",
        "towers": "tower",
        "villas": "villa",
    ]

    /// Remove generic-only alternatives while retaining their original index
    /// for deterministic diagnostics and result selection.
    static func viableQueryCandidates(from candidates: [String]) -> [String] {
        candidates.enumerated().compactMap { _, candidate in
            prepare(candidate, index: 0) == nil ? nil : candidate
        }
    }

    static func evaluate(
        queryCandidates: [String],
        candidates: [Candidate]
    ) -> Assessment {
        let preparedQueries = queryCandidates.enumerated().compactMap { index, query in
            prepare(query, index: index)
        }
        guard !preparedQueries.isEmpty else {
            return Assessment(
                disposition: .rejectedGenericQuery,
                score: 0,
                candidateRank: nil,
                queryCandidateIndex: nil,
                distinctiveTokenCount: 0,
                features: [.genericQuery]
            )
        }
        guard !candidates.isEmpty else {
            return Assessment(
                disposition: .rejectedNoCandidates,
                score: 0,
                candidateRank: nil,
                queryCandidateIndex: preparedQueries[0].originalIndex,
                distinctiveTokenCount: preparedQueries[0].distinctiveTokens.count,
                features: []
            )
        }

        let pairs = candidates.flatMap { candidate in
            preparedQueries.map { score(query: $0, candidate: candidate) }
        }
        let best = pairs.max { lhs, rhs in
            if lhs.accepted != rhs.accepted { return !lhs.accepted && rhs.accepted }
            if lhs.assessment.score != rhs.assessment.score {
                return lhs.assessment.score < rhs.assessment.score
            }
            let lhsRank = lhs.assessment.candidateRank ?? .max
            let rhsRank = rhs.assessment.candidateRank ?? .max
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return (lhs.assessment.queryCandidateIndex ?? .max)
                > (rhs.assessment.queryCandidateIndex ?? .max)
        }
        guard let best else {
            return Assessment(
                disposition: .rejectedNoCandidates,
                score: 0,
                candidateRank: nil,
                queryCandidateIndex: nil,
                distinctiveTokenCount: 0,
                features: []
            )
        }
        return best.assessment
    }

    private static func score(
        query: PreparedQuery,
        candidate: Candidate
    ) -> PairAssessment {
        let nameTokens = Set(tokens(candidate.name))
        let addressTokens = Set(tokens(candidate.address))
        let geographicTokens = Set(tokens([
            candidate.mapLocality,
            candidate.mapRegion,
            candidate.reverseLocality,
            candidate.reverseSubLocality,
            candidate.reverseAdministrativeArea,
            candidate.reverseMetro,
            candidate.reverseIsland,
            candidate.reverseCountry,
        ].compactMap { $0 }.joined(separator: " ")))
        let allResultTokens = nameTokens.union(addressTokens).union(geographicTokens)
        let required = query.requiredTokens
        let allCovered = required.isSubset(of: allResultTokens)

        let nameFull = required.isSubset(of: nameTokens)
        let addressFull = required.isSubset(of: addressTokens)
        let geographyFull = !query.distinctiveTokens.isEmpty
            && query.distinctiveTokens.isSubset(of: geographicTokens)
        let nameOverlap = query.distinctiveTokens.intersection(nameTokens).count
        let geographicOverlap = query.distinctiveTokens.intersection(geographicTokens).count
        let namePhrase = containsSequence(tokens(candidate.name), query.matchTokens)
        let addressPhrase = containsSequence(tokens(candidate.address), query.matchTokens)
        let category = candidate.pointOfInterestCategory?.lowercased() ?? ""
        let knownPOI = !category.isEmpty && nameFull
        let categoryAgreement = categoryMatches(
            querySemanticTokens: query.semanticTokens,
            category: category
        )
        let semanticTextTokens = nameTokens.union(addressTokens)
        let semanticsSatisfied = query.semanticTokens.allSatisfy { token in
            semanticTextTokens.contains(token)
                || categoryMatches(querySemanticTokens: [token], category: category)
        }

        var features = Set<Feature>()
        var score = 0
        if allCovered {
            features.insert(.allDistinctiveTokensCovered)
            score += 15
        } else {
            features.insert(.missingDistinctiveTokens)
        }
        if namePhrase {
            features.insert(.exactNamePhrase)
            score += 35
        } else if nameFull {
            features.insert(.fullNameCoverage)
            score += 25
        } else if nameOverlap > 0 {
            features.insert(.partialNameCoverage)
            score += 10
        }
        if addressPhrase {
            features.insert(.exactAddressPhrase)
            score += 45
        } else if addressFull {
            features.insert(.fullAddressCoverage)
            score += 25
        }
        if geographyFull {
            features.insert(.fullGeographicCoverage)
            score += 25
        } else if geographicOverlap > 0 {
            features.insert(.partialGeographicCoverage)
            score += 10
        }
        if knownPOI {
            features.insert(.knownPointOfInterest)
            score += 15
        }
        if categoryAgreement {
            features.insert(.semanticCategoryAgreement)
            score += 15
        }
        score = max(0, score - min(max(candidate.rank, 0), 4) * 3)

        let hasIndependentSupport = addressPhrase
            || addressFull
            || geographyFull
            || geographicOverlap > 0
            || knownPOI
            || categoryAgreement
        let hasPrimaryMatch = namePhrase || nameFull || addressPhrase || addressFull
        let accepted = allCovered
            && semanticsSatisfied
            && hasPrimaryMatch
            && hasIndependentSupport
            && score >= acceptanceThreshold

        return PairAssessment(
            assessment: Assessment(
                disposition: accepted ? .accepted : .rejectedLowConfidence,
                score: score,
                candidateRank: candidate.rank,
                queryCandidateIndex: query.originalIndex,
                distinctiveTokenCount: query.distinctiveTokens.count,
                features: features.sorted()
            ),
            accepted: accepted
        )
    }

    private static func prepare(_ raw: String, index: Int) -> PreparedQuery? {
        let allTokens = tokens(raw)
        guard !allTokens.isEmpty else { return nil }
        let distinctive = Set(allTokens.filter { token in
            token.count >= 2
                && !connectorTokens.contains(token)
                && !genericCalendarTokens.contains(token)
                && !semanticTokens.contains(token)
                && !isIdentifier(token)
        })
        // An identifier or a type word can refine a real place name, but it
        // cannot turn boilerplate into a destination by itself.
        guard !distinctive.isEmpty else { return nil }
        let identifiers = Set(allTokens.filter(isIdentifier))
        let semantics = Set(allTokens.filter { semanticTokens.contains($0) })
        let matchTokens = allTokens.filter {
            !connectorTokens.contains($0) && !genericCalendarTokens.contains($0)
        }
        return PreparedQuery(
            originalIndex: index,
            matchTokens: matchTokens,
            distinctiveTokens: distinctive,
            identifiers: identifiers,
            semanticTokens: semantics
        )
    }

    private static func categoryMatches(
        querySemanticTokens: Set<String>,
        category: String
    ) -> Bool {
        guard !querySemanticTokens.isEmpty, !category.isEmpty else { return false }
        let categoryGroups: [(Set<String>, [String])] = [
            (["hotel", "hostel", "inn", "motel", "resort", "villa", "apartment"],
             ["hotel"]),
            (["airport"], ["airport"]),
            (["bus", "ferry", "harbor", "harbour", "marina", "port", "station", "terminal", "train"],
             ["airport", "marina", "publictransport"]),
            (["bar", "brewery", "cafe", "pub", "restaurant", "taverna"],
             ["bakery", "brewery", "cafe", "foodmarket", "nightlife", "restaurant"]),
            (["beach", "castle", "landmark", "museum", "park", "tower"],
             ["beach", "castle", "landmark", "museum", "nationalpark", "park"]),
            (["theater", "theatre"], ["theater"]),
        ]
        return categoryGroups.contains { queryWords, categoryFragments in
            !querySemanticTokens.isDisjoint(with: queryWords)
                && categoryFragments.contains(where: category.contains)
        }
    }

    private static func isIdentifier(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.allSatisfy(\.isNumber) { return true }
        let hasLetter = token.contains(where: \.isLetter)
        let hasNumber = token.contains(where: \.isNumber)
        return hasLetter && hasNumber && token.count <= 8
    }

    private static func containsSequence(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        if needle.count == 1 { return haystack.contains(needle[0]) }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    private static func tokens(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let latin = raw.toLatinAscii.lowercased()
        return latin
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .map { canonicalAliases[$0] ?? $0 }
    }
}
