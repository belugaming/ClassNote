//
//  InlineMath.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/6/17.
//
//  ClassNote: one formula view instead of a `ViewThatFits` holding two and a
//  horizontal scroll view; a formula wider than the line is scaled to fit.
//  See PATCHES.md.
//

#if ENABLE_MATH_RENDERING
import SwiftUI

struct InlineMath: View {
    var latexText: String
    @Environment(\.markdownFontGroup.inlineMath) private var font

    init(latexText: String) {
        self.latexText = latexText
    }

    var body: some View {
        SwiftMathView(
            latex: latexText,
            font: font,
            labelMode: .text,
            textAlignment: .left
        )
    }
}

#endif
