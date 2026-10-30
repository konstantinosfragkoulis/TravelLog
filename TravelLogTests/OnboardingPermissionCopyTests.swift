import Foundation
import Testing

struct OnboardingPermissionCopyTests {
    @Test("Onboarding uses the concise English catalog copy")
    func englishCatalogCopy() throws {
        let expected = [
            "onboarding.feature.battery.description": "No constant GPS in the background",
            "onboarding.feature.automatic-trips.description.without-ai": "Your stays turn into trips on their own",
            "onboarding.location.explanation": "“Always” location access lets Travel Log notice trips in the background with minimal battery use. Your travel history stays on your device and in your private iCloud. Weather and some place names come from Apple services.",
            "onboarding.photo-scan.title.full": "Rebuild past trips from your photos.",
            "onboarding.photo-scan.title.limited": "Rebuild past trips from your selected photos.",
            "onboarding.location.title": "Record trips, even when the app is closed.",
            "onboarding.location.status.when-in-use.detail": "Choose “Always” in Settings to record trips in the background.",
            "onboarding.location.status.denied.detail": "Turn on location access in Settings to record trips.",
            "onboarding.background-refresh.off.detail": "Turn it on in Settings so tracking keeps running when iOS closes the app.",
            "onboarding.background-refresh.restricted.detail": "A device policy blocks it, so tracking may stop when iOS closes the app.",
            "onboarding.home.title": "Set your home.",
            "onboarding.home.caption": "Time at home never counts as a trip.",
            "onboarding.routine.title": "Skip the everyday places.",
            "onboarding.routine.caption": "Work, gym, campus: places like these won't become trips.",
            "onboarding.icloud.title": "Keep your trips on every device.",
            "onboarding.icloud.caption": "Synced privately through your iCloud.",
            "onboarding.photos.title": "Bring your photos into your trips.",
            "onboarding.photos.caption": "Matched on your device by time and place. Never uploaded or changed.",
            "onboarding.photo-scan.caption": "Runs on your device. You can also start it later from Settings.",
            "onboarding.notifications.title": "Know when you land.",
            "onboarding.notifications.caption": "A hello when you arrive abroad, a welcome when you're back home. Optional.",
            "Continue": "Continue",
        ]
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let catalogURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("TravelLog/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        for (key, value) in expected {
            let entry = strings[key] as? [String: Any]
            let english = ((entry?["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
            let catalogValue = english?["value"] as? String ?? key
            #expect(catalogValue == value, "\(key) resolves to \(catalogValue)")
        }
    }
}
