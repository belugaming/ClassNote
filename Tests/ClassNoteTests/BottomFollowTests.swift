import XCTest
@testable import ClassNote

/// When a growing transcript or answer keeps scrolling itself to its end.
/// Every new word used to scroll to the end, so a reader who scrolled up was
/// pulled back down several times a second.
final class BottomFollowTests: XCTestCase {
    private func position(_ offset: CGFloat, _ distanceToEnd: CGFloat) -> BottomFollow.Position {
        BottomFollow.Position(offset: offset, distanceToEnd: distanceToEnd)
    }

    func testScrollingUpStopsFollowing() {
        XCTAssertFalse(BottomFollow.following(true, from: position(800, 0), to: position(700, 100)))
    }

    /// A new line pushes the end down without the reader moving.
    func testNewTextBelowKeepsFollowing() {
        XCTAssertTrue(BottomFollow.following(true, from: position(800, 0), to: position(800, 120)))
    }

    func testNewTextBelowDoesNotStartFollowingAgain() {
        XCTAssertFalse(BottomFollow.following(false, from: position(300, 500), to: position(300, 620)))
    }

    func testReachingTheEndFollowsAgain() {
        XCTAssertTrue(BottomFollow.following(false, from: position(700, 100), to: position(790, 10)))
    }

    /// The scroll view moves content up when rows above are measured smaller;
    /// a reader still at the end is still following.
    func testOffsetCorrectionAtTheEndKeepsFollowing() {
        XCTAssertTrue(BottomFollow.following(true, from: position(800, 0), to: position(760, 0)))
    }

    func testScrollingDownShortOfTheEndChangesNothing() {
        XCTAssertFalse(BottomFollow.following(false, from: position(300, 500), to: position(400, 400)))
    }

    /// Content shorter than the window is always at its end.
    func testShortContentFollows() {
        XCTAssertTrue(BottomFollow.following(false, from: position(0, -200), to: position(0, -150)))
    }
}
