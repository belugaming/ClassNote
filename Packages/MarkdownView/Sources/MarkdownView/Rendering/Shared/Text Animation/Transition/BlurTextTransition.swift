//
//  BlurTextTransition.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct BlurTextTransition: TextTransition {
    let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
    }

    func apply(progress: Double, to context: inout GraphicsContext) {
        let progress = min(max(progress, 0), 1)
        context.opacity = progress
        context.addFilter(.blur(radius: radius * (1 - progress)))
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension TextTransition where Self == BlurTextTransition {
    static var blur: BlurTextTransition { .init(radius: 12) }
    
    static func blur(radius: CGFloat = 3) -> Self {
        .init(radius: radius)
    }
}
