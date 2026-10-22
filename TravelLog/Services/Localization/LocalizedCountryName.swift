//
//  LocalizedCountryName.swift
//  TravelLog
//

import Foundation

nonisolated func localizedCountryName(
    iso: String?,
    fallback: String?,
    locale: Locale = AppLanguagePreference.currentLocale()
) -> String? {
    iso.flatMap { locale.localizedString(forRegionCode: $0) } ?? fallback
}
