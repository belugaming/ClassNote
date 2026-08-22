import SwiftUI

/// Shared "how do I start a recording" model for the menu bar and the toolbar.
///
/// Both surfaces used to spell out the same seven fixed combinations -- record
/// mic / system / mixed, transcribe-only mic, and translate-only mic / system /
/// mixed -- as seven separate buttons, each duplicated in both places and each
/// given its own ad-hoc tint. That is really only two independent choices, so
/// this expresses them as two:
///
///   * **source**  microphone / system audio / both
///   * **intent**  keep it as a session, or a temporary translation that is
///                 never written to the library
///
/// Translation on/off stays where it already lived, on `AppState`.
enum RecordingIntent: String, CaseIterable, Identifiable {
    /// Saved into the library as a session.
    case keep
    /// Live translation only; nothing is persisted unless the user explicitly
    /// saves it afterwards.
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

extension AudioSourceKind {
    /// Short label for pickers. `displayName` is a long English-only sentence
    /// used elsewhere, so it is unsuitable here.
    var shortTitle: String {
        switch self {
        case .microphone: return L10n.t("session.source.mic")
        case .system: return L10n.t("session.source.system")
        case .mixed: return L10n.t("session.source.mixed")
        case .file: return L10n.t("session.source.file")
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        case .mixed: return "person.wave.2"
        case .file: return "doc"
        }
    }

    /// The three sources a live recording can actually use.
    static var liveCases: [AudioSourceKind] { [.microphone, .system, .mixed] }
}

/// Persisted launch preferences plus the single entry point that starts a
/// recording, so the menu bar and the toolbar cannot drift apart.
@MainActor
struct RecordingLauncher {
    @AppStorage("preferredRecordingSource") private var sourceRaw = AudioSourceKind.microphone.rawValue
    @AppStorage("preferredRecordingIntent") private var intentRaw = RecordingIntent.keep.rawValue

    var source: AudioSourceKind {
        get { AudioSourceKind(rawValue: sourceRaw) ?? .microphone }
        nonmutating set { sourceRaw = newValue.rawValue }
    }

    var intent: RecordingIntent {
        get { RecordingIntent(rawValue: intentRaw) ?? .keep }
        nonmutating set { intentRaw = newValue.rawValue }
    }

    /// Starts (or stops) a recording using the current preferences.
    func toggle(_ appState: AppState) {
        if appState.isRecording {
            appState.stopRecording()
            return
        }
        switch intent {
        case .keep:
            appState.startNewSession(source: source)
        case .temporary:
            appState.startEphemeralTranslation(source: source)
        }
    }
}

/// Source + intent pickers, shared by both surfaces.
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
                .tint(Theme.accent)
                .controlSize(.small)
        }
    }
}

/// The same three choices, rendered for a `Menu`.
///
/// `RecordingOptionsView` cannot be reused inside a menu: AppKit renders menu
/// content itself, so a `.segmented` picker collapses into a bare row of icons
/// and `.labelsHidden()` strips the title that would otherwise become the
/// section header — which is exactly what a menu needs. Inline pickers are the
/// native idiom here: each renders as a titled group of checkmarked items.
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
