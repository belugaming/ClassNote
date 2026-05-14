import Foundation

enum TaskCenterStatus: String, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

struct TaskCenterItem: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var icon: String
    var startedAt: Date
    var completedAt: Date?
    var progress: Double?
    var status: TaskCenterStatus
    var errorMessage: String?
    var retry: (@MainActor () async -> Void)?
    var cancel: (@MainActor () async -> Void)?

    static func == (lhs: TaskCenterItem, rhs: TaskCenterItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.detail == rhs.detail &&
        lhs.icon == rhs.icon &&
        lhs.startedAt == rhs.startedAt &&
        lhs.completedAt == rhs.completedAt &&
        lhs.progress == rhs.progress &&
        lhs.status == rhs.status &&
        lhs.errorMessage == rhs.errorMessage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(detail)
        hasher.combine(icon)
        hasher.combine(startedAt)
        hasher.combine(completedAt)
        hasher.combine(progress)
        hasher.combine(status)
        hasher.combine(errorMessage)
    }
}

@MainActor
final class TaskCenter: ObservableObject {
    @Published private(set) var items: [TaskCenterItem] = []

    var runningCount: Int {
        items.filter { $0.status == .running }.count
    }

    var needsAttentionCount: Int {
        items.filter { $0.status == .failed }.count
    }

    @discardableResult
    func start(title: String,
               detail: String,
               icon: String,
               progress: Double? = nil,
               retry: (@MainActor () async -> Void)? = nil,
               cancel: (@MainActor () async -> Void)? = nil) -> String {
        let id = UUID().uuidString
        let item = TaskCenterItem(id: id,
                                  title: title,
                                  detail: detail,
                                  icon: icon,
                                  startedAt: Date(),
                                  completedAt: nil,
                                  progress: progress,
                                  status: .running,
                                  errorMessage: nil,
                                  retry: retry,
                                  cancel: cancel)
        items.insert(item, at: 0)
        trimFinishedIfNeeded()
        return id
    }

    func configureActions(id: String,
                          retry: (@MainActor () async -> Void)? = nil,
                          cancel: (@MainActor () async -> Void)? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].retry = retry
        items[idx].cancel = cancel
    }

    func update(id: String, detail: String? = nil, progress: Double? = nil) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let detail { items[idx].detail = detail }
        if let progress { items[idx].progress = progress }
    }

    func succeed(id: String, detail: String? = nil) {
        finish(id: id, status: .succeeded, detail: detail, errorMessage: nil)
    }

    func fail(id: String, detail: String? = nil, error: Error) {
        finish(id: id,
               status: .failed,
               detail: detail,
               errorMessage: error.localizedDescription)
    }

    func fail(id: String, detail: String? = nil, message: String) {
        finish(id: id,
               status: .failed,
               detail: detail,
               errorMessage: message)
    }

    func cancel(id: String, detail: String? = nil) {
        finish(id: id, status: .cancelled, detail: detail, errorMessage: nil)
    }

    func clearFinished() {
        items.removeAll { $0.status != .running }
    }

    func clear(id: String) {
        items.removeAll { $0.id == id }
    }

    private func finish(id: String,
                        status: TaskCenterStatus,
                        detail: String?,
                        errorMessage: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let detail { items[idx].detail = detail }
        items[idx].status = status
        items[idx].completedAt = Date()
        items[idx].progress = status == .succeeded ? 1 : items[idx].progress
        items[idx].errorMessage = errorMessage
        trimFinishedIfNeeded()
    }

    private func trimFinishedIfNeeded() {
        let maxCount = 30
        guard items.count > maxCount else { return }
        let running = items.filter { $0.status == .running }
        let finished = items.filter { $0.status != .running }.prefix(max(0, maxCount - running.count))
        items = running + finished
    }
}
