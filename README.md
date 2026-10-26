# TravelLog

TravelLog is an iOS app that builds your travel history by itself. It records where you go in the background, works out where home is, and turns the time you spend away into trips. You can browse them on a map and a globe, search them in plain language, and see yearly stats, a passport, and a year in review. Travel-history processing and AI run on the device. The app uses Apple services for maps, place search, some place names and time zones, weather and iCloud Photos downloads. CloudKit sync of your travel history is optional; a few small preferences sync through iCloud whenever you are signed in.

## Features

- **Automatic trips.** Background location, place visits and an optional photo-library import become stays. A classifier works out which stays are home and groups the rest into trips with titles.
- **Home that adapts.** Home is an urban area, not a single point: it uses GHS urban-centre boundaries, learned commuting patterns and your corrections. You can also declare a temporary home, for example for a semester abroad.
- **Offline geocoder.** A bundled SQLite database built from GeoNames, OpenStreetMap, Natural Earth and GHSL data names places without a network call. MapKit is only a fallback.
- **Search.** Search accepts plain-language queries ("beach trips last summer", "kyoto 2024") in 18 languages and tolerates typos. Optional on-device Foundation Models features help with titles and search.
- **Map, globe and stats.** These include a hexagon visit map, a 3D globe, countries and cities visited, yearly summaries, On This Day, and widgets.
- **Calendar and planning.** The app reads your calendar to show upcoming trips and to help classify trips and confirm flights. Calendar events do not name past trips.
- **Siri, Shortcuts and Spotlight.** These include "Where was I", trip search and travel stats.
- **Your data stays yours.** You get JSON export and import and delete-all. There are no analytics, ads or developer servers. See the [privacy policy](legal/privacy-policy.html).

## Engineering notes

- **SwiftData with frozen schema history.** The store is at schema version 21; every historical schema is frozen so installed stores keep migrating (`TravelLog/App/TravelLogSchema.swift`), and migration tests open each old shape.
- **Bounded, ordered writes.** All pipeline writes go through one non-reentrant gate (`PipelineGate`), and inference runs outside it, applying only after its inputs are re-validated.
- **Geocoder build pipeline.** `scripts/` downloads the public datasets, builds the database, trims it for shipping and checks the trimmed copy against the master. See [REBUILD_GEOCODER.md](scripts/REBUILD_GEOCODER.md).
- **Tests.** About 4,500 Swift Testing tests run against real on-disk SwiftData stores.

## How this was built

Built with AI coding agents under my direction.

## Building

1. Clone the repo and open `TravelLog.xcodeproj` in Xcode 27 or later (iOS 27 SDK); the app supports iOS 26 and later.
2. Fetch the offline geocoder database (about 106 MB, released separately because it is larger than GitHub's file limit):

   ```sh
   scripts/fetch-geocoder.sh
   ```

   Until the database is present, the build stops with an error that names `scripts/fetch-geocoder.sh`.

3. Build and run the `TravelLog` scheme. To use iCloud sync and the widget's App Group, sign with your own team and change the identifiers in these places:

   - bundle identifiers of the three targets (Signing & Capabilities);
   - `TravelLog/TravelLog.entitlements` and `TravelLogWidgetsExtension.entitlements` (iCloud container and App Group);
   - `appGroupIdentifier` and `cloudKitContainerIdentifier` in `TravelLog/App/AppDelegate+Persistence.swift`, and `appGroupIdentifier` in `TravelLogWidgets/SharedModelContainer.swift`;
   - the background task and activity identifiers in `TravelLog/Info.plist`, which must match `AppDelegate+BackgroundTasks.swift` and `TripDetailView.swift`.

## Repository notes

- `legal/privacy-policy.html` and `TravelLog/PrivacyPolicy.html` must stay identical.

## Licence

The code is under the MIT licence (see [LICENSE](LICENSE)). Bundled and derived data keep their own licences, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
