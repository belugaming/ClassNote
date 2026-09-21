import XCTest
@testable import ClassNote

/// The tests run inside the real app (`TEST_HOST`), so nothing but
/// `AppEnvironment` keeps them off the developer's database, recordings and
/// preferences. A regression in the detection is silent — it just starts eating
/// somebody's API key — so it gets asserted rather than assumed.
final class TestIsolationTests: XCTestCase {
    func testDataDirectoryIsNotTheRealApplicationSupport() {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClassNote")
            .standardizedFileURL.path
        XCTAssertFalse(AppBootstrap.applicationSupportURL.standardizedFileURL.path.hasPrefix(real),
                       "tests are writing to the real data directory")
    }

    func testDefaultsAreNotTheStandardSuite() {
        XCTAssertFalse(AppEnvironment.defaults === UserDefaults.standard,
                       "tests are writing to the real UserDefaults")
    }

    /// The suite only isolates writes, and that is the half that can damage the
    /// developer's preferences, so it is the half that is pinned.
    func testWritesDoNotReachTheStandardSuite() {
        let key = "classnote.isolation.probe"
        AppEnvironment.defaults.set("probe", forKey: key)
        addTeardownBlock { AppEnvironment.defaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    func testXCTestIsDetected() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }
}
