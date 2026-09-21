import Foundation

protocol TranscriptionEngine: Sendable {
    func prepare() async throws
    func transcribe(_ segment: AudioSegment) async throws -> Transcription
}

protocol BatchTranscriptionEngine: TranscriptionEngine {
    func transcribeBatch(_ segments: [AudioSegment]) async -> [Result<Transcription, Error>]
}

struct ModelPreparationProgress: Sendable {
    let fractionCompleted: Double?
    let message: String
}

protocol PreparationProgressReporting: Sendable {
    nonisolated var preparationProgress: AsyncStream<ModelPreparationProgress> { get }
}

protocol TranscriptionPreparationProgressReporting: BatchTranscriptionEngine, PreparationProgressReporting {}

protocol TranslationProvider: Sendable {
    func prepare() async throws
    func translate(text: String, from source: String, to target: String) async throws -> String
}

protocol SuggestionProvider: Sendable {
    func updateMemory(
        previous: ConversationMemory,
        newUtterances: [Utterance],
        systemPrompt: String
    ) async throws -> ConversationMemory

    func suggestions(
        memory: ConversationMemory,
        recentUtterances: [Utterance],
        targetLanguage: String,
        systemPrompt: String
    ) async throws -> [ReplySuggestion]
}
