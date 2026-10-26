//
//  P10RegressionTests.swift
//  TravelLogTests
//
//  Regression tests for the photo and presentation fixes of package P10.
//  Round fictional coordinates and invented dates throughout.
//

import CoreLocation
import Foundation
import MapKit
import Photos
import SwiftData
import SwiftUI
import Testing
@testable import TravelLog

// MARK: - PHOTO-003: the coarse cull keeps every photo inside 50 km

@Suite("Photo admission's coarse cull never drops a photo inside the radius")
struct PhotoCullSupersetTests {

    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    private func context(_ latitude: Double, _ longitude: Double) -> StayMatchContext {
        StayMatchContext(latitude: latitude, longitude: longitude,
                         startTime: start, endTime: start.addingTimeInterval(3600),
                         radiusMeters: 50_000, timeBuffer: 1800)
    }

    private func admitted(_ point: CLLocation, near contexts: [StayMatchContext]) -> Bool {
        PhotoService.isAdmittedAsset(
            location: point, creationDate: start, mediaSubtypes: [], sourceType: .typeUserLibrary,
            localIdentifier: "photo", hidden: [], matchContexts: contexts)
    }

    /// A point `meters` along `bearing` on a sphere of `radius`.
    private func destination(_ latitude: Double, _ longitude: Double, bearing: Double,
                             meters: Double, radius: Double) -> CLLocationCoordinate2D {
        let rad = Double.pi / 180
        let angle = meters / radius
        let lat1 = latitude * rad, lon1 = longitude * rad, theta = bearing * rad
        let lat2 = asin(sin(lat1) * cos(angle) + cos(lat1) * sin(angle) * cos(theta))
        let lon2 = lon1 + atan2(sin(theta) * sin(angle) * cos(lat1), cos(angle) - sin(lat1) * sin(lat2))
        var lon = lon2 / rad
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: lat2 / rad, longitude: lon)
    }

    @Test("a photo 0.45 degrees north or south of an equatorial stay is admitted")
    func equatorialMeridianPhotosAdmit() {
        let stay = [context(0, 0)]
        for latitude in [0.45, -0.45] {
            let photo = CLLocation(latitude: latitude, longitude: 0)
            #expect(photo.distance(from: stay[0].location) < 50_000)
            #expect(stay[0].boxContains(latitude: latitude, longitude: 0))
            #expect(admitted(photo, near: stay))
        }
    }

    @Test("near either pole a close photo at a distant longitude is admitted")
    func polarPhotosAdmit() {
        for latitude in [89.9, -89.9] {
            let stay = [context(latitude, 0)]
            let photo = CLLocation(latitude: latitude, longitude: 100)
            #expect(photo.distance(from: stay[0].location) < 50_000)
            #expect(admitted(photo, near: stay))
        }
    }

    @Test("ordinary, dateline and outside-radius controls keep their answers")
    func controlsKeepTheirAnswers() {
        let stay = [context(44.3, 12.9)]
        #expect(admitted(CLLocation(latitude: 44.6, longitude: 12.9), near: stay))
        #expect(!admitted(CLLocation(latitude: 44.8, longitude: 12.9), near: stay))
        #expect(!admitted(CLLocation(latitude: 44.3, longitude: 13.6), near: stay))
        let dateline = [context(10, 179.9)]
        #expect(admitted(CLLocation(latitude: 10, longitude: -179.9), near: dateline))
        #expect(!admitted(CLLocation(latitude: 10, longitude: -179.0), near: dateline))
        // A photo without a fix still follows the stay's time window only.
        #expect(PhotoService.isAdmittedAsset(
            location: nil, creationDate: start, mediaSubtypes: [], sourceType: .typeUserLibrary,
            localIdentifier: "photo", hidden: [], matchContexts: stay))
    }

    @Test("every swept point CoreLocation puts inside 50 km lies in the box")
    func sweptMatchesStayInsideTheBox() {
        var checked = 0
        for latitude in Array(stride(from: -89.9, through: 89.9, by: 7.3)) + [-89.99, 0, 89.99] {
            for longitude in [-179.9, 0.4, 179.9] {
                let stay = context(latitude, longitude)
                for bearing in stride(from: 0.0, to: 360, by: 22.5) {
                    for meters in [10_000.0, 49_000, 49_900] {
                        // A smaller sphere bends the same distance through a wider angle.
                        for radius in [6_335_000.0, 6_371_008, 6_399_594] {
                            let point = destination(latitude, longitude, bearing: bearing,
                                                    meters: meters, radius: radius)
                            let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
                            guard location.distance(from: stay.location) < 50_000 else { continue }
                            checked += 1
                            #expect(stay.boxContains(latitude: point.latitude, longitude: point.longitude),
                                    "\(latitude), \(longitude) bearing \(bearing) at \(meters) m")
                        }
                    }
                }
            }
        }
        #expect(checked > 1_000)
    }
}

// MARK: - PHOTO-004: a visible thumbnail reloads an edited photo

@Suite("A mounted thumbnail reloads when its photo is edited")
struct ThumbnailContentRevisionTests {

    private typealias Revision = PhotoThumbnailView.ContentRevision

    @Test("an edit to the visible photo reloads it; nothing else does")
    func editsReloadVisibleCells() {
        let first = Date(timeIntervalSince1970: 1_900_000_000)
        let original = Revision(localIdentifier: "A", modificationDate: first)
        let cropped = Revision(localIdentifier: "A", modificationDate: first.addingTimeInterval(60))
        #expect(PhotoThumbnailView.shouldReload(from: original, to: cropped, isVisible: true))
        // A second, rapid edit reloads again.
        let rotated = Revision(localIdentifier: "A", modificationDate: first.addingTimeInterval(61))
        #expect(PhotoThumbnailView.shouldReload(from: cropped, to: rotated, isVisible: true))
        // A refetch that changed nothing costs no request.
        #expect(!PhotoThumbnailView.shouldReload(from: original, to: original, isVisible: true))
        // Off screen the cell loads on its next appearance instead.
        #expect(!PhotoThumbnailView.shouldReload(from: original, to: cropped, isVisible: false))
        // A first modification date, or another photo in the same cell, reloads too.
        #expect(PhotoThumbnailView.shouldReload(
            from: Revision(localIdentifier: "A", modificationDate: nil), to: original, isVisible: true))
        #expect(PhotoThumbnailView.shouldReload(
            from: original, to: Revision(localIdentifier: "B", modificationDate: first), isVisible: true))
    }
}

// MARK: - PHOTO-005: a photo neither request delivered fails with Try Again

@Suite("The full-size viewer ends a failed load with Try Again")
struct PhotoPageLoadTests {

    @Test("no preview and no full-size picture is a failure, not a spinner")
    func nilThenNilFails() {
        var load = PhotoPageLoad()
        load.previewFinished()
        #expect(load.isLoadingFullResolution && !load.failed)
        load.fullResolutionFinished(hasImage: false)
        #expect(load.failed)
        #expect(!load.isLoadingFullResolution)
    }

    @Test("Try Again loads again and a picture clears the failure")
    func retryRecovers() {
        var load = PhotoPageLoad()
        load.previewFinished()
        load.fullResolutionFinished(hasImage: false)
        load.retry()
        #expect(!load.failed && load.isLoadingFullResolution)
        load.fullResolutionFinished(hasImage: true)
        #expect(!load.failed && !load.isLoadingFullResolution)
    }

    @Test("a preview on screen survives a failed full-size request")
    func previewSurvives() {
        var load = PhotoPageLoad()
        load.previewFinished()
        load.fullResolutionFinished(hasImage: true)
        #expect(!load.failed)
        // A page that swiped away starts afresh: no stale failure on return.
        load = PhotoPageLoad()
        #expect(!load.failed && !load.isLoadingFullResolution)
    }
}

// MARK: - MAP-001: a trip across the dateline frames and draws on one world copy

@MainActor
@Suite("The trip map frames and draws a dateline trip across the dateline")
struct TripRouteMapDatelineTests {

    private let size = CGSize(width: 400, height: 300)

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    @Test("stays either side of the dateline frame as tightly as the same gap elsewhere")
    func datelineFramesCompactly() throws {
        let across = try #require(TripRouteMap.framing(
            for: [coordinate(10, 179), coordinate(10, -179)], size: size, covered: EdgeInsets()))
        let ordinary = try #require(TripRouteMap.framing(
            for: [coordinate(10, 23), coordinate(10, 25)], size: size, covered: EdgeInsets()))
        #expect(abs(across.rect.width - ordinary.rect.width) < 1)
        #expect(across.rect.width < MKMapSize.world.width / 10)
        // Centred on the dateline, at either edge of the canonical world.
        let centre = TripMapProjection.unwrap(across.rect.midX, near: MKMapSize.world.width)
        #expect(abs(centre - MKMapSize.world.width) < 1)
    }

    @Test("ordinary routes keep their plain map x, and one stop stays finite")
    func ordinaryRoutesUnchanged() throws {
        let route = [coordinate(44.3, 12.9), coordinate(45.1, 13.7), coordinate(43.9, 11.2)]
        #expect(TripRouteMap.routeXs(route) == route.map { MKMapPoint($0).x })
        let wide = [coordinate(10, -120), coordinate(10, 0), coordinate(10, 100)]
        #expect(TripRouteMap.routeXs(wide) == wide.map { MKMapPoint($0).x })
        let single = try #require(TripRouteMap.framing(
            for: [coordinate(44.3, 12.9)], size: size, covered: EdgeInsets()))
        #expect(single.rect.width.isFinite && single.rect.width > 0)
    }

    @Test("a station across the dateline draws on screen beside its neighbour")
    func projectionPicksTheVisibleCopy() throws {
        let framing = try #require(TripRouteMap.framing(
            for: [coordinate(10, 179), coordinate(10, -179)], size: size, covered: EdgeInsets()))
        let projection = TripMapProjection(rect: framing.rect, size: framing.size)
        let east = projection.point(coordinate(10, 179))
        let west = projection.point(coordinate(10, -179))
        for point in [east, west] {
            #expect(point.x >= 0 && point.x <= framing.size.width)
        }
        #expect(west.x > east.x)
        // The same rect moved one world over draws the same picture.
        var shifted = framing.rect
        shifted.origin.x += MKMapSize.world.width
        let again = TripMapProjection(rect: shifted, size: framing.size).point(coordinate(10, -179))
        #expect(abs(again.x - west.x) < 0.001)
    }

    @Test("a group either side of the dateline sits on it, not at Greenwich")
    func groupMeanStaysAtTheDateline() {
        let mean = TripMapMarker.mean([coordinate(10, 179), coordinate(10, -179)])
        #expect(abs(abs(mean.longitude) - 180) < 0.01)
        let ordinary = TripMapMarker.mean([coordinate(10, 23), coordinate(10, 25)])
        #expect(abs(ordinary.longitude - 24) < 1e-6)
    }
}

// MARK: - UI-003: a stop's dates are its own days, like its nights

@MainActor
@Suite("Stop captions read a stop's dates in its own zone")
struct StopCaptionZoneTests {

    private let locale = Locale(identifier: "en_GB")

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, zone: String) -> Date {
        calendar(zone).date(from: DateComponents(year: 2031, month: 6, day: day, hour: hour, minute: minute))!
    }

    private func stay(_ start: Date, _ end: Date, zone: String?, in context: ModelContext) -> Stay {
        let stay = Stay(startTime: start, endTime: end, centroidLatitude: 44.3, centroidLongitude: 12.9,
                        h3IndexRes6: "", pingCount: 2, distanceFromHomeKm: 900, pingIDs: [],
                        timeZoneIdentifier: zone)
        stay.category = .destination
        context.insert(stay)
        return stay
    }

    @Test("a same-day stop far east of the device reads one date, as its nights say")
    func sameDayStopReadsOneDate() throws {
        let context = try TestSupport.makeInMemoryContainer().mainContext
        let device = calendar("Europe/Athens")
        let start = date(5, 0, 30, zone: "Asia/Tokyo"), end = date(5, 23, zone: "Asia/Tokyo")
        let caption = TripDisplayText.stopCaption(
            stay(start, end, zone: "Asia/Tokyo", in: context), calendar: device, locale: locale)
        let own = TripDisplayText.range(from: start, to: end, includeYear: false, calendar: calendar("Asia/Tokyo"), locale: locale)
        let deviceDates = TripDisplayText.range(from: start, to: end, includeYear: false, calendar: device, locale: locale)
        #expect(own != deviceDates)
        #expect(caption.hasPrefix(own + " · "), "\(caption)")
        #expect(caption.hasSuffix(TripDisplayText.stopDuration(minutes: 22 * 60 + 30)))
    }

    @Test("an overnight stop reads both its dates beside its one night")
    func overnightStopReadsTwoDates() throws {
        let context = try TestSupport.makeInMemoryContainer().mainContext
        let device = calendar("Europe/Athens")
        let start = date(5, 23, zone: "Asia/Tokyo"), end = date(6, 2, zone: "Asia/Tokyo")
        let caption = TripDisplayText.stopCaption(
            stay(start, end, zone: "Asia/Tokyo", in: context), calendar: device, locale: locale)
        let own = TripDisplayText.range(from: start, to: end, includeYear: false, calendar: calendar("Asia/Tokyo"), locale: locale)
        #expect(caption == "\(own) · \(TripDisplayText.nightsPhrase(1))")
    }

    @Test("a stop without a usable zone keeps the device's dates")
    func missingZoneKeepsDeviceDates() throws {
        let context = try TestSupport.makeInMemoryContainer().mainContext
        let device = calendar("Europe/Athens")
        let start = date(5, 10, zone: "Europe/Athens"), end = date(5, 12, zone: "Europe/Athens")
        let deviceDates = TripDisplayText.range(from: start, to: end, includeYear: false, calendar: device, locale: locale)
        for zone in [nil, "Not/AZone"] {
            let caption = TripDisplayText.stopCaption(
                stay(start, end, zone: zone, in: context), calendar: device, locale: locale)
            #expect(caption.hasPrefix(deviceDates + " · "), "\(caption)")
        }
    }
}

// MARK: - TEMP-003: twin stays reach the temporary-home hints in one order

@Suite("Temporary-home hints read same-id twin stays in one order")
struct TemporaryHomeCardTwinOrderTests {

    private typealias Sample = TemporaryHomeLedger.StaySample

    private func permutations(_ items: [Sample]) -> [[Sample]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[Sample]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    private func signature(_ stays: [Sample]) -> [String] {
        stays.map { "\($0.id)|\($0.latitude)|\($0.longitude)|\($0.timeZoneIdentifier ?? "nil")|\($0.sourceRaw)|\($0.pingCount)" }
    }

    @Test("coordinate, zone and provenance twins sort the same from any fetch order")
    func twinsSortDeterministically() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let end = start.addingTimeInterval(7200)
        func twin(_ latitude: Double, zone: String?, source: String = "liveSLC", pings: Int = 4) -> Sample {
            Sample(id: id, start: start, end: end, latitude: latitude, longitude: 12.9,
                   categoryRaw: StayCategory.destination.rawValue, sourceRaw: source,
                   pingCount: pings, timeZoneIdentifier: zone)
        }
        let twins = [
            twin(44.3, zone: "Europe/Athens"),
            twin(45.3, zone: "Europe/Athens"),
            twin(44.3, zone: nil),
            twin(44.3, zone: ""),
            twin(44.3, zone: "Europe/Athens", source: "photoImport"),
            twin(44.3, zone: "Europe/Athens", pings: 9),
        ]
        let expected = signature(twins.sorted(by: TemporaryHomeCards.timelineOrder))
        #expect(Set(expected).count == twins.count)
        for order in permutations(twins) {
            #expect(signature(order.sorted(by: TemporaryHomeCards.timelineOrder)) == expected)
        }
        // nil and empty zones stay apart, nil first.
        #expect(TemporaryHomeCards.timelineOrder(twin(44.3, zone: nil), twin(44.3, zone: "")))
        #expect(!TemporaryHomeCards.timelineOrder(twin(44.3, zone: ""), twin(44.3, zone: nil)))
    }

    @Test("distinct stays keep plain time order")
    func distinctStaysKeepTimeOrder() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        let early = Sample(id: UUID(), start: start, end: start.addingTimeInterval(60), latitude: 45.3,
                           longitude: 12.9, categoryRaw: "home", sourceRaw: "liveSLC", pingCount: 1,
                           timeZoneIdentifier: nil)
        let late = Sample(id: UUID(), start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200),
                          latitude: 44.3, longitude: 12.9, categoryRaw: "home", sourceRaw: "liveSLC",
                          pingCount: 1, timeZoneIdentifier: nil)
        #expect([late, early].sorted(by: TemporaryHomeCards.timelineOrder).map(\.id) == [early, late].map(\.id))
    }
}

// MARK: - TIME-002: the share map counts each civil day once, across daylight saving

@Suite("The share-card map counts civil days across a daylight-saving change")
struct ShareMapCivilDayTests {

    private func stay(zone: String, start: Date, pings: [SharedPing]) -> SharedStay {
        SharedStay(
            id: UUID(), startTime: start, endTime: start.addingTimeInterval(3 * 86_400),
            durationMinutes: 3 * 1440, categoryRaw: StayCategory.destination.rawValue,
            latitude: 44.3, longitude: 12.9, h3IndexRes6: nil, pingCount: pings.count, pingIDs: pings.map(\.id),
            orderInTrip: 0, locality: "Alpha", subLocality: nil, administrativeArea: nil,
            country: nil, isoCountryCode: "AA", metroName: nil, islandName: nil, isAirport: false,
            sourceRaw: "liveSLC", userOverridden: false, continuesPreviousTrip: false,
            transitFromPreviousRaw: nil, distanceFromPreviousKm: nil, stepsWalked: nil,
            weatherData: nil, avgTemperatureC: nil, weatherConditionRaw: nil, precipitationMm: nil,
            dayKey: nil, timeZoneIdentifier: zone)
    }

    private func ping(_ date: Date) -> SharedPing {
        SharedPing(id: UUID(), timestamp: date, latitude: 44.3, longitude: 12.9,
                   horizontalAccuracy: 20, altitude: nil, verticalAccuracy: nil, sourceRaw: "liveSLC")
    }

    /// Noon on the day before, of and after `zone`'s first spring change in 2031.
    private func noons(around zone: TimeZone) throws -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let january = try #require(calendar.date(from: DateComponents(year: 2031, month: 1, day: 1)))
        let change = try #require(zone.nextDaylightSavingTimeTransition(after: january))
        let day = calendar.startOfDay(for: change)
        return try [-1, 0, 1].map { offset in
            let date = try #require(calendar.date(byAdding: .day, value: offset, to: day))
            return try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date))
        }
    }

    private func visitCount(zone: String, dates: [Date]) throws -> Int {
        let pings = dates.map(ping)
        let trip = SharedTrip(
            shareID: UUID(), startDate: dates[0], endDate: dates[dates.count - 1], isComplete: true,
            stays: [stay(zone: zone, start: dates[0], pings: pings)], pings: pings)
        let frame = try #require(TripShareMapGeometry.frame(for: TripShareMapGeometry.stations(of: trip)))
        let cells = TripShareMapGeometry.cells(of: trip, resolution: 6, frame: frame)
        #expect(cells.count == 1)
        return try #require(cells.first).visitCount
    }

    @Test("three days around a spring change count as three", arguments: ["Europe/London", "America/New_York"])
    func springChangeKeepsEveryDay(zone: String) throws {
        let dates = try noons(around: try #require(TimeZone(identifier: zone)))
        #expect(try visitCount(zone: zone, dates: dates) == 3)
    }

    @Test("same-day repeats and zones without daylight saving keep their counts")
    func controlsKeepTheirCounts() throws {
        // 10:00 UTC, so an hour later is the same day.
        let start = Date(timeIntervalSince1970: 22_337 * 86_400 + 36_000)
        #expect(try visitCount(zone: "UTC", dates: [start, start.addingTimeInterval(3600)]) == 1)
        #expect(try visitCount(zone: "UTC", dates: (0..<3).map { start.addingTimeInterval(Double($0) * 86_400) }) == 3)
    }
}

// MARK: - L10N-001: a routine place's radius keeps the unit it was given

@MainActor
@Suite("Routine-place radius labels keep metres or feet")
struct RoutineRadiusLabelTests {

    @Test("every slider step reads in metres or feet, never rounded to km or mi",
          arguments: ["de_DE", "en_US", "el_GR", "da_DK"])
    func sliderStepsKeepTheirUnit(identifier: String) {
        let locale = Locale(identifier: identifier)
        let metric = locale.measurementSystem == .metric
        let short = metric ? UnitLength.meters : UnitLength.feet
        let long = metric ? UnitLength.kilometers : UnitLength.miles
        let symbol = MeasurementFormatter.symbol(for: short, locale: locale)
        let longSymbol = MeasurementFormatter.symbol(for: long, locale: locale)
        for meters in stride(from: 100.0, through: 2000, by: 100) {
            let label = UnitsFormatter.formatRoutineRadius(meters, locale: locale)
            let value = metric ? meters : Measurement(value: meters, unit: UnitLength.meters).converted(to: .feet).value
            let digits = value.rounded().formatted(.number.precision(.fractionLength(0)).locale(locale))
            #expect(label.contains(digits), "\(identifier) \(meters): \(label)")
            #expect(label.contains(symbol), "\(identifier) \(meters): \(label)")
            #expect(!label.contains(longSymbol), "\(identifier) \(meters): \(label)")
        }
    }
}

// MARK: - L10N-003: the accepted count reads right whatever the photo count

@Suite("Photo import progress words its accepted count independently")
struct PhotoImportAcceptedWordingTests {

    private func lines(_ language: String, processed: Int, total: Int, accepted: Int) -> [String] {
        let locale = Locale(identifier: language)
        return [
            localizedRendererString(
                localized: "settings.photo-import.progress.total.one",
                defaultValue: "\(processed, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never)) photos · \(accepted, format: .number.grouping(.never)) accepted",
                bundle: nil, locale: locale),
            localizedRendererString(
                localized: "settings.photo-import.progress.total.other",
                defaultValue: "\(processed, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never)) photos · \(accepted, format: .number.grouping(.never)) accepted",
                bundle: nil, locale: locale),
            localizedRendererString(
                localized: "settings.photo-import.progress.scanned.one",
                defaultValue: "\(processed, format: .number.grouping(.never)) photos scanned · \(accepted, format: .number.grouping(.never)) accepted",
                bundle: nil, locale: locale),
            localizedRendererString(
                localized: "settings.photo-import.progress.scanned.other",
                defaultValue: "\(processed, format: .number.grouping(.never)) photos scanned · \(accepted, format: .number.grouping(.never)) accepted",
                bundle: nil, locale: locale),
        ]
    }

    @Test("Greek reads one accepted location with no plural verb", arguments: [0, 1, 2])
    func greekAcceptanceIsCountInvariant(accepted: Int) {
        for line in lines("el", processed: 100, total: 10_000, accepted: accepted) {
            #expect(line.hasSuffix("Αποδεκτές τοποθεσίες: \(accepted)"), "\(line)")
            #expect(!line.contains("έγινε") && !line.contains("έγιναν"), "\(line)")
            #expect(line.contains("100"), "\(line)")
        }
    }

    @Test("languages that inflect the participle use a count-free label")
    func inflectingLanguagesUseALabel() {
        let labels = ["es": "Ubicaciones aceptadas: 1", "fr": "Lieux acceptés\u{202F}: 1",
                      "it": "Posizioni accettate: 1", "pt-BR": "Locais aceitos: 1",
                      "pt-PT": "Locais aceites: 1", "sv": "Godkända platser: 1"]
        for (language, label) in labels {
            for line in lines(language, processed: 100, total: 10_000, accepted: 1) {
                #expect(line.hasSuffix(label), "\(language): \(line)")
            }
        }
        #expect(lines("en", processed: 100, total: 10_000, accepted: 1)[1] == "100 of 10000 photos · 1 accepted")
    }
}

// MARK: - L10N-004: the coverage floor writes its decimal like its neighbours

@MainActor
@Suite("Tiny country coverage writes its floor in the locale's decimals")
struct CountryCoverageFloorTests {

    @Test("comma-decimal locales write <0,1%, dot-decimal ones <0.1%")
    func floorFollowsTheLocale() {
        for (identifier, floor, tenth) in [("de_DE", "<0,1%", "0,1%"), ("el_GR", "<0,1%", "0,1%"),
                                           ("da_DK", "<0,1%", "0,1%"), ("en_US", "<0.1%", "0.1%")] {
            let locale = Locale(identifier: identifier)
            #expect(CountryCatalog.countryPercentText(0.04, locale: locale) == floor, "\(identifier)")
            #expect(CountryCatalog.countryPercentText(0.1, locale: locale) == tenth, "\(identifier)")
            #expect(CountryCatalog.countryPercentText(0, locale: locale) == "0%", "\(identifier)")
            #expect(CountryCatalog.countryPercentText(100, locale: locale) == "100%", "\(identifier)")
        }
    }
}

// MARK: - Trip dates read in the trip's own zones, as its day count is

@MainActor
@Suite("Trip dates read in the trip's own zones, agreeing with its day count")
struct TripDatesInStayZonesTests {

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let locale = Locale(identifier: "en_US")

    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2031, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// Noon in Tokyo on `day` October 2031: the same civil day by another path.
    private func tokyoNoon(_ day: Int) -> Date { utc(day, 3) }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// 23:30 UTC on 8 and 13 October is 9 and 14 October in Tokyo.
    private func trip(in context: ModelContext) -> Trip {
        let trip = Trip(startDate: utc(8, 23, 30))
        trip.endDate = utc(13, 23, 30)
        context.insert(trip)
        for (start, end) in [(utc(8, 23, 30), utc(10, 23)), (utc(11, 1), utc(13, 23, 30))] {
            let stay = Stay(startTime: start, endTime: end, centroidLatitude: 44.3, centroidLongitude: 12.9,
                            h3IndexRes6: "", pingCount: 2, distanceFromHomeKm: 900, pingIDs: [],
                            timeZoneIdentifier: "Asia/Tokyo")
            context.insert(stay)
            stay.trip = trip
        }
        return trip
    }

    @Test("a trip's row and page dates match its day count from a device far away")
    func tripDatesFollowStayZones() throws {
        let context = try TestSupport.makeInMemoryContainer().mainContext
        let trip = trip(in: context)
        #expect(trip.durationDays == 6)
        for deviceZone in ["Europe/Lisbon", "America/Los_Angeles", "Asia/Tokyo"] {
            let device = calendar(TimeZone(identifier: deviceZone)!)
            let shown = TripDisplayText.tripDates(trip, includeYear: true, calendar: device, locale: locale)
            let expected = TripDisplayText.range(from: tokyoNoon(9), to: tokyoNoon(14), includeYear: true,
                                                 calendar: calendar(tokyo), locale: locale)
            #expect(shown == expected, "\(deviceZone): \(shown)")
        }
        // An ongoing trip reads its first day where it began.
        trip.endDate = nil
        #expect(TripDisplayText.tripDates(trip, includeYear: false, calendar: calendar(TimeZone(identifier: "America/Los_Angeles")!))
            == TripDisplayText.since(tokyoNoon(9), in: tokyo))
    }

    @Test("a trip with no stay zones keeps the device's reading")
    func zonelessTripKeepsDeviceDates() throws {
        let context = try TestSupport.makeInMemoryContainer().mainContext
        let trip = Trip(startDate: utc(8, 12))
        trip.endDate = utc(13, 12)
        context.insert(trip)
        let device = calendar(TimeZone(identifier: "Europe/Lisbon")!)
        #expect(TripDisplayText.tripDates(trip, includeYear: true, calendar: device, locale: locale)
            == TripDisplayText.range(from: utc(8, 12), to: utc(13, 12), includeYear: true, calendar: device, locale: locale))
    }

    @Test("the Current Trip widget prints a finished trip's days in its stays' zones")
    func widgetDatesFollowStayZones() {
        let snapshot = Trip.WidgetSnapshot(
            title: "Fixture Trip", countryFlags: "", startDate: utc(8, 23, 30), endDate: utc(13, 23, 30),
            dayCount: 6, isOngoing: false,
            startDayTimeZoneIdentifier: "Asia/Tokyo", endDayTimeZoneIdentifier: "Asia/Tokyo")
        var style = Date.IntervalFormatStyle(locale: locale).month().day()
        style.timeZone = tokyo
        #expect(snapshot.dateRangeText(locale: locale) == DateRangeText.format(tokyoNoon(9)..<tokyoNoon(14), style))
        var day = Date.FormatStyle(locale: locale).month().day()
        day.timeZone = tokyo
        #expect(snapshot.startDayText(locale: locale) == tokyoNoon(9).formatted(day))
    }

    @Test("a shared trip's card and preview dates match its day count")
    func sharedTripDatesFollowStayZones() {
        let stays = [(utc(8, 23, 30), utc(10, 23)), (utc(11, 1), utc(13, 23, 30))].enumerated().map { index, span in
            SharedStay(
                id: UUID(), startTime: span.0, endTime: span.1,
                durationMinutes: Int(span.1.timeIntervalSince(span.0) / 60), categoryRaw: StayCategory.destination.rawValue,
                latitude: 44.3, longitude: 12.9, h3IndexRes6: nil, pingCount: 0, pingIDs: [],
                orderInTrip: index, locality: "Alpha", subLocality: nil, administrativeArea: nil,
                country: nil, isoCountryCode: "AA", metroName: nil, islandName: nil, isAirport: false,
                sourceRaw: "liveSLC", userOverridden: false, continuesPreviousTrip: false,
                transitFromPreviousRaw: nil, distanceFromPreviousKm: nil, stepsWalked: nil,
                weatherData: nil, avgTemperatureC: nil, weatherConditionRaw: nil, precipitationMm: nil,
                dayKey: nil, timeZoneIdentifier: "Asia/Tokyo")
        }
        let shared = SharedTrip(shareID: UUID(), customName: "Fixture Trip", startDate: utc(8, 23, 30),
                                endDate: utc(13, 23, 30), isComplete: true, stays: stays)
        #expect(SharedTripText.dayCount(shared) == 6)
        var device = Calendar.current
        device.timeZone = tokyo
        #expect(SharedTripText.dates(shared)
            == TripDisplayText.range(from: tokyoNoon(9), to: tokyoNoon(14), includeYear: true, calendar: device))
        var style = TripShareCardContent.intervalStyle(includeYear: true, locale: locale)
        style.timeZone = tokyo
        #expect(TripShareCardContent.dates(shared, includeYear: true, locale: locale)
            == DateRangeText.format(tokyoNoon(9)..<tokyoNoon(14), style))
    }
}

private extension MeasurementFormatter {
    /// The abbreviated symbol `locale` writes for `unit`, read off a formatted value.
    static func symbol(for unit: UnitLength, locale: Locale) -> String {
        let text = Measurement(value: 7, unit: unit).formatted(
            .measurement(width: .abbreviated, usage: .asProvided).locale(locale))
        return text.filter { !$0.isNumber && !$0.isWhitespace }
    }
}
