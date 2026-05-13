import SwiftUI

struct SearchResultsView: View {
    let query: String
    @State private var results: [SearchHit] = []
    @State private var loading = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView()
                        .padding()
                } else if results.isEmpty {
                    ContentUnavailableView("No matches",
                                            systemImage: "text.magnifyingglass",
                                            description: Text("No transcript lines match \"\(query)\"."))
                        .padding(40)
                } else {
                    ForEach(results) { hit in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(hit.sessionTitle)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(formatTs(hit.segment.startMs))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(hit.segment.textOriginal)
                                .textSelection(.enabled)
                            if !hit.segment.textTranslated.isEmpty {
                                Text(hit.segment.textTranslated)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    }
                }
            }
            .padding(12)
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
