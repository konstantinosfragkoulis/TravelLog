#!/bin/sh
# Downloads the offline geocoder database into TravelLog/Resources/Geocoder.sqlite.
# The file is larger than GitHub's per-file limit, so it ships as a release asset.
# Building it from public data instead takes the full pipeline in scripts/REBUILD_GEOCODER.md.
set -eu

URL="https://github.com/konstantinosfragkoulis/TravelLog/releases/download/geocoder-a9e4fceb/Geocoder.sqlite"
SHA256="a9e4fceba59e180796557d51b3e204034a69557faeaec9d3f4a61fba9a76ede3"

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/TravelLog/Resources/Geocoder.sqlite"

if [ -f "$dest" ] && [ "$(shasum -a 256 "$dest" | cut -d' ' -f1)" = "$SHA256" ]; then
    echo "Geocoder.sqlite is already up to date."
    exit 0
fi

tmp="$dest.download"
trap 'rm -f "$tmp"' EXIT
echo "Downloading Geocoder.sqlite (about 106 MB)..."
curl --fail --location --progress-bar --output "$tmp" "$URL"

actual="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
if [ "$actual" != "$SHA256" ]; then
    echo "Checksum mismatch: expected $SHA256, got $actual" >&2
    exit 1
fi
mv "$tmp" "$dest"
trap - EXIT
echo "Saved $dest"
