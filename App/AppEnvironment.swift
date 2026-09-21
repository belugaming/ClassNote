import Foundation

/// Where the app keeps its data, and the one question that changes the answer:
/// is this process hosting a test bundle?
///
/// The tests are injected into the real app (`TEST_HOST` in project.yml), so
/// without this every `xcodebuild test` would open the developer's own database,
/// rewrite their API key and sweep their recordings directory.
enum AppEnvironment {
    /// True when this process was launched to host XCTest.
    ///
    /// Checked several ways because Xcode has moved the marker around between
    /// releases. The environment variables are present from process start (the
    /// test runner sets them on the host app), and XCTest.framework is loaded
    /// before `main`, so the class lookup also answers correctly from inside
    /// `ClassNoteApp.init()`.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["CLASSNOTE_TEST_MODE"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }()

    /// Explicit override, honoured in and out of tests, so a fixture run can be
    /// pointed anywhere: `CLASSNOTE_DATA_DIR=/tmp/fixture ...`.
    static var dataDirectoryOverride: URL? {
        guard let raw = ProcessInfo.processInfo.environment["CLASSNOTE_DATA_DIR"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Scratch directory a test run gets instead of Application Support. One per
    /// process, wiped on first use so a run never inherits the last one's data.
    static let testDataDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassNoteTests", isDirectory: true)
            .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        return url
    }()

    /// Deliberately not `com.beluga.classnote.tests`, which is the test bundle's
    /// own identifier — `UserDefaults(suiteName:)` returns nil for a name that
    /// is a bundle identifier of the running process.
    private static let defaultsSuiteName = "com.beluga.classnote.tests.defaults"

    /// Every `UserDefaults` access in the app goes through this. Under test it is
    /// a throwaway suite, because `UserDefaults.standard` inside a test-hosted
    /// bundle is the *host app's* domain, not the test bundle's, so writes would
    /// otherwise land in the developer's own preferences.
    ///
    /// Only writes are confined. `UserDefaults(suiteName:)` keeps the host app's
    /// domain in its search list, so a read still falls through to whatever the
    /// developer has set — a test that depends on a default must write it first.
    ///
    /// `nonisolated(unsafe)` rather than an actor: `UserDefaults` is documented
    /// thread-safe, so the shared store is safe to reach from any isolation and
    /// it is Foundation, not the compiler, that serialises access to it.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isRunningTests, let suite = UserDefaults(suiteName: defaultsSuiteName) else {
            return .standard
        }
        suite.removePersistentDomain(forName: defaultsSuiteName)
        return suite
    }()
}
