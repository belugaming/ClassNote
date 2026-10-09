//
//  StandardTextDiffer.swift
//  MarkdownView
//
//  Created by Codex on 2026/7/4.
//

import Foundation

/// A text differ that compares characters with Swift's standard collection difference API.
struct StandardTextDiffer: TextDiffer {
    /// Creates a standard text differ.
    init() { }

    /// Returns changed character ranges computed with `difference(from:)`.
    ///
    /// Removal offsets become source-only changes, and insertion offsets become target-only changes.
    func difference(from sourceText: String, to targetText: String) -> TextDifference {
        let sourceCharacters = Array(sourceText)
        let targetCharacters = Array(targetText)
        let difference = targetCharacters.difference(from: sourceCharacters)
        let changedSourceOffsets = difference.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else {
                return nil
            }

            return offset
        }
        let changedTargetOffsets = difference.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else {
                return nil
            }

            return offset
        }

        let changedSourceCharacterRanges = Self.ranges(
            forOffsets: changedSourceOffsets,
            upperBound: sourceCharacters.count
        )
        let changedTargetCharacterRanges = Self.ranges(
            forOffsets: changedTargetOffsets,
            upperBound: targetCharacters.count
        )

        return TextDifference(
            changes: changedSourceCharacterRanges.map { sourceRange in
                TextDifference.Change(
                    sourceRange: sourceRange,
                    targetRange: nil
                )
            } + changedTargetCharacterRanges.map { targetRange in
                TextDifference.Change(
                    sourceRange: nil,
                    targetRange: targetRange
                )
            }
        )
    }

    private static func ranges(forOffsets offsets: [Int], upperBound: Int) -> [Range<Int>] {
        let sortedOffsets = Set(offsets)
            .filter { offset in
                0 <= offset && offset < upperBound
            }
            .sorted()

        guard let firstOffset = sortedOffsets.first else {
            return []
        }

        var ranges: [Range<Int>] = []
        var lowerBound = firstOffset
        var upperBound = firstOffset + 1

        for offset in sortedOffsets.dropFirst() {
            if offset == upperBound {
                upperBound += 1
            } else {
                ranges.append(lowerBound..<upperBound)
                lowerBound = offset
                upperBound = offset + 1
            }
        }

        ranges.append(lowerBound..<upperBound)
        return ranges
    }
}

extension TextDiffer where Self == StandardTextDiffer {
    /// A standard text differ that compares individual characters.
    static var standard: Self { .init() }
}
