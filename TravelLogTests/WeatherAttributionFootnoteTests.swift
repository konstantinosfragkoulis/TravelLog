import Testing
@testable import TravelLog

@Suite("Weather attribution mark fallback")
struct WeatherAttributionFootnoteTests {
    @Test("a missing mark URL shows the fallback")
    func missingMarkURL() {
        #expect(WeatherAttributionFootnote.showsFallbackMark(hasMarkURL: false, remoteLoaded: false))
        #expect(WeatherAttributionFootnote.showsFallbackMark(hasMarkURL: false, remoteLoaded: true))
    }

    @Test("a remote mark that has not loaded shows the fallback")
    func remoteMarkNotLoaded() {
        #expect(WeatherAttributionFootnote.showsFallbackMark(hasMarkURL: true, remoteLoaded: false))
    }

    @Test("a loaded remote mark replaces the fallback")
    func remoteMarkLoaded() {
        #expect(!WeatherAttributionFootnote.showsFallbackMark(hasMarkURL: true, remoteLoaded: true))
    }
}
