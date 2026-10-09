//
//  TextDiffer.swift
//  MarkdownView
//
//  Created by Codex on 2026/7/4.
//

import SwiftUI

/// A type that computes changed character ranges between two text values.
protocol TextDiffer: Sendable {
    /// Returns the changed source and target ranges between two text values.
    ///
    /// The returned ranges use character offsets, because `DiffAnimatedTextRenderer` applies transitions to text layout slices by character position.
    ///
    /// - Parameter sourceText: The old text that is currently visible.
    /// - Parameter targetText: The new text that should replace the source text.
    /// - Returns: The changed character ranges in both text values.
    func difference(from sourceText: String, to targetText: String) -> TextDifference
}

// MARK: - SwiftUI Environment Value

struct TextDifferEnvironmentKey: EnvironmentKey {
    static let defaultValue: any TextDiffer = .standard
}

extension EnvironmentValues {
    var textDiffer: any TextDiffer {
        get { self[TextDifferEnvironmentKey.self] }
        set { self[TextDifferEnvironmentKey.self] = newValue }
    }
}

