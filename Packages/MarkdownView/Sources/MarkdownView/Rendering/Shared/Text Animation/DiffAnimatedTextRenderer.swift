//
//  DiffAnimatedTextRenderer.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct DiffAnimatedTextRenderer: TextRenderer {
    var progress: Double

    let changedCharacterRanges: [Range<Int>]
    var drawsUnchangedText = true
    let transition: any TextTransition

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.runSlices
        let totalCharacterCount = slices.reduce(0) { count, slice in
            count + slice.characterIndices.count
        }
        let changedCharacterRanges = changedCharacterRanges(in: 0..<totalCharacterCount)

        var currentCharacterOffset = 0

        for slice in slices {
            let sliceCharacterCount = slice.characterIndices.count
            let sliceRange = currentCharacterOffset..<(currentCharacterOffset + sliceCharacterCount)

            if changedCharacterRanges.contains(where: { $0.overlaps(sliceRange) }) {
                var changedTextContext = context
                transition.apply(progress: progress, to: &changedTextContext)
                changedTextContext.draw(slice, options: .disablesSubpixelQuantization)
            } else if drawsUnchangedText {
                context.draw(slice, options: .disablesSubpixelQuantization)
            }

            currentCharacterOffset += sliceCharacterCount
        }
    }

    private func changedCharacterRanges(in bounds: Range<Int>) -> [Range<Int>] {
        changedCharacterRanges.compactMap { range in
            let lowerBound = max(range.lowerBound, bounds.lowerBound)
            let upperBound = min(range.upperBound, bounds.upperBound)
            guard lowerBound < upperBound else { return nil }
            return lowerBound..<upperBound
        }
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
fileprivate extension Text.Layout {
    var runSlices: [Text.Layout.RunSlice] {
        var slices: [Text.Layout.RunSlice] = []

        for line in self {
            for run in line {
                for slice in run {
                    slices.append(slice)
                }
            }
        }

        return slices
    }
}
