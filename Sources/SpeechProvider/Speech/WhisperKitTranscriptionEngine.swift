import Foundation
import WhisperKit

actor WhisperKitTranscriptionEngine: TranscriptionPreparationProgressReporting {
    static let defaultModel = "large-v3-v20240930_turbo"

    private let model: String
    nonisolated let preparationProgress: AsyncStream<ModelPreparationProgress>
    private let preparationProgressContinuation: AsyncStream<ModelPreparationProgress>.Continuation
    private var whisperKit: WhisperKit?

    init(model: String = defaultModel) {
        self.model = model
        let stream = AsyncStream<ModelPreparationProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        preparationProgress = stream.stream
        preparationProgressContinuation = stream.continuation
    }

    func prepare() async throws {
        guard whisperKit == nil else { return }
        preparationProgressContinuation.yield(.init(fractionCompleted: 0, message: "Проверяю модель распознавания…"))
        let modelFolder = try await WhisperKit.download(variant: model) { [preparationProgressContinuation] progress in
            let fraction = min(1, max(0, progress.fractionCompleted))
            let percent = Int((fraction * 100).rounded())
            let message: String
            if progress.totalUnitCount > 0 {
                message = "Скачиваю модель: \(percent)% (шаг \(progress.completedUnitCount) из \(progress.totalUnitCount))"
            } else {
                message = "Скачиваю модель: \(percent)%"
            }
            preparationProgressContinuation.yield(.init(fractionCompleted: fraction, message: message))
        }
        preparationProgressContinuation.yield(.init(fractionCompleted: nil, message: "Загружаю модель в память…"))
        let configuration = WhisperKitConfig(
            model: model,
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(configuration)
        preparationProgressContinuation.yield(.init(fractionCompleted: 1, message: "Распознавание готово"))
    }

    func transcribe(_ segment: AudioSegment) async throws -> Transcription {
        if whisperKit == nil {
            try await prepare()
        }
        guard let whisperKit else {
            throw TranscriptionError.engineUnavailable
        }

        let results = try await whisperKit.transcribe(
            audioArray: segment.samples,
            decodeOptions: decodingOptions(concurrentWorkerCount: 1)
        )
        return try transcription(from: results)
    }

    func transcribeBatch(_ segments: [AudioSegment]) async -> [Result<Transcription, Error>] {
        guard !segments.isEmpty else { return [] }
        do {
            if whisperKit == nil {
                try await prepare()
            }
            guard let whisperKit else {
                throw TranscriptionError.engineUnavailable
            }
            let results = await whisperKit.transcribeWithResults(
                audioArrays: segments.map(\.samples),
                decodeOptions: decodingOptions(concurrentWorkerCount: 2)
            )
            return results.map { result in
                result.flatMap { transcriptionResults in
                    Result { try self.transcription(from: transcriptionResults) }
                }
            }
        } catch {
            return Array(repeating: .failure(error), count: segments.count)
        }
    }

    private func decodingOptions(concurrentWorkerCount: Int) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = nil
        options.detectLanguage = true
        options.temperature = 0
        options.temperatureFallbackCount = 0
        options.sampleLength = 128
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.concurrentWorkerCount = concurrentWorkerCount
        return options
    }

    private func transcription(from results: [TranscriptionResult]) throws -> Transcription {
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.emptyResult
        }

        let language = results.first?.language ?? "und"
        let logProbabilities = results.flatMap(\.segments).map(\.avgLogprob)
        let meanLogProbability = logProbabilities.isEmpty
            ? -1
            : logProbabilities.reduce(0, +) / Float(logProbabilities.count)
        let confidence = min(1, max(0, exp(meanLogProbability)))

        return Transcription(
            text: text,
            language: language,
            languageConfidence: confidence
        )
    }
}

enum TranscriptionError: LocalizedError {
    case engineUnavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            "Движок распознавания не загружен"
        case .emptyResult:
            "Речь в аудиосегменте не распознана"
        }
    }
}
