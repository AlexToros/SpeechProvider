import Foundation

struct TranscribedSegment: Sendable {
    let segment: AudioSegment
    let transcription: Transcription
}

actor TranscriptionScheduler {
    nonisolated let results: AsyncStream<Result<TranscribedSegment, Error>>

    private let engine: any BatchTranscriptionEngine
    private let resultContinuation: AsyncStream<Result<TranscribedSegment, Error>>.Continuation
    private var remoteQueue = FIFOQueue<AudioSegment>()
    private var localQueue = FIFOQueue<AudioSegment>()
    private var isProcessing = false
    private var conversationGeneration = 0

    init(engine: any BatchTranscriptionEngine) {
        self.engine = engine
        let stream = AsyncStream<Result<TranscribedSegment, Error>>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        results = stream.stream
        resultContinuation = stream.continuation
    }

    func prepare() async throws {
        try await engine.prepare()
    }

    func submit(_ segment: AudioSegment) {
        if segment.speaker == .remote {
            remoteQueue.append(segment)
        } else {
            localQueue.append(segment)
        }

        guard !isProcessing else { return }
        isProcessing = true
        Task { await drain() }
    }

    /// Clears queued segments and prevents an already-running transcription from
    /// publishing into the next conversation.
    func resetConversation() {
        conversationGeneration &+= 1
        remoteQueue = FIFOQueue()
        localQueue = FIFOQueue()
    }

    private func drain() async {
        while let segment = nextSegment() {
            let batch = nextBatch(startingWith: segment, maximumCount: 2)
            let batchGeneration = conversationGeneration
            let transcriptions = await engine.transcribeBatch(batch)
            guard batchGeneration == conversationGeneration else { continue }
            for (segment, result) in zip(batch, transcriptions) {
                switch result {
                case let .success(transcription):
                    resultContinuation.yield(.success(TranscribedSegment(
                        segment: segment,
                        transcription: transcription
                    )))
                case let .failure(error):
                    if case TranscriptionError.emptyResult = error {
                        continue
                    }
                    resultContinuation.yield(.failure(error))
                }
            }
        }
        isProcessing = false
    }

    private func nextSegment() -> AudioSegment? {
        remoteQueue.popFirst() ?? localQueue.popFirst()
    }

    private func nextBatch(startingWith first: AudioSegment, maximumCount: Int) -> [AudioSegment] {
        var batch = [first]
        while batch.count < maximumCount {
            let next: AudioSegment?
            if first.speaker == .remote {
                next = remoteQueue.popFirst()
            } else {
                next = localQueue.popFirst()
            }
            guard let next else { break }
            batch.append(next)
        }
        return batch
    }
}

private struct FIFOQueue<Element> {
    private var storage: [Element] = []
    private var head = 0

    var isEmpty: Bool { head >= storage.count }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard !isEmpty else {
            storage.removeAll(keepingCapacity: true)
            head = 0
            return nil
        }
        let element = storage[head]
        head += 1
        if head >= 32, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }
}
