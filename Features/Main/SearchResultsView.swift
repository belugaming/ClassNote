import SwiftUI

struct SearchResultsView: View {
    let query: String
    @State private var results: [SearchHit] = []
    @State private var loading = false

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
                    LazyVStack(alignment: .leading, spacing: 10) {
                        Text(L10n.isChinese ? "\(results.count) 条命中" : "\(results.count) matches")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                        ForEach(results) { hit in
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
                                    .textSelection(.enabled)
                                if !hit.segment.textTranslated.isEmpty {
                                    Text(hit.segment.textTranslated)
                                        .foregroundStyle(Theme.translation)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(12)
                            .cardBackground()
                        }
                    }
                    .padding(14)
                }
            }
        }
        .task(id: query) { await runSearch() }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        loading = true
        defer { loading = false }
        do {
            let rows = try await SegmentRepository.shared.searchFTS(query: q, limit: 200)
            self.results = rows.map { SearchHit(segment: $0.segment, sessionTitle: $0.sessionTitle) }
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
