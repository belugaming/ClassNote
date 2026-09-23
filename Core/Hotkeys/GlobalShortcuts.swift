import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .shift]))
    static let markHighlight = Self("markHighlight", default: .init(.m, modifiers: [.command, .shift]))
    static let toggleTranslation = Self("toggleTranslation", default: .init(.t, modifiers: [.command, .shift]))
    static let toggleOverlay = Self("toggleOverlay", default: .init(.o, modifiers: [.command, .shift]))
}

enum GlobalShortcuts {
    static func register() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            Task { @MainActor in
                RecordingLauncher.toggle(AppState.shared)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .markHighlight) {
            Task { @MainActor in
                AppState.shared.markHighlight()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleTranslation) {
            Task { @MainActor in
                AppState.shared.translationEnabled.toggle()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleOverlay) {
            Task { @MainActor in
                WindowRouter.shared.toggleOverlay()
            }
        }
    }
}
