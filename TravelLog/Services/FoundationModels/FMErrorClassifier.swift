//
//  FMErrorClassifier.swift
//  TravelLog
//

import FoundationModels

nonisolated enum FMErrorClassifier {
    enum Disposition: Equatable, Sendable {
        case transient
        case permanent
    }

    /// nil when the error is not a Foundation Models error; callers retain their availability fallback.
    static func disposition(of error: any Error) -> Disposition? {
        // iOS 26 still throws this family, even when built with the iOS 27 SDK.
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited, .concurrentRequests, .assetsUnavailable,
                 .unsupportedLanguageOrLocale:
                return .transient
            case .exceededContextWindowSize, .guardrailViolation,
                 .unsupportedGuide, .decodingFailure, .refusal:
                return .permanent
            @unknown default:
                return .transient
            }
        }

        if #available(iOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .rateLimited, .timeout, .unsupportedLanguageOrLocale:
                    return .transient
                case .contextSizeExceeded, .guardrailViolation, .refusal,
                     .unsupportedCapability, .unsupportedTranscriptContent,
                     .unsupportedGenerationGuide:
                    return .permanent
                @unknown default:
                    return .transient
                }
            }
            if let error = error as? SystemLanguageModel.Error {
                switch error {
                case .assetsUnavailable:
                    return .transient
                @unknown default:
                    return .transient
                }
            }
            if let error = error as? LanguageModelSession.Error {
                switch error {
                case .concurrentRequests:
                    return .transient
                case .transcriptMutationWhileResponding:
                    return .permanent
                @unknown default:
                    return .transient
                }
            }
            if error is GeneratedContent.ParsingError { return .permanent }
            return nil
        } else {
            return nil
        }
    }
}
