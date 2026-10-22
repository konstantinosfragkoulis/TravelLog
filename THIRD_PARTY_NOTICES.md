# Third-party notices

The source code in this repository is MIT-licensed (see `LICENSE`). The libraries, data and artwork below keep their own licences.

## Libraries

| Package | Licence | Notes |
|---|---|---|
| [SwiftH3](https://github.com/bdotdub/SwiftH3) | MIT, © 2019 Benny Wong | Swift bindings for H3 |
| [Ch3](https://github.com/bdotdub/Ch3) | MIT, © 2019 Benny Wong | Packages the H3 C library |
| [H3](https://github.com/uber/h3) (bundled in Ch3) | Apache License 2.0, © Uber Technologies, Inc. | Hexagonal grid index |

The full licence texts ship in the app (`TravelLog/Resources/Acknowledgements.txt`, shown under Settings → Data Sources & Acknowledgements → License Texts).

## Data

| Dataset | Where it is used | Licence |
|---|---|---|
| [GeoNames](https://www.geonames.org) | Cities and admin names in the offline geocoder database | CC BY 4.0 |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors | Island and neighbourhood layers in the offline geocoder database | ODbL 1.0 |
| [Natural Earth](https://www.naturalearthdata.com) | `TravelLog/Resources/countries.geojson`, admin-1 boundaries | Public domain |
| [OurAirports](https://ourairports.com/data/) | `TravelLog/Resources/airports.json` | Public domain |
| [mledoze/countries](https://github.com/mledoze/countries) | `TravelLog/Services/Geography/CountryCatalogData.swift` (generated) | ODbL 1.0 |
| [GHS-FUA R2019A](https://human-settlement.emergency.copernicus.eu) | Metropolitan-area polygons in the offline geocoder database | CC BY 4.0, © European Union, 2019. Schiavina M., Moreno-Monroy A., Maffenini L., Veneri P., GHSL-OECD Functional Urban Areas 2019, EUR 30001 EN, Publications Office of the European Union, 2019, doi:10.2760/67415 |
| [GHS-UCDB R2024A](https://human-settlement.emergency.copernicus.eu) | Urban-centre boundaries in the offline geocoder database | CC BY 4.0, © European Union, JRC. Mari Rivero, I., Melchiorri, M., Florio, P., Schiavina, M. et al. (2024). doi:10.2905/1a338be6-7eaf-480c-9664-3a8ade88cbcd |
| [Wikidata](https://www.wikidata.org) | Island supplement for the offline geocoder database | CC0 |

GHSL reference publication for both GHS rows: Pesaresi, M., Schiavina, M., Politis, P., Freire, S., Krasnodębska, K., Uhl, J. H., et al. (2024). Advances on the Global Human Settlement Layer by joint assessment of Earth Observation and population survey data. International Journal of Digital Earth, 17(1). doi:10.1080/17538947.2024.2390454

Modified: all datasets are filtered, reprojected and reshaped by the scripts in `scripts/`.

Database licence: `Geocoder.sqlite` (published as a release asset, built by `scripts/build-geocoder-db.py`) and `CountryCatalogData.swift` contain data derived from ODbL sources. They are made available under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/); the MIT licence does not apply to them.

## Artwork

The app icon (`icon.icon`) composes two SVG icons from [SVG Repo](https://www.svgrepo.com), recoloured, scaled and layered in Icon Composer.

| Asset | Source | Licence |
|---|---|---|
| `icon.icon/Assets/location-pin-svgrepo-com.svg` | [Location Pin](https://www.svgrepo.com/svg/513213/location-pin) | CC0 1.0 |
| `icon.icon/Assets/maps-svgrepo-com.svg` | [Maps](https://www.svgrepo.com/svg/428096/maps) | CC0 1.0 |
| `TravelLog/Flags.xcassets` (`flag-<iso>`, 250 SVGs) | [flag-icons](https://github.com/lipis/flag-icons) 7.5.0, 4:3 set | MIT, © 2013 Panayiotis Lipiridis |

The country flags are copied by `scripts/build-flag-assets.py`, unchanged apart from an added intrinsic size on each SVG root, into the app and the widget extension. The full MIT text ships in `TravelLog/Resources/Acknowledgements.txt`.
