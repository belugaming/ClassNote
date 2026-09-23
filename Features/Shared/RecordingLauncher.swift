import SwiftUI

/// Whether a recording is kept in the library or is a live translation that is
/// thrown away when it stops (unless saved explicitly).
enum RecordingIntent: String, CaseIterable, Identifiable {
    case keep
    case temporary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return L10n.t("record.intent.keep")
        case .temporary: return L10n.t("record.intent.temporary")
        }
    }

    var icon: String {
        switch self {
        case .keep: return "square.and.arrow.down"
        case .temporary: return "bolt"
        }
    }
}

/// The remembered recording choices. An observable object rather than
/// `@AppStorage` inside a plain struct, which never told any view it changed,
/// so the menu checkmarks and hints went stale.
@MainActor
final class RecordingPreferences: ObservableObject {
    static let shared = RecordingPreferences()

    private let defaults = AppEnvironment.defaults

    @Published var source: AudioSourceKind {
        didSet { defaults.set(source.rawValue, forKey: "preferredRecordingSource") }
    }
    @Published var intent: RecordingIntent {
        didSet { defaults.set(intent.rawValue, forKey: "preferredRecordingIntent") }
    }

    private init() {
        source = AudioSourceKind(rawValue: defaults.string(forKey: "preferredRecordingSource") ?? "")
            .flatMap { $0 == .file ? nil : $0 } ?? .microphone
        intent = RecordingIntent(rawValue: defaults.string(forKey: "preferredRecordingIntent") ?? "") ?? .keep
    }
}

/// The one entry point that starts a recording, so the toolbar, the menu bar,
/// ⌘N and the global shortcut all honour the same choices.
@MainActor
enum RecordingLauncher {
    /// Starts a recording with the remembered choices, into `courseId`, or
    /// stops the one running.
    static func toggle(_ appState: AppState, courseId: String? = nil) {
        if appState.isRecording {
            appState.stopRecording()
            return
        }
        start(appState, courseId: courseId)
    }

    /// Starts one, and does nothing if one is already running: a "new
    /// recording" button must never end the recording in progress.
    static func start(_ appState: AppState, courseId: String? = nil) {
        guard !appState.isRecording else {
            WindowRouter.shared.openLive(windowId: AppState.liveWindowId)
            return
        }
        let prefs = RecordingPreferences.shared
        switch prefs.intent {
        case .keep:
            Task { _ = await appState.startNewSession(courseId: courseId, source: prefs.source) }
        case .temporary:
            appState.startEphemeralTranslation(source: prefs.source)
        }
    }
}

/// Source, intent and translation choices, as compact controls.
struct RecordingOptionsView: View {
    @Binding var source: AudioSourceKind
    @Binding var intent: RecordingIntent
    @Binding var translationEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.t("record.source"), selection: $source) {
                ForEach(AudioSourceKind.liveCases) { kind in
                    Label(kind.shortTitle, systemImage: kind.icon).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker(L10n.t("record.intent"), selection: $intent) {
                ForEach(RecordingIntent.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Toggle(L10n.t("record.translation"), isOn: $translationEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// The same choices, rendered for a `Menu`: inline pickers become titled
/// groups of checkmarked items, which is how a menu says "pick one".
struct RecordingOptionsMenuContent: View {
    @Binding var source: AudioSourceKind
    @Binding var intent: RecordingIntent
    @Binding var translationEnabled: Bool

    var body: some View {
        Picker(L10n.t("record.source"), selection: $source) {
            ForEach(AudioSourceKind.liveCases) { kind in
                Label(kind.shortTitle, systemImage: kind.icon).tag(kind)
            }
        }
        .pickerStyle(.inline)

        Picker(L10n.t("record.intent"), selection: $intent) {
            ForEach(RecordingIntent.allCases) { option in
                Label(option.title, systemImage: option.icon).tag(option)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Toggle(L10n.t("record.translation"), isOn: $translationEnabled)
    }
}
