#!/usr/bin/env python3
"""
Build TravelLog's bundled place-name table, `TravelLog/Resources/PlaceNames.sqlite`.

Localized trip titles name each place in the app language from this table
(`PlaceNameTable` in the app); a place it has no name for keeps the
canonical spelling. Standard-library Python only.

# Inputs

- The bundled `Geocoder.sqlite` (`--geocoder`): its `city` table is the set
  of places a stay's locality can name, its `island` table (OpenStreetMap,
  ODbL) the islands a stay's island can name, and their names are the
  stored form the table is keyed by.
- GeoNames `alternateNamesV2.zip` (`--alternate-names`, CC BY 4.0), from
  https://download.geonames.org/export/dump/alternateNamesV2.zip. Downloaded
  into `.build-cache/geocoder/` when missing. An extracted `.txt`, or a TSV
  with the same columns already filtered to the needed rows, also works.
- GeoNames `allCountries.zip` (`--geonames`, CC BY 4.0), from
  https://download.geonames.org/export/dump/allCountries.zip, for its
  island features, island groups, second-level divisions and the division
  of each city and island. Downloaded likewise; an extracted `.txt` also
  works.
- GeoNames `admin1CodesASCII.txt` and `admin2Codes.txt` (`--admin1-codes`,
  `--admin2-codes`, CC BY 4.0), from the same folder: the feature of each
  first- and second-level division code. Downloaded likewise.

# Run

    python3 scripts/build-place-names.py
    python3 scripts/build-place-names.py --alternate-names /path/alternateNamesV2.zip \
        --geonames /path/allCountries.zip

# What it keeps

Keys: `(name_key, iso_country, layer)`. A `city` row's `name_key` is the
city name as stays store it (GeoNames `name` before any trailing "[qualifier]", diacritics
stripped) folded like `TripTitleStore.normalizedPlaceName` (lowercased,
whitespace collapsed). A metro or region named like a city of its country
finds that city's names; English alternate names add keys only where no city
of that country already holds the key. A key several cities share belongs to
the most populous one.

Metro aliases: a metro (functional urban area, the geocoder's `fua` layer)
whose primary name no city of its country keys, not even by an English
alias, gets a key for the most populous city of that country inside its
polygon, when one name is a whole-word prefix of the other ("New York" ->
New York City, "Jerez" -> Jerez de la Frontera). The polygon keeps a
namesake elsewhere in the country from answering for the metro.

Stored codes: a stay stores the country code of the admin-1 polygon it lies
in, before its city's (`GeocodeResolver.resolve`), and the metro part it
lies in is the one in its own country. So a city, metro or island row keyed
under a territory's GeoNames code that no admin-1 polygon carries (MQ, GP,
RE, YT, GF under FR; BQ under NL; SJ under NO: the code of most of the
polygons holding its cities) gets the same key under the code its stays
store, and a cross-border metro's part the table cannot key (Basel in DE,
Singapore in MY) takes the key of the most populous part of that name in
another country whose box meets its own. Either only where that country
has no key of its own, and an island key islands of two of a country's
territories carry is left out, as above.

Islands: an `island` row keys an island of the geocoder by its stored name
(`name_en`, else its Latin `name`, diacritics stripped; a non-Latin name is
stored through ICU Any-Latin, which this script cannot mirror) and names it
with the GeoNames island (feature ISL, ISLET, ISLT or ATOL; never an island
group or section) whose point lies in that island's polygon, or within
0.05 degrees of its box, under any GeoNames spelling of that name, with or
without a word for island ("Corsica" is GeoNames' "Corsica Island", "Samos"
its "Nisí Sámos", "Poros" its "Nísos Póros"). Its country is that
island's: a stay's island is looked up in the stay's country. Several
matches prefer, in order: a point inside the polygon; an island over an
islet; the GeoNames name over an alternate one; population; the oldest
feature. A key several geocoder islands of a country carry is left out
unless they all match the same GeoNames island (one island drawn twice):
two islands of one name ("Nakanoshima" of Oki and of Osaka) cannot be told
apart by a stay's name and country, and neither may lend the other its
names. An island no GeoNames island matches counts in the country of its
nearest geocoder city.
An island GeoNames does not link to Wikipedia takes only names in another
script and accented spellings of its own name: its other Latin names are
mostly local variants and misspellings ("Åkerøya" for Agerøya), which would
rename a local's own island.
A title's island never takes a city's names, nor a city an island's.

Regions and groups (search only; titles never read them): a `region` row
keys a GeoNames first-level division by its geocoder `admin1_name`
spelling (the GeoNames region trip search derives for a stay, "Andalusia")
and by each English name of it no other division of its country has
("Okinawa Prefecture", the Natural Earth name a stay may store). A `group`
row keys, under a city's or island's own key, the island group it lies in:
a GeoNames second-level division that shares a name with an island group
(ISLS) GeoNames places in it (Cyclades, Dodecanese;
not Mishima city and the Mishima islands elsewhere in Japan) and in which
GeoNames places at least two islands (Vestmannaeyjar too, though its town
shares its name), named
from the group and then the division, with an English (`en`) name too,
else its English Wikipedia title; a group keeps every name, its English one
included. Trip search finds a stay's group by the GeoNames id of the city
nearest it, so a group row is keyed by every such city's id; by an island's
key; and by a city name only when every city of the country so named lies
in the group (three Greek Plakas, one on Milos, never all take the
Cyclades). One name per language, preferring, in order: in Japanese, a
name with Han characters over a kana-only reading (沖縄県 over
おきなわけん; a foreign region has only kana); a Latin name GeoNames
marks preferred or short, the common one ("Bayern", "País Vasco",
"Penghu County" over the old "Hoko Group"; in Greek or Korean a marked
designator form binds the name, Επαρχία Λεμεσού, so it waits; a group's
English short name is its division's, so it waits for the group's own,
"Hebrides" over "Western Isles"); a name
without an administrative word or a word for a group of islands
("Andalucía" over "Comunidad Autónoma de Andalucía", "Κυκλάδες" over
"Νομός Κυκλάδων" and "Νησιά Κυκλάδες"; never judged in Chinese or
Japanese, whose suffix may be the name itself, 北海道, and which search
reads without one); the group's own name over its division's; GeoNames'
preferred name; a short name; monotonic Greek; the oldest row. Never an
abbreviation ("PACA"). A Korean designator 주 or 도 becomes a word of its
own (`korean_designator_word`), which search drops; a 도 ending the name
itself stays (홋카이도). A region's name is kept only when it differs from
the GeoNames name; a group keeps all. `AREA_NAME_CHECKS` fails the build
when the selection loses a known name (北海道, Bayern, País Vasco,
홋카이도, Hebrides).

Names: one per (place, language), never colloquial, historic or
time-bounded, in the language's own script, without list punctuation or
digits, and only when it differs from the canonical spelling. The choice
prefers, in order: GeoNames' preferred name; monotonic over polytonic Greek;
a full over a short name; the oldest row. GeoNames flags many common
exonyms as both preferred and short ("Londres", "Moscou", "Niza"), so a
short name counts when it is preferred, not an abbreviation (no period) and
not the name of another city of the country, which it would name instead
("Camboriú" is a neighbour of Balneário Camboriú); unpreferred short names
are mostly truncations. A row that merely copies the canonical spelling
never hides an equally ranked row giving the city's own GeoNames name with
its diacritics ("Kraków" for "Krakow"); it does hold off other unflagged
names, which are as often local alternatives or regions as exonyms. An
island prefers, before all of these, a name without a word for island
("Sicilia" over the preferred "Isola di Sicilia"), and one that is only its
canonical spelling with that word counts as a copy of it ("Isola Corsica");
Greek drops the word ("Νησί Σπέτσες" is Σπέτσες) unless the canonical
spelling has one ("Νήσος Γουάιτ" for Isle of Wight), and Chinese, Japanese
and Korean names keep it (マヨルカ島). An island never takes a name of an area or group it lies in
or belongs to: one carrying a word for an administrative area, a protected
area or a group of islands ("Provincia di Cebu", "Nationalpark Gotska
Sandön", "Archipel de Vega", "怀特岛郡", "萊夫卡斯州"; a Han name its
Japanese and Chinese names agree on is its own, as 九州), or its canonical spelling with
other words than one for island around it ("Bornholms Amt"). Polytonic Greek is folded to monotonic (breathings and iota
subscripts dropped, perispomeni and varia read as tonos). App languages map
from GeoNames codes: nb from nb/no; pt-BR rows override pt for pt-BR, and
pt-PT reads pt; zh-Hans from zh-Hans/zh-CN/zh; zh-Hant from
zh-Hant/zh-TW/zh-HK. Where no Traditional name exists the app converts the
Simplified one at runtime (ICU Hans-Hant).

The table's `meta` records each input's SHA-256, the date it was
downloaded (its modification date) and, for a GeoNames zip, the dump's date;
`--expect-sha256 KIND=HEX` (geocoder, alternate-names, geonames) refuses an
input that differs.

Licence: the table is a derivative of OpenStreetMap's island names and is
made available under the ODbL 1.0, with GeoNames names under CC BY 4.0
(`meta.licence`, THIRD_PARTY_NOTICES.md).

Bump `TripTitleStore.currentGenerationVersion` when a rebuild changes names
existing installs have already stored.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import io
import math
import os
import re
import sqlite3
import sys
import unicodedata
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GEOCODER_PATH = REPO_ROOT / "TravelLog" / "Resources" / "Geocoder.sqlite"
OUTPUT_PATH = REPO_ROOT / "TravelLog" / "Resources" / "PlaceNames.sqlite"
CACHE_DIR = Path(os.environ.get(
    "TRAVELLOG_GEOCODER_CACHE", REPO_ROOT / ".build-cache" / "geocoder"))
ALTERNATE_NAMES_URL = "https://download.geonames.org/export/dump/alternateNamesV2.zip"
ALL_COUNTRIES_URL = "https://download.geonames.org/export/dump/allCountries.zip"
ADMIN1_CODES_URL = "https://download.geonames.org/export/dump/admin1CodesASCII.txt"
ADMIN2_CODES_URL = "https://download.geonames.org/export/dump/admin2Codes.txt"

LICENCE = (
    "This database is made available under the Open Database License 1.0 "
    "(https://opendatacommons.org/licenses/odbl/1-0/): its island keys are "
    "names (c) OpenStreetMap contributors (https://www.openstreetmap.org/copyright). "
    "Place names from GeoNames (https://www.geonames.org/), CC BY 4.0 "
    "(https://creativecommons.org/licenses/by/4.0/); metro names from GHS-FUA "
    "R2019A, CC BY 4.0, (c) European Union, 2019. "
    "Attributions: THIRD_PARTY_NOTICES.md in "
    "https://github.com/konstantinosfragkoulis/TravelLog"
)

# Stored language -> GeoNames codes, most specific first.
LANGUAGE_SOURCES = {
    "da": ["da"], "de": ["de"], "el": ["el"], "es": ["es"], "fr": ["fr"],
    "it": ["it"], "ja": ["ja"], "ko": ["ko"], "nb": ["nb", "no"], "nl": ["nl"],
    "pt": ["pt"], "pt-BR": ["pt-BR"], "sv": ["sv"], "tr": ["tr"], "vi": ["vi"],
    "zh-Hans": ["zh-Hans", "zh-CN", "zh"], "zh-Hant": ["zh-Hant", "zh-TW", "zh-HK"],
}
SOURCE_TO_LANGUAGE = {
    source: (language, rank)
    for language, sources in LANGUAGE_SOURCES.items()
    for rank, source in enumerate(sources)
}
ALIAS_SOURCE = "en"

# The script a language's names must be written in (Unicode name prefixes).
LATIN = ("LATIN",)
SCRIPTS = {
    "el": ("GREEK",),
    "ja": ("CJK", "HIRAGANA", "KATAKANA"),
    "ko": ("HANGUL",),
    "zh-Hans": ("CJK",),
    "zh-Hant": ("CJK",),
}
# Name punctuation; anything else (commas, ampersands, brackets, slashes,
# digits) would break a title's list or carries a qualifier.
ALLOWED_PUNCTUATION = set(" -'’.·・‐‑")

# GeoNames island feature codes (class T) and their rank: an island before
# an islet, a land-tied island or an atoll.
ISLAND_CODES = {"ISL": 0, "ISLET": 1, "ISLT": 1, "ATOL": 1}
# How far (degrees) outside an island's polygon, within its box widened so,
# a GeoNames point still names it: points sit on simplified coastlines.
ISLAND_NEAR_DEGREES = 0.05
# A word for island around a folded Latin name, with its connector, as
# GeoNames spells many islands ("Nisí Sámos", "Isla de Ometepe", "Skiathos
# Island").
LATIN_ISLAND_WORD = re.compile(
    r"^(nisi|nisos|nisis|nisida|isla|isola|ile|ilha|insel|isle of|island of)"
    r"\s+(de\s+la\s+|del?\s+|di\s+|d['’]|d[ao]\s+|du\s+|of\s+)?"
    r"|\s+(island|isle|islet)$")

# A word for one island, islet or atoll before or after an island's name, with its
# connector, by language (see Names). Not in Chinese, Japanese or Korean,
# whose island names carry it (マヨルカ島).
ISLAND_WORDS = {
    language: re.compile(pattern, re.IGNORECASE)
    for language, pattern in {
        "de": r"^(insel|atoll)\s+",
        "el": r"^(νησί|νησίς|νησίδα|νησάκι|νήσος|βραχονησίς|βραχονησίδα|βραχονήσι)\s+",
        "es": r"^(isla|atolón)\s+(de\s+l[ao]s?\s+|del?\s+)?",
        "fr": r"^([îi]le|atoll)\s+(de\s+la\s+|de\s+l['’]|d['’]|de\s+|du\s+|des\s+)?",
        "it": r"^(isola|atollo)\s+(di\s+|d['’]|del\s+|della\s+|delle\s+|dei\s+|degli\s+|dell['’])?",
        "nl": r"^(eiland|atol)\s+",
        "pt": r"^(ilha|atol)\s+(d[aeo]s?\s+)?", "pt-BR": r"^(ilha|atol)\s+(d[aeo]s?\s+)?",
        "tr": r"\s+adas[ıi]$",
        "vi": r"^đảo\s+",
    }.items()
}

# Words for something an island is not, or more than: an administrative
# area, a protected area or a group of islands ("Provincia di Cebu",
# "Nationalpark Gotska Sandön", "Archipel de Vega"). A Latin or Greek name
# with one as a word (or a Latin compound ending in one) never names an
# island; a Chinese, Japanese or Korean name never ends in one, unless the
# island's Japanese and Chinese names agree on it (九州, 本州).
LATIN_NON_ISLAND_WORDS = re.compile(
    r"(?<!\w)(province|provincia|provinz|provincie|provins|provinsen|provinsi|"
    r"municipality|municipio|município|municipalité|municipalità|comune|commune|"
    r"gemeente|county|condado|contea|comté|kreis|fylke|län|amt|kunta|"
    r"region|regione|región|région|regio|regionen|department|département|"
    r"departamento|dipartimento|district|distrito|distretto|bezirk|distrikt|"
    r"parish|paroisse|parroquia|prefecture|préfecture|prefettura|prefectura|"
    r"präfektur|prefeitura|bailiwick|bailliage|governorate|gouvernorat|oblast|okrug|"
    r"national park|parc national|parco nazionale|parque nacional|nationaal park|"
    r"reserve|réserve|reserva|riserva|reservaat|archipelago|archipel|archipiélago|"
    r"arcipelago|arquipélago|archipelag|islands|islas|isole|îles|iles|ilhas|inseln|"
    r"eilanden|øyane|øyene|øyer|øer|øerne|öarna|öar|ili|ilçesi|bölgesi|eyaleti|"
    r"milli parkı|takımadaları|adaları|tỉnh|huyện|quận|thành phố|quần đảo|"
    r"vườn quốc gia)(?!\w)"
    r"|(kommune|kommun|gemeinde|landkreis|nationalpark|nasjonalpark|naturreservat|"
    r"naturschutzgebiet|skärgård|skärgården|skjærgård|skjærgården|skærgård|skærgården|"
    r"öarna|øyane|øyene|øerne|inseln|eilanden)(?!\w)",
    re.IGNORECASE)
GREEK_NON_ISLAND_WORDS = re.compile(
    r"(?<!\w)(νομός|περιφέρεια|περιφερειακή|δήμος|επαρχία|κοινότητα|δρυμός|"
    r"πάρκο|αρχιπέλαγος|νησιά|νήσοι|νησίδες|νησάκια|σύμπλεγμα)(?!\w)",
    re.IGNORECASE)
CJK_NON_ISLAND_SUFFIXES = (
    "県", "郡", "市", "町", "村", "区", "區", "州", "省", "县", "縣", "支庁", "振興局",
    "諸島", "列島", "群島", "群岛", "列岛", "诸岛", "国立公園", "国家公园", "國家公園",
    "自治区", "自治區", "特别行政区", "特別行政區",
    "군", "시", "주", "군도", "제도", "열도", "국립공원", "특별자치도",
)


def names_non_island(name: str, language: str, han_names: dict[str, set[str]]) -> bool:
    """Whether `name` names an area or group rather than an island (see
    Names). `han_names` holds the island's Japanese ("ja") and Chinese
    ("zh") names: a Han name both give is the island's own, suffix and all
    (九州, 本州), while a suffix only one gives is its area's (萊夫卡斯州)."""
    if language in ("ja", "ko", "zh-Hans", "zh-Hant"):
        compact = name.replace(" ", "")
        return compact.endswith(CJK_NON_ISLAND_SUFFIXES) and not (
            name in han_names.get("ja", ()) and name in han_names.get("zh", ()))
    if language == "el":
        return bool(GREEK_NON_ISLAND_WORDS.search(name))
    return bool(LATIN_NON_ISLAND_WORDS.search(name))


def wraps_canonical(name: str, canonical: str, language: str) -> bool:
    """Whether `name` is the canonical name with other words around it, not
    only a word for island ("Bornholms Amt", "Archipel de Vega")."""
    key, canonical_key = name_key(strip_diacritics(name)), name_key(canonical)
    if key == canonical_key or not re.search(
            r"(?<!\w)" + re.escape(canonical_key) + r"(?!\w)", key):
        return False
    rest = without_island_word(name, language)
    return rest is None or name_key(strip_diacritics(rest)) != canonical_key


def without_island_word(name: str, language: str) -> str | None:
    """`name` without its word for island (`ISLAND_WORDS`), or nil without one."""
    pattern = ISLAND_WORDS.get(language)
    match = pattern.search(name) if pattern else None
    if match is None:
        return None
    rest = (name[:match.start()] + name[match.end():]).strip()
    return rest or None


# Polytonic Greek marks: dropped (psili, dasia, iota subscript, macron,
# breve) or read as the monotonic tonos (perispomeni, varia).
POLYTONIC_DROPPED = {"\u0313", "\u0314", "\u0345", "\u0304", "\u0306"}
POLYTONIC_TO_TONOS = {"\u0342", "\u0300"}
TONOS = "\u0301"


def monotonic_greek(value: str) -> tuple[str, bool]:
    """A Greek name in monotonic spelling, and whether it was polytonic."""
    decomposed = unicodedata.normalize("NFD", value)
    if not any(ch in POLYTONIC_DROPPED or ch in POLYTONIC_TO_TONOS for ch in decomposed):
        return value, False
    out: list[str] = []
    for ch in decomposed:
        if ch in POLYTONIC_DROPPED:
            continue
        if ch in POLYTONIC_TO_TONOS:
            ch = TONOS
        if ch == TONOS and out and out[-1] == TONOS:
            continue
        out.append(ch)
    return unicodedata.normalize("NFC", "".join(out)), True


def load_geocoder_builder():
    """`build-geocoder-db.py`, for its WKB decoder and longitude helper."""
    spec = importlib.util.spec_from_file_location(
        "build_geocoder_db", Path(__file__).resolve().with_name("build-geocoder-db.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ring_contains(ring: list[list[float]], lon: float, lat: float, wrapped) -> bool:
    """`GeoMath.pointInPolygon`: ray casting, unwrapped around the first vertex."""
    if len(ring) < 3:
        return False
    ref = ring[0][0]
    px = ref + wrapped(lon, ref)
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ref + wrapped(ring[i][0], ref), ring[i][1]
        xj, yj = ref + wrapped(ring[j][0], ref), ring[j][1]
        if (yi > lat) != (yj > lat) and px < (xj - xi) * (lat - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def geometry_contains(geometry: dict, lon: float, lat: float, wrapped) -> bool:
    """`GeocodeResolver`'s polygon test: in an outer ring and in none of its holes."""
    polygons = ([geometry["coordinates"]] if geometry["type"] == "Polygon"
                else geometry["coordinates"])
    for rings in polygons:
        if rings and ring_contains(rings[0], lon, lat, wrapped) and not any(
                ring_contains(hole, lon, lat, wrapped) for hole in rings[1:]):
            return True
    return False


def is_word_prefix(shorter: str, longer: str) -> bool:
    return longer.startswith(shorter + " ")


def metro_aliases(
    geocoder: sqlite3.Connection,
    cities: dict[int, tuple[str, str, int]],
    keyed: set[tuple[str, str]],
) -> dict[tuple[str, str], int]:
    """(metro key, iso) -> the city a metro the table cannot key names (see Metro aliases)."""
    builder = load_geocoder_builder()
    wrapped = builder.wrapped_lon_delta
    # Every city, Latin or not, so "most populous" means just that.
    by_country: dict[str, list[tuple[int, int, float, float]]] = {}
    for geoname_id, iso, population, lat, lon in geocoder.execute(
            "SELECT geoname_id, iso_country, population, lat, lon FROM city"):
        by_country.setdefault(iso, []).append((-(population or 0), geoname_id, lat, lon))
    for rows in by_country.values():
        rows.sort()

    aliases: dict[tuple[str, str], int] = {}
    for name, iso, wkb in geocoder.execute(
            "SELECT name, iso_country, wkb FROM fua ORDER BY uc_pop_2015 DESC, efua_id"):
        primary = primary_place_name(name)
        if not is_latin(primary):
            continue
        key = name_key(primary)
        if not key or (key, iso) in keyed or (key, iso) in aliases:
            continue
        geometry = builder.decode_wkb_to_geojson(wkb)
        min_lat, max_lat, min_lon, max_lon = builder.geometry_bbox(geometry)
        anchor = (geometry["coordinates"][0] if geometry["type"] == "Polygon"
                  else geometry["coordinates"][0][0])[0][0]

        def inside(lat: float, lon: float) -> bool:
            unwrapped = anchor + wrapped(lon, anchor)
            return (min_lat <= lat <= max_lat and min_lon <= unwrapped <= max_lon
                    and geometry_contains(geometry, lon, lat, wrapped))

        # The first city inside, in population order, is the most populous.
        largest = next(
            (geoname_id for _, geoname_id, lat, lon in by_country.get(iso, ())
             if inside(lat, lon)), None)
        if largest is None or largest not in cities:
            continue
        city_key = name_key(cities[largest][0])
        if is_word_prefix(key, city_key) or is_word_prefix(city_key, key):
            aliases[(key, iso)] = largest
    return aliases


def is_country_code(value: str | None) -> bool:
    """Whether `GeocodeResolver.sanitizedISOCountryCode` keeps `value` as is."""
    return bool(value) and len(value) == 2 and value.isascii() and value.isalpha() and value.isupper()


def territory_codes(geocoder: sqlite3.Connection) -> dict[str, str]:
    """City country code -> the code a stay there stores, for each code no
    admin-1 polygon carries (see Stored codes): the code of most of the
    admin-1 polygons holding its cities."""
    builder = load_geocoder_builder()
    wrapped = builder.wrapped_lon_delta
    carried = {iso for (iso,) in geocoder.execute("SELECT DISTINCT iso_country FROM admin1")}
    votes: dict[str, dict[str, int]] = {}
    for iso, lat, lon in geocoder.execute("SELECT iso_country, lat, lon FROM city").fetchall():
        if iso in carried:
            continue
        for admin_iso, wkb in geocoder.execute(
                "SELECT admin1.iso_country, admin1.wkb FROM admin1_rtree"
                " JOIN admin1 ON admin1.id = admin1_rtree.id"
                " WHERE min_lat <= ?1 AND max_lat >= ?1 AND min_lon <= ?2 AND max_lon >= ?2"
                " ORDER BY admin1.id", (lat, lon)).fetchall():
            if is_country_code(admin_iso) and geometry_contains(
                    builder.decode_wkb_to_geojson(wkb), lon, lat, wrapped):
                counts = votes.setdefault(iso, {})
                counts[admin_iso] = counts.get(admin_iso, 0) + 1
                break
    codes = {}
    for iso, counts in votes.items():
        stored, count = max(counts.items(), key=lambda item: (item[1], item[0]))
        if 2 * count > sum(counts.values()) and stored != iso:
            codes[iso] = stored
    return codes


def cross_border_metro_aliases(
    geocoder: sqlite3.Connection,
    owners: dict[tuple[str, str], tuple[int, int, int]],
) -> dict[tuple[str, str], int]:
    """(metro key, iso) -> the city that keys the metro's part in another
    country, for a metro part the table cannot key (see Stored codes)."""
    builder = load_geocoder_builder()
    parts: dict[str, list[tuple[str, int, tuple[float, float, float, float]]]] = {}
    for name, iso, population, wkb in geocoder.execute(
            "SELECT name, iso_country, uc_pop_2015, wkb FROM fua ORDER BY efua_id"):
        primary = primary_place_name(name)
        if is_latin(primary) and name_key(primary):
            parts.setdefault(name_key(primary), []).append(
                (iso, population or 0, builder.geometry_bbox(builder.decode_wkb_to_geojson(wkb))))
    aliases: dict[tuple[str, str], int] = {}
    for key, members in parts.items():
        if len({iso for iso, _, _ in members}) < 2:
            continue
        for iso, _, box in members:
            if (key, iso) in owners or (key, iso) in aliases:
                continue
            # The most populous part elsewhere that the table keys and whose
            # box meets this one's: a namesake far away never answers.
            cores = [
                (population, other) for other, population, other_box in members
                if other != iso and (key, other) in owners
                and other_box[0] <= box[1] and box[0] <= other_box[1]
                and other_box[2] <= box[3] and box[2] <= other_box[3]]
            if cores:
                aliases[(key, iso)] = owners[(key, max(cores)[1])][2]
    return aliases


def geometry_area(geometry: dict, wrapped) -> float:
    """An outer-ring area in square degrees scaled by latitude, for ranking."""
    polygons = ([geometry["coordinates"]] if geometry["type"] == "Polygon"
                else geometry["coordinates"])
    total = 0.0
    for rings in polygons:
        if not rings or len(rings[0]) < 3:
            continue
        ring = rings[0]
        ref = ring[0][0]
        xs = [ref + wrapped(x, ref) for x, _ in ring]
        ys = [y for _, y in ring]
        twice = sum(xs[i] * ys[i + 1] - xs[i + 1] * ys[i] for i in range(len(ring) - 1))
        total += abs(twice) / 2 * math.cos(math.radians(sum(ys) / len(ys)))
    return total


def open_geonames(path: Path) -> io.TextIOBase:
    if path.suffix == ".zip":
        archive = zipfile.ZipFile(path)
        member = next((name for name in archive.namelist() if name.endswith(".txt")), None)
        if member is None:
            raise SystemExit(f"{path} has no .txt member")
        return io.TextIOWrapper(archive.open(member), encoding="utf-8")
    return open(path, encoding="utf-8")


def geonames_islands(
        path: Path) -> dict[int, tuple[str, float, float, int, str, int, set[str], set[str]]]:
    """GeoNames islands: id -> (name, lat, lon, code rank, iso, population,
    keys of its name and ASCII name, keys of its other names)."""
    islands = {}
    with open_geonames(path) as rows:
        for line in rows:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 15 or fields[6] != "T" or fields[7] not in ISLAND_CODES:
                continue
            iso = fields[8]
            if len(iso) != 2:
                continue
            primary = {name_key(strip_diacritics(value)) for value in fields[1:3]
                       if value and is_latin(value)}
            others = {name_key(strip_diacritics(value)) for value in fields[3].split(",")
                      if value and "://" not in value and is_latin(value)}
            others |= {LATIN_ISLAND_WORD.sub("", key) for key in primary | others} - {""}
            islands[int(fields[0])] = (
                fields[1], float(fields[4]), float(fields[5]), ISLAND_CODES[fields[7]], iso,
                int(fields[14] or 0), primary, others - primary)
    return islands


def nearest_country(geocoder: sqlite3.Connection):
    """A function giving the country of the geocoder city nearest a point."""
    grid: dict[tuple[int, int], list[tuple[float, float, str]]] = {}
    for lat, lon, iso in geocoder.execute("SELECT lat, lon, iso_country FROM city"):
        grid.setdefault((math.floor(lat), math.floor(lon)), []).append((lat, lon, iso))

    def country(lat: float, lon: float) -> str | None:
        scale = math.cos(math.radians(lat))
        for radius in range(0, 6):
            best = None
            for dlat in range(-radius, radius + 1):
                for dlon in range(-radius, radius + 1):
                    cell = (math.floor(lat) + dlat, (math.floor(lon) + dlon + 180) % 360 - 180)
                    for clat, clon, iso in grid.get(cell, ()):
                        dx = ((clon - lon + 180) % 360 - 180) * scale
                        distance = (clat - lat) ** 2 + dx * dx
                        if best is None or distance < best[0]:
                            best = (distance, iso)
            if best is not None:
                return best[1]
        return None
    return country


def island_owners(
    geocoder: sqlite3.Connection,
    candidates: dict[int, tuple],
) -> tuple[dict[tuple[str, str], tuple[int, str, float]], int, int, int, set[tuple[str, str]]]:
    """(island key, iso) -> (GeoNames island, stored name, area) for the
    geocoder's islands (see Islands), with the counts of Latin and matched
    islands and of keys left out because islands of a country that carry
    them are not all the same GeoNames island, and every (key, iso) some
    geocoder island of that country carries, named or left out."""
    builder = load_geocoder_builder()
    wrapped = builder.wrapped_lon_delta
    by_key: dict[str, list[int]] = {}
    for geoname_id, island in candidates.items():
        for key in island[6] | island[7]:
            by_key.setdefault(key, []).append(geoname_id)

    # Every Latin island whose key some GeoNames island carries:
    # (key, stored, GeoNames match or None, its country or None, area, point).
    islands: list[tuple[str, str, int | None, str | None, float, tuple[float, float]]] = []
    latin = matched = 0
    for osm_id, name, name_en, wkb in geocoder.execute(
            "SELECT osm_id, name, name_en, wkb FROM island ORDER BY osm_id"):
        display = (name_en if name_en else name).strip()
        if not display or not is_latin(display):
            continue
        latin += 1
        stored = strip_diacritics(display)
        key = name_key(stored)
        ids = by_key.get(key)
        if not ids:
            continue
        geometry = builder.decode_wkb_to_geojson(wkb)
        min_lat, max_lat, min_lon, max_lon = builder.geometry_bbox(geometry)
        anchor = (geometry["coordinates"][0] if geometry["type"] == "Polygon"
                  else geometry["coordinates"][0][0])[0][0]
        best = None
        for geoname_id in ids:
            _, lat, lon, code_rank, iso, population, primary, _ = candidates[geoname_id]
            unwrapped = anchor + wrapped(lon, anchor)
            near = ISLAND_NEAR_DEGREES
            if not (min_lat - near <= lat <= max_lat + near
                    and min_lon - near <= unwrapped <= max_lon + near):
                continue
            inside = (min_lat <= lat <= max_lat and min_lon <= unwrapped <= max_lon
                      and geometry_contains(geometry, lon, lat, wrapped))
            rank = (0 if inside else 1, code_rank, 0 if key in primary else 1,
                    -population, geoname_id)
            if best is None or rank < best[0]:
                best = (rank, geoname_id, iso)
        if best is not None:
            matched += 1
        center = ((min_lat + max_lat) / 2, ((min_lon + max_lon) / 2 + 180) % 360 - 180)
        islands.append((key, stored, best[1] if best else None, best[2] if best else None,
                        geometry_area(geometry, wrapped), center))

    # An island no GeoNames island names counts in the country of its
    # nearest city, where a stay on it would be looked up.
    keyed = {island[0] for island in islands if island[2] is not None}
    country = nearest_country(geocoder)
    groups: dict[tuple[str, str], list[tuple]] = {}
    for key, stored, geoname_id, iso, area, center in islands:
        if key not in keyed:
            continue
        iso = iso or country(*center)
        if iso:
            groups.setdefault((key, iso), []).append((geoname_id, stored, area))
    owners: dict[tuple[str, str], tuple[int, str, float]] = {}
    ambiguous = 0
    for place, members in groups.items():
        ids = {member[0] for member in members}
        if len(ids) != 1 or None in ids:
            ambiguous += any(member[0] is not None for member in members)
            continue
        geoname_id, stored, area = max(members, key=lambda member: (member[2], member[1]))
        owners[place] = (geoname_id, stored, area)
    return owners, latin, matched, ambiguous, set(groups)


def primary_place_name(raw: str) -> str:
    """`GeocodeResolver.primaryPlaceName`: the name before a trailing " [qualifier]"."""
    if raw.endswith("]"):
        open_at = raw.rfind(" [")
        if open_at != -1:
            primary = raw[:open_at].strip()
            if primary:
                return primary
    return raw


def strip_diacritics(value: str) -> str:
    """ICU stripDiacritics on Latin text: ø, ł and ß stay letters."""
    decomposed = unicodedata.normalize("NFD", value)
    kept = "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")
    return unicodedata.normalize("NFC", kept)


def name_key(stored: str) -> str:
    """`TripTitleStore.normalizedPlaceName` of an already-Latin stored name."""
    return " ".join(strip_diacritics(stored).lower().split())


def is_latin(value: str) -> bool:
    return all(not ch.isalpha() or unicodedata.name(ch, "").startswith(LATIN) for ch in value)


def is_clean_name(value: str, language: str) -> bool:
    if not value or value != value.strip() or len(value) > 60:
        return False
    scripts = SCRIPTS.get(language, LATIN)
    has_letter = False
    for ch in value:
        category = unicodedata.category(ch)
        if category.startswith("L"):
            if not unicodedata.name(ch, "").startswith(scripts):
                return False
            has_letter = True
        elif category.startswith("M"):
            continue
        elif ch not in ALLOWED_PUNCTUATION:
            return False
    return has_letter


def open_alternate_names(path: Path) -> io.TextIOBase:
    if path.suffix == ".zip":
        archive = zipfile.ZipFile(path)
        member = next(
            (name for name in archive.namelist() if name.startswith("alternateNamesV2")
             and name.endswith(".txt")), None)
        if member is None:
            raise SystemExit(f"{path} has no alternateNamesV2.txt")
        return io.TextIOWrapper(archive.open(member), encoding="utf-8")
    return open(path, encoding="utf-8")


def source_metadata(kind: str, path: Path) -> dict[str, str]:
    """An input's SHA-256, download (modification) date and, for a zip, dump date."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    modified = datetime.datetime.fromtimestamp(path.stat().st_mtime, datetime.timezone.utc)
    meta = {f"source.{kind}.file": path.name,
            f"source.{kind}.sha256": digest.hexdigest(),
            f"source.{kind}.downloaded": modified.date().isoformat()}
    if path.suffix == ".zip":
        members = [info for info in zipfile.ZipFile(path).infolist()
                   if info.filename.endswith(".txt")]
        if members:
            dump = max(member.date_time for member in members)
            meta[f"source.{kind}.dump_date"] = datetime.date(*dump[:3]).isoformat()
    return meta


def download(url: str, size: str) -> Path:
    destination = CACHE_DIR / url.rsplit("/", 1)[1]
    if destination.exists():
        return destination
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {url} ({size})...")
    partial = destination.with_suffix(".zip.part")
    urllib.request.urlretrieve(url, partial)
    partial.rename(destination)
    return destination


# Words that make a name an area's official form rather than the name
# people use ("Comunidad Autónoma de Andalucía", "Région Normandie",
# "Nomós Kykládon", "Free State of Bavaria", "沖縄県", "토스카나 주"); a
# region or group prefers a name without one (see Regions and groups).
LATIN_AREA_WORDS = re.compile(
    r"(?<!\w)(province|provincia|provinz|provincie|provins|province of|municipality|municipio|"
    r"comune|commune|county|condado|contea|comté|kreis|landkreis|region|regione|región|région|"
    r"regio|região|department|département|departamento|dipartimento|district|distrito|"
    r"distretto|bezirk|prefecture|préfecture|prefettura|prefectura|präfektur|prefeitura|"
    r"governorate|oblast|okrug|comunidad|comunitat|comunidade|autónoma|autonoma|autonome|"
    r"autonomous|freistaat|free state|state|estado|stato|staat|bundesland|nomos|nomós|"
    r"regional unit|tỉnh|vùng|eyaleti|bölgesi|ili|islands|islas|isole|îles|iles|inseln|eilanden|"
    r"ilhas|adaları|öarna|øer|øerne|øyane|øyene|archipelago|archipel|arcipelago|archipiélago|"
    r"arquipélago|quần đảo)(?!\w)",
    re.IGNORECASE)
GREEK_AREA_WORDS = re.compile(
    r"(?<!\w)(νομός|περιφέρεια|περιφερειακή|ενότητα|επαρχία|δήμος|κοινότητα|νησιά|νήσοι|νησίδες|"
    r"σύμπλεγμα|αρχιπέλαγος)(?!\w)", re.IGNORECASE)
KOREAN_AREA_WORDS = {"주", "도", "현", "지방", "자유주", "특별자치도", "자치주", "지역", "제도", "군도"}
# An abbreviation ("PACA", "NRW") would take the language's one name.
ABBREVIATION = re.compile(r"[A-Z]{2,6}")


def is_area_form(name: str, language: str) -> bool:
    """Whether `name` is an area's official or administrative form, or
    carries a word for a group of islands. Never a Chinese or Japanese
    name: their suffix is often the name itself (北海道), and search reads
    them without it (`TripSearchAliases.regionSuffixes`)."""
    if language in ("ja", "zh-Hans", "zh-Hant"):
        return False
    if language == "ko":
        return name.split()[-1] in KOREAN_AREA_WORDS or name.endswith(("특별자치도", "자유주"))
    if language == "el":
        return bool(GREEK_AREA_WORDS.search(name))
    return bool(LATIN_AREA_WORDS.search(name))


def area_keys(fields: list[str]) -> set[str]:
    """The folded names of an allCountries row (name, ASCII name, alternates)."""
    values = [fields[1], fields[2]] + fields[3].split(",")
    return {key for key in (name_key(value) for value in values if value and "://" not in value)
            if len(key) >= 3}


def geonames_areas(path: Path, ids: set[int]) -> tuple[
        dict[int, str], dict[str, list[tuple[int, set[str]]]], dict[str, tuple[int, set[str]]],
        dict[str, int]]:
    """One allCountries pass: the admin-2 code ("ES.07.PM") of each of
    `ids` (cities and islands), the island groups (ISLS) in each
    second-level division with their folded names, and each second-level
    division (ADM2) by code with its folded names, and how many islands
    (ISL, ISLET, ISLT, ATOL) GeoNames places in each division."""
    codes: dict[int, str] = {}
    groups: dict[str, list[tuple[int, set[str]]]] = {}
    divisions: dict[str, tuple[int, set[str]]] = {}
    islands: dict[str, int] = {}
    with open_geonames(path) as rows:
        for line in rows:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 15:
                continue
            geoname_id = int(fields[0])
            iso, admin1, admin2 = fields[8], fields[10], fields[11]
            if geoname_id in ids and admin1 and admin2:
                codes[geoname_id] = f"{iso}.{admin1}.{admin2}"
            if fields[6] == "T" and fields[7] == "ISLS" and admin1 and admin2:
                groups.setdefault(f"{iso}.{admin1}.{admin2}", []).append((geoname_id, area_keys(fields)))
            elif fields[6] == "T" and fields[7] in ISLAND_CODES and admin1 and admin2:
                code = f"{iso}.{admin1}.{admin2}"
                islands[code] = islands.get(code, 0) + 1
            elif fields[6] == "A" and fields[7] == "ADM2" and admin1 and admin2:
                divisions[f"{iso}.{admin1}.{admin2}"] = (geoname_id, area_keys(fields))
    return codes, groups, divisions, islands


def admin_code_ids(path: Path) -> dict[str, tuple[int, str]]:
    """admin1CodesASCII / admin2Codes: code ("ES.51", "ES.07.PM") -> (geoname id, ASCII name)."""
    ids = {}
    with open(path, encoding="utf-8") as rows:
        for line in rows:
            fields = line.rstrip("\n").split("\t")
            if len(fields) >= 4 and fields[3].isdigit():
                ids[fields[0]] = (int(fields[3]), fields[2])
    return ids


def wikipedia_title(url: str) -> str | None:
    """The title of an English Wikipedia article URL, when it is a plain name."""
    prefix = "https://en.wikipedia.org/wiki/"
    if not url.startswith(prefix):
        return None
    title = urllib.parse.unquote(url[len(prefix):]).replace("_", " ").strip()
    return title if is_latin(title) and is_clean_name(title, "en") else None


def choose_area_names(
        rows: list[tuple[int, int, str, str, str, str]], canonical: str,
        english: bool) -> dict[str, str]:
    """One name per app language (and `en` when `english`) for a region or
    group from its alternate-name rows (source rank, alternateNameId,
    GeoNames language, name, preferred, short); see Regions and groups."""
    best: dict[str, tuple] = {}
    for source, alt_id, raw_language, name, preferred, short in rows:
        if raw_language == ALIAS_SOURCE:
            if not english:
                continue
            target, rank = ALIAS_SOURCE, 0
        else:
            mapped = SOURCE_TO_LANGUAGE.get(raw_language)
            if mapped is None:
                continue
            target, rank = mapped
        if not is_clean_name(name, target) or ABBREVIATION.fullmatch(name):
            continue
        if english and target in ("ja", "zh-Hans", "zh-Hant") and name.endswith(("島", "岛")) and not name.endswith(
                ("諸島", "群島", "列島", "诸岛", "群岛", "列岛")):
            # One island's name (バーラ島), never its group's.
            continue
        polytonic = False
        if target == "el":
            name, polytonic = monotonic_greek(name)
        # A kana-only Japanese name of a place with a Han one is its reading (おきなわけん).
        reading = target == "ja" and all(
            unicodedata.name(ch, "").startswith(("HIRAGANA", "KATAKANA")) for ch in name if ch.isalpha())
        # A preferred or short Latin name comes first: its designator is a
        # word search drops ("Penghu County"). A Greek or Korean one binds
        # the name (Επαρχία Λεμεσού, genitive; 이와테현), so it waits. A
        # group's English short name is its division's (the council
        # area's "Western Isles"), so only a preferred one outranks the
        # group's own ("Hebrides"; "Penghu County" over "Hoko Group").
        group_english = english and target == ALIAS_SOURCE
        marked = (preferred == "1" or (short == "1" and not group_english)) and is_latin(name)
        candidate = (rank, int(reading), int(not marked), int(is_area_form(name, target)), source,
                     0 if preferred == "1" else 1,
                     0 if short == "1" else 1, int(polytonic), alt_id, name)
        if target not in best or candidate < best[target]:
            best[target] = candidate
    names = {language: candidate[-1] for language, candidate in best.items()}
    if "ko" in names:
        names["ko"] = korean_designator_word(names["ko"], canonical)
    portuguese = names.get("pt", canonical)
    for language in list(names):
        # A group keeps every name: its canonical one is indexed nowhere else.
        if (not english and name_key(names[language]) == name_key(canonical)) or (
                language == "pt-BR" and names[language] == portuguese):
            del names[language]
    return names


def korean_designator_word(name: str, canonical: str) -> str:
    """A Korean region name with its attached designator 주 (state,
    province) or 도 (province, when the GeoNames name carries "-do") as a
    word of its own (캘리포니아주 → 캘리포니아 주, 경기도 → 경기 도), so
    search finds the name without it; a 주 or 도 that ends the name itself
    stays (홋카이도, 콜로라도, 제주 of "Jeju")."""
    folded = canonical.lower()
    if len(name) >= 3 and name[-2] != " ":
        if name.endswith("주") and not folded.endswith("ju"):
            return name[:-1] + " 주"
        if name.endswith("도") and not name.endswith(("특별자치도", "제도")) and folded.endswith("-do"):
            return name[:-1] + " 도"
    return name


# Region and group names the selection must keep (see Regions and groups):
# (admin-1 or admin-2 code, language, name). A build whose inputs have the area and language
# but chose another name fails.
AREA_NAME_CHECKS = [
    ("JP.12", "ja", "北海道"), ("JP.47", "ja", "沖縄県"), ("ES.51", "es", "Andalucía"),
    ("DE.02", "de", "Bayern"), ("IT.16", "de", "Toskana"), ("ES.59", "es", "País Vasco"),
    ("JP.12", "ko", "홋카이도"), ("GB.SCT.W8", ALIAS_SOURCE, "Hebrides"),
]


def check_area_names(area_names: dict[int, dict[str, str]], admin: dict[str, tuple[int, str]]) -> None:
    for code, language, expected in AREA_NAME_CHECKS:
        found = admin.get(code)
        chosen = area_names.get(found[0], {}).get(language) if found else None
        if chosen is not None and chosen != expected:
            raise SystemExit(f"region {code} [{language}]: chose {chosen!r}, expected {expected!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--geocoder", type=Path, default=GEOCODER_PATH)
    parser.add_argument("--alternate-names", type=Path, default=None)
    parser.add_argument("--geonames", type=Path, default=None)
    parser.add_argument("--admin1-codes", type=Path, default=None)
    parser.add_argument("--admin2-codes", type=Path, default=None)
    parser.add_argument("--output", type=Path, default=OUTPUT_PATH)
    parser.add_argument(
        "--expect-sha256", action="append", default=[], metavar="KIND=HEX",
        help="refuse an input (geocoder, alternate-names, geonames) with another SHA-256")
    args = parser.parse_args()
    expected: dict[str, str] = {}
    for item in args.expect_sha256:
        kind, _, value = item.partition("=")
        if kind not in ("geocoder", "alternate-names", "geonames", "admin1-codes",
                        "admin2-codes") or len(value) != 64:
            parser.error(f"--expect-sha256 {item}: want KIND=HEX with KIND geocoder,"
                         " alternate-names, geonames, admin1-codes or admin2-codes")
        expected[kind] = value.lower()
    args.geonames = args.geonames or download(ALL_COUNTRIES_URL, "about 400 MB")
    args.alternate_names = args.alternate_names or download(ALTERNATE_NAMES_URL, "about 200 MB")
    args.admin1_codes = args.admin1_codes or download(ADMIN1_CODES_URL, "about 150 kB")
    args.admin2_codes = args.admin2_codes or download(ADMIN2_CODES_URL, "about 2 MB")
    sources: dict[str, str] = {}
    for kind, path in (("geocoder", args.geocoder), ("alternate-names", args.alternate_names),
                       ("geonames", args.geonames), ("admin1-codes", args.admin1_codes),
                       ("admin2-codes", args.admin2_codes)):
        meta = source_metadata(kind, path)
        digest = meta[f"source.{kind}.sha256"]
        if kind in expected and digest != expected[kind]:
            raise SystemExit(f"{path}: SHA-256 {digest}, expected {expected[kind]}")
        sources.update(meta)
    for key, value in sources.items():
        print(f"  {key} = {value}")

    source = sqlite3.connect(f"file:{args.geocoder}?mode=ro", uri=True)
    cities: dict[int, tuple[str, str, int]] = {}
    # A city's GeoNames name where stripping its diacritics changed it.
    accented_names: dict[int, str] = {}
    for geoname_id, name, iso, population in source.execute(
            "SELECT geoname_id, name, iso_country, population FROM city"):
        primary = primary_place_name(name)
        if not is_latin(primary):
            # Stored through ICU Any-Latin, which this script cannot mirror.
            continue
        cities[geoname_id] = (strip_diacritics(primary), iso, population or 0)
        if cities[geoname_id][0] != primary:
            accented_names[geoname_id] = unicodedata.normalize("NFC", primary)
    print(f"{len(cities):,} cities with Latin names")
    # (name key, iso) -> the cities named so, to tell a short name that
    # names another place of the country.
    named: dict[tuple[str, str], set[int]] = {}
    for geoname_id, (canonical, iso, _) in cities.items():
        named.setdefault((name_key(canonical), iso), set()).add(geoname_id)

    candidates = geonames_islands(args.geonames)
    owned, latin_islands, matched, ambiguous, island_claims = island_owners(source, candidates)
    print(f"{len(candidates):,} GeoNames islands; {matched:,} of {latin_islands:,} geocoder"
          f" islands with Latin names matched, {len(owned):,} keys; {ambiguous:,} keys"
          f" left out for islands of a country that share them")
    # GeoNames island -> (canonical, iso): the largest island it names.
    islands: dict[int, tuple[str, str]] = {}
    for (key, iso), (geoname_id, stored, _) in sorted(
            owned.items(), key=lambda item: (-item[1][2], item[0])):
        islands.setdefault(geoname_id, (stored, iso))
    island_named: dict[tuple[str, str], set[int]] = {}
    for (key, iso), (geoname_id, _, _) in owned.items():
        island_named.setdefault((key, iso), set()).add(geoname_id)
    for geoname_id in islands:
        primary = primary_place_name(candidates[geoname_id][0])
        if is_latin(primary) and strip_diacritics(primary) == islands[geoname_id][0] != primary:
            accented_names[geoname_id] = unicodedata.normalize("NFC", primary)
    del candidates

    # Regions and groups (see Regions and groups).
    admin1 = admin_code_ids(args.admin1_codes)
    admin2 = admin_code_ids(args.admin2_codes)
    # (key, iso) -> region; region -> its admin1_name spelling.
    regions: dict[tuple[str, str], int] = {}
    region_names: dict[int, str] = {}
    for iso, code, name in source.execute("SELECT iso_country, admin1_code, name FROM admin1_name"):
        found = admin1.get(f"{iso}.{code}")
        if found:
            regions[(name_key(strip_diacritics(name)), iso)] = found[0]
            region_names[found[0]] = name
    island_ids = {owner[0] for owner in owned.values()}
    # Every geocoder city, Latin or not: trip search keys a stay's group by
    # the GeoNames id of the city nearest it (`StayAreaTable`).
    city_countries = dict(source.execute("SELECT geoname_id, iso_country FROM city"))
    area_codes, island_groups, divisions, division_islands = geonames_areas(
        args.geonames, set(city_countries) | island_ids)
    # Archipelago division code -> (division, island group), the group
    # sharing the most names with it.
    archipelagos: dict[str, tuple[int, int]] = {}
    for code, (division, keys) in divisions.items():
        shared = [(len(keys & group_keys), -group, keys & group_keys)
                  for group, group_keys in island_groups.get(code, ()) if keys & group_keys]
        if not shared or code not in admin2:
            continue
        best = max(shared, key=lambda item: item[:2])
        # Islands of the group: GeoNames places at least two in it.
        if division_islands.get(code, 0) >= 2:
            archipelagos[code] = (division, -best[1])
    print(f"{len(regions):,} regions; {len(archipelagos):,} archipelago divisions: "
          + ", ".join(sorted(admin2[code][1] for code in archipelagos)[:60]))
    area_ids = set(region_names) | {ids for pair in archipelagos.values() for ids in pair}
    # Area -> its alternate-name rows (alternateNameId, language, name,
    # preferred, short) and English Wikipedia title.
    area_rows: dict[int, list[tuple[int, str, str, str, str]]] = {}
    area_titles: dict[int, str] = {}

    # (geoname, language, pool) -> (source rank, an island's island word, not
    # preferred, was polytonic, short, alternateNameId, name); `accented` holds the best row spelling
    # the city's GeoNames name with its diacritics. See Names.
    best: dict[tuple[int, str, int], tuple[int, int, int, int, int, int, str]] = {}
    accented: dict[tuple[int, str, int], tuple[int, int, int, int, int, int, str]] = {}
    aliases: dict[int, set[str]] = {}
    # Islands GeoNames links to Wikipedia (see Islands).
    linked: set[int] = set()
    counts = {"short": 0, "areas": 0}
    def consider(alt_id: str, geoname_id: int, is_island: bool, language: str, name: str,
                 preferred: str, short: str) -> None:
        """Rank one alternate name of a city or island (see Names)."""
        mapped = SOURCE_TO_LANGUAGE.get(language)
        if mapped is None:
            return
        target, rank = mapped
        if not is_clean_name(name, target) or (
                short == "1" and (preferred != "1" or "." in name)):
            # Unpreferred short names are mostly truncations, and one
            # with a period is an abbreviation ("Neustadt a. Main").
            return
        canonical, iso = islands[geoname_id] if is_island else cities[geoname_id][:2]
        if short == "1" and name_key(name) != name_key(canonical) and (
                island_named if is_island else named).get(
                (name_key(name), iso), {geoname_id}) - {geoname_id}:
            # A short name that is another city (island) of the
            # country's name names that place ("Camboriú" for
            # Balneário Camboriú).
            counts["short"] += 1
            return
        polytonic = False
        if target == "el":
            name, polytonic = monotonic_greek(name)
        rest = without_island_word(name, target) if is_island else None
        if rest is not None and target == "el" and not LATIN_ISLAND_WORD.search(
                name_key(canonical)):
            # Greek names an island without the word ("Νησί Σπέτσες"),
            # unless its name has one ("Νήσος Γουάιτ", Isle of Wight).
            name, rest = rest, None
        if rest is not None and name_key(strip_diacritics(rest)) == name_key(canonical):
            # The canonical spelling with a word for island adds
            # nothing ("Isola Corsica" for Corsica).
            return
        if is_island and (names_non_island(name, target, han.get(geoname_id, {}))
                          or wraps_canonical(name, canonical, target)):
            # An area or group the island lies in or belongs to.
            counts["areas"] += 1
            return
        candidate = (
            rank, int(rest is not None), 0 if preferred == "1" else 1, int(polytonic),
            int(short == "1"), int(alt_id), name)
        # Pool 1 holds what an island GeoNames does not link to
        # Wikipedia may take (see Islands).
        pools = [0]
        if is_island and (target in SCRIPTS or strip_diacritics(name) == canonical):
            pools.append(1)
        for pool in pools:
            key = (geoname_id, target, pool)
            if key not in best or candidate < best[key]:
                best[key] = candidate
            if name == accented_names.get(geoname_id) and (
                    key not in accented or candidate < accented[key]):
                accented[key] = candidate

    island_rows: list[tuple[str, int, str, str, str, str]] = []
    # Island -> its Japanese ("ja") and Chinese ("zh") names.
    han: dict[int, dict[str, set[str]]] = {}
    alt_path = args.alternate_names
    with open_alternate_names(alt_path) as rows:
        for line in rows:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 8:
                continue
            alt_id, geoname, language, name = fields[0], fields[1], fields[2], fields[3]
            preferred, short, colloquial, historic = fields[4:8]
            ended = fields[9] if len(fields) > 9 else ""
            if colloquial == "1" or historic == "1" or ended:
                continue
            if not geoname.isdigit():
                continue
            geoname_id = int(geoname)
            if geoname_id in area_ids:
                if language == "link":
                    title = wikipedia_title(name)
                    if title:
                        area_titles.setdefault(geoname_id, title)
                else:
                    area_rows.setdefault(geoname_id, []).append((int(alt_id), language, name, preferred, short))
                continue
            is_island = geoname_id in islands
            if not is_island and geoname_id not in cities:
                continue
            if language == "link":
                if is_island and "wikipedia.org" in name:
                    linked.add(geoname_id)
                continue
            if language == ALIAS_SOURCE:
                if not is_island and short != "1" and is_latin(name) and is_clean_name(name, "en"):
                    aliases.setdefault(geoname_id, set()).add(name_key(name))
                continue
            if is_island:
                # Islands wait for all their Han names (`names_non_island`).
                island_rows.append((alt_id, geoname_id, language, name, preferred, short))
                han_language = "ja" if language == "ja" else (
                    "zh" if SOURCE_TO_LANGUAGE.get(language, ("",))[0].startswith("zh") else None)
                if han_language:
                    han.setdefault(geoname_id, {}).setdefault(han_language, set()).add(name)
            else:
                consider(alt_id, geoname_id, False, language, name, preferred, short)
    for row in island_rows:
        consider(row[0], row[1], True, *row[2:])

    print(f"{counts['short']:,} short names that name another city skipped")
    print(f"{counts['areas']:,} island names of an area or group skipped")
    def canonical_name(geoname_id: int) -> str:
        return (islands.get(geoname_id) or cities[geoname_id])[0]

    names: dict[int, dict[str, str]] = {}
    for (geoname_id, language, pool), candidate in best.items():
        if geoname_id in islands and (pool == 1) == (geoname_id in linked):
            continue
        name = candidate[-1]
        # A copy of the canonical spelling never hides an equally ranked
        # row giving the place's own accented name ("Kraków" over "Krakow").
        spelled = accented.get((geoname_id, language, pool))
        if name == canonical_name(geoname_id) and spelled and spelled[:3] == candidate[:3]:
            name = spelled[-1]
        names.setdefault(geoname_id, {})[language] = name
    for geoname_id, by_language in names.items():
        canonical = canonical_name(geoname_id)
        portuguese = by_language.get("pt", canonical)
        for language in list(by_language):
            name = by_language[language]
            if language == "pt-BR":
                if name == portuguese:
                    del by_language[language]
            elif name == canonical:
                del by_language[language]
    names = {geoname_id: value for geoname_id, value in names.items() if value}

    # (key, iso) -> (alias kind, -population, geoname_id): primary names
    # first, then English aliases, then metro aliases.
    owners: dict[tuple[str, str], tuple[int, int, int]] = {}
    for geoname_id, (canonical, iso, population) in cities.items():
        claims = [(name_key(canonical), 0)]
        claims += [(alias, 1) for alias in aliases.get(geoname_id, ())]
        for key, is_alias in claims:
            candidate = (is_alias, -population, geoname_id)
            if (key, iso) not in owners or candidate < owners[(key, iso)]:
                owners[(key, iso)] = candidate
    metros = metro_aliases(source, cities, set(owners))
    print(f"{len(metros):,} metro aliases")
    for key, geoname_id in metros.items():
        owners[key] = (2, -cities[geoname_id][2], geoname_id)

    # Keys under the code a stay stores where the place's GeoNames code
    # differs (see Stored codes), only where that country has no key of its own.
    territories = territory_codes(source)
    print("territory codes: " + ", ".join(f"{iso}->{stored}" for iso, stored in sorted(territories.items())))
    stored_owners: dict[tuple[str, str], tuple[int, int, int]] = {}
    for (key, iso), owner in owners.items():
        stored = territories.get(iso)
        if stored and (key, stored) not in owners and (
                (key, stored) not in stored_owners or owner < stored_owners[(key, stored)]):
            stored_owners[(key, stored)] = owner
    owners.update(stored_owners)
    # Islands of two of a country's territories that share a key cannot be
    # told apart either, whether or not GeoNames names them.
    territory_claims: dict[tuple[str, str], set[str]] = {}
    for key, iso in island_claims:
        if iso in territories:
            territory_claims.setdefault((key, territories[iso]), set()).add(iso)
    island_aliases = {
        (key, stored): owned[(key, iso)]
        for (key, stored), codes in territory_claims.items()
        if len(codes) == 1 and (key, stored) not in island_claims
        for iso in codes if (key, iso) in owned}
    owned.update(island_aliases)
    borders = cross_border_metro_aliases(source, owners)
    for key, geoname_id in borders.items():
        owners[key] = (3, -cities[geoname_id][2], geoname_id)
    print(f"{len(stored_owners):,} city and {len(island_aliases):,} island keys under a"
          f" territory's stored code; {len(borders):,} cross-border metro keys")
    source.close()

    # Region names, and keys for their English names no other region of
    # the country has; then island groups keyed by their cities and islands.
    area_names: dict[int, dict[str, str]] = {}
    for region, canonical in region_names.items():
        area_names[region] = choose_area_names(
            [(0, *row) for row in area_rows.get(region, ())], canonical, english=False)
    english_claims: dict[tuple[str, str], set[int]] = {}
    for (_, iso), region in regions.items():
        for _, language, name, _, _ in area_rows.get(region, ()):
            if language == ALIAS_SOURCE and is_latin(name) and is_clean_name(name, "en"):
                english_claims.setdefault((name_key(name), iso), set()).add(region)
    for place, claimants in english_claims.items():
        if place not in regions and len(claimants) == 1:
            regions[place] = next(iter(claimants))
    for code, (division, group) in archipelagos.items():
        rows = [(0, *row) for row in area_rows.get(group, ())] + [
            (1, *row) for row in area_rows.get(division, ())]
        canonical = admin2[code][1]
        chosen = choose_area_names(rows, canonical, english=True)
        title = area_titles.get(group) or area_titles.get(division)
        if ALIAS_SOURCE not in chosen and title:
            chosen[ALIAS_SOURCE] = title
        area_names[division] = chosen
    check_area_names(area_names, admin1 | admin2)
    # Group keys: each city's GeoNames id; each island's key; a city name
    # only when every city of the country so named lies in that group
    # (three Greek Plakas, one on Milos, never all take the Cyclades).
    groups: dict[tuple[str, str], int] = {}
    for geoname_id, iso in city_countries.items():
        code = area_codes.get(geoname_id)
        if code in archipelagos:
            groups[(str(geoname_id), iso)] = archipelagos[code][0]
    for place, owner in owners.items():
        homonyms = named.get(place, set())
        codes = {area_codes.get(geoname_id) for geoname_id in homonyms}
        if owner[2] in homonyms and len(codes) == 1 and (code := next(iter(codes))) in archipelagos:
            groups[place] = archipelagos[code][0]
    for place, owner in owned.items():
        code = area_codes.get(owner[0])
        if code in archipelagos:
            groups[place] = archipelagos[code][0]
    area_names = {area: value for area, value in area_names.items() if value}
    print(f"{sum(1 for region in regions.values() if region in area_names):,} region keys,"
          f" {sum(1 for group in groups.values() if group in area_names):,} island group keys")

    if args.output.exists():
        args.output.unlink()
    output = sqlite3.connect(args.output)
    output.executescript("""
        PRAGMA journal_mode = DELETE;
        PRAGMA page_size = 4096;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE place (
            name_key    TEXT NOT NULL,
            iso_country TEXT NOT NULL,
            layer       TEXT NOT NULL,  -- 'city', 'island', 'region' or 'group'
            geoname_id  INTEGER NOT NULL,
            PRIMARY KEY (name_key, iso_country, layer)
        ) WITHOUT ROWID;
        CREATE TABLE name (
            geoname_id INTEGER NOT NULL,
            language   TEXT NOT NULL,
            name       TEXT NOT NULL,
            PRIMARY KEY (geoname_id, language)
        ) WITHOUT ROWID;
    """)
    output.execute("INSERT INTO meta VALUES ('licence', ?)", (LICENCE,))
    output.executemany("INSERT INTO meta VALUES (?, ?)", sorted(sources.items()))
    places = sorted(
        [(key, iso, "city", owner[2]) for (key, iso), owner in owners.items() if owner[2] in names]
        + [(key, iso, "island", owner[0]) for (key, iso), owner in owned.items()
           if owner[0] in names]
        + [(key, iso, "region", region) for (key, iso), region in regions.items() if region in area_names]
        + [(key, iso, "group", group) for (key, iso), group in groups.items() if group in area_names])
    names.update(area_names)
    output.executemany("INSERT INTO place VALUES (?, ?, ?, ?)", places)
    used = {geoname_id for _, _, _, geoname_id in places}
    output.executemany(
        "INSERT INTO name VALUES (?, ?, ?)",
        sorted((geoname_id, language, name)
               for geoname_id in used for language, name in names[geoname_id].items()))
    output.commit()
    output.execute("VACUUM")
    output.close()

    island_keys = sum(1 for place in places if place[2] == "island")
    print(f"{len(places):,} keys ({island_keys:,} islands) for {len(used):,} places"
          f" -> {args.output} ({args.output.stat().st_size / 1_048_576:.1f} MB)")
    for language in LANGUAGE_SOURCES:
        count = sum(1 for geoname_id in used if language in names[geoname_id]
                    and geoname_id not in islands and geoname_id not in area_names)
        island_count = sum(1 for geoname_id in used if language in names[geoname_id]
                           and geoname_id in islands)
        area_count = sum(1 for names_ in area_names.values() if language in names_)
        print(f"  {language:8} {count:7,} names ({100 * count / len(cities):.1f}% of cities),"
              f" {island_count:6,} island names, {area_count:5,} region and group names")
    return 0


if __name__ == "__main__":
    sys.exit(main())
