//
//  SwiftMathView.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/6/21.
//
//  ClassNote: a formula is typeset once into an image and drawn from a cache,
//  instead of being a live MTMathUILabel. See PATCHES.md.
//

#if ENABLE_MATH_RENDERING

import SwiftMath
import SwiftUI

struct SwiftMathView: View {
    var latex: String
    var font: any CustomCTFontConvertible
    var labelMode: MTMathUILabelMode
    var textAlignment: MTTextAlignment

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let platformFont = font.asPlatformFont
        let rendered = SwiftMathImageCache.image(
            latex: latex,
            fontSize: platformFont.pointSize,
            labelMode: labelMode,
            dark: colorScheme == .dark
        )
        Group {
            if let rendered {
                FormulaLayout(naturalSize: rendered.size) {
                    Image(platformImage: rendered)
                        .resizable()
                        .accessibilityLabel(latex)
                }
            } else {
                // LaTeX the typesetter cannot read stays legible as source.
                Text(latex)
                    .foregroundStyle(.secondary)
            }
        }
        .alignmentGuide(.firstTextBaseline) { dimensions in
            font.asPlatformFont.ascender
        }
        .alignmentGuide(.lastTextBaseline) { dimensions in
            font.asPlatformFont.ascender
        }
    }
}

/// Typeset formulas, keyed by everything that changes how they look.
///
/// A live `MTMathUILabel` parsed its LaTeX again on every view update and ran
/// the whole typesetter on every size query, with no cache, and the package
/// made two of them (plus a scroll view) per formula. A note with formulas
/// paid all of that each time a paragraph scrolled into view. Here a formula
/// is parsed and typeset once; after that it is an image, which costs nothing
/// to lay out or scroll. The image draws the typeset glyphs on demand, so it is
/// sharp at any screen scale.
@MainActor
enum SwiftMathImageCache {
    private static let images: NSCache<NSString, MTImage> = {
        let cache = NSCache<NSString, MTImage>()
        cache.countLimit = 2_000
        return cache
    }()
    /// LaTeX the typesetter rejected, so it is not parsed again on each update.
    private static var failures = Set<String>()

    static func image(latex: String, fontSize: CGFloat, labelMode: MTMathUILabelMode, dark: Bool) -> MTImage? {
        let key = "\(dark ? "d" : "l")|\(labelMode == .display ? "D" : "T")|\(fontSize)|\(latex)"
        if let cached = images.object(forKey: key as NSString) { return cached }
        if failures.contains(key) { return nil }

        let math = MTMathImage(
            latex: equation(in: latex),
            fontSize: fontSize,
            textColor: dark ? MTColor.white : MTColor.black,
            labelMode: labelMode,
            textAlignment: .left
        )
        let (error, image) = math.asImage()
        guard error == nil, let image, image.size.width > 0, image.size.height > 0 else {
            failures.insert(key)
            return nil
        }
        images.setObject(image, forKey: key as NSString)
        return image
    }

    /// The formula without its `$…$`, `\(…\)` or similar delimiters.
    private static func equation(in latex: String) -> String {
        guard let mathRepresentation = MathParser(text: latex).mathRepresentations.first,
              mathRepresentation.range == latex.startIndex..<latex.endIndex,
              !mathRepresentation.kind.preservesTerminatorsWhenRendering else {
            return latex
        }

        let contentStartIndex = latex.index(
            mathRepresentation.range.lowerBound,
            offsetBy: mathRepresentation.kind.leftTerminator.count
        )
        let contentEndIndex = latex.index(
            mathRepresentation.range.upperBound,
            offsetBy: -mathRepresentation.kind.rightTerminator.count
        )
        return String(latex[contentStartIndex..<contentEndIndex])
    }
}

/// A formula at its natural size, or scaled down to the width on offer when
/// that is narrower. Only the width counts: a formula is never shrunk to fit a
/// height.
private struct FormulaLayout: Layout {
    var naturalSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard naturalSize.width > 0 else { return .zero }
        let width = min(naturalSize.width, proposal.width ?? naturalSize.width)
        return CGSize(width: width, height: naturalSize.height * width / naturalSize.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

#endif
