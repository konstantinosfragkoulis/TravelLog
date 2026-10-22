#!/usr/bin/env python3
"""
Validate Travel Log's source String Catalogs. Standard-library only.

Run from any directory:

    python3 scripts/l10n-check.py
    python3 scripts/l10n-check.py --languages en,de,el,ja

By default, English and every localization already present in any catalog are
checked. Length and stale-key findings are warnings; all other findings fail.
"""

import argparse
import json
import re
import sys
import unicodedata
from itertools import combinations
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = (ROOT / "TravelLog", ROOT / "TravelLogWidgets")
PROOF_PREFIX = "localization.proof."
PROTECTED_TOKENS = (
    "Travel Log",
    "TravelLog",
    "iCloud",
    "Apple Intelligence",
    "Apple Weather",
)
BUILD_DIR_NAMES = {
    ".build",
    "build",
    "deriveddata",
    "buildproducts",
    "buildintermediates.noindex",
}

# printf/NSString format syntax emitted by Swift interpolation in catalogs.
# %% is deliberately excluded because it is an escaped literal percent sign.
FORMAT_SPECIFIER = re.compile(
    r"%(?!%)(?:#@[A-Za-z_][A-Za-z0-9_]*@|"
    r"(?:\d+\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?:hh|h|ll|l|q|L|z|t|j)?[@diuoxXfFeEgGaAcCsSpD])"
)
APP_SHORTCUT_PLACEHOLDER = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}")

OTHER_ONLY_SPLIT_KEYS = {
    # CollectionsViews.swift:405: the days branch starts at a 48-hour gap.
    "collections.flight-gap.days.other",
    # NotificationService.swift:170: the inclusive count is at least two.
    "notification.welcome-home.body.other",
    # PlannedTripCard.swift:42: rendered only when legCount is greater than one.
    "planned-trip.calendar-events.other",
    # TripsListView+Rows.swift:563: only rows of five or more countries count the rest.
    "trips.row.countries-more.other",
}

# En dashes denote ranges or compact label separators here, not sentence
# punctuation. All other catalog prose uses sentences, commas, or colons.
DASH_LABEL_KEYS = {
    "%@–%@", "%@ Wrapped", "Generate %@ Wrapped", "Generating %@ Wrapped…",
    "app-intent.trip-entity.date-range.completed", "app-intent.trip-entity.date-range.ongoing",
    "widget.current-trip.date-range.present", "trip-detail.date-range.present", "trips.date-range.now", "wrapped.share-preview",
    "trip-filter.duration.week.label", "trip-filter.duration.weekend.label",
    "trip-sort.name-a-z.label", "trip-sort.name-a-z.short-label",
}


class Reporter:
    def __init__(self):
        self.errors = 0
        self.warnings = 0

    def error(self, code, catalog, key, message):
        self.errors += 1
        print(f"ERROR [{code}] {catalog} :: {key!r}: {message}")

    def warning(self, code, catalog, key, message):
        self.warnings += 1
        print(f"WARNING [{code}] {catalog} :: {key!r}: {message}")


def relative(path):
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def is_build_path(path):
    return any(part.casefold() in BUILD_DIR_NAMES for part in path.parts)


def discover_catalogs():
    return sorted(
        path for path in ROOT.glob("**/*.xcstrings")
        if not is_build_path(path)
    )


def load_catalogs(paths, reporter):
    catalogs = []
    for path in paths:
        name = relative(path)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            reporter.error("CATALOG_READ", name, "<catalog>", str(exc))
            continue
        strings = data.get("strings")
        if not isinstance(strings, dict):
            reporter.error(
                "CATALOG_SHAPE", name, "<catalog>", "top-level 'strings' is not an object"
            )
            continue
        catalogs.append((path, strings))
    return catalogs


def string_units(localization):
    """Return {(variation path): value} for every nested stringUnit."""
    units = {}

    def visit(node, path):
        if not isinstance(node, dict):
            return
        unit = node.get("stringUnit")
        if isinstance(unit, dict):
            units[path] = unit.get("value")
        for name, child in node.items():
            if name == "stringUnit":
                continue
            if isinstance(child, dict):
                visit(child, path + (name,))

    visit(localization, ())
    return units


def variant_label(path):
    return "root" if not path else "/".join(path)


def placeholders(value):
    # Map argument index -> specifier without its position prefix, so a
    # translation may reorder arguments but must reference every English
    # argument by the same index and type: `%2$@ … %1$lld` matches
    # `%@ … %lld`, while `%1$@ %1$@` (second argument dropped) or `%2$@`
    # alone (first argument skipped) do not. Implicit specifiers take
    # sequential indexes. Mixing implicit and positional forms in one string
    # is invalid in Foundation and is marked so it never matches English.
    # Escaped percent pairs are removed before scanning; this also handles
    # %%%d as one literal percent followed by one real %d placeholder.
    result = {}
    next_index = 1
    saw_positional = saw_implicit = False
    for specifier in FORMAT_SPECIFIER.findall(value.replace("%%", "")):
        position = re.match(r"%(\d+)\$", specifier)
        if position:
            index = int(position.group(1))
            specifier = "%" + specifier[position.end():]
            saw_positional = True
        else:
            index = next_index
            next_index += 1
            saw_implicit = True
        result[index] = specifier
    if saw_positional and saw_implicit:
        result["mixed positional and implicit"] = True
    return result


def reference_value(en_units, path):
    if path in en_units:
        return en_units[path]
    if len(en_units) == 1:
        return next(iter(en_units.values()))
    return None


# Values that are legitimately identical across every localization: universal
# UI words Apple itself leaves untranslated.
UNIVERSAL_VALUES = {"OK", "KM"}

# SI/unit tokens that legitimately stay Latin in any script (value strings
# like "%lld (≈%@ km²)"). Longest-first so "km²" strips before "km".
UNIT_TOKENS = ["km²", "km", "m²", "mm", "min", "°C", "°F", "h", "m", "k"]


def english_is_script_exempt(value):
    if value in UNIVERSAL_VALUES:
        return True
    remainder = value
    for token in PROTECTED_TOKENS:
        remainder = remainder.replace(token, "")
    for token in UNIT_TOKENS:
        remainder = remainder.replace(token, "")
    remainder = FORMAT_SPECIFIER.sub("", remainder)
    remainder = APP_SHORTCUT_PLACEHOLDER.sub("", remainder)
    # Symbols (S*: →, ≈, ×, ·-class glyphs) are as script-neutral as
    # punctuation — route separators and math-adjacent value strings must not
    # demand native script.
    return all(
        char.isspace()
        or char.isdigit()
        or unicodedata.category(char).startswith(("P", "S"))
        for char in remainder
    )


def in_ranges(char, ranges):
    scalar = ord(char)
    return any(start <= scalar <= end for start, end in ranges)


SCRIPT_RANGES = {
    "el": ((0x0370, 0x03FF), (0x1F00, 0x1FFF)),
    "ja": (
        (0x3040, 0x30FF),
        (0x31F0, 0x31FF),
        (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF),
        (0xF900, 0xFAFF),
    ),
    "ko": (
        (0x1100, 0x11FF),
        (0x3130, 0x318F),
        (0xA960, 0xA97F),
        (0xAC00, 0xD7AF),
        (0xD7B0, 0xD7FF),
    ),
    "zh-Hans": (
        (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF),
        (0xF900, 0xFAFF),
        (0x20000, 0x2FA1F),
    ),
    "zh-Hant": (
        (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF),
        (0xF900, 0xFAFF),
        (0x20000, 0x2FA1F),
    ),
}


def has_expected_script(value, language):
    ranges = SCRIPT_RANGES.get(language)
    return ranges is None or any(in_ranges(char, ranges) for char in value)


def swift_source_text():
    chunks = []
    for directory in SOURCE_DIRS:
        if not directory.is_dir():
            continue
        for path in sorted(directory.rglob("*.swift")):
            try:
                chunks.append(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                pass
    return "\n".join(chunks)


def validate_catalog(path, strings, languages, source_text, quoted_keys, reporter):
    catalog = relative(path)
    keys = set(strings)

    for key in sorted(keys):
        entry = strings[key]
        if not isinstance(entry, dict):
            reporter.error("CATALOG_SHAPE", catalog, key, "entry is not an object")
            continue
        localizations = entry.get("localizations", {})
        if not isinstance(localizations, dict):
            reporter.error("CATALOG_SHAPE", catalog, key, "localizations is not an object")
            continue

        key_is_quoted = (key in quoted_keys if '"' not in key
                         else f'"{key}"' in source_text)
        exempt = key.startswith(PROOF_PREFIX)
        en_units = string_units(localizations.get("en", {}))

        # Compiler-extraction artifacts. Xcode emits every interpolated
        # `String.LocalizationValue` literal it cannot pair with a key —
        # the `defaultValue:` of a custom wrapper such as
        # `localizedRendererString(localized:defaultValue:)` — keyed by the
        # literal itself: an English-only entry no code ever looks up,
        # re-created on every build. A real literal key appears in a Swift
        # lookup position; an interpolated one never appears verbatim, and a
        # default-value duplicate appears only as that argument. Reported, not
        # counted, so the build cannot churn the error total.
        only_english = set(localizations) <= {"en"}
        looks_literal = key == "" or " " in key or "%" in key
        appears_as_default_value = False
        used_as_localization_key = False
        if only_english:
            escaped_key = re.escape(key)
            appears_as_default_value = bool(re.search(
                rf'defaultValue:\s*"{escaped_key}"', source_text
            ))
            if appears_as_default_value:
                localization_key_patterns = (
                    rf'localized:\s*"{escaped_key}"',
                    rf'localizedString\(\s*"{escaped_key}"',
                    rf'(?:title|name):\s*"{escaped_key}"',
                    rf'LocalizedStringKey\(\s*"{escaped_key}"',
                    rf'(?:Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|'
                    rf'NavigationLink|Link|Menu|GroupBox|DisclosureGroup|ProgressView|'
                    rf'LabeledContent|ContentUnavailableView|ShareLink|Tab)\(\s*"{escaped_key}"',
                    rf'\.(?:alert|confirmationDialog|navigationTitle|navigationSubtitle|'
                    rf'help|accessibilityLabel|accessibilityHint|accessibilityValue)'
                    rf'\(\s*"{escaped_key}"',
                )
                used_as_localization_key = any(
                    re.search(pattern, source_text)
                    for pattern in localization_key_patterns
                )
        absent_literal_artifact = looks_literal and not key_is_quoted
        default_value_artifact = (
            appears_as_default_value and not used_as_localization_key
        )
        if only_english and (absent_literal_artifact or default_value_artifact):
            reason = (
                "English-only literal used only as a defaultValue argument; "
                "Xcode extraction artifact"
                if default_value_artifact
                else "English-only literal absent from Swift source; Xcode extraction artifact"
            )
            reporter.warning(
                "EXTRACTION_ARTIFACT", catalog, key,
                reason,
            )
            continue

        # Placeholder parity is the only check that proof keys participate in.
        if not en_units:
            reporter.error(
                "PLACEHOLDER_PARITY", catalog, key, "English reference value is missing"
            )
        else:
            for language in languages:
                translated_units = string_units(localizations.get(language, {}))
                for unit_path, translated in translated_units.items():
                    if not isinstance(translated, str):
                        continue
                    english = reference_value(en_units, unit_path)
                    if not isinstance(english, str):
                        reporter.error(
                            "PLACEHOLDER_PARITY",
                            catalog,
                            key,
                            f"{language} {variant_label(unit_path)} has no matching English variant",
                        )
                        continue
                    expected = placeholders(english)
                    actual = placeholders(translated)
                    if actual != expected:
                        reporter.error(
                            "PLACEHOLDER_PARITY",
                            catalog,
                            key,
                            f"{language} {variant_label(unit_path)} has {dict(actual)}; "
                            f"English has {dict(expected)}",
                        )

        if exempt:
            continue

        for language in languages:
            localization = localizations.get(language)
            if not isinstance(localization, dict):
                # Info.plist brand names are deliberately English-only; a
                # translation that does exist is still checked below.
                if catalog == "TravelLog/InfoPlist.xcstrings" \
                        and key in {"CFBundleDisplayName", "CFBundleName"}:
                    continue
                reporter.error(
                    "KEY_PARITY", catalog, key, f"missing {language} localization"
                )
                continue
            units = string_units(localization)
            if not units:
                reporter.error(
                    "KEY_PARITY", catalog, key, f"{language} has no string value"
                )
                continue
            for unit_path, value in units.items():
                if isinstance(value, str) and re.search("[—–]", value) and key not in DASH_LABEL_KEYS:
                    reporter.error(
                        "PROSE_DASH", catalog, key,
                        f"{language} {variant_label(unit_path)}: replace prose dash with sentence punctuation",
                    )
                if not isinstance(value, str) or not value:
                    reporter.error(
                        "KEY_PARITY",
                        catalog,
                        key,
                        f"{language} {variant_label(unit_path)} value is empty",
                    )

        for unit_path, english in en_units.items():
            if not isinstance(english, str) or not english:
                reporter.error(
                    "EN_SANITY", catalog, key, f"{variant_label(unit_path)} value is empty"
                )
                continue
            expected_tokens = [token for token in PROTECTED_TOKENS if token in english]
            script_exempt = english_is_script_exempt(english)

            for language in languages:
                translated_units = string_units(localizations.get(language, {}))
                translated = reference_value(translated_units, unit_path)
                if not isinstance(translated, str) or not translated:
                    continue

                for token in expected_tokens:
                    if token not in translated:
                        reporter.error(
                            "PROTECTED_TOKEN",
                            catalog,
                            key,
                            f"{language} {variant_label(unit_path)} changed or removed {token!r}",
                        )

                # Spanish inverted punctuation in any non-Spanish language is a
                # cross-language contamination signature (caught live in a pt-PT
                # batch: '¿Apagar…?').
                if language != "es" and ("¡" in translated or "¿" in translated):
                    reporter.error(
                        "FOREIGN_PUNCTUATION",
                        catalog,
                        key,
                        f"{language} {variant_label(unit_path)} contains Spanish inverted punctuation",
                    )

                # CJK catalogs end sentences with the ideographic full stop;
                # an ASCII period followed by a space is a mechanical-edit
                # signature (caught in a 2026-09 dash sweep).
                if language in ("ja", "zh-Hans", "zh-Hant") and ". " in translated:
                    reporter.error(
                        "CJK_PUNCTUATION",
                        catalog,
                        key,
                        f"{language} {variant_label(unit_path)} uses an ASCII period instead of the ideographic full stop",
                    )

                if language in SCRIPT_RANGES and not script_exempt \
                        and not english_is_script_exempt(translated):
                    if not has_expected_script(translated, language):
                        reporter.error(
                            "SCRIPT_PRESENCE",
                            catalog,
                            key,
                            f"{language} {variant_label(unit_path)} has no expected-script character",
                        )

                if len(english) >= 20 and len(translated) > 1.6 * len(english):
                    reporter.warning(
                        "LENGTH_ALARM",
                        catalog,
                        key,
                        f"{language} {variant_label(unit_path)} is {len(translated) / len(english):.2f}× English",
                    )

        if key.endswith(".one"):
            sibling = key[:-4] + ".other"
            if sibling not in keys:
                reporter.error(
                    "SPLIT_KEY", catalog, key, f"missing sibling {sibling!r}"
                )
        elif key.endswith(".other") and key not in OTHER_ONLY_SPLIT_KEYS:
            sibling = key[:-6] + ".one"
            if sibling not in keys:
                reporter.error(
                    "SPLIT_KEY", catalog, key, f"missing sibling {sibling!r}"
                )

        english_values = {
            value for value in en_units.values() if isinstance(value, str)
        }
        is_literal_english = key in english_values
        is_semantic = (
            "." in key
            and " " not in key
            and "%" not in key
            and not is_literal_english
        )
        if is_semantic and not key_is_quoted:
            reporter.warning(
                "STALE_KEY", catalog, key, "not found as a string literal in app or widget Swift"
            )

    family_prefix = "wrapped.narrative.opening.with-cities."
    expected_family = {
        family_prefix + f"{a}-{b}-{c}"
        for a in ("one", "other")
        for b in ("one", "other")
        for c in ("one", "other")
    }
    present_family = {key for key in keys if key.startswith(family_prefix)}
    if present_family:
        for missing in sorted(expected_family - keys):
            reporter.error(
                "SPLIT_KEY", catalog, family_prefix + "*", f"missing family member {missing!r}"
            )

    # Resolution sanity: a language whose every real value equals English is
    # catalog-shaped fallback, not a translation. Run per catalog so a future
    # language cannot be real in one target while silently unresolved in another.
    for language in languages:
        if language == "en":
            continue
        has_non_english_value = False
        for key, entry in strings.items():
            if key.startswith(PROOF_PREFIX) or not isinstance(entry, dict):
                continue
            localizations = entry.get("localizations", {})
            if not isinstance(localizations, dict):
                continue
            en_units = string_units(localizations.get("en", {}))
            translated_units = string_units(localizations.get(language, {}))
            if any(
                isinstance(value, str)
                and isinstance(reference_value(en_units, unit_path), str)
                and value != reference_value(en_units, unit_path)
                for unit_path, value in translated_units.items()
            ):
                has_non_english_value = True
                break
        if not has_non_english_value:
            reporter.error(
                "LANGUAGE_RESOLUTION",
                catalog,
                "<catalog>",
                f"{language} has no non-proof value that differs from English",
            )


def validate_shared_keys(catalogs, languages, reporter):
    """Shared catalog keys are one contract and must render identically."""
    for (left_path, left_strings), (right_path, right_strings) in combinations(catalogs, 2):
        shared_keys = set(left_strings) & set(right_strings)
        if not shared_keys:
            continue
        catalog = f"{relative(left_path)} ↔ {relative(right_path)}"
        for key in sorted(shared_keys):
            left_entry = left_strings.get(key, {})
            right_entry = right_strings.get(key, {})
            if not isinstance(left_entry, dict) or not isinstance(right_entry, dict):
                continue
            left_localizations = left_entry.get("localizations", {})
            right_localizations = right_entry.get("localizations", {})
            if not isinstance(left_localizations, dict) or not isinstance(right_localizations, dict):
                continue
            for language in languages:
                left_units = string_units(left_localizations.get(language, {}))
                right_units = string_units(right_localizations.get(language, {}))
                if left_units != right_units:
                    reporter.error(
                        "SHARED_KEY_MISMATCH",
                        catalog,
                        key,
                        f"{language} values differ between catalogs",
                    )


def parse_languages(argument, catalogs):
    if argument is None:
        found = {"en"}
        for _, strings in catalogs:
            for entry in strings.values():
                if isinstance(entry, dict):
                    localizations = entry.get("localizations", {})
                    if isinstance(localizations, dict):
                        found.update(localizations)
        return ["en"] + sorted(found - {"en"})

    requested = [language.strip() for language in argument.split(",")]
    if not requested or any(not language for language in requested):
        raise ValueError("--languages must be a comma-separated list without empty entries")
    ordered = []
    for language in ["en"] + requested:
        if language not in ordered:
            ordered.append(language)
    return ordered


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--languages",
        metavar="en,de,...",
        help="languages required in every non-proof key (English is always included)",
    )
    args = parser.parse_args()

    reporter = Reporter()
    paths = discover_catalogs()
    if not paths:
        reporter.error("CATALOG_DISCOVERY", "<repo>", "<catalog>", "no .xcstrings files found")
        return 1

    catalogs = load_catalogs(paths, reporter)
    try:
        languages = parse_languages(args.languages, catalogs)
    except ValueError as exc:
        parser.error(str(exc))

    source_text = swift_source_text()
    quoted_keys = set(source_text.split('"')[1:-1])
    for path, strings in catalogs:
        validate_catalog(path, strings, languages, source_text, quoted_keys, reporter)
    validate_shared_keys(catalogs, languages, reporter)

    for path, strings in catalogs:
        print(f"CATALOG {relative(path)}: {len(strings)} keys")
    print(
        f"Checked {len(catalogs)} catalog(s), {sum(len(strings) for _, strings in catalogs)} keys, "
        f"languages {','.join(languages)}: {reporter.errors} error(s), "
        f"{reporter.warnings} warning(s)."
    )
    return 1 if reporter.errors else 0


if __name__ == "__main__":
    sys.exit(main())
