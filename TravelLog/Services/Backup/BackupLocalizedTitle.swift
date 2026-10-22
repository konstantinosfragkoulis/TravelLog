//
//  BackupLocalizedTitle.swift
//  TravelLog
//

import Foundation

/// Value mirror shared by backup import and export. Serialized titles follow
/// the live title store's usability and content ranking policies.
nonisolated struct BackupLocalizedTitle: Codable, Sendable, Equatable {
    let id: UUID
    let languageTag: String
    let title: String
    let sourceTitle: String
    let generationVersion: Int
    let updatedAt: Date
    var sourceRevision: UUID? = nil

    /// Source title and revision are fixed by admission, so the normalized
    /// language is the complete remaining identity key.
    static func selected(
        _ variants: [BackupLocalizedTitle],
        canonicalTitle: String?,
        sourceRevision: UUID?
    ) -> [BackupLocalizedTitle] {
        guard let canonicalTitle = TripTitleStore.normalized(canonicalTitle) else {
            return []
        }
        var chosen: [String: BackupLocalizedTitle] = [:]
        for variant in variants {
            guard let languageTag = AppLanguagePreference.normalizedSupportedTag(
                    variant.languageTag),
                  languageTag != "en",
                  let title = TripTitleStore.normalized(variant.title),
                  // Invisible (incomplete-list) rows carry no authority and
                  // must not outrank, or travel instead of, a valid one.
                  TripTitleStore.isUsableVariantTitle(
                      title, languageTag: languageTag),
                  TripTitleStore.normalized(variant.sourceTitle) == canonicalTitle,
                  variant.sourceRevision == sourceRevision else {
                continue
            }
            let normalizedVariant = BackupLocalizedTitle(
                id: variant.id,
                languageTag: languageTag,
                title: title,
                sourceTitle: canonicalTitle,
                generationVersion: variant.generationVersion,
                updatedAt: variant.updatedAt,
                sourceRevision: variant.sourceRevision)
            guard let existing = chosen[languageTag] else {
                chosen[languageTag] = normalizedVariant
                continue
            }
            if TripTitleStore.hasPreferredContent(
                .init(
                    id: normalizedVariant.id,
                    title: normalizedVariant.title,
                    generationVersion: normalizedVariant.generationVersion,
                    updatedAt: normalizedVariant.updatedAt),
                over: .init(
                    id: existing.id,
                    title: existing.title,
                    generationVersion: existing.generationVersion,
                    updatedAt: existing.updatedAt)) {
                chosen[languageTag] = normalizedVariant
            }
        }
        return chosen.values.sorted { $0.languageTag < $1.languageTag }
    }
}
