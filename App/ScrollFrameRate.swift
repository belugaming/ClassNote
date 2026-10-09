import AppKit
import QuartzCore

/// Asks for the display's full refresh rate for as long as the user scrolls.
///
/// On macOS 27 a ProMotion panel does not settle on one refresh rate while a
/// SwiftUI view scrolls: it flips between 120 Hz and 60 Hz, each frame stays
/// on screen for an unpredictable time, and scrolling judders however little
/// is drawn, on every page of the app, plain text included. Apple has the
/// report (FB24091347, Developer Forums thread 840214) and no fix yet; the
/// only confirmed workaround is setting the whole display to 60 Hz.
///
/// What an app can do is say which rate it wants. A display link carrying a
/// preferred frame-rate range is that request, so one runs from the first
/// scroll event until shortly after the last (momentum included), asking for
/// the most the window's screen can show (120 Hz on a ProMotion panel, 144 Hz
/// on such a monitor), and pauses when the page stops so an idle window costs
/// nothing. A screen that only runs at 60 Hz has no other rate to settle on,
/// so nothing is asked of it.
///
/// `defaults write com.beluga.classnote scrollFrameRate -int 60` asks for a
/// steady 60 Hz instead, and `0` turns the request off, from the next launch,
/// so either can be compared on the machine that judders without a new build.
@MainActor
final class ScrollFrameRate: NSObject {
    static let shared = ScrollFrameRate()

    static let settingKey = "scrollFrameRate"
    /// How long after the last scroll event the request is held, so a pause
    /// between two flicks does not drop the rate in the middle of reading.
    private static let linger: CFTimeInterval = 0.4

    private var monitor: Any?
    /// The stored setting: nil for the screen's own maximum, 0 for off.
    private var setting: Int?
    private var link: CADisplayLink?
    private weak var linkedView: NSView?
    private var linkedScreenMaximum = 0
    private var lastScrollAt: CFTimeInterval = 0

    /// The range to ask for on a screen that shows at most `screenMaximum`
    /// frames per second, or nil when there is nothing to ask for. `setting`
    /// is the stored preference: nil for the screen's maximum, 0 or less for
    /// off, otherwise that rate, never above what the screen can show.
    nonisolated static func range(setting: Int?, screenMaximum: Int) -> CAFrameRateRange? {
        if let setting, setting <= 0 { return nil }
        // A fixed-rate screen, unless a rate was asked for explicitly.
        if setting == nil, screenMaximum <= 60 { return nil }
        let target = min(setting ?? screenMaximum, max(screenMaximum, 1))
        let rate = Float(target)
        if target < 80 {
            return CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        }
        return CAFrameRateRange(minimum: 80, maximum: rate, preferred: rate)
    }

    func start() {
        guard monitor == nil else { return }
        setting = AppEnvironment.defaults.object(forKey: Self.settingKey) as? Int
        if let setting, setting <= 0 { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { ScrollFrameRate.shared.scrolled(in: event.window) }
            return event
        }
    }

    private func scrolled(in window: NSWindow?) {
        lastScrollAt = CACurrentMediaTime()
        guard let view = window?.contentView else { return }
        let screenMaximum = window?.screen?.maximumFramesPerSecond ?? 60
        if link == nil || linkedView !== view || linkedScreenMaximum != screenMaximum {
            link?.invalidate()
            link = nil
            linkedView = view
            linkedScreenMaximum = screenMaximum
            guard let range = Self.range(setting: setting, screenMaximum: screenMaximum) else { return }
            // A view's display link follows the view to whichever screen it is
            // on, and that screen's refresh rate.
            let newLink = view.displayLink(target: self, selector: #selector(tick(_:)))
            newLink.preferredFrameRateRange = range
            newLink.add(to: .main, forMode: .common)
            link = newLink
        }
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        if CACurrentMediaTime() - lastScrollAt > Self.linger {
            link.isPaused = true
        }
    }
}
