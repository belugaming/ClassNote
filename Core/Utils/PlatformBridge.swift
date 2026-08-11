import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Small cross-platform wrappers for the handful of AppKit calls that have a
/// direct UIKit equivalent. Anything with no iOS equivalent (Finder reveal,
/// save panels) stays behind `#if os(macOS)` at the call site instead of
/// being faked here.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

/// `HSplitView` (user-resizable side-by-side panes) is macOS-only. iOS falls
/// back to a plain non-resizable `HStack` — panes stay side by side, just
/// without a draggable divider.
struct AdaptiveSplitView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        HSplitView { content }
        #else
        HStack(spacing: 0) { content }
        #endif
    }
}
