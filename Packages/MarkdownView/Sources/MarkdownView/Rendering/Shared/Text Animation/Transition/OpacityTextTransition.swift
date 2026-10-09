//
//  OpacityTextTransition.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct OpacityTextTransition: TextTransition {
    init() {
    }

    func apply(progress: Double, to context: inout GraphicsContext) {
        context.opacity = min(max(progress, 0), 1)
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension TextTransition where Self == OpacityTextTransition {
    static var opacity: Self { .init() }
}
