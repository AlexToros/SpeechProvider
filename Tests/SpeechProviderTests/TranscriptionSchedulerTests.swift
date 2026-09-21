import XCTest
@testable import SpeechProvider

final class TranscriptionSchedulerTests: XCTestCase {
    func testQueuesFollowingRemoteSegmentsWhileFirstBatchIsRunning() async {
        let engine = BlockingBatchEngine()
        let scheduler = TranscriptionScheduler(engine: engine)

        await scheduler.submit(segment(at: 0))
        await engine.waitForFirstBatch()

        await scheduler.submit(segment(at: 1))
        await scheduler.submit(segment(at: 2))
        await engine.releaseFirstBatch()
        await engine.waitForBatchCount(2)

        let batchSizes = await engine.batchSizes()
        XCTAssertEqual(batchSizes, [1, 2])
    }

    func testResetDiscardsQueuedAndInFlightResults() async {
        let engine = BlockingBatchEngine()
        let scheduler = TranscriptionScheduler(engine: engine)
        let results = scheduler.results

        await scheduler.submit(segment(at: 0))
        await engine.waitForFirstBatch()
        await scheduler.submit(segment(at: 1))
        await scheduler.resetConversation()
        await engine.releaseFirstBatch()

        let result = await firstResult(from: results, timeoutNanoseconds: 100_000_000)
        XCTAssertNil(result)
    }

    func testResetProcessesSegmentsSubmittedForTheNextConversation() async {
        let engine = BlockingBatchEngine()
        let scheduler = TranscriptionScheduler(engine: engine)
        let results = scheduler.results

        await scheduler.submit(segment(at: 0))
        await engine.waitForFirstBatch()
        await scheduler.resetConversation()
        await scheduler.submit(segment(at: 1))
        await engine.releaseFirstBatch()
        await engine.waitForBatchCount(2)

        let result = await firstResult(from: results, timeoutNanoseconds: 100_000_000)
        guard case let .success(transcribed)? = result else {
            return XCTFail("Expected a result for the segment submitted after reset")
        }
        XCTAssertEqual(transcribed.segment.startedAt, Date(timeIntervalSinceReferenceDate: 1))
    }

    private func firstResult(
        from results: AsyncStream<Result<TranscribedSegment, Error>>,
        timeoutNanoseconds: UInt64
    ) async -> Result<TranscribedSegment, Error>? {
        await withTaskGroup(of: Result<TranscribedSegment, Error>?.self) { group in
            group.addTask {
                for await result in results {
                    return result
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func segment(at offset: TimeInterval) -> AudioSegment {
        AudioSegment(
            speaker: .remote,
            samples: Array(repeating: 0.1, count: 1_600),
            sampleRate: 16_000,
            startedAt: Date(timeIntervalSinceReferenceDate: offset),
            endedAt: Date(timeIntervalSinceReferenceDate: offset + 0.1)
        )
    }
}

private actor BlockingBatchEngine: BatchTranscriptionEngine {
    private var batches: [[AudioSegment]] = []
    private var firstBatchWaiter: CheckedContinuation<Void, Never>?
    private var releaseFirstBatchWaiter: CheckedContinuation<Void, Never>?
    private var secondBatchWaiter: CheckedContinuation<Void, Never>?

    func prepare() async throws {}

    func transcribe(_ segment: AudioSegment) async throws -> Transcription {
        Transcription(text: "", language: "en", languageConfidence: 1)
    }

    func transcribeBatch(_ segments: [AudioSegment]) async -> [Result<Transcription, Error>] {
        batches.append(segments)
        if batches.count == 1 {
            firstBatchWaiter?.resume()
            await withCheckedContinuation { releaseFirstBatchWaiter = $0 }
        } else if batches.count == 2 {
            secondBatchWaiter?.resume()
        }
        return segments.map { _ in .success(Transcription(text: "text", language: "en", languageConfidence: 1)) }
    }

    func waitForFirstBatch() async {
        guard batches.isEmpty else { return }
        await withCheckedContinuation { firstBatchWaiter = $0 }
    }

    func releaseFirstBatch() {
        releaseFirstBatchWaiter?.resume()
        releaseFirstBatchWaiter = nil
    }

    func waitForBatchCount(_ count: Int) async {
        guard batches.count < count else { return }
        await withCheckedContinuation { secondBatchWaiter = $0 }
    }

    func batchSizes() -> [Int] {
        batches.map(\.count)
    }
}
