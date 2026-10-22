//
//  GeocodeResultTests.swift
//  TravelLogTests
//
//  Tests the pure value-type `GeocodeResolver.Result` and its
//  `bestLocalityName` fallback chain (localityName ?? islandName ?? metroName).
//  These cover the documented edge cases: island fallback for a remote beach
//  on Cephalonia, the post-V10 Istanbul-Airport→Istanbul FUA metro fallback, and
//  the Samos-gap case where all three are nil.
//
//  Not @MainActor: Result is an internal Sendable/Equatable struct constructed
//  via its synthesized memberwise init - no @Model, no actor, no await.
//

import Testing
import Foundation
@testable import TravelLog

struct GeocodeResultTests {

    /// Build a Result, overriding only the three name fields that drive
    /// `bestLocalityName`. Country/admin default populated so the "country is
    /// non-nil" arms can be distinguished from the name arms.
    private func makeResult(
        locality: String?,
        island: String?,
        metro: String?,
        country: String? = "Greece",
        iso: String? = "GR",
        admin: String? = "Attica"
    ) -> GeocodeResolver.Result {
        GeocodeResolver.Result(
            country: country,
            isoCountryCode: iso,
            administrativeArea: admin,
            metroName: metro,
            localityName: locality,
            subLocalityName: nil,
            islandName: island
        )
    }

    @Test("bestLocalityName fallback chain: locality ?? island ?? metro (\"\" stands for nil)", arguments: [
        ("Gérakas", "Cephalonia", "Athens", "Attica", "Gérakas"), // locality wins when all three are set
        ("", "Cephalonia", "Athens", "Attica", "Cephalonia"),          // island fallback (remote beach on Cephalonia)
        ("", "", "Istanbul", "Attica", "Istanbul"),          // metro fallback (Istanbul-Airport→Istanbul)
        ("", "", "", "North Aegean", ""),                    // all nil → nil even with country/admin set (Samos-gap)
    ])
    func bestLocalityNameFallbackChain(locality: String, island: String, metro: String,
                                       admin: String, expected: String) {
        let r = makeResult(locality: locality.isEmpty ? nil : locality,
                           island: island.isEmpty ? nil : island,
                           metro: metro.isEmpty ? nil : metro,
                           admin: admin)
        let want: String? = expected.isEmpty ? nil : expected
        #expect(r.bestLocalityName == want)
    }

    // MARK: - localityForStorage (the shared country-name guard, GUARD-DUP-01)

    @Test("localityForStorage passes a normal candidate through unchanged")
    func localityForStoragePassesNormalCandidate() {
        let r = makeResult(locality: "Gérakas", island: nil, metro: nil)
        #expect(r.localityForStorage == "Gérakas")
    }

    @Test("localityForStorage guards the country-as-locality case (candidate == country → nil)")
    func localityForStorageGuardsCountryName() {
        let r = makeResult(locality: "Greece", island: nil, metro: nil, country: "Greece")
        #expect(r.bestLocalityName == "Greece")
        #expect(r.localityForStorage == nil)
    }

    @Test("localityForStorage guard applies whichever fallback arm produced the candidate")
    func localityForStorageGuardsFallbackArms() {
        // Island arm and metro arm must be guarded identically to the
        // locality arm - the guard reads `bestLocalityName`, not the fields.
        let viaIsland = makeResult(locality: nil, island: "Greece", metro: nil, country: "Greece")
        #expect(viaIsland.localityForStorage == nil)
        let viaMetro = makeResult(locality: nil, island: nil, metro: "Greece", country: "Greece")
        #expect(viaMetro.localityForStorage == nil)
    }

    @Test("localityForStorage is nil when there is no candidate at all (Samos-gap)")
    func localityForStorageNilWhenNoCandidate() {
        let r = makeResult(locality: nil, island: nil, metro: nil)
        #expect(r.localityForStorage == nil)
    }

    @Test("localityForStorage does NOT guard when country is nil (island-only match keeps its name)")
    func localityForStorageKeepsCandidateWhenCountryNil() {
        // A coord can match the island layer alone - country comes back nil
        // even though the candidate is real. The guard requires a non-nil
        // country to fire; "Cephalonia" with country == nil must survive.
        let r = makeResult(locality: nil, island: "Cephalonia", metro: nil, country: nil, iso: nil, admin: nil)
        #expect(r.localityForStorage == "Cephalonia")
    }

    @Test("localityForStorage compare is exact (case-sensitive today, by design)")
    func localityForStorageExactCompare() {
        // Documented current behavior: the guard fires only on an exact
        // string match, same as every inline copy it replaced. If this is
        // ever loosened (case/whitespace-insensitive), this test pins the
        // intentional change.
        let r = makeResult(locality: "greece", island: nil, metro: nil, country: "Greece")
        #expect(r.localityForStorage == "greece")
    }
}

// MARK: - The admin1 "-1" placeholder is not a country code

@MainActor
extension GeocodeResultTests {

    @Test("Natural-Earth's '-1' placeholder never becomes an ISO country code")
    func minusOnePlaceholderIsRejected() {
        // The 12 disputed/undetermined admin1 rows (Northern Cyprus, Akrotiri,
        // Dhekelia, Somaliland, Kashmir, Baikonur, Spratly, …) carry this.
        #expect(GeocodeResolver.sanitizedISOCountryCode("-1") == nil)
        // It also has no localized country name, which is how it produced a
        // country-less, flag-less stay.
        #expect(Locale(identifier: "en_US").localizedString(forRegionCode: "-1") == nil)
    }

    @Test("Real ISO codes pass through, normalised")
    func realISOCodesSurvive() {
        #expect(GeocodeResolver.sanitizedISOCountryCode("GR") == "GR")
        #expect(GeocodeResolver.sanitizedISOCountryCode("cy") == "CY")
        #expect(GeocodeResolver.sanitizedISOCountryCode(" us ") == "US")
        #expect(GeocodeResolver.sanitizedISOCountryCode(nil) == nil)
        #expect(GeocodeResolver.sanitizedISOCountryCode("") == nil)
        #expect(GeocodeResolver.sanitizedISOCountryCode("GRC") == nil)
        #expect(GeocodeResolver.sanitizedISOCountryCode("99") == nil)
    }
}
