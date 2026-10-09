import QuartzCore
import XCTest
@testable import ClassNote

/// The refresh rate asked for while scrolling, from the `scrollFrameRate`
/// setting. A range CADisplayLink cannot take (a preferred rate above the
/// maximum) raises an exception, so each one must be well formed.
final class ScrollFrameRateTests: XCTestCase {
    private func assertWellFormed(_ range: CAFrameRateRange, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(range.minimum, range.preferred ?? range.maximum, file: file, line: line)
        XCTAssertLessThanOrEqual(range.preferred ?? range.minimum, range.maximum, file: file, line: line)
    }

    func testDefaultAsksForTheFullRate() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(forSetting: 120))
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 120)
        assertWellFormed(range)
    }

    func testSixtyAsksForASteadySixty() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(forSetting: 60))
        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.maximum, 60)
        XCTAssertEqual(range.preferred, 60)
    }

    func testZeroOrLessTurnsTheRequestOff() {
        XCTAssertNil(ScrollFrameRate.range(forSetting: 0))
        XCTAssertNil(ScrollFrameRate.range(forSetting: -1))
    }

    func testRatesAboveTheDisplayAreCapped() throws {
        let range = try XCTUnwrap(ScrollFrameRate.range(forSetting: 240))
        XCTAssertEqual(range.maximum, 120)
        assertWellFormed(range)
    }

    func testEverySettingGivesARangeADisplayLinkAccepts() {
        for setting in [1, 30, 79, 80, 90, 119, 120, 144, 1000] {
            guard let range = ScrollFrameRate.range(forSetting: setting) else {
                return XCTFail("no range for \(setting)")
            }
            assertWellFormed(range)
        }
    }
}
