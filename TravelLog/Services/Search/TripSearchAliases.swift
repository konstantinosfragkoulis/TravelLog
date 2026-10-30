//
//  TripSearchAliases.swift
//  TravelLog
//

import Foundation
import os

/// Curated and Locale-derived search vocabulary. Input-only: nothing here is
/// shown to the user, so it needs no string catalog keys.
///
/// Country aliases are indexed with every destination country (see
/// `TripSearch.countryAliases`). Everything else is recognized on the query
/// side: abbreviation classes and city abbreviations add alias alternatives,
/// while region words, country names in any supported language and the
/// query-only country aliases add a country-code alternative. Recognition
/// is exact on normalized text, never prefix or fuzzy.
nonisolated enum TripSearchAliases {

    /// Common names Locale does not provide (CLDR says Türkiye, Czechia,
    /// China mainland, 대한민국 and アメリカ合衆国).
    static let countryAliases: [String: [String]] = [
        "GB": ["UK", "Britain", "Great Britain", "England", "Αγγλία"],
        "US": ["USA", "America", "United States of America", "米国", "ΗΠΑ", "Αμερική"],
        "NL": ["Holland"],
        "TR": ["Turkey"],
        "AE": ["UAE", "Emirates"],
        "CZ": ["Czech Republic", "Czech"],
        "CH": ["Swiss"],
        "CN": ["China"],
        "KR": ["Korea", "South Korea", "한국", "남한"],
        "KP": ["North Korea"],
        "MM": ["Burma"],
        "CI": ["Ivory Coast"],
        "VA": ["Vatican"],
        "MK": ["Macedonia"],
        "SZ": ["Swaziland"],
        "TL": ["East Timor"],
        "CV": ["Cape Verde"],
        "GR": ["Hellas", "Ellada"],
    ]

    /// The same kind of names in the other supported languages, and country
    /// abbreviations, recognized on the query side only, like other
    /// languages' Locale names: a short form CLDR lacks ("Corea", "中国",
    /// "Emirate"), a former official name ("República Checa"), the part
    /// named for the whole ("Inglaterra", "Holanda"), an abbreviation
    /// ("EEUU", "VAE"). Never indexed: their words would match places
    /// ("gran" of "Gran Bretaña"), and the letters of a dotted abbreviation
    /// ("U.S.", "EE. UU.") are no words (`TripSearch.phraseTerm`).
    static let queryCountryAliases: [String: [String]] = [
        "GB": ["U.K.", "Großbritannien", "Grande-Bretagne", "Angleterre", "Gran Bretagna", "Inghilterra",
               "Gran Bretaña", "Inglaterra", "Grã-Bretanha", "Groot-Brittannië", "Engeland",
               "İngiltere", "Μεγάλη Βρετανία", "英国"],
        "US": ["U.S.", "U.S.A.", "EEUU", "EE. UU.", "EUA", "ABD", "Amerika", "アメリカ"],
        "NL": ["Holanda", "Olanda", "Hollande", "Ολλανδία"],
        "AE": ["U.A.E.", "VAE", "EAU", "BAE", "ΗΑΕ", "Emirate", "Émirats", "Emirati", "Emiratos", "Emirados",
               "Emiraten", "Emirater", "Εμιράτα"],
        "CZ": ["Tschechische Republik", "République tchèque", "Repubblica Ceca", "República Checa",
               "República Tcheca", "Tsjechische Republiek", "Çek Cumhuriyeti", "Τσεχική Δημοκρατία",
               "チェコ共和国", "체코 공화국", "捷克共和国", "捷克共和國"],
        "CN": ["Chine", "Cina", "Kina", "Çin", "Trung Quốc", "Κίνα", "中国", "中國", "중국"],
        "KR": ["Corea", "Coreia", "Corée", "Kore", "Κορέα"],
        "VA": ["Vatikan", "Vaticano", "Vaticaan", "Βατικανό"],
    ]

    /// Bidirectional abbreviation classes. A query word in a class also
    /// matches every other member exactly.
    static let abbreviationClasses: [[String]] = [
        ["st", "saint", "sankt", "ste", "sainte"],
        ["mt", "mount"],
        ["ft", "fort"],
    ]

    /// City abbreviations as alias alternatives, matched against place words
    /// only (`dc` is not Washington State, `nyc` is not Buffalo, New York).
    /// Multi-word names use the compound the index builds from one place
    /// value, so the words must be adjacent in the same name. The
    /// abbreviation keeps its literal meaning: `la` still finds La Paz by
    /// prefix.
    static let cityAbbreviations: [String: [[String]]] = [
        "nyc": [["newyork"]],
        "ny": [["newyork"]],
        "la": [["losangeles"]],
        "sf": [["sanfrancisco"]],
        "dc": [["washington"]],
        "hk": [["hongkong"]],
        "kl": [["kualalumpur"]],
        "cdmx": [["mexicocity"], ["ciudaddemexico"]],
        "bcn": [["barcelona"]],
    ]

    /// Common exonyms the bundled place-name table lacks, keyed by the
    /// stored (or GeoNames region) name's folded form and ISO code
    /// (`TripSearchPlaceNames`), for every layer. Searchable like the
    /// table's names, never shown. Only names in wide use: the table covers
    /// the rest.
    static let placeNameExtras: [String: [String]] = [
        // Brazilian Portuguese; the table has European "Nova Iorque" only.
        "new york|US": ["Nova York"],
        // Greek; the table has the transliteration "Ισταμπούλ" only.
        "istanbul|TR": ["Κωνσταντινούπολη"],
        // German short forms; the table has "Kanarische Inseln" and
        // "Balearische Inseln", and English "Balearics" is colloquial.
        "canary islands|ES": ["Kanaren"],
        "balearic islands|ES": ["Balearen", "Balearics"],
    ]

    /// Administrative suffixes of Han, kana and Hangul place names, longest
    /// first. On both sides a name is also searchable without one (東京都 →
    /// 東京, 京都市 → 京都, 서울특별시 → 서울), so a query is not an infix of
    /// another place's suffixed name (京都 inside 東京都), and 東京都 typed
    /// finds Tokyo stored without it. Hangul 도 (province, island) is a query
    /// particle already (`hangulParticles`).
    static let administrativeSuffixes: [String] = [
        "特別市", "特别市", "広域市", "广域市", "특별시", "광역시",
        "都", "府", "県", "县", "縣", "省", "市", "区", "區", "시", "구",
    ]

    /// Island suffixes, stripped on the query side only (済州島 finds Jeju):
    /// a stored island without one can be another place (宮古島 is Miyako
    /// Island, 宮古 the city of Miyako).
    static let islandSuffixes: [String] = ["島", "岛"]

    /// The suffixes of region and island-group names, longest first: the
    /// administrative ones plus a state's, a French region's, a town's or
    /// village's and an archipelago's (トスカーナ州 → トスカーナ,
    /// ノルマンディー地域圏 → ノルマンディー, 诺曼底大区 → 诺曼底,
    /// 제주특별자치도 → 제주, カナリア諸島 → カナリア). Only for those
    /// names: a city's 町 or 州 is part of it (十日町, 广州). A bare Korean
    /// 주 or 도 also ends names (홋카이도, 콜로라도), so the table writes
    /// it as a word of its own where it is a designator (캘리포니아 주,
    /// 경기 도), which the name is found without.
    static let regionSuffixes: [String] = [
        "特別市", "特别市", "広域市", "广域市", "地域圏", "특별자치도", "특별시", "광역시",
        "大区", "大區", "諸島", "群島", "群岛", "列島", "列岛", "诸岛", "제도",
        "都", "府", "県", "县", "縣", "省", "州", "市", "区", "區", "町", "村", "시", "구",
    ]

    /// Words of other-language place names that do not name the place by
    /// themselves: generic designators ("Ciudad de México", "Stadt Capri",
    /// "Jeju Şehri", "Thành phố New York"), a region's ("Präfektur Osaka",
    /// "Comunidade Valenciana", "Νομός Κυκλάδων"), compass words
    /// ("Basse-Californie du Nord", "Südliche Ägäis") and words for a
    /// group of islands ("Kanarische Inseln", "Kiklad Adaları", "카나리아
    /// 제도"). Native normalized
    /// forms. The full name still matches as a compound.
    static let placeNameNoiseWords: Set<String> = [
        "city", "ciudad", "cidade", "citta", "ville", "stadt", "stad", "kenti", "sehri", "thanh",
        "comuna", "kommun", "kommune",
        "prefecture", "prefectura", "prefettura", "prefeitura", "prafektur", "prefektur", "praefekturet",
        "province", "provincia", "provinz", "provincie", "provins", "region", "regione", "regiao",
        "comunidad", "comunidade", "comunitat", "autonoma", "freistaat", "departement", "departamento",
        "dipartimento", "county", "condado", "contea", "landkreis", "estado", "distrito", "distretto", "oblast",
        "νομος", "περιφερεια", "επαρχια",
        "north", "south", "east", "west", "northern", "southern", "eastern", "western", "nord", "norte",
        "oriental", "occidental", "meridional", "septentrional", "nordliche", "sudliche", "ostliche",
        "westliche",
        "islands", "islas", "isole", "iles", "inseln", "eilanden", "ilhas", "adalari", "oarna", "oer",
        "oerne", "oyane", "oyene", "archipelago", "archipel", "arcipelago", "archipielago", "arquipelago",
        "quan", "νησια", "νησοι", "제도", "군도",
        "지방", "지역", "자유주", "자치주", "남부", "북부", "동부", "서부", "중부",
        "νοτιο", "νοτια", "βορειο", "βορεια", "κεντρικη", "δυτικη", "ανατολικη",
        "guney", "kuzey", "dogu", "bati",
    ]

    /// Words of stored administrative names that only say what kind of
    /// area they are ("County Cork", "Comunidad de Madrid", "Città
    /// Metropolitana di Roma Capitale", "Kyoto Prefecture", "Freistaat
    /// Bayern"), in the supported languages, native normalized form. An
    /// administrative area's name is whole without them, a place's is not
    /// ("Seo District" is no Seo; `TripSearchDocument.GeographicName`); Han,
    /// kana and Hangul designators are suffixes (`administrativeSuffixes`).
    static let administrativeDesignators: Set<String> = [
        "county", "province", "prefecture", "region", "state", "district", "municipality", "department",
        "community", "metropolitan", "borough", "parish", "governorate", "territory",
        "landkreis", "kreis", "bezirk", "regierungsbezirk", "provinz", "kanton", "freistaat", "gemeinde",
        "departement", "communaute", "metropole", "arrondissement", "canton", "commune",
        "provincia", "regione", "comune", "metropolitana", "capitale",
        "comunidad", "autonoma", "departamento", "municipio", "distrito", "estado",
        "regiao", "concelho", "provincie", "gemeente", "fylke", "lan", "amt",
        "ili", "ilcesi", "tinh", "huyen", "quan", "pho",
        "νομος", "περιφερεια", "δημος", "περιφερειακη", "ενοτητα",
    ]

    /// Compass and position qualifiers of administrative names ("Central
    /// Macedonia", "Northern Ireland", "Nordrhein"), native normalized form:
    /// such an area is the qualified name, not another one ("New Mexico").
    static let compassWords: Set<String> = [
        "north", "south", "east", "west", "northern", "southern", "eastern", "western", "central",
        "upper", "lower", "nord", "sud", "ost", "mittel", "ober", "nieder", "est", "ouest", "centre",
        "norte", "sur", "este", "oeste", "centro", "ovest", "centrale", "sul", "leste",
        "noord", "zuid", "oost", "midden", "syd", "vest", "vast", "mellersta",
        "kuzey", "guney", "dogu", "bati", "orta", "bac", "nam", "dong", "tay", "trung",
        "βορεια", "νοτια", "ανατολικη", "δυτικη", "κεντρικη", "βορειο", "νοτιο",
        "oriental", "occidental", "meridional", "septentrional", "nordliche", "sudliche", "ostliche",
        "westliche", "남부", "북부", "동부", "서부", "중부",
    ]

    /// Dropped from segmented Han and kana alternatives.
    static let cjkParticles: Set<String> = ["の", "と", "之", "的"]

    /// Greek genitive endings, native normalized form (final sigma folds
    /// to σ), longest first.
    static let greekEndings: [String] = ["ου", "ων", "σ", "ς"]

    /// Connecting words inside multi-word country names ("United States of
    /// America", "Bosnia and Herzegovina", "Côte d’Ivoire"). They are not
    /// whole words of the country field (compounds keep them; a leading
    /// article such as "La Réunion" stays) and a recognized phrase does not
    /// require them literally.
    static let nameStopWords: Set<String> = [
        "of", "and", "the", "d", "l", "de", "du", "des", "la", "le", "et", "del", "y", "e", "di",
        "da", "do", "dos", "das", "en", "van", "het", "und", "og", "och", "ve", "va", "και",
    ]

    /// Trailing Hangul particles, longest first.
    static let hangulParticles: [String] = [
        "에서", "으로", "까지", "부터",
        "의", "에", "로", "와", "과", "은", "는", "이", "가", "을", "를", "도",
    ]

    /// Foreign-language country names that are ordinary English words or
    /// names ("Island" is Iceland in de, da, nb and sv; "Granada" is Grenada
    /// in es). They never become a country-code alternative.
    static let foreignNameExclusions: Set<String> = [
        "island", "chili", "suede", "grenade", "somali", "argentine",
        "ascension", "dominique", "maurice", "norfolk", "granada", "georgie",
        "guiana",
    ]

    /// ISO 639-1 languages whose name is also one country's adjective, and
    /// that country: the one the adjective names, not where most speakers
    /// live (Portuguese is Portugal, Spanish is Spain). Chinese and Korean
    /// are China and South Korea, as their curated aliases. Left out:
    /// languages of several countries (English, Arabic, Malay, Samoan), of
    /// a region or people (Welsh, Catalan, Kurdish, Tibetan, Khmer, Somali),
    /// of a country with another adjective (Hebrew, Persian, Hindi, Urdu,
    /// Swahili) and Macedonian (a Greek region too).
    static let nationalLanguages: [String: String] = [
        "az": "AZ", "be": "BY", "bg": "BG", "bs": "BA", "cs": "CZ", "da": "DK", "de": "DE",
        "el": "GR", "es": "ES", "et": "EE", "fi": "FI", "fj": "FJ", "fo": "FO", "fr": "FR",
        "ga": "IE", "hr": "HR", "hu": "HU", "hy": "AM", "id": "ID", "is": "IS", "it": "IT",
        "ja": "JP", "ka": "GE", "kk": "KZ", "ko": "KR", "ky": "KG", "lb": "LU", "lo": "LA",
        "lt": "LT", "lv": "LV", "mg": "MG", "mn": "MN", "mt": "MT", "my": "MM", "ne": "NP",
        "nl": "NL", "no": "NO", "pl": "PL", "pt": "PT", "ro": "RO", "ru": "RU", "sk": "SK",
        "sl": "SI", "sq": "AL", "sr": "RS", "sv": "SE", "tg": "TJ", "th": "TH", "tk": "TM",
        "to": "TO", "tr": "TR", "uk": "UA", "uz": "UZ", "vi": "VN", "zh": "CN",
    ]

    /// UN M49 codes whose English and app-language names are region words
    /// (003 North America: 021, 013 and 029).
    static let regionCodes: [String] = [
        "002", "003", "005", "009", "011", "013", "014", "015", "017", "018", "019",
        "021", "029", "030", "034", "035", "039", "053", "054", "057", "061",
        "142", "143", "145", "150", "151", "154", "155", "419",
    ]

    /// English region words Locale does not name. Values are ISO codes or
    /// M49 codes (expanded to their ISO members).
    static let regionExtras: [String: [String]] = [
        "north america": ["021", "013", "029"],
        "central america": ["013"],
        "middle east": ["BH", "CY", "EG", "IR", "IQ", "IL", "JO", "KW", "LB",
                        "OM", "PS", "QA", "SA", "SY", "TR", "AE", "YE"],
        "scandinavia": ["DK", "NO", "SE"],
        "nordics": ["DK", "FI", "IS", "NO", "SE"],
        "nordic": ["DK", "FI", "IS", "NO", "SE"],
        "balkans": ["AL", "BA", "BG", "GR", "HR", "ME", "MK", "RS", "SI", "XK", "RO"],
        "balkan": ["AL", "BA", "BG", "GR", "HR", "ME", "MK", "RS", "SI", "XK", "RO"],
        "benelux": ["BE", "NL", "LU"],
        "british isles": ["GB", "IE", "IM", "JE", "GG"],
        "southeast asia": ["035"],
        "south east asia": ["035"],
        // Short forms of the CLDR names (Eastern Asia, Western Africa, ...).
        "east asia": ["030"],
        "south asia": ["034"],
        "west asia": ["145"],
        "north africa": ["015"],
        "west africa": ["011"],
        "east africa": ["014"],
        "central africa": ["017"],
        "east europe": ["151"],
        "west europe": ["155"],
        "north europe": ["154"],
        "south europe": ["039"],
        "central europe": ["AT", "CH", "CZ", "DE", "HU", "LI", "PL", "SK", "SI"],
        "oceania": ["009"],
        "latin america": ["419"],
    ]

    /// Commonly counted as European although M49 files them under Asia.
    static let europeExtras: Set<String> = ["CY", "TR"]

    /// Longest phrase (in query words) the recognizer tries.
    static let maxPhraseWords = 3

    // MARK: - Locale names

    private static let englishLocaleKey = "en_US"
    private static let countryNameCache = OSAllocatedUnfairLock(
        initialState: [String: String?]())

    /// `Locale.localizedString(forRegionCode:)` for the app language, cached
    /// per (code, languageTag). `english: true` pins en_US.
    static func countryName(
        _ code: String,
        languageTag: String,
        english: Bool = false
    ) -> String? {
        let key = (english ? englishLocaleKey : languageTag) + "|" + code
        if let cached = countryNameCache.withLock({ $0[key] }) { return cached }
        let locale = english
            ? Locale(identifier: englishLocaleKey)
            : AppLanguagePreference.locale(for: languageTag)
        let name = locale.localizedString(forRegionCode: code)
        countryNameCache.withLock { $0[key] = .some(name) }
        return name
    }

    // MARK: - Query-side recognition

    /// ISO codes a normalized phrase names, or nil. `key` is the native
    /// normalized form of 1 to `maxPhraseWords` query words joined by one
    /// space. Region words and country names come from every supported
    /// language (`makeRegionTable`), country names also from the curated
    /// aliases.
    static func countryCodes(forPhrase key: String, languageTag: String) -> Set<String>? {
        let region = regionTable(languageTag: languageTag)[key]
        let country = foreignCountryNames[key]
        switch (region, country) {
        case let (region?, country?): return region.union(country)
        case let (region?, nil): return region
        case let (nil, country?): return country
        case (nil, nil): return nil
        }
    }

    /// True when the native normalized `key` names a country in any
    /// supported language or by a curated alias ("monaco", "mexico").
    static func isCountryName(_ key: String) -> Bool {
        foreignCountryNames[key] != nil
    }

    /// Forces the lazily built tables, for callers that prefer to pay the
    /// one-time Locale cost off the main thread.
    static func prewarm(languageTag: String) {
        _ = foreignCountryNames.count
        _ = regionTable(languageTag: languageTag).count
    }

    /// Normalized recognition key of a display name: native form, words
    /// joined by one space.
    static func phraseKey(_ value: String) -> String {
        TripSearchText.words(TripSearchText.nativeForm(value)).joined(separator: " ")
    }

    private static let isoCodes: [String] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isLetter } && !partCodes.contains($0) }

    /// Exceptionally reserved codes Locale lists as regions that are parts
    /// of a country, whose code a stay stores instead: Ascension, Clipperton,
    /// Diego Garcia, Ceuta and Melilla, the Canary Islands, Tristan da
    /// Cunha. Their names are region names ("Canarias" is a Spanish region),
    /// never a country no trip could have.
    static let partCodes: Set<String> = ["AC", "CP", "DG", "EA", "IC", "TA"]

    /// Country names in all supported languages (Latin names shorter than
    /// four letters and the exclusions are skipped), language names as
    /// their country's adjective, plus curated aliases and abbreviations.
    private static let foreignCountryNames = makeForeignCountryNames()

    static func makeForeignCountryNames() -> [String: Set<String>] {
        var table: [String: Set<String>] = [:]
        let locales = AppLanguagePreference.supportedTags.sorted().map { Locale(identifier: $0) }
            + [Locale(identifier: englishLocaleKey)]
        for code in isoCodes {
            for locale in locales {
                guard let name = locale.localizedString(forRegionCode: code) else { continue }
                var variants = [name]
                if name.contains("&") {
                    variants.append(name.replacingOccurrences(of: "&", with: "and"))
                }
                for variant in variants {
                    let key = phraseKey(variant)
                    guard !key.isEmpty, !foreignNameExclusions.contains(key) else { continue }
                    if TripSearchText.isLatinScript(key),
                       key.unicodeScalars.filter({ $0 != " " }).count < 4 {
                        continue
                    }
                    table[key, default: []].insert(code)
                }
            }
        }
        // A language's name in most languages is also its country's
        // adjective ("Greek islands", "ελληνικά νησιά", "Spanish trips"), for
        // the reviewed `nationalLanguages`, Latin names shorter than five
        // letters skipped (Thai, Lao).
        for (language, region) in nationalLanguages {
            for locale in locales {
                guard let name = locale.localizedString(forLanguageCode: language) else { continue }
                let key = phraseKey(name)
                guard !key.isEmpty, !foreignNameExclusions.contains(key) else { continue }
                if TripSearchText.isLatinScript(key), key.unicodeScalars.filter({ $0 != " " }).count < 5 { continue }
                table[key, default: []].insert(region)
            }
        }
        for (code, aliases) in countryAliases.merging(queryCountryAliases, uniquingKeysWith: +) {
            for alias in aliases {
                let key = phraseKey(alias)
                if !key.isEmpty { table[key, default: []].insert(code) }
            }
        }
        return table
    }

    private static let regionTables = OSAllocatedUnfairLock(
        initialState: [String: [String: Set<String>]]())

    private static func regionTable(languageTag: String) -> [String: Set<String>] {
        if let table = regionTables.withLock({ $0[languageTag] }) { return table }
        let built = makeRegionTable(languageTag: languageTag)
        regionTables.withLock { $0[languageTag] = built }
        return built
    }

    /// Region words of English, the app language and every other supported
    /// language (a Greek speaker using the app in English still types
    /// `Ευρώπη`). Another language's name never adds a region to a country
    /// name or alias (Spanish `América` stays the curated alias of the US
    /// unless the app is in Spanish).
    static func makeRegionTable(languageTag: String) -> [String: Set<String>] {
        var table: [String: Set<String>] = [:]
        let english = Locale(identifier: englishLocaleKey)
        let appLocale = AppLanguagePreference.locale(for: languageTag)
        let others = AppLanguagePreference.supportedTags.sorted().map { Locale(identifier: $0) }
        for code in regionCodes {
            guard let members = regionMembers[code], !members.isEmpty else { continue }
            for locale in [english, appLocale] {
                guard let name = locale.localizedString(forRegionCode: code) else { continue }
                let key = phraseKey(name)
                if !key.isEmpty { table[key, default: []].formUnion(members) }
            }
            for locale in others {
                guard let name = locale.localizedString(forRegionCode: code) else { continue }
                let key = phraseKey(name)
                guard !key.isEmpty, table[key] != nil || !isCountryName(key) else { continue }
                table[key, default: []].formUnion(members)
            }
        }
        for (phrase, codes) in regionExtras {
            let members = codes.reduce(into: Set<String>()) { result, code in
                if code.first?.isNumber == true {
                    result.formUnion(regionMembers[code] ?? [])
                } else {
                    result.insert(code)
                }
            }
            table[phraseKey(phrase), default: []].formUnion(members)
        }
        return table
    }

    /// ISO members of every region code (Europe with its extras), computed once.
    private static let regionMembers: [String: Set<String>] = {
        var parents: [String: [String]] = [:]
        for iso in isoCodes {
            let region = Locale.Region(iso)
            for parent in [region.continent, region.subcontinent].compactMap({ $0?.identifier }) {
                parents[parent, default: []].append(iso)
            }
        }
        var members: [String: Set<String>] = [:]
        for code in regionCodes {
            var set = isoMembers(ofRegion: code).union(parents[code] ?? [])
            if code == "150" { set.formUnion(europeExtras) }
            members[code] = set
        }
        return members
    }()

    /// ISO members of an M49 region's sub-region tree.
    private static func isoMembers(ofRegion code: String) -> Set<String> {
        func leaves(_ region: Locale.Region, depth: Int) -> [String] {
            let subRegions = region.subRegions
            if subRegions.isEmpty || depth > 4 {
                return region.isISORegion && region.identifier.count == 2 ? [region.identifier] : []
            }
            return subRegions.flatMap { leaves($0, depth: depth + 1) }
        }
        return Set(leaves(Locale.Region(code), depth: 0))
    }
}
