//
//  TextTransition.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
protocol TextTransition: Sendable {
    func apply(progress: Double, to context: inout GraphicsContext)
}

// MARK: - SwiftUI Environment Value

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
struct TextTransitionEnvironmentKey: EnvironmentKey {
    static let defaultValue: any TextTransition = .blur
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension EnvironmentValues {
    var textTransition: any TextTransition {
        get { self[TextTransitionEnvironmentKey.self] }
        set { self[TextTransitionEnvironmentKey.self] = newValue }
    }
}
