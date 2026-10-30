#!/bin/sh
# Downloads the offline databases into TravelLog/Resources: the geocoder (Geocoder.sqlite) and the
# place-name table (PlaceNames.sqlite). Both ship as release assets; the geocoder is larger than
# GitHub's per-file limit. Building them from public data instead takes the full pipeline in
# scripts/REBUILD_GEOCODER.md, and scripts/build-place-names.py.
set -eu

RELEASE="https://github.com/konstantinosfragkoulis/TravelLog/releases/download/geocoder-a9e4fceb"

root="$(cd "$(dirname "$0")/.." && pwd)"

fetch() {
    name="$1" sha256="$2" size="$3"
    dest="$root/TravelLog/Resources/$name"

    if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$sha256" ]; then
        echo "$name is already up to date."
        return
    fi

    tmp="$dest.download"
    trap 'rm -f "$tmp"' EXIT
    echo "Downloading $name (about $size)..."
    curl --fail --location --progress-bar --output "$tmp" "$RELEASE/$name"

    actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
    if [ "$actual" != "$sha256" ]; then
        echo "Checksum mismatch for $name: expected $sha256, got $actual" >&2
        exit 1
    fi
    mv "$tmp" "$dest"
    trap - EXIT
    echo "Saved $dest"
}

fetch Geocoder.sqlite a9e4fceba59e180796557d51b3e204034a69557faeaec9d3f4a61fba9a76ede3 "106 MB"
fetch PlaceNames.sqlite 1d27cbeb828240ff7c7e79c45a3c01068b135e9c350767e05a0bc5be0d947cfc "5 MB"
