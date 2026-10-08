import SwiftUI

/// Copies a whole piece of text in one click and says so: the icon turns into
/// a checkmark for a moment, since copying changes nothing else on screen.
///
/// `text` is read only when clicked, so a long transcript is not assembled on
/// every redraw. The label follows the surrounding `labelStyle`, so a toolbar
/// can show the icon alone.
struct CopyButton: View {
    var title = L10n.t("common.copy")
    let text: () -> String

    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            Clipboard.copy(text())
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            Label(copied ? L10n.t("common.copied") : title,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .help(title)
        .onDisappear { reset?.cancel() }
    }
}
