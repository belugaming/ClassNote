//
//  ResolvedText.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

struct ResolvedText<Content: View>: View {
    let text: Text
    @Environment(\.self) var environmentValues
    
    @ViewBuilder var content: @Sendable (String) -> Content
    
    nonisolated init(
        _ text: Text,
        @ViewBuilder content: @Sendable @escaping (String) -> Content
    ) {
        self.text = text
        self.content = content
    }
    
    var body: some View {
        let resolvedString: String = text._resolveText(in: environmentValues)
        content(resolvedString)
    }
}
