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
                let app = AppState.shared
                if app.isRecording {
                    app.stopRecording()
                } else {
                    app.startNewSession(source: .microphone)
                }
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
                NotificationCenter.default.post(name: .toggleOverlay, object: nil)
            }
        }
    }
}
