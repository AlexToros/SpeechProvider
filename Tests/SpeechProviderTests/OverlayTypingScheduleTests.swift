import XCTest
@testable import SpeechProvider

final class OverlayTypingScheduleTests: XCTestCase {
    func testDurationGetsShorterAsPendingQueueGrows() {
        XCTAssertEqual(OverlayTypingSchedule.duration(forPendingCaptionCount: 0), 1_000_000_000)
        XCTAssertEqual(OverlayTypingSchedule.duration(forPendingCaptionCount: 1), 1_000_000_000)
        XCTAssertEqual(OverlayTypingSchedule.duration(forPendingCaptionCount: 2), 850_000_000)
        XCTAssertEqual(OverlayTypingSchedule.duration(forPendingCaptionCount: 3), 700_000_000)
    }
}
