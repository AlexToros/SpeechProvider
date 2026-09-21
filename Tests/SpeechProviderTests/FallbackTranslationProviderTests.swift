import XCTest
@testable import SpeechProvider

final class FallbackTranslationProviderTests: XCTestCase {
    func testReturnsPrimaryTranslationWithoutStartingFallback() async throws {
        let primary = StubTranslationProvider(result: .success("Привет"))
        let fallback = StubTranslationProvider(result: .success("Fallback"))
        let provider = FallbackTranslationProvider(primary: primary, fallback: fallback)

        let translation = try await provider.translate(text: "Hello", from: "en", to: "ru")
        let primaryCallCount = await primary.translateCallCount
        let fallbackCallCount = await fallback.translateCallCount

        XCTAssertEqual(translation, "Привет")
        XCTAssertEqual(primaryCallCount, 1)
        XCTAssertEqual(fallbackCallCount, 0)
    }

    func testUsesFallbackWhenPrimaryFails() async throws {
        let primary = StubTranslationProvider(result: .failure(TestError.unavailable))
        let fallback = StubTranslationProvider(result: .success("Привет"))
        let provider = FallbackTranslationProvider(primary: primary, fallback: fallback)

        let translation = try await provider.translate(text: "Hello", from: "en", to: "ru")
        let primaryCallCount = await primary.translateCallCount
        let fallbackCallCount = await fallback.translateCallCount

        XCTAssertEqual(translation, "Привет")
        XCTAssertEqual(primaryCallCount, 1)
        XCTAssertEqual(fallbackCallCount, 1)
    }
}

private actor StubTranslationProvider: TranslationProvider {
    let result: Result<String, Error>
    private(set) var translateCallCount = 0

    init(result: Result<String, Error>) {
        self.result = result
    }

    func prepare() async throws {}

    func translate(text: String, from source: String, to target: String) async throws -> String {
        translateCallCount += 1
        return try result.get()
    }
}

private enum TestError: Error {
    case unavailable
}
