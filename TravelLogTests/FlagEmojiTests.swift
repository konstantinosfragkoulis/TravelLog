//
//  FlagEmojiTests.swift
//  TravelLogTests
//
//  Pure unit tests for the internal free function flagEmoji(for:) in Trip.swift
//  (drives Trip.countryFlags and StatsView). flagEmoji maps a 2-letter ISO
//  3166-1 alpha-2 code to the two Regional Indicator Symbol scalars
//  (uppercasing first) and rejects malformed input, including non-alphabetic
//  2-char input and characters whose uppercase form expands.
//
//  Expected flags are hard-coded emoji literals so an arithmetic bug in
//  production cannot also generate the expected value.
//

import Testing
import Foundation
@testable import TravelLog

struct FlagEmojiTests {

    @Test("known alpha-2 codes map to their real flags, case-insensitively",
          arguments: [
            ("GR", "🇬🇷"), ("gr", "🇬🇷"),
            ("US", "🇺🇸"), ("GB", "🇬🇧"),
            ("FR", "🇫🇷"), ("jp", "🇯🇵"),
          ])
    func knownCodesMapToRealFlags(code: String, flag: String) {
        #expect(flagEmoji(for: code) == flag)
    }

    @Test("sample malformed country codes return nil",
          // "ß" pins the case-expansion guard: uppercased() == "SS", which
          // must NOT become 🇸🇸.
          arguments: ["", "G", "USA", "12", "1A", "A1", "G!", "ΕΛ", "🇬🇷", "ß"])
    func malformedInputReturnsNil(code: String) {
        #expect(flagEmoji(for: code) == nil)
    }
}
