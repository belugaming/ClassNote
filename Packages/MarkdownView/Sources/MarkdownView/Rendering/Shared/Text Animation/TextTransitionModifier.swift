//
//  TextTransitionModifier.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

extension SwiftUI.Text {
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    nonisolated func textTransition(
        _ transition: some TextTransition = .blur(radius: 3)
    ) -> some View {
        ResolvedText(self) { text in
            DiffAnimatedText(text)
                .textTransition(transition)
        }
    }
}

extension SwiftUI.View {
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    nonisolated func textTransition(_ transition: some TextTransition = .blur(radius: 3)) -> some View {
        environment(\.textTransition, transition)
    }

    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    nonisolated func textDiffer(_ differ: some TextDiffer) -> some View {
        environment(\.textDiffer, differ)
    }
}
