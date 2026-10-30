import Foundation
import Testing
import os
@testable import TravelLog

struct TripSearchOptimizationTests {
    @Test("Bounded edit distance agrees with OSA for every abc string through length four and every ab string of length five")
    func boundedOneEditParity() {
        var strings = [""]
        var level = [""]
        for _ in 1...4 {
            level = level.flatMap { prefix in ["a", "b", "c"].map { prefix + $0 } }
            strings.append(contentsOf: level)
        }
        var mismatches: [String] = []
        for a in strings {
            for b in strings where !Self.agrees(a, b) {
                mismatches.append("\(a)|\(b)")
            }
        }
        // A fifth row or column reaches the band edges the bounded DP clears at
        // limit 3 (`low > 1` from row five, `high < n` with a fifth column):
        // every {a, b} string of length five against every {a, b} string up to
        // length five, both ways, plus the named repeated-character witnesses.
        var binary = [""]
        level = [""]
        for _ in 1...5 {
            level = level.flatMap { prefix in ["a", "b"].map { prefix + $0 } }
            binary.append(contentsOf: level)
        }
        for a in binary where a.count == 5 {
            for b in binary where !Self.agrees(a, b) || !Self.agrees(b, a) {
                mismatches.append("\(a)|\(b)")
            }
        }
        for (a, b) in [("aaaaa", "aa"), ("aa", "aaaaa"), ("aaaaa", "a"), ("a", "aaaaa")] where !Self.agrees(a, b) {
            mismatches.append("\(a)|\(b)")
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
        // Four apart: over limit 3, exact at limit 4.
        let five = "aaaaa".unicodeScalars.map(\.value)
        let one = "a".unicodeScalars.map(\.value)
        var scratch = EditDistance()
        #expect(scratch.within(five[...], one[...], limit: 3) == nil)
        #expect(scratch.within(five[...], one[...], limit: 4) == 4)
        #expect(scratch.within(one[...], five[...], limit: 4) == 4)
    }

    @Test("Bounded edit distance agrees with OSA on Unicode scalars and seeded fuzz")
    func unicodeOneEditParity() {
        let fixed = ["", "Αθήνα", "Αθήαν", "東京", "京東", "café", "cafe\u{301}",
                     "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇬🇷", "🇯🇵", "\r\n", "\n\r", "a\r\nb", "a\n\rb"]
        var mismatches: [String] = []
        for a in fixed {
            for b in fixed where !Self.agrees(a, b) {
                mismatches.append("\(a)|\(b)")
            }
        }
        let alphabet = ["a", "b", "c", "α", "東", "e\u{301}", "👩🏽‍💻", "👨‍👩‍👧‍👦", "🇬🇷", "🇯🇵", "\r\n", "\n"]
        var state: UInt64 = 0xF3_2026
        func next(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        func randomString() -> String {
            (0..<next(12)).map { _ in alphabet[next(alphabet.count)] }.joined()
        }
        for index in 0..<2_000 {
            let a = randomString()
            var chars = Array(a)
            let offset = next(chars.count + 1)
            let b: String
            switch index % 5 {
            case 0:
                chars.insert(Character(alphabet[next(alphabet.count)]), at: offset)
                b = String(chars)
            case 1 where offset < chars.count:
                chars.remove(at: offset)
                b = String(chars)
            case 2 where offset < chars.count:
                chars[offset] = Character(alphabet[next(alphabet.count)])
                b = String(chars)
            case 3 where offset + 1 < chars.count:
                chars.swapAt(offset, offset + 1)
                b = String(chars)
            default:
                b = randomString()
            }
            if !Self.agrees(a, b) {
                mismatches.append("\(a)|\(b)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(10))")
    }

    @Test("Normalization memo stays bounded and agrees with the original transform")
    func normalizationMemoParityAndBound() async {
        let values = ["Αθήνα", "東京", "CAFÉ", "cafe\u{301}", "👩🏽‍💻", "  ", "\r\n", "İstanbul",
                      "Tromsø", "Đà Lạt", "ＴＯＫＹＯ", "도쿄", "Paris"]
        let failures = await withTaskGroup(of: [String].self) { group in
            for worker in 0..<8 {
                group.addTask {
                    var failures: [String] = []
                    // 10 of the 13 values stay non-ASCII: 8 × 720 × 10/13 keys pass the 4,096 cap.
                    for index in 0..<720 {
                        let value = values[index % values.count] + " \(worker)-\(index)"
                        let expected = Self.originalForms(value)
                        if TripSearch.normalizedSearchForms(value) != expected
                            || TripSearch.normalizedSearchForms(value) != expected {
                            failures.append(value)
                        }
                        if TripSearch.normalizedFormsCache.withLock({ $0.count }) > 4096 {
                            failures.append("cache over bound at \(value)")
                        }
                    }
                    return failures
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
        for value in values {
            #expect(TripSearch.normalizedSearchForms(value) == Self.originalForms(value))
        }
    }

    /// The engine's one-edit predicate and bounded distance (limits 1 to 3)
    /// against an unbounded OSA oracle, over Unicode scalars as the engine
    /// compares them.
    private static func agrees(_ a: String, _ b: String) -> Bool {
        let x = a.unicodeScalars.map(\.value)
        let y = b.unicodeScalars.map(\.value)
        let exact = osa(x, y)
        guard EditDistance.withinOne(x[...], y[...]) == (exact <= 1) else { return false }
        var scratch = EditDistance()
        for limit in 1...3 where scratch.within(x[...], y[...], limit: limit) != (exact <= limit ? exact : nil) {
            return false
        }
        return true
    }

    private static func osa(_ a: [UInt32], _ b: [UInt32]) -> Int {
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
                if i >= 2, j >= 2, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    dp[i][j] = min(dp[i][j], dp[i - 2][j - 2] + 1)
                }
            }
        }
        return dp[m][n]
    }

    /// Independent statement of the fold: native (case, diacritic and width
    /// folded, then Latin-ASCII), Latin (`Any-Latin; Latin-ASCII`, not for
    /// Han), and UNGEGN for Greek.
    private static func originalForms(_ value: String) -> [String] {
        let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        let folded = value.lowercased().folding(options: fold, locale: nil)
        var forms = [(folded.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? folded).lowercased()]
        if !value.unicodeScalars.contains(where: { $0.properties.isIdeographic }),
           let latin = value.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) {
            forms.append(latin.lowercased().folding(options: fold, locale: nil))
        }
        if value.unicodeScalars.contains(where: { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) }),
           let greek = value.applyingTransform(StringTransform("Greek-Latin/UNGEGN; Latin-ASCII"), reverse: false) {
            forms.append(greek.lowercased().folding(options: fold, locale: nil))
        }
        // ä, ö, ü, ø and å spelled out (Tromsø as Tromsoe).
        let lowered = value.lowercased().precomposedStringWithCanonicalMapping
        let spelledOut: [Character: String] = ["ä": "ae", "ö": "oe", "ü": "ue", "ø": "oe", "å": "aa"]
        if lowered.contains(where: { spelledOut[$0] != nil }) {
            let spelled = lowered.map { spelledOut[$0] ?? String($0) }.joined().folding(options: fold, locale: nil)
            forms.append((spelled.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? spelled)
                .lowercased())
        }
        var seen = Set<String>()
        return forms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
