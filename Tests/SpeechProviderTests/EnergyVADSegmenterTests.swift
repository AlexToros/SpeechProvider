import XCTest
@testable import SpeechProvider

final class EnergyVADSegmenterTests: XCTestCase {
    func testSilenceDoesNotProduceSegment() async {
        let segmenter = EnergyVADSegmenter(speaker: .remote)
        let chunk = AudioChunk(
            speaker: .remote,
            samples: Array(repeating: 0, count: 8_000),
            sampleRate: 16_000,
            capturedAt: Date()
        )

        let segment = await segmenter.consume(chunk)
        XCTAssertNil(segment)
    }

    func testSpeechFollowedBySilenceProducesOneSegment() async {
        let segmenter = EnergyVADSegmenter(speaker: .remote)
        let speech = AudioChunk(
            speaker: .remote,
            samples: Array(repeating: 0.1, count: 8_000),
            sampleRate: 16_000,
            capturedAt: Date()
        )
        let silence = AudioChunk(
            speaker: .remote,
            samples: Array(repeating: 0, count: 8_000),
            sampleRate: 16_000,
            capturedAt: Date()
        )

        let initialSegment = await segmenter.consume(speech)
        XCTAssertNil(initialSegment)
        let segment = await segmenter.consume(silence)
        XCTAssertEqual(segment?.speaker, .remote)
    }
}
