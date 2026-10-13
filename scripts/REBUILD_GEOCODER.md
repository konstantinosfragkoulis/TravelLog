# Geocoder rebuild

Use Python 3.10 or later, `osmium-tool`, the intended planet PBF, the local Wikidata island CSVs, and a **full master**. Never rebuild from the trimmed bundle. Keep masters/intermediates outside synchronized `TravelLog/`; keep off-machine backups of the master and the CSVs because both are gitignored. Scripts own constants, phase inputs, and validation details.

## First master

Neither the master nor the Wikidata CSVs are in the repository; the released `Geocoder.sqlite` is a trimmed bundle and cannot be a starting point. A first master needs:

1. The OSM places extract: run the `osmium` steps of section 4 to produce `$G/places.geojsonseq`.
2. The GHS-UCDB R2024A GeoPackage (`GHS_UCDB_GLOBE_R2024A.gpkg`), downloaded by hand from the GHSL site.
3. A full build, which downloads GeoNames, Natural Earth and GHS-FUA itself: `python3 scripts/build-geocoder-db.py --output="$G/Geocoder.master.sqlite" --osm-input="$G/places.geojsonseq" --ucdb-input=/path/GHS_UCDB_GLOBE_R2024A.gpkg`.
4. The two Wikidata CSVs (query in section 4.5), then the island supplement of section 4.5 with that master as `--baseline`; the supplemented output becomes the master.

Then verify (section 6) and trim (section 8).

## 4. OSM rebuild

From the repository root, with fresh output paths:

```sh
G=.build-cache/geocoder
mkdir -p "$G"
osmium fileinfo --extended /path/to/planet.osm.pbf
osmium tags-filter /path/to/planet.osm.pbf \
    nwr/place=neighbourhood,suburb,quarter,island -o "$G/places.pbf"
osmium export "$G/places.pbf" --geometry-types=point,polygon \
    -a id,type -f geojsonseq -o "$G/places.geojsonseq"
cp "$G/Geocoder.master.sqlite" "$G/Geocoder.sqlite.new"
chmod u+w "$G/Geocoder.sqlite.new"
python3 scripts/build-geocoder-db.py --phase=1e --wipe-supplement \
    --osm-input="$G/places.geojsonseq" --output="$G/Geocoder.sqlite.new"
```

Keep `nwr` to retain polygon neighbourhoods and `-a id,type` for supplement identity. Require `Phase 1E complete`; missing input can skip the phase. Always supplement afterward: Phase 1E replaces OSM tables. `--phase=all` also rebuilds non-OSM layers and needs their inputs, including GHS-UCDB; read the builder before using it.

### 4.5 Island supplement

Prepare two ID files from `scripts/wikidata-island-{relations,ways}.csv`: numeric `osm_rel` values prefixed `r`, numeric `osm_way` values prefixed `w`, one per line. Extract from the same PBF; the supplement excludes baseline IDs. Fresh CSVs can be queried from Wikidata island/subclass Q23442 using P402 for relations and P10689 for ways; verify CSV headers before replacing the existing CSVs.

```sh
osmium getid /path/to/planet.osm.pbf --id-file=/path/rel-ids.txt \
    -r -t -o "$G/relations.pbf"
osmium export "$G/relations.pbf" -a id,type -f geojson -o "$G/relations.geojson"
osmium getid /path/to/planet.osm.pbf --id-file=/path/way-ids.txt \
    -r -t -o "$G/ways.pbf"
osmium export "$G/ways.pbf" -a id,type -f geojson -o "$G/ways.geojson"
python3 scripts/supplement-islands.py --variant F \
    --baseline "$G/Geocoder.sqlite.new" --output="$G/Geocoder.sqlite.F" \
    --candidates "$G/relations.geojson" --candidates-ways "$G/ways.geojson"
```

## 6. Verification

Check supplemented `.F`, not `.new`: SQLite `integrity_check = ok`, `journal_mode = delete`, supplement marker `variant=F`, and `python3 scripts/test-geocoder-tooling.py`. Require no out-of-range/globe-spanning OSM R*Tree rows. Preserve all untouched layer contents/metadata in an OSM-only rebuild; counts alone are insufficient. Investigate lost islands, including those supplied by the missing-tag supplement. Do not change pinned expectations just to pass.

### 6.6a Resolver comparison

Trim the candidate and require zero sampled ordered-query mismatches. A failed trim deletes its `--output`, so chain every copy of it with `&&`. Keep the original bundle outside `TravelLog/`:

```sh
cp TravelLog/Resources/Geocoder.sqlite "$G/original.ship.sqlite" &&
python3 scripts/ship-trim-geocoder.py \
    --master "$G/Geocoder.sqlite.F" --output "$G/candidate.ship.sqlite"
```

Run `GeocoderSnapshotDumpTests` once with each bundle and distinct outputs (install the candidate with `cp "$G/candidate.ship.sqlite" TravelLog/Resources/Geocoder.sqlite`), then restore the original:

```sh
xcodebuild test -project TravelLog.xcodeproj -scheme TravelLog \
    -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
    -only-testing:TravelLogTests/GeocoderSnapshotDumpTests \
    TEST_RUNNER_TRAVELLOG_GEOCODER_DUMP=1 \
    TEST_RUNNER_GEOCODER_DUMP_INPUT=/path/probe.tsv \
    TEST_RUNNER_GEOCODER_DUMP_OUTPUT=/path/resolved.tsv
python3 scripts/compare-geocoder-dumps.py baseline.tsv candidate.tsv apt,island,lost,20
```

Input TSV: label, latitude, longitude. Include stays/pings, dateline probes, and remote points inside islands supplied by the missing-tag supplement. Verify the expected island name against the baseline before comparing the candidate. OSM-only rebuilds must preserve country/admin/metro/locality output; adjudicate island/sub-locality changes. Intentionally rebuilt urban-centre data also needs `HomeShapeTests` against the candidate.

## 8. Promotion

Preserve the previous master before replacing it with verified `.F`; back up the new master off-machine. Generate the bundled copy:

```sh
python3 scripts/ship-trim-geocoder.py \
    --master "$G/Geocoder.master.sqlite" --output="$G/Geocoder.ship.sqlite" &&
cp "$G/Geocoder.ship.sqlite" TravelLog/Resources/Geocoder.sqlite
```

Bump the current `offlineGeocoderBackfillCompletedKey` suffix in `AppDelegate` when changed coverage requires existing installs to heal. Build and check the bundle, affected/known-good trips, and backfill completion on device before retiring backups. New resolver queries, and new parameters in existing ones, need bindings in the trim verifier; it refuses to trim until the declared parameter counts match.
