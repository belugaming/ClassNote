import SwiftUI

/// Centralized design tokens. Keeps the app visually coherent and makes the
/// "let me change ALL the corner radii" kind of edit a one-liner.
enum Theme {
    // MARK: - Colors

    /// Clear academic blue: modern, readable, and calmer than the old amber UI.
    static let accent = Color(red: 0.16, green: 0.38, blue: 0.78)
    static let accentSoft = Color(red: 0.16, green: 0.38, blue: 0.78).opacity(0.12)
    static let accentMuted = Color(red: 0.31, green: 0.48, blue: 0.76)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .textBackgroundColor)
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

/// Card chrome used everywhere (settings sections, session rows, transcript bubbles).
struct CardBackground: ViewModifier {
    var radius: CGFloat = Theme.cornerMedium
    var filled: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(filled ? Theme.surface.opacity(0.72) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// Soft filled pill used for status labels.
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
