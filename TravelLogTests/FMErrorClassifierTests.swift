import Foundation
import FoundationModels
import Testing
@testable import TravelLog

@MainActor
struct FMErrorClassifierTests {
    @Test("temporary model errors do not spend canonical title retry budget")
    func legacyTransientErrors() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "injected")
        let errors: [LanguageModelSession.GenerationError] = [
            .rateLimited(context), .concurrentRequests(context),
            .assetsUnavailable(context), .unsupportedLanguageOrLocale(context)
        ]
        for error in errors {
            #expect(FMErrorClassifier.disposition(of: error) == .transient)
        }
    }

    @Test("iOS 26 quality and decoding failures remain permanent")
    func legacyPermanentErrors() {
        let context = LanguageModelSession.GenerationError.Context(debugDescription: "injected")
        let errors: [LanguageModelSession.GenerationError] = [
            .exceededContextWindowSize(context), .guardrailViolation(context),
            .unsupportedGuide(context), .decodingFailure(context),
            .refusal(.init(transcriptEntries: []), context)
        ]
        for error in errors {
            #expect(FMErrorClassifier.disposition(of: error) == .permanent)
        }
    }

    @Test("iOS 27 rate limits, timeouts, and unsupported languages remain retryable")
    func newTransientModelErrors() {
        if #available(iOS 27, *) {
            let errors: [LanguageModelError] = [
                .rateLimited(.init(resetDate: nil, debugDescription: "injected")),
                .timeout(.init(debugDescription: "injected")),
                .unsupportedLanguageOrLocale(.init(languageCode: .init("en"), debugDescription: "injected"))
            ]
            for error in errors {
                #expect(FMErrorClassifier.disposition(of: error) == .transient)
            }
        } else {
            // The legacy tests cover the iOS 26 error family.
            return
        }
    }

    @Test("iOS 27 content, capability, guide, and refusal errors are permanent")
    func newPermanentModelErrors() {
        if #available(iOS 27, *) {
            let errors: [LanguageModelError] = [
                .contextSizeExceeded(.init(contextSize: 1, tokenCount: 2, debugDescription: "injected")),
                .guardrailViolation(.init(debugDescription: "injected")),
                .refusal(.init(explanation: "injected", debugDescription: "injected")),
                .unsupportedCapability(.init(capability: .toolCalling, debugDescription: "injected")),
                .unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "injected")),
                .unsupportedGenerationGuide(.init(schemaName: nil, debugDescription: "injected"))
            ]
            for error in errors {
                #expect(FMErrorClassifier.disposition(of: error) == .permanent)
            }
        } else {
            return
        }
    }

    @Test("iOS 27 asset and concurrency errors are transient; transcript mutation and parsing are permanent")
    func newSystemSessionAndParsingErrors() {
        if #available(iOS 27, *) {
            #expect(FMErrorClassifier.disposition(of:
                SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "injected"))) == .transient)
            #expect(FMErrorClassifier.disposition(of:
                LanguageModelSession.Error.concurrentRequests) == .transient)
            #expect(FMErrorClassifier.disposition(of:
                LanguageModelSession.Error.transcriptMutationWhileResponding) == .permanent)
            #expect(FMErrorClassifier.disposition(of:
                GeneratedContent.ParsingError(rawContent: "{", debugDescription: "injected")) == .permanent)
        } else {
            return
        }
    }

    @Test("cancellation and unrelated errors leave the caller's fallback intact")
    func unrelatedErrors() {
        #expect(FMErrorClassifier.disposition(of: CancellationError()) == nil)
        #expect(FMErrorClassifier.disposition(of: NSError(domain: "FMErrorClassifierTests", code: 1)) == nil)
    }
}
