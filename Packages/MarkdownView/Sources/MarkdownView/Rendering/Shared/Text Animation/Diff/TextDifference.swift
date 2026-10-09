//
//  TextDifference.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import Foundation

/// The changed character ranges between source text and target text.
///
/// `DiffAnimatedText` renders source text and target text as separate layers during an update. Each change can identify characters that animate out of the source text, characters that animate into the target text, or both sides of a replacement.
struct TextDifference: Sendable, Equatable {
    /// The ordered changes between source text and target text.
    let changes: [Change]

    /// The changed character ranges in the source text.
    ///
    /// Use these ranges to mark characters that should receive the outgoing transition. For example, when `"Hello World"` changes to `"Hello Swift"`, the source range points at `"World"`.
    var changedSourceCharacterRanges: [Range<Int>] {
        changes.compactMap(\.sourceRange)
    }

    /// The changed character ranges in the target text.
    ///
    /// Use these ranges to mark characters that should receive the incoming transition. For example, when `"Hello World"` changes to `"Hello Swift"`, the target range points at `"Swift"`.
    var changedTargetCharacterRanges: [Range<Int>] {
        changes.compactMap(\.targetRange)
    }
    
    /// Creates a text difference with ordered changes.
    ///
    /// - Parameter changes: The ordered changes between source text and target text.
    init(changes: [Change]) {
        self.changes = changes
    }
}

extension TextDifference {
    /// A changed region in source text, target text, or both text values.
    struct Change: Sendable, Equatable {
        /// The changed character range in the source text.
        ///
        /// A `nil` value represents a pure insertion with no source characters to animate out.
        let sourceRange: Range<Int>?

        /// The changed character range in the target text.
        ///
        /// A `nil` value represents a pure deletion with no target characters to animate in.
        let targetRange: Range<Int>?

        /// Creates a changed region.
        ///
        /// - Parameter sourceRange: The changed character range in the source text, or `nil` for a pure insertion.
        /// - Parameter targetRange: The changed character range in the target text, or `nil` for a pure deletion.
        init(
            sourceRange: Range<Int>?,
            targetRange: Range<Int>?
        ) {
            self.sourceRange = sourceRange
            self.targetRange = targetRange
        }
    }
}
