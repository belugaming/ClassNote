import QuartzCore
import XCTest
@testable import ClassNote

/// The refresh rate asked for while scrolling, from the screen and the
/// `scrollFrameRate` setting. A range CADisplayLink cannot take (a preferred
/// rate above the maximum) raises an exception, so each one must be well formed.
final class ScrollFrameRateTests: XCTestCase {
    private func assertWellFormed(_ range: CAFrameRateRange, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(range.minimum, range.preferred ?? range.maximum, file: file, line: line)
        XCTAssertLessThanOrEqual(range.preferred ?? range.minimum, range.maximum, file: file, line: line)
    }

    func testProMotionAsksForItsFullRate() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(setting: nil, screenMaximum: 120))
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 120)
        assertWellFormed(range)
    }

    /// A 144 Hz monitor is not held to a MacBook's 120.
    func testAFasterMonitorAsksForItsOwnRate() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(setting: nil, screenMaximum: 144))
        XCTAssertEqual(range.maximum, 144)
        XCTAssertEqual(range.preferred, 144)
        assertWellFormed(range)
    }

    /// A 60 Hz screen has no other rate to settle on.
    func testAFixedRateScreenIsLeftAlone() {
        XCTAssertNil(ScrollFrameRate.range(setting: nil, screenMaximum: 60))
    }

    func testSixtyAsksForASteadySixty() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(setting: 60, screenMaximum: 120))
        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.maximum, 60)
        XCTAssertEqual(range.preferred, 60)
    }

    func testZeroOrLessTurnsTheRequestOff() {
        XCTAssertNil(ScrollFrameRate.range(setting: 0, screenMaximum: 120))
        XCTAssertNil(ScrollFrameRate.range(setting: -1, screenMaximum: 120))
    }

    func testARateAboveTheScreenIsCapped() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(setting: 240, screenMaximum: 120))
        XCTAssertEqual(range.maximum, 120)
        assertWellFormed(range)
    }

    func testEverySettingGivesARangeADisplayLinkAccepts() {
        for screen in [60, 120, 144] {
            for setting in [1, 30, 79, 80, 90, 119, 120, 144, 1000] {
                guard let range = ScrollFrameRate.range(setting: setting, screenMaximum: screen) else {
                    return XCTFail("no range for \(setting) on a \(screen) Hz screen")
                }
                assertWellFormed(range)
                XCTAssertLessThanOrEqual(range.maximum, Float(screen))
            }
        }
    }
}
