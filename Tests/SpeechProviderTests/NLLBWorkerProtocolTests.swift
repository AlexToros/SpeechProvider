import XCTest
@testable import SpeechProvider

final class NLLBWorkerProtocolTests: XCTestCase {
    func testSameLanguageDoesNotStartWorker() async throws {
        let provider = NLLBTranslationProvider(configuration: .init(
            pythonExecutable: "/missing/python",
            modelDirectory: "/missing/model",
            beamSize: 1
        ))

        let translated = try await provider.translate(text: "Привет", from: "ru", to: "ru")
        XCTAssertEqual(translated, "Привет")
    }
}
