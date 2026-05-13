import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.r, modifiers: [.command, .shift]))
    static let markHighlight = Self("markHighlight", default: .init(.m, modifiers: [.command, .shift]))
    static let toggleTranslation = Self("toggleTranslation", default: .init(.t, modifiers: [.command, .shift]))
}

enum GlobalShortcuts {
    static func register() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
            Task { @MainActor in
                let app = AppState.shared
                if app.isRecording {
                    app.stopRecording()
                } else {
                    app.startNewSession()
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
    }
}
