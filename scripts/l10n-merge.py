#!/usr/bin/env python3
"""Merge per-language translation sidecars into the .xcstrings catalogs.

Usage: python3 scripts/l10n-merge.py /path/to/translations/de.json [more.json ...]

Sidecar schema (produced by a translation batch, one file per language):
  {
    "language": "de",
    "catalogs": {
      "TravelLog/Localizable.xcstrings": {"<key>": "<translation>", ...},
      ...
    }
  }

Rules:
  - A sidecar key that does not exist in the target catalog is an ERROR (the
    batch hallucinated or the catalog moved) — nothing is written for that
    catalog until fixed.
  - Catalog keys missing from the sidecar are reported (they will also fail
    l10n-check key parity).
  - Existing translations for the same language are overwritten (re-runs are
    idempotent).
  - Written entries get state "translated". Run scripts/l10n-check.py after
    merging.
"""

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# The catalogs are not all serialized the same way: the Localizable pair uses
# spaced separators and Xcode's AppShortcuts catalog uses the compact default,
# and only some carry a trailing newline. Writing the wrong style reformats the
# whole file and buries the real diff, so the style is detected by round-tripping
# the untouched object against the bytes on disk.
STYLES = ({"separators": (",", " : ")}, {"separators": (",", ": ")})
DEFAULT_STYLE = STYLES[0]


def detect_style(raw, obj):
    """Return (style, had_trailing_newline) that reproduces `raw` byte for byte."""
    for style in STYLES:
        body = json.dumps(obj, ensure_ascii=False, indent=2, **style)
        for newline in (True, False):
            if body + ("\n" if newline else "") == raw:
                return style, newline
    return None, raw.endswith("\n")



def merge(sidecar_path: Path) -> int:
    data = json.loads(sidecar_path.read_text())
    lang = data["language"]
    errors = 0
    for rel, entries in data["catalogs"].items():
        cat_path = REPO / rel
        if not cat_path.exists():
            print(f"ERROR {sidecar_path.name}: no catalog {rel}")
            errors += 1
            continue
        raw_catalog = cat_path.read_text()
        catalog = json.loads(raw_catalog)
        style, had_trailing_newline = detect_style(raw_catalog, catalog)
        if style is None:
            print(
                f"NOTE {sidecar_path.name}: {rel}: unrecognized formatting; "
                f"writing with {DEFAULT_STYLE['separators']!r} separators"
            )
            style = DEFAULT_STYLE
        strings = catalog["strings"]
        unknown = [k for k in entries if k not in strings]
        if unknown:
            for k in unknown[:20]:
                print(f"ERROR {sidecar_path.name}: {rel}: unknown key {k!r}")
            errors += len(unknown)
            continue
        for key, value in entries.items():
            if not isinstance(value, str) or not value:
                print(f"ERROR {sidecar_path.name}: {rel}: empty value for {key!r}")
                errors += 1
                continue
            entry = strings[key]
            locs = entry.setdefault("localizations", {})
            locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
        missing = [k for k in strings if k not in entries]
        if missing:
            print(f"NOTE {sidecar_path.name}: {rel}: {len(missing)} key(s) not in sidecar")
        cat_path.write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, **style)
            + ("\n" if had_trailing_newline else "")
        )
        if json.loads(cat_path.read_text()) != catalog:
            print(f"ERROR {sidecar_path.name}: {rel}: written catalog does not match merged data")
            errors += 1
            continue
        print(f"MERGED {lang} -> {rel}: {len(entries)} entries")
    return errors


def main() -> int:
    total = 0
    for arg in sys.argv[1:]:
        total += merge(Path(arg))
    if total:
        print(f"{total} error(s)")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
