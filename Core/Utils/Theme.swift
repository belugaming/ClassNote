import SwiftUI

/// Design tokens. The app follows the system: the user's accent color,
/// system materials and semantic text colors, so it looks at home in light and
/// dark mode and next to every other Mac app. What is ours is a small palette
/// with a job each: translation text, recording, success/warning.
enum Theme {
    // MARK: - Colors

    /// The user's system accent color.
    static let accent = Color.accentColor
    static let accentSoft = Color.accentColor.opacity(0.12)
    static let onAccent = Color.white

    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .textBackgroundColor)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let hairline = Color.primary.opacity(0.09)
    static let chrome = Color.primary.opacity(0.05)
    static let rowHover = Color.primary.opacity(0.045)

    /// Translation text. Teal, so it reads as a second voice next to the
    /// original in both appearances without competing with the accent.
    static let translation = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.42, green: 0.80, blue: 0.78, alpha: 1)
            : NSColor(red: 0.05, green: 0.50, blue: 0.50, alpha: 1)
    })

    static let recording = Color(nsColor: .systemRed)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)

    // MARK: - Metrics

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 14

    static let cardPadding: CGFloat = 14
    static let gridSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 22
    static let pagePadding: CGFloat = 24

    /// Reading width for long text (transcripts, notes): lines much longer
    /// than this are tiring to follow.
    static let readingWidth: CGFloat = 760
}

enum OverlayCaptionDisplayMode: String, CaseIterable, Identifiable {
    case original
    case bilingual
    case translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return L10n.t("overlay.display.original")
        case .bilingual: return L10n.t("overlay.display.bilingual")
        case .translation: return L10n.t("overlay.display.translation")
        }
    }

    var systemImage: String {
        switch self {
        case .original: return "text.alignleft"
        case .bilingual: return "rectangle.split.2x1"
        case .translation: return "character.bubble"
        }
    }
}

enum OverlayCaptionTextSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return L10n.t("overlay.textSize.small")
        case .medium: return L10n.t("overlay.textSize.medium")
        case .large: return L10n.t("overlay.textSize.large")
        case .extraLarge: return L10n.t("overlay.textSize.extraLarge")
        }
    }

    var primaryPointSize: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 20
        case .large: return 26
        case .extraLarge: return 32
        }
    }

    var secondaryPointSize: CGFloat {
        switch self {
        case .small: return 13
        case .medium: return 16
        case .large: return 20
        case .extraLarge: return 24
        }
    }
}

enum OverlayCaptionRecentCount: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4

    var id: Int { rawValue }

    var title: String {
        String(format: L10n.t("overlay.recentCount.value"), rawValue)
    }
}

extension String {
    func overlayCaptionTail(maxLines: Int) -> String {
        let maxLines = max(1, maxLines)
        let trimmedText = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        let maxCharacters = maxLines * 86
        let captionText = trimmedText.overlayCaptionSentenceBreaks()
        let scanText = String(captionText.overlayBoundedSuffix(maxCharacters: maxCharacters * 3))

        let logicalLines = scanText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let tailText: String
        if logicalLines.count > maxLines {
            tailText = logicalLines.suffix(maxLines).joined(separator: "\n")
        } else {
            tailText = scanText
        }

        guard tailText.count > maxCharacters else { return tailText }
        return String(tailText.suffix(maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func overlayBoundedSuffix(maxCharacters: Int) -> Substring {
        guard maxCharacters > 0,
              let start = index(endIndex, offsetBy: -maxCharacters, limitedBy: startIndex)
        else {
            return self[startIndex..<endIndex]
        }
        return self[start..<endIndex]
    }

    private func overlayCaptionSentenceBreaks() -> String {
        replacingOccurrences(
            of: #"(?<!\d)\.\s+(?=\S)"#,
            with: ".\n",
            options: .regularExpression
        )
    }
}

/// A quiet surface for grouped content.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cornerMedium
    var filled: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(filled ? AnyShapeStyle(Theme.surfaceElevated) : AnyShapeStyle(Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Small status label.
struct PillStyle: ViewModifier {
    var color: Color
    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

extension View {
    func cardBackground(radius: CGFloat = Theme.cornerMedium, filled: Bool = true) -> some View {
        modifier(CardBackground(radius: radius, filled: filled))
    }
    func pill(_ color: Color) -> some View { modifier(PillStyle(color: color)) }
}

/// A titled group on a settings-style page.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.cardPadding)
                .cardBackground(radius: Theme.cornerLarge)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Caption label above a control.
struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content
        }
    }
}

/// A centered placeholder for an empty list or pane.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "mm:ss" or "h:mm:ss".
enum TimeLabel {
    static func string(ms: Int64) -> String {
        let s = Int(max(0, ms) / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
