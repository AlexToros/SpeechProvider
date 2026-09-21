import XCTest
@testable import SpeechProvider

final class LanguageTrackerTests: XCTestCase {
    func testRequiresRepeatedEvidenceBeforeSwitchingLanguage() async {
        let tracker = LanguageTracker()

        let initialLanguage = await tracker.language(for: .remote, detected: "en", confidence: 0.9)
        let firstCandidate = await tracker.language(for: .remote, detected: "es", confidence: 0.9)
        let confirmedLanguage = await tracker.language(for: .remote, detected: "es", confidence: 0.9)

        XCTAssertEqual(initialLanguage, "en")
        XCTAssertEqual(firstCandidate, "en")
        XCTAssertEqual(confirmedLanguage, "es")
    }

    func testRemembersDetectedRemoteLanguage() async {
        let tracker = LanguageTracker()
        _ = await tracker.language(for: .remote, detected: "de", confidence: 1)

        let language = await tracker.lastRemoteLanguage()
        XCTAssertEqual(language, "de")
    }
}
