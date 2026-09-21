@preconcurrency import AVFoundation
import Foundation

final class MicrophoneCaptureService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var converter: AVAudioConverter?

    func chunks() -> AsyncStream<AudioChunk> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AudioSampleConverter.makeMicrophoneConverter(inputFormat: format) else {
            throw CaptureError.invalidMicrophoneFormat
        }
        self.converter = converter

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            guard
                let self,
                let converter = self.converter,
                let samples = AudioSampleConverter.convert(buffer, using: converter),
                !samples.isEmpty
            else {
                return
            }
            let chunk = AudioChunk(
                speaker: .local,
                samples: samples,
                sampleRate: AudioSampleConverter.targetSampleRate,
                capturedAt: Date()
            )
            _ = self.lock.withLock {
                self.continuation?.yield(chunk)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }
}

enum CaptureError: LocalizedError {
    case invalidMicrophoneFormat
    case noDisplay
    case applicationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidMicrophoneFormat:
            "Не удалось получить формат микрофона"
        case .noDisplay:
            "Не найден дисплей для захвата системного аудио"
        case .applicationUnavailable:
            "Выбранное приложение больше недоступно"
        }
    }
}
