import SwiftUI

/// Centralized design tokens. Keeps the app visually coherent and makes the
/// "let me change ALL the corner radii" kind of edit a one-liner.
enum Theme {
    // MARK: - Colors

    /// Minimal editorial style: monochrome accent, no color-coded chrome.
    static let accent = Color.primary
    /// Label color for controls filled with `accent`. Because `accent` is
    /// `Color.primary` (white in dark mode), prominent buttons must use the
    /// inverse color for their label or the text disappears.
    #if os(macOS)
    static let onAccent = Color(nsColor: .windowBackgroundColor)
    #else
    static let onAccent = Color(uiColor: .systemBackground)
    #endif
    static let accentSoft = Color.primary.opacity(0.08)
    static let accentMuted = Color.secondary
    #if os(macOS)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .textBackgroundColor)
    #else
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let surfaceElevated = Color(uiColor: .systemBackground)
    #endif
    static let chrome = Color.primary.opacity(0.055)
    static let hairline = Color.primary.opacity(0.08)

    /// Translation color in overlay + transcript.
    static let translation = Color(red: 0.12, green: 0.52, blue: 0.48)

    static let recording = Color(red: 0.95, green: 0.30, blue: 0.30)
    static let success = Color(red: 0.20, green: 0.62, blue: 0.38)
    static let warning = Color(red: 0.82, green: 0.48, blue: 0.12)

    // MARK: - Metrics

    static let cornerSmall: CGFloat = 6
    static let cornerMedium: CGFloat = 8
    static let cornerLarge: CGFloat = 10

    static let cardPadding: CGFloat = 12
    static let gridSpacing: CGFloat = 12
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

/// Card chrome used everywhere (settings sections, session rows, transcript bubbles).
/// Editorial style: content + hairline border, no filled background block.
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cornerMedium
    var filled: Bool = true

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Outlined pill used for status labels. Only `Theme.recording` keeps a
/// filled/colored treatment — everything else stays monochrome to avoid
/// turning every list into a wall of colored badges.
struct PillStyle: ViewModifier {
    var color: Color
    func body(content: Content) -> some View {
        let isRecording = color == Theme.recording
        content
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(isRecording ? color.opacity(0.14) : Color.clear))
            .overlay(Capsule().stroke(isRecording ? Color.clear : color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(isRecording ? color : Color.secondary)
    }
}

extension View {
    func cardBackground(radius: CGFloat = Theme.cornerMedium, filled: Bool = true) -> some View {
        modifier(CardBackground(radius: radius, filled: filled))
    }
    func pill(_ color: Color) -> some View { modifier(PillStyle(color: color)) }
    /// Monochrome filled button: `accent` fill with the inverse label color.
    func prominentAccentButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(Theme.onAccent)
    }
}

/// Standard section container with a title — replaces Form's default ugly frame.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(Theme.cardPadding)
                .cardBackground()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
