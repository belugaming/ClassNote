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
            Divider().opacity(0.4)
            content
                .frame(maxHeight: .infinity)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
        .padding(6)
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
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            }
        )
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(appState.isRecording ? Color.red : Color.gray)
                .frame(width: 8, height: 8)
            Text(appState.isRecording ? "Live · translating" : "Idle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if !appState.isRecording {
                Button {
                    appState.startNewSession(source: .system)
                } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Start system-audio session")
            } else {
                Button {
                    appState.stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
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
            .help("Close overlay (⌘⇧O)")
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        let segs = appState.orchestrator.transcript.segments.suffix(3)
        if segs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Start a session to see live translation here.")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.callout)
                Text("Tip: choose System audio to capture a YouTube video playing next door.")
                    .foregroundStyle(.white.opacity(0.5))
                    .font(.caption)
            }
            .padding(.vertical, 8)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(segs)) { seg in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(seg.original)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                Text(seg.translated.isEmpty ? "…" : seg.translated)
                                    .font(.callout)
                                    .foregroundStyle(.yellow.opacity(0.9))
                            }
                            .id(seg.rowId)
                        }
                        Color.clear.frame(height: 1).id("overlay-bottom")
                    }
                }
                .onChange(of: appState.orchestrator.transcript.segments.count) { _, _ in
                    withAnimation { proxy.scrollTo("overlay-bottom", anchor: .bottom) }
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
