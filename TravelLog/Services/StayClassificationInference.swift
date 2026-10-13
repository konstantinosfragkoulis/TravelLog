import Foundation
import FoundationModels

/// One classification batch's model session. Only prompt text and scalar
/// responses cross this boundary; eligibility, coverage retry decisions,
/// category writes and provenance remain in TripClassifier.
///
/// This extraction does not release PipelineGate during inference.
actor StayClassificationInference {
    nonisolated struct Classification: Sendable {
        let stayIndex: Int
        let category: String
    }

    #if DEBUG
    nonisolated enum TestHook {
        @TaskLocal static var availability: Bool?
        @TaskLocal static var response:
            (@Sendable (String) async throws -> [Classification])?
    }
    #endif

    nonisolated static var isAvailable: Bool {
        #if DEBUG
        if let availability = TestHook.availability { return availability }
        #endif
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private let instructions: String
    private var session: LanguageModelSession?

    init(instructions: String) {
        self.instructions = instructions
    }

    func respond(to prompt: String) async throws -> [Classification] {
        #if DEBUG
        if let response = TestHook.response { return try await response(prompt) }
        #endif
        let session: LanguageModelSession
        if let existing = self.session {
            session = existing
        } else {
            session = LanguageModelSession(instructions: instructions)
            self.session = session
        }
        let result = try await session.respond(
            to: prompt,
            generating: StayClassificationResult.self,
            // Retain greedy sampling and the same session for coverage retries.
            options: GenerationOptions(samplingMode: .greedy))
        return result.content.classifications.map {
            Classification(stayIndex: $0.stayIndex, category: $0.category)
        }
    }
}
