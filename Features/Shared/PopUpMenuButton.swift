import SwiftUI
import AppKit

/// One row of a `PopUpMenuButton` menu.
enum PopUpMenuEntry {
    case header(String)
    case item(String, enabled: Bool = true, action: @MainActor () -> Void)
    case submenu(String, enabled: Bool = true, [PopUpMenuEntry])
    case separator
}

/// A button that opens a plain AppKit menu, built from `entries` at the moment
/// it is clicked.
///
/// SwiftUI's `Menu` keeps its `NSMenu` in step with the view graph while it is
/// open, and each sync closes an open submenu: the Export submenu in the
/// session "⋯" menu appeared and vanished straight away, and making the menu's
/// own view skip updates was not enough to stop it. A menu built here belongs
/// to AppKit alone, so nothing SwiftUI does can rebuild it under the pointer.
struct PopUpMenuButton<Label: View>: View {
    let entries: @MainActor () -> [PopUpMenuEntry]
    @ViewBuilder let label: () -> Label

    @State private var anchor = MenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(makeMenu(entries()))
        } label: {
            label()
        }
        .background(MenuAnchorView(anchor: anchor))
    }
}

@MainActor
private func makeMenu(_ entries: [PopUpMenuEntry]) -> NSMenu {
    let menu = NSMenu()
    // Otherwise AppKit enables every item whose target answers its action.
    menu.autoenablesItems = false
    for entry in entries {
        switch entry {
        case .header(let title):
            menu.addItem(.sectionHeader(title: title))
        case .item(let title, let enabled, let action):
            let target = MenuActionTarget(action)
            let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: "")
            item.target = target
            // `target` is weak; the item keeps it alive for as long as the menu.
            item.representedObject = target
            item.isEnabled = enabled
            menu.addItem(item)
        case .submenu(let title, let enabled, let children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = makeMenu(children)
            item.isEnabled = enabled
            menu.addItem(item)
        case .separator:
            menu.addItem(.separator())
        }
    }
    return menu
}

@MainActor
private final class MenuActionTarget: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init()
    }

    @objc func fire() { run() }
}

/// The AppKit view behind the button, for the menu to open from.
private final class MenuAnchor {
    weak var view: NSView?

    @MainActor
    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        // Just below the button with the left edges lined up, where a
        // pull-down menu would open.
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
