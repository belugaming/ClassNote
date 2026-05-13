import SwiftUI
import AppKit

/// Floating always-on-top translation widget. Designed to sit next to a YouTube /
/// video window while you study. Shows the latest 2-3 transcript segments with
/// both original + translation.
struct OverlayView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.15)).padding(.vertical, 6)
            content
                .frame(maxHeight: .infinity)
        }
        .padding(12)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [
                        Theme.accent.opacity(0.10),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .background(
            WindowAccessor { win in
                win.level = .floating
                win.isMovableByWindowBackground = true
                win.hasShadow = true
                win.isOpaque = false
                win.backgroundColor = .clear
                win.titlebarAppearsTransparent = true
                win.standardWindowButton(.miniaturizeButton)?.isHidden = true
                win.standardWindowButton(.zoomButton)?.isHidden = true
                win.standardWindowButton(.closeButton)?.isHidden = true
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            }
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRecording ? Theme.recording : Color.gray)
                .frame(width: 8, height: 8)
                .scaleEffect(appState.isRecording ? 1.0 : 0.85)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: appState.isRecording)
            Text(appState.isRecording ? L10n.t("live.statusLive") : L10n.t("live.statusIdle"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            if !appState.isRecording {
                Button {
                    appState.startNewSession(source: .system)
                } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(L10n.t("overlay.startSystem"))
            } else {
                Button {
                    appState.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(Theme.recording)
                }
                .buttonStyle(.plain)
            }
            Button {
                NotificationCenter.default.post(name: .toggleOverlay, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.7))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L10n.t("overlay.close"))
        }
    }

    @ViewBuilder
    private var content: some View {
        let segs = appState.orchestrator.transcript.segments.suffix(3)
        if segs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("overlay.empty.title"))
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.callout.weight(.medium))
                Text(L10n.t("overlay.empty.tip"))
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.caption)
            }
            .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(segs)) { seg in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(seg.original)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                Text(seg.translated.isEmpty ? "…" : seg.translated)
                                    .font(.callout)
                                    .foregroundStyle(Theme.translation)
                            }
                            .id(seg.rowId)
                            .transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id("overlay-bottom")
                    }
                }
                .onChange(of: appState.orchestrator.transcript.segments.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("overlay-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// Lets us reach into the containing NSWindow from SwiftUI.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window { onResolve(w) }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let w = nsView.window { onResolve(w) }
        }
    }
}
