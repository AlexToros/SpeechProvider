import Foundation

actor EnergyVADSegmenter {
    struct Configuration: Sendable {
        var speechThreshold: Float = 0.012
        var endSilenceSeconds = 0.38
        var preRollSeconds = 0.20
        var minimumSpeechSeconds = 0.25
        var maximumSegmentSeconds = 14.0
    }

    private let speaker: Speaker
    private var configuration: Configuration
    private var activeSamples: [Float] = []
    private var preRoll: [Float] = []
    private var silentSampleCount = 0
    private var segmentStart: Date?

    init(speaker: Speaker, configuration: Configuration = .init()) {
        self.speaker = speaker
        self.configuration = configuration
    }

    func setEndSilenceSeconds(_ seconds: Double) {
        configuration.endSilenceSeconds = max(0.15, min(seconds, 1.5))
    }

    /// Discards a phrase that was only partially collected before a new conversation began.
    func resetConversation() {
        reset()
        preRoll.removeAll(keepingCapacity: true)
    }

    func consume(_ chunk: AudioChunk) -> AudioSegment? {
        guard chunk.speaker == speaker, !chunk.samples.isEmpty else { return nil }

        let energy = rootMeanSquare(chunk.samples)
        let isSpeech = energy >= configuration.speechThreshold
        let preRollLimit = Int(chunk.sampleRate * configuration.preRollSeconds)

        if segmentStart == nil {
            guard isSpeech else {
                appendBounded(chunk.samples, to: &preRoll, limit: preRollLimit)
                return nil
            }
            let preRollDuration = Double(preRoll.count) / chunk.sampleRate
            segmentStart = chunk.capturedAt.addingTimeInterval(-preRollDuration)
            activeSamples = preRoll
            activeSamples.append(contentsOf: chunk.samples)
            preRoll.removeAll(keepingCapacity: true)
        } else {
            activeSamples.append(contentsOf: chunk.samples)
        }

        silentSampleCount = isSpeech ? 0 : silentSampleCount + chunk.samples.count
        let silenceLimit = Int(chunk.sampleRate * configuration.endSilenceSeconds)
        let maximumLength = Int(chunk.sampleRate * configuration.maximumSegmentSeconds)

        guard silentSampleCount >= silenceLimit || activeSamples.count >= maximumLength else {
            return nil
        }

        let speechSamples = max(0, activeSamples.count - silentSampleCount)
        let minimumLength = Int(chunk.sampleRate * configuration.minimumSpeechSeconds)
        defer { reset() }
        guard speechSamples >= minimumLength, let startedAt = segmentStart else { return nil }

        return AudioSegment(
            speaker: speaker,
            samples: activeSamples,
            sampleRate: chunk.sampleRate,
            startedAt: startedAt,
            endedAt: chunk.capturedAt
        )
    }

    private func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return sqrt(sum / Float(samples.count))
    }

    private func appendBounded(_ samples: [Float], to buffer: inout [Float], limit: Int) {
        buffer.append(contentsOf: samples)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    private func reset() {
        activeSamples.removeAll(keepingCapacity: true)
        silentSampleCount = 0
        segmentStart = nil
    }
}
