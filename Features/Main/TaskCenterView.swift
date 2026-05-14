import SwiftUI

struct TaskCenterButton: View {
    @ObservedObject var taskCenter: TaskCenter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
        .help(L10n.t("task.center.title"))
    }

    private var label: String {
        if taskCenter.needsAttentionCount > 0 {
            return "\(L10n.t("task.center.title")) (\(taskCenter.needsAttentionCount))"
        }
        if taskCenter.runningCount > 0 {
            return "\(L10n.t("task.center.title")) (\(taskCenter.runningCount))"
        }
        return L10n.t("task.center.title")
    }

    private var icon: String {
        if taskCenter.needsAttentionCount > 0 { return "exclamationmark.triangle.fill" }
        if taskCenter.runningCount > 0 { return "clock.arrow.circlepath" }
        return "checklist"
    }
}

struct TaskCenterSheet: View {
    @ObservedObject var taskCenter: TaskCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if taskCenter.items.isEmpty {
                ContentUnavailableView {
                    Label(L10n.t("task.center.empty"), systemImage: "checkmark.circle")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(taskCenter.items) { item in
                        TaskCenterRow(item: item, taskCenter: taskCenter)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 620, height: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label(L10n.t("task.center.title"), systemImage: "checklist")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                taskCenter.clearFinished()
            } label: {
                Label(L10n.t("task.center.clear"), systemImage: "xmark.circle")
            }
            Button(L10n.t("common.close")) { dismiss() }
        }
        .padding(16)
    }
}

private struct TaskCenterRow: View {
    let item: TaskCenterItem
    @ObservedObject var taskCenter: TaskCenter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .foregroundStyle(statusColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.title).font(.headline)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let progress = item.progress, item.status == .running {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if item.status == .running, let cancel = item.cancel {
                Button {
                    Task { await cancel() }
                } label: {
                    Image(systemName: "xmark.circle")
                }
            }
            if item.status == .failed, let retry = item.retry {
                Button {
                    Task { await retry() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            if item.status != .running {
                Button {
                    taskCenter.clear(id: item.id)
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch item.status {
        case .running: return L10n.t("task.status.running")
        case .succeeded: return L10n.t("task.status.succeeded")
        case .failed: return L10n.t("task.status.failed")
        case .cancelled: return L10n.t("task.status.cancelled")
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .running: return Theme.accent
        case .succeeded: return Theme.success
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

struct DiagnosticsSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.t("diagnostics.title"), systemImage: "stethoscope")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await appState.runDiagnostics() }
                } label: {
                    Label(L10n.t("diagnostics.run"), systemImage: "arrow.clockwise")
                }
                Button(L10n.t("common.close")) { dismiss() }
            }
            .padding(16)
            Divider()
            List(appState.diagnosticReport) { check in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: check.status))
                        .foregroundStyle(color(for: check.status))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(check.name).font(.headline)
                        Text(check.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 360)
        .task {
            if appState.diagnosticReport.isEmpty {
                await appState.runDiagnostics()
            }
        }
    }

    private func icon(for status: DiagnosticStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func color(for status: DiagnosticStatus) -> Color {
        switch status {
        case .ok: return Theme.success
        case .warning: return Theme.warning
        case .failed: return .red
        }
    }
}
