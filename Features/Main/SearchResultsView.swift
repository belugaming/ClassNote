import SwiftUI

/// A request to open a session and scroll its transcript to one segment.
///
/// `token` is fresh per click so two clicks on the same hit are two distinct
/// values: without it the second click changes nothing and `.onChange` in the
/// detail view never fires.
struct SegmentJumpTarget: Equatable {
    let sessionId: String
    let segmentId: Int64
    let startMs: Int64
    let token: UUID

    init(sessionId: String, segmentId: Int64, startMs: Int64) {
        self.sessionId = sessionId
        self.segmentId = segmentId
        self.startMs = startMs
        self.token = UUID()
    }
}

struct SearchResultsView: View {
    let query: String
    /// Navigation stays a closure rather than a reach into `AppState`: the
    /// owner of `selectedSessionId` is the main window, same as the sidebar.
    let onOpen: (SegmentJumpTarget) -> Void
    @State private var results: [SearchHit] = []
    @State private var loading = false

    init(query: String, onOpen: @escaping (SegmentJumpTarget) -> Void) {
        self.query = query
        self.onOpen = onOpen
    }

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.t("common.loading"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("\"\(query)\"", systemImage: "text.magnifyingglass")
                } description: {
                    Text(L10n.isChinese ? "没有匹配的逐字稿内容。" : "No transcript lines match this query.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        Text(L10n.isChinese ? "\(results.count) 条命中" : "\(results.count) matches")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                        ForEach(results) { hit in
                            // A hit whose row id did not survive the search join
                            // cannot be scrolled to, so it stays a plain card.
                            if let segmentId = hit.segment.id {
                                Button {
                                    onOpen(SegmentJumpTarget(sessionId: hit.segment.sessionId,
                                                             segmentId: segmentId,
                                                             startMs: hit.segment.startMs))
                                } label: {
                                    hitCard(hit)
                                }
                                .buttonStyle(.plain)
                                .help(L10n.t("search.openHit"))
                            } else {
                                hitCard(hit)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
        .background(Theme.surfaceElevated.opacity(0.25))
        .task(id: query) { await runSearch() }
    }

    /// Text selection is deliberately off here: this list is a navigation
    /// surface, and a selectable `Text` swallows the tap that opens the hit.
    /// The same lines are selectable in the detail view.
    private func hitCard(_ hit: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.sessionTitle)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.accent)
                Text(formatTs(hit.segment.startMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(hit.segment.textOriginal)
            if !hit.segment.textTranslated.isEmpty {
                Text(hit.segment.textTranslated)
                    .foregroundStyle(Theme.translation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .fill(Theme.surfaceElevated.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        loading = true
        defer { loading = false }
        do {
            let rows = try await SegmentRepository.shared.searchFTS(query: q, limit: 200)
            self.results = rows.map { SearchHit(segment: $0.segment, sessionTitle: $0.sessionTitle) }
        } catch is CancellationError {
            // `.task(id: query)` cancels the previous search on every keystroke,
            // and a cancelled GRDB read throws rather than running on to a
            // discarded result. That is not a failure, and the newer search owns
            // `results` by now, so leave both the banner and the list alone.
        } catch {
            AppState.shared.setError("Search failed: \(error.localizedDescription)")
            self.results = []
        }
    }

    private func formatTs(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

struct SearchHit: Identifiable {
    var id: Int64 { segment.id ?? 0 }
    let segment: Segment
    let sessionTitle: String
}
