import SwiftUI

/// Lists the Voice Memos library and imports the chosen recordings where they
/// lie: each session points at Voice Memos' own file, so nothing is stored twice.
struct VoiceMemosImportSheet: View {
    let onImport: ([VoiceMemo]) -> Void
    let onCancel: () -> Void

    /// nil while loading.
    @State private var result: VoiceMemosLibrary.LoadResult?
    @State private var selection: Set<VoiceMemo.ID> = []
    /// Paths some session already points at, so importing a memo twice is a
    /// choice rather than an accident.
    @State private var importedPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 580, height: 500)
        .task { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("voiceMemos.title"))
                .font(.title3.weight(.semibold))
            Text(L10n.t("voiceMemos.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case nil:
            ProgressView(L10n.t("voiceMemos.loading"))
        case .accessDenied?:
            EmptyStateView(systemImage: "lock",
                           title: L10n.t("voiceMemos.denied.title"),
                           message: L10n.t("voiceMemos.denied.body"))
        case .notFound?:
            EmptyStateView(systemImage: "waveform",
                           title: L10n.t("voiceMemos.notFound.title"),
                           message: L10n.t("voiceMemos.notFound.body"))
        case .memos(let memos, _)?:
            if memos.isEmpty {
                EmptyStateView(systemImage: "waveform", title: L10n.t("voiceMemos.empty"))
            } else {
                List(memos, selection: $selection) { memo in
                    row(memo)
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(_ memo: VoiceMemo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(memo.title)
                    .lineLimit(1)
                Text(detail(memo))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if importedPaths.contains(memo.url.path) {
                Text(L10n.t("voiceMemos.imported"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isAccessDenied {
                Button(L10n.t("voiceMemos.denied.open")) {
                    NSWorkspace.shared.open(VoiceMemosLibrary.fullDiskAccessSettingsURL)
                }
            }
            if isAccessDenied || isNotFound {
                Button(L10n.t("voiceMemos.retry")) { Task { await reload() } }
            }
            if notDownloaded > 0 {
                Text(String(format: L10n.t("voiceMemos.notDownloaded"), notDownloaded))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L10n.t("common.cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(String(format: L10n.t("voiceMemos.importSelected"), chosen.count)) {
                onImport(chosen)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen.isEmpty)
        }
        .padding(16)
    }

    // MARK: - State

    private var memos: [VoiceMemo] {
        if case .memos(let memos, _)? = result { return memos }
        return []
    }

    private var notDownloaded: Int {
        if case .memos(_, let count)? = result { return count }
        return 0
    }

    private var isAccessDenied: Bool {
        if case .accessDenied? = result { return true }
        return false
    }

    private var isNotFound: Bool {
        if case .notFound? = result { return true }
        return false
    }

    private var chosen: [VoiceMemo] {
        memos.filter { selection.contains($0.id) }
    }

    private func reload() async {
        result = nil
        let loaded = await Task.detached(priority: .userInitiated) { VoiceMemosLibrary.load() }.value
        importedPaths = (try? await SessionRepository.shared.allReferencedAudioPaths().paths) ?? []
        if case .memos(let memos, _) = loaded {
            selection.formIntersection(memos.map(\.id))
        } else {
            selection = []
        }
        result = loaded
    }

    private func detail(_ memo: VoiceMemo) -> String {
        var parts = [DateLabels.dateTime(memo.recordedAt)]
        if let seconds = memo.durationSeconds {
            let total = Int(seconds.rounded())
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            parts.append(h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s))
        }
        return parts.joined(separator: " · ")
    }
}
