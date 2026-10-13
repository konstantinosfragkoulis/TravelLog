//
//  ToLatinAsciiTests.swift
//  TravelLogTests
//
//  Contract check for `String.toLatinAscii` (GeocodeResolver.swift) — the
//  single normalisation pass every resolver string is forced through so the
//  user never sees mixed Greek/Latin labels. The (input, expected) tuples are
//  taken verbatim from the doc-comment examples on the property.
//
//  Not @MainActor: `toLatinAscii` is a `nonisolated var` on String; no @Model
//  touched, no actor instantiated.
//

import Testing
import Foundation
@testable import TravelLog

struct ToLatinAsciiTests {

    @Test("Greek text is transliterated to Latin and accents stripped (Σύρος → Syros)")
    func greekTransliteratesAndStripsAccents() {
        #expect("Σύρος".toLatinAscii == "Syros")
    }

    @Test("Latin-script diacritics are stripped to plain ASCII",
          arguments: [
            ("Gérakas", "Gerakas"),
            ("München", "Munchen"),
            ("Köln", "Koln"),
            ("São Paulo", "Sao Paulo"),
            ("Sýros", "Syros"),
          ])
    func latinDiacriticsStripped(input: String, expected: String) {
        #expect(input.toLatinAscii == expected)
    }

    @Test("a pure-ASCII string returns itself and the transform is idempotent")
    func plainAsciiIsIdempotentNoOp() {
        #expect("Athens".toLatinAscii == "Athens")
        // Applying twice equals applying once.
        #expect("Athens".toLatinAscii.toLatinAscii == "Athens".toLatinAscii)
        #expect("Σύρος".toLatinAscii.toLatinAscii == "Σύρος".toLatinAscii)
    }

    @Test("the empty string normalises to the empty string (never nil)")
    func emptyStringReturnsEmpty() {
        #expect("".toLatinAscii == "")
    }

    // MARK: ASCII fast path parity

    /// The three normalizers as they were before ASCII skipped ICU and
    /// non-ASCII names were memoized. Each transform runs over every input
    /// in turn: Foundation reuses its last ICU transliterator, so the oracle
    /// stays fast while computing exactly what the old code did.
    private enum Oracle {
        static func toLatinAscii(_ values: [String]) -> [String] {
            let latin = values.map { $0.applyingTransform(.toLatin, reverse: false) ?? $0 }
            return latin.map { $0.applyingTransform(.stripDiacritics, reverse: false) ?? $0 }
        }

        static func toLatinAsciiStrict(_ values: [String]) -> [String] {
            zip(values, toLatinAscii(values)).map { value, fallback in
                var result = String.UnicodeScalarView()
                var previousWasWhitespace = false
                let ascii = value.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false)
                    ?? fallback
                for scalar in ascii.unicodeScalars {
                    if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                        if !previousWasWhitespace {
                            result.append(" ")
                            previousWasWhitespace = true
                        }
                        continue
                    }
                    guard scalar.value >= 0x21, scalar.value <= 0x7E else { continue }
                    result.append(scalar)
                    previousWasWhitespace = false
                }
                return String(result)
            }
        }

        static func normalizedPlaceName(_ values: [String]) -> [String] {
            toLatinAscii(values).map {
                $0.lowercased()
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
            }
        }
    }

    /// Every ASCII scalar alone, ASCII place names with punctuation,
    /// whitespace and control characters, and names outside ASCII.
    private static let parityInputs: [String] = (0..<128).map { String(UnicodeScalar(UInt8($0))) } + [
        "", "London", "  New   York ", "Saint-Tropez", "St. John's", "Washington, D.C.",
        "L'Aquila", "Rio de Janeiro (RJ)", "A\tB\nC", "Line\r\nBreak", "Tab\u{0B}Feed\u{0C}",
        "Nul\u{0}Byte", "Del\u{7F}", "~!@#$%^&*()_+`-={}|[]\\:\";'<>?,./", "MiXeD 1234",
        "Köniz ", "Αθήνα", "東京", "Tromsø", "Wrocław", "Gießen", "Côte d’Ivoire", "Türkiye",
        "İstanbul", "Đà Nẵng", "Москва", "Þingvellir", "Bad\u{00A0}Tölz", "Cafe\u{0301}",
    ]

    @Test("ASCII fast paths and the non-ASCII memos return exactly the old normalization")
    func fastPathParity() {
        func scalars(_ value: String) -> [Unicode.Scalar] { Array(value.unicodeScalars) }
        let inputs = Self.parityInputs
        let latin = Oracle.toLatinAscii(inputs)
        let strict = Oracle.toLatinAsciiStrict(inputs)
        let placeNames = Oracle.normalizedPlaceName(inputs)
        for (index, input) in inputs.enumerated() {
            // Twice each: the second call of a name outside ASCII reads the memo.
            for _ in 0..<2 {
                #expect(scalars(input.toLatinAscii) == scalars(latin[index]),
                        "toLatinAscii \(input.debugDescription)")
                #expect(scalars(TripTitleStore.normalizedPlaceName(input)) == scalars(placeNames[index]),
                        "normalizedPlaceName \(input.debugDescription)")
            }
            #expect(scalars(input.toLatinAsciiStrict) == scalars(strict[index]),
                    "toLatinAsciiStrict \(input.debugDescription)")
        }
    }
}
