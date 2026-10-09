import SwiftUI

/// Whether text that keeps growing (a live transcript, an answer being
/// written) should keep scrolling itself to its end. It does until the reader
/// scrolls up to look at something, and again once they scroll back down to
/// the end. Text growing under a reader who has not moved is not a scroll up,
/// so following survives every new line.
///
/// Before this, each new word scrolled to the end unconditionally, several
/// times a second, so a reader who scrolled up was dragged straight back down
/// and the page looked like it could not be scrolled.
enum BottomFollow {
    struct Position: Equatable {
        /// How far the content is scrolled from its top.
        var offset: CGFloat
        /// How much content lies below the visible part.
        var distanceToEnd: CGFloat
    }

    /// Within this of the end counts as at the end.
    static let slack: CGFloat = 40

    static func following(_ following: Bool, from old: Position, to new: Position) -> Bool {
        if new.distanceToEnd <= slack { return true }
        if new.offset < old.offset - 1 { return false }
        return following
    }
}

extension View {
    /// Keeps `following` in step with the reader's scrolling.
    func tracksBottomFollow(_ following: Binding<Bool>) -> some View {
        modifier(BottomFollowTracker(following: following))
    }
}

private struct BottomFollowTracker: ViewModifier {
    @Binding var following: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: BottomFollow.Position.self) { geometry in
            BottomFollow.Position(offset: geometry.contentOffset.y,
                                  distanceToEnd: geometry.contentSize.height - geometry.visibleRect.maxY)
        } action: { old, new in
            let next = BottomFollow.following(following, from: old, to: new)
            if next != following { following = next }
        }
    }
}
