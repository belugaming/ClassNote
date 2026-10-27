import Foundation
import XCTest
@testable import ClassNote

/// coreaudiod can deadlock (a macOS bug), and then every Core Audio query
/// waits forever. The app used to list microphones on the main thread at
/// launch, so it spun before its window had drawn.
@MainActor
final class AudioServiceStallTests: XCTestCase {
    private let usbMic = MicrophoneInputDevice(id: "usb-mic", name: "USB Mic", uniqueID: "usb-mic")

    override func tearDown() async throws {
        AppState.shared.preferredMicrophoneDeviceID = MicrophoneInputDevice.systemDefaultID
        AppState.shared.lastError = nil
        try await super.tearDown()
    }

    func testAStuckDeviceQueryLeavesTheAppResponsiveAndRefusesToRecord() async throws {
        let appState = AppState.shared
        let stuck = DispatchSemaphore(value: 0)
        appState.refreshMicrophoneDevices(stallAfter: .milliseconds(50)) {
            stuck.wait()
            return [.systemDefault]
        }
        // Getting here at all means the main actor was not blocked.
        try await waitUntil { appState.isAudioServiceUnresponsive }

        let sessionId = await appState.startNewSession(courseId: nil, source: .microphone)
        XCTAssertNil(sessionId)
        XCTAssertEqual(appState.lastError, L10n.t("record.error.audioServiceUnresponsive"))
        XCTAssertFalse(appState.isRecording)

        stuck.signal()
        try await waitUntil { !appState.isAudioServiceUnresponsive }
    }

    func testOnlyAPromptAnswerForgetsAMissingMicrophone() async throws {
        let appState = AppState.shared
        appState.preferredMicrophoneDeviceID = usbMic.id

        // Late, as from a daemon that was just restarted: the USB mic is
        // missing from the answer, but the preference stays.
        let late = DispatchSemaphore(value: 0)
        appState.refreshMicrophoneDevices(stallAfter: .milliseconds(50)) {
            late.wait()
            return [.systemDefault]
        }
        try await waitUntil { appState.isAudioServiceUnresponsive }
        late.signal()
        // Cleared in the same main-actor turn that applies the answer.
        try await waitUntil { !appState.isAudioServiceUnresponsive }
        XCTAssertEqual(appState.preferredMicrophoneDeviceID, usbMic.id)
        XCTAssertEqual(appState.selectedMicrophoneName, usbMic.id)

        // Prompt and still without it: the mic really is gone.
        appState.refreshMicrophoneDevices { [.systemDefault] }
        try await waitUntil { appState.preferredMicrophoneDeviceID == MicrophoneInputDevice.systemDefaultID }
    }

    func testSelectedNameComesFromTheLoadedList() async throws {
        let appState = AppState.shared
        let mic = usbMic
        appState.refreshMicrophoneDevices { [.systemDefault, mic] }
        try await waitUntil { appState.microphoneDevices.contains(mic) }
        appState.preferredMicrophoneDeviceID = mic.id
        XCTAssertEqual(appState.selectedMicrophoneName, "USB Mic")
    }

    private func waitUntil(_ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        var waited = 0
        while !condition(), waited < 300 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }
}
