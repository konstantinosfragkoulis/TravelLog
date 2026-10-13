//
//  ApplyResolverResultTests.swift
//  TravelLogTests
//
//  Tests `LocationPing.applyResolverResult(_:)` (GeocodeResolver.swift), the
//  coalesce-vs-overwrite + country-name-guard semantics that map a
//  GeocodeResolver.Result onto a persisted ping. Covers: nil clears isGeocoded
//  but preserves legacy fields; bestLocalityName upgrade; the post-V10
//  country-as-locality guard; the island-only-match coalesce regression fix
//  (don't wipe existing country); and the "country alone counts as geocoded"
//  final assignment.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation, which makes the @Model LocationPing and its members
//  MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct ApplyResolverResultTests {

    /// Insert a fresh ping into an in-memory context and optionally pre-seed
    /// the place-name fields so coalesce-vs-overwrite is observable.
    private func makePing(
        locality: String? = nil,
        subLocality: String? = nil,
        administrativeArea: String? = nil,
        country: String? = nil,
        iso: String? = nil,
        isGeocoded: Bool = false
    ) throws -> LocationPing {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let ping = LocationPing(
            timestamp: .now,
            latitude: 37.0,
            longitude: 23.0,
            horizontalAccuracy: 10,
            h3IndexRes6: "861f8d4ffffffff"
        )
        context.insert(ping)
        ping.locality = locality
        ping.subLocality = subLocality
        ping.administrativeArea = administrativeArea
        ping.country = country
        ping.isoCountryCode = iso
        ping.isGeocoded = isGeocoded
        return ping
    }

    private func result(
        country: String? = nil,
        iso: String? = nil,
        admin: String? = nil,
        metro: String? = nil,
        locality: String? = nil,
        subLocality: String? = nil,
        island: String? = nil,
        demoted: String? = nil
    ) -> GeocodeResolver.Result {
        GeocodeResolver.Result(
            country: country,
            isoCountryCode: iso,
            administrativeArea: admin,
            metroName: metro,
            localityName: locality,
            subLocalityName: subLocality,
            islandName: island,
            demotedIslandName: demoted
        )
    }

    // MARK: - Island size cap (2026-09-04)

    @Test("a locality the old island fallback wrote from a now-demoted landmass is cleared")
    func staleLandmassLocalityIsCleared() throws {
        let ping = try makePing(locality: "Great Britain", country: "United Kingdom", iso: "GB", isGeocoded: true)
        ping.applyResolverResult(result(country: "United Kingdom", iso: "GB", admin: "Wales", demoted: "Great Britain"))
        #expect(ping.locality == nil)
        #expect(ping.country == "United Kingdom")
        #expect(ping.isGeocoded == true)
    }

    @Test("a real town locality survives a demoted-landmass result untouched")
    func townLocalitySurvivesDemotion() throws {
        let ping = try makePing(locality: "Betws-y-Coed", country: "United Kingdom", iso: "GB", isGeocoded: true)
        ping.applyResolverResult(result(country: "United Kingdom", iso: "GB", admin: "Wales", demoted: "Great Britain"))
        #expect(ping.locality == "Betws-y-Coed")
    }

    @Test("a demoted landmass never becomes the locality when a town is present")
    func demotedLandmassIsNotALocality() throws {
        let ping = try makePing(locality: "Great Britain", country: "United Kingdom", iso: "GB", isGeocoded: true)
        ping.applyResolverResult(result(
            country: "United Kingdom", iso: "GB", locality: "Portree", island: "Skye", demoted: "Great Britain"))
        #expect(ping.locality == "Portree")
        let rural = try makePing()
        rural.applyResolverResult(result(country: "United Kingdom", iso: "GB", admin: "Wales", demoted: "Great Britain"))
        #expect(rural.locality == nil)
        #expect(rural.isGeocoded == true)
    }

    @Test("a nil result clears isGeocoded but leaves existing locality and country untouched")
    func nilResultClearsIsGeocodedButKeepsExistingFields() throws {
        let ping = try makePing(locality: "Paris", country: "France", iso: "FR", isGeocoded: true)
        ping.applyResolverResult(nil)
        #expect(ping.isGeocoded == false)
        #expect(ping.locality == "Paris")
        #expect(ping.country == "France")
    }

    @Test("a result whose bestLocalityName is a real city writes it into locality and sets isGeocoded")
    func localityUpgradedFromBestName() throws {
        let ping = try makePing()
        ping.applyResolverResult(result(country: "Greece", iso: "GR", locality: "Gérakas"))
        #expect(ping.locality == "Gérakas")
        #expect(ping.isGeocoded == true)
    }

    @Test("when bestLocalityName equals the country name, locality is cleared (country-name guard)")
    func countryAsLocalityGuardClearsLocality() throws {
        let ping = try makePing(locality: "stale")
        // localityName == country == "Greece" → candidate == country → clear.
        ping.applyResolverResult(result(country: "Greece", iso: "GR", locality: "Greece"))
        #expect(ping.locality == nil)
        // country still non-nil → still counts as geocoded.
        #expect(ping.country == "Greece")
        #expect(ping.isGeocoded == true)
    }

    @Test("an island fallback (no city) is written into locality via the locality ?? island chain")
    func islandFallbackUsedAsLocalityWhenNoCity() throws {
        let ping = try makePing()
        ping.applyResolverResult(result(country: "Greece", iso: "GR", island: "Cephalonia"))
        #expect(ping.locality == "Cephalonia")
        #expect(ping.isGeocoded == true)
    }

    @Test("an island-only match with nil country does not wipe an existing country/iso (coalesce)")
    func coalesceDoesNotWipeExistingCountryWhenResolverCountryNil() throws {
        let ping = try makePing(country: "France", iso: "FR")
        // country/iso nil but islandName set; must NOT downgrade existing France/FR.
        ping.applyResolverResult(result(country: nil, iso: nil, island: "Cephalonia"))
        #expect(ping.country == "France")
        #expect(ping.isoCountryCode == "FR")
        #expect(ping.locality == "Cephalonia")
    }

    @Test("subLocality and administrativeArea coalesce: nil keeps existing, non-nil overwrites")
    func subLocalityAndAdminCoalesce() throws {
        // nil arm: existing values survive.
        let keep = try makePing(subLocality: "Karaköy", administrativeArea: "Attica")
        keep.applyResolverResult(result(country: "Greece", iso: "GR", locality: "Gérakas"))
        #expect(keep.subLocality == "Karaköy")
        #expect(keep.administrativeArea == "Attica")

        // non-nil arm: incoming values overwrite.
        let overwrite = try makePing(subLocality: "old", administrativeArea: "old")
        overwrite.applyResolverResult(
            result(country: "Greece", iso: "GR", admin: "Epirus",
                   locality: "Ioánnina", subLocality: "Seismoplikta")
        )
        #expect(overwrite.subLocality == "Seismoplikta")
        #expect(overwrite.administrativeArea == "Epirus")
    }

    @Test("a country-only result (locality nil) still sets isGeocoded true")
    func isGeocodedTrueWhenOnlyCountryPresent() throws {
        let ping = try makePing()
        ping.applyResolverResult(result(country: "Japan", iso: "JP"))
        #expect(ping.locality == nil)
        #expect(ping.country == "Japan")
        #expect(ping.isGeocoded == true)
    }
}
