import Testing
import MapKit
@testable import TravelLog

nonisolated struct CountryOverlayRendererTests {
    private static func country(_ id: String, x: Double) -> CountryPolygonProvider.CountryPolygon {
        let square = [
            MKMapPoint(x: x, y: 0), MKMapPoint(x: x + 100, y: 0),
            MKMapPoint(x: x + 100, y: 100), MKMapPoint(x: x, y: 100)
        ]
        let hole = [MKMapPoint(x: x + 40, y: 40), MKMapPoint(x: x + 60, y: 40), MKMapPoint(x: x + 60, y: 60)]
        return CountryPolygonProvider.CountryPolygon(
            id: id, isoCode: id,
            polygon: MKPolygon(points: square, count: 4, interiorPolygons: [MKPolygon(points: hole, count: 3)])
        )
    }

    @Test("Visited countries become one vector shape, holes kept; none, no shape")
    func oneShapeForAllCountries() throws {
        #expect(CountryOverlayLayer.shape(for: []) == nil)
        let shape = try #require(CountryOverlayLayer.shape(for: [Self.country("GR", x: 0), Self.country("CY", x: 500)]))
        #expect(shape.polygons.count == 2)
        #expect(shape.polygons.allSatisfy { $0.interiorPolygons?.count == 1 })
        #expect(shape.boundingMapRect.minX == 0 && shape.boundingMapRect.maxX == 600)
        #expect(CountryOverlayLayer.lineWidth == 1.5)
    }
}
