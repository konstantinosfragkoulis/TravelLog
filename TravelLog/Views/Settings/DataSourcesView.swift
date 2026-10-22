//
//  DataSourcesView.swift
//  TravelLog
//

import SwiftUI

/// Acknowledgements for the bundled open datasets and libraries, reachable
/// from Settings → About.
///
/// This screen is not optional polish: several bundled sources carry
/// licenses that REQUIRE attribution in the shipped product (GeoNames and
/// GHSL are CC BY 4.0; OpenStreetMap and mledoze/countries are ODbL), so
/// surfacing them is a ship requirement. Apple Weather attribution is
/// handled separately by `WeatherAttributionFootnote` (Apple mandates its
/// own mark + legal link wherever weather is shown). CC BY and ODbL also
/// require a licence link and a note that the data was modified; the MIT
/// and Apache library licences require their full texts, which ship in
/// `Resources/Acknowledgements.txt`.
struct DataSourcesView: View {

    private struct DataSource: Identifiable {
        var id: String { name }
        let name: String
        let role: String
        let license: String
        let url: URL
        var licenseURL: URL? = nil
    }

    private static let ccBy4 = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    private static let odbl1 = URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")!
    /// GHSL asks every product citation to be accompanied by this reference publication.
    private static let ghslReference = "Pesaresi, M., Schiavina, M., Politis, P., Freire, S., "
        + "Krasnodębska, K., Uhl, J. H., et al. (2024). Advances on the Global Human "
        + "Settlement Layer by joint assessment of Earth Observation and population "
        + "survey data. International Journal of Digital Earth, 17(1). "
        + "doi:10.1080/17538947.2024.2390454"

    /// One row per bundled dataset. Keep in sync with THIRD_PARTY_NOTICES.md
    /// when sources change.
    private static let sources: [DataSource] = [
        DataSource(
            name: "GeoNames",
            role: String(localized: "data-sources.role.geonames", defaultValue: "City and town database for the offline geocoder", comment: "Data Sources description of how the bundled GeoNames dataset is used."),
            license: "CC BY 4.0",
            url: URL(string: "https://www.geonames.org")!,
            licenseURL: ccBy4
        ),
        DataSource(
            name: String(localized: "data-sources.name.openstreetmap", defaultValue: "OpenStreetMap contributors", comment: "Data Sources credit line for OpenStreetMap, the standard attribution phrase."),
            role: String(localized: "data-sources.role.openstreetmap", defaultValue: "Island and neighbourhood layers for the offline geocoder", comment: "Data Sources description of how bundled OpenStreetMap data is used."),
            license: "ODbL 1.0",
            url: URL(string: "https://www.openstreetmap.org/copyright")!,
            licenseURL: odbl1
        ),
        DataSource(
            name: "Natural Earth",
            role: String(localized: "data-sources.role.natural-earth", defaultValue: "Country and admin-region boundaries", comment: "Data Sources description of how bundled Natural Earth data is used."),
            license: String(localized: "data-sources.license.public-domain", defaultValue: "Public domain", comment: "Data Sources license description for a bundled public-domain dataset (Natural Earth, OurAirports)."),
            url: URL(string: "https://www.naturalearthdata.com")!
        ),
        DataSource(
            name: "mledoze/countries",
            role: String(localized: "data-sources.role.countries", defaultValue: "Country areas, UN membership and territories", comment: "Data Sources description of how the bundled mledoze/countries dataset is used."),
            license: "ODbL 1.0",
            url: URL(string: "https://github.com/mledoze/countries")!,
            licenseURL: odbl1
        ),
        DataSource(
            name: "GHS-FUA R2019A, Copernicus / EU Joint Research Centre",
            role: String(localized: "data-sources.role.ghs-fua", defaultValue: "Metropolitan-area polygons for the offline geocoder", comment: "Data Sources description of how the bundled GHS-FUA dataset is used."),
            license: "CC BY 4.0, © European Union, 2019. Schiavina, M.; Moreno-Monroy, A.; Maffenini, L.; "
                   + "Veneri, P. (2019), GHSL-OECD Functional Urban Areas 2019, "
                   + "EUR 30001 EN, Publications Office of the European Union. "
                   + "doi:10.2760/67415. " + ghslReference,
            url: URL(string: "https://human-settlement.emergency.copernicus.eu")!,
            licenseURL: ccBy4
        ),
        DataSource(
            name: "GHS-UCDB R2024A, Copernicus / EU Joint Research Centre",
            role: String(localized: "data-sources.role.ghs-ucdb", defaultValue: "Urban-centre boundaries used to define your home area", comment: "Data Sources description of how the bundled GHS-UCDB dataset is used."),
            license: "CC BY 4.0, © European Union. Mari Rivero, I.; Melchiorri, M.; Florio, P.; "
                   + "Schiavina, M. et al. (2024), European Commission, JRC. "
                   + "doi:10.2905/1a338be6-7eaf-480c-9664-3a8ade88cbcd. " + ghslReference,
            url: URL(string: "https://human-settlement.emergency.copernicus.eu")!,
            licenseURL: ccBy4
        ),
        DataSource(
            name: "OurAirports",
            role: String(localized: "data-sources.role.ourairports", defaultValue: "Airport locations for transit detection", comment: "Data Sources description of how the bundled OurAirports dataset is used."),
            license: String(localized: "data-sources.license.public-domain", defaultValue: "Public domain", comment: "Data Sources license description for a bundled public-domain dataset (Natural Earth, OurAirports)."),
            url: URL(string: "https://ourairports.com")!
        ),
    ]

    /// Open-source code linked into the app. Full licence texts:
    /// `Resources/Acknowledgements.txt`; keep both in sync with
    /// THIRD_PARTY_NOTICES.md and the package pins.
    private static let libraries: [DataSource] = [
        DataSource(
            name: "SwiftH3",
            role: String(localized: "data-sources.role.swifth3", defaultValue: "Swift interface to the H3 grid", comment: "Data Sources description of the SwiftH3 open-source library."),
            license: "MIT, © 2019 Benny Wong",
            url: URL(string: "https://github.com/bdotdub/SwiftH3")!
        ),
        DataSource(
            name: "Ch3",
            role: String(localized: "data-sources.role.ch3", defaultValue: "Packages the H3 C library for Swift", comment: "Data Sources description of the Ch3 open-source library."),
            license: "MIT, © 2019 Benny Wong",
            url: URL(string: "https://github.com/bdotdub/Ch3")!
        ),
        DataSource(
            name: "H3",
            role: String(localized: "data-sources.role.h3", defaultValue: "Hexagonal grid for the visit map", comment: "Data Sources description of the H3 open-source library by Uber."),
            license: "Apache License 2.0, © 2016-2019 Uber Technologies, Inc.",
            url: URL(string: "https://github.com/uber/h3")!
        ),
        DataSource(
            name: "flag-icons",
            role: String(localized: "data-sources.role.flag-icons", defaultValue: "Country flag artwork", comment: "Data Sources description of the flag-icons open-source artwork used for country flags."),
            license: "MIT, © 2013 Panayiotis Lipiridis",
            url: URL(string: "https://github.com/lipis/flag-icons")!
        ),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.sources) { source in
                    row(source)
                }
            } header: {
                Text(String(localized: "data-sources.section.datasets", defaultValue: "Datasets", comment: "Data Sources section header above the list of bundled open datasets."))
                    .settingsHeader()
            } footer: {
                // No absolute "never leaves your iPhone" claim: rare
                // hard-to-name places, weather, and
                // planned-trip lookups do use Apple services — exactly what
                // the location-permission copy already discloses.
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "data-sources.modified", defaultValue: "The datasets are filtered, simplified and reshaped for use in the app.", comment: "Data Sources footer stating that the bundled datasets were modified, as their licences require."))
                    Text("These datasets are bundled into the app, so the places you visit are named on-device. A small number of hard-to-name places and weather lookups use Apple services.")
                }
            }

            Section {
                ForEach(Self.libraries) { library in
                    row(library)
                }
                NavigationLink {
                    LicenseTextsView()
                } label: {
                    Text(LicenseTextsView.title)
                }
            } header: {
                Text(String(localized: "data-sources.section.libraries", defaultValue: "Libraries", comment: "Data Sources section header above the list of open-source libraries the app uses."))
                    .settingsHeader()
            }
        }
        .navigationTitle("Data Sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ source: DataSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.name)
                .font(.headline)
            Text(source.role)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(source.license)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let licenseURL = source.licenseURL {
                    Link(String(localized: "data-sources.license-link", defaultValue: "License", comment: "Data Sources link that opens the dataset's licence text on the web."), destination: licenseURL)
                        .font(.caption)
                }
                Link("Website", destination: source.url)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The bundled library licence texts, kept verbatim in
/// `Resources/Acknowledgements.txt` and shown in English.
private struct LicenseTextsView: View {

    static let title = String(localized: "data-sources.license-texts.title", defaultValue: "License Texts", comment: "Data Sources row and screen title for the full open-source library licence texts.")

    /// The file wraps lines at about 80 columns; join each paragraph's lines
    /// so the text flows at any width. The file itself stays verbatim.
    private static let text: String = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }()

    var body: some View {
        ScrollView {
            Text(verbatim: Self.text)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
