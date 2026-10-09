//
//  DefaultCodeBlockStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/3/25.
//

import SwiftUI

#if canImport(Highlightr)
@preconcurrency import Highlightr
#endif

/// Default code block style that applies to a MarkdownView.
public struct DefaultCodeBlockStyle: MarkdownCodeBlockStyle {
    /// Theme configuration in the current context.
    public var highlighterTheme: CodeHighlighterTheme
    
    /// Creates a default code block style.
    ///
    /// - Parameter highlighterTheme: The syntax highlighting theme configuration.
    public init(
        highlighterTheme: CodeHighlighterTheme = CodeHighlighterTheme(
            lightModeThemeName: "xcode",
            darkModeThemeName: "dark"
        )
    ) {
        self.highlighterTheme = highlighterTheme
    }
    
    public func makeBody(configuration: Configuration) -> some View {
        DefaultMarkdownCodeBlock(
            codeBlockConfiguration: configuration,
            theme: highlighterTheme
        )
    }
}

extension MarkdownCodeBlockStyle where Self == DefaultCodeBlockStyle {
    /// Default code block theme with light theme called "xcode" and dark theme called "dark".
    static public var `default`: DefaultCodeBlockStyle { .init() }
    
    /// Default code block theme with customized light & dark themes.
    static public func `default`(
        lightTheme: String = "xcode",
        darkTheme: String = "dark"
    ) -> DefaultCodeBlockStyle {
        .init(
            highlighterTheme: CodeHighlighterTheme(
                lightModeThemeName: lightTheme,
                darkModeThemeName: darkTheme
            )
        )
    }
}

fileprivate struct DefaultMarkdownCodeBlock: View {
    var codeBlockConfiguration: MarkdownCodeBlockStyleConfiguration
    
    var theme: CodeHighlighterTheme
    @Environment(\.colorScheme) private var colorScheme
    
    @Environment(\.markdownFontGroup.codeBlock) private var font
    
    @State private var language: String?
    @State private var attributedCode: AttributedString?
    @State private var codeHighlightTask: Task<Void, Error>?
    
    @State private var showCopyButton = false
    @State private var codeCopied = false
    
    var body: some View {
        ScrollView(.horizontal) {
            Group {
                if let attributedCode {
                    Text(attributedCode)
                } else {
                    Text(verbatim: codeBlockConfiguration.code)
                }
            }
            #if os(macOS) || os(iOS)
            .textSelection(.enabled)
            #endif
        }
        .task(id: codeHighlightingConfiguration, immediateHighlight)
        .onValueChange(codeBlockConfiguration) {
            debouncedHighlight()
        }
        .lineSpacing(4)
        .font(font._swiftUIFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS) || os(iOS)
        .safeAreaInset(edge: .top, spacing: 16) {
            HStack(spacing: 0) {
                if let language = codeBlockConfiguration.language {
                    Text(language)
                }
                Spacer() // minimum length of 10
                copyButton
            }
            .fontWeight(.semibold)
        }
        #endif
        .contentPadding(16)
        .background(.background)
        .clipShape(.rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.quaternary)
        }
    }
    
    private func debouncedHighlight() {
        codeHighlightTask?.cancel()
        codeHighlightTask = Task.detached(priority: .background) {
            try await updateAttributeCode()
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            try await highlight()
        }
    }
    
    private func updateAttributeCode() async throws {
        guard var attributedCode = attributedCode else { return }
        let characters = attributedCode.characters
        
        for difference in codeBlockConfiguration.code.difference(from: characters) {
            try Task.checkCancellation()
            
            switch difference {
            case .insert(let offset, let insertion, _):
                let insertionPoint = attributedCode.index(
                    attributedCode.startIndex,
                    offsetByCharacters: offset
                )
                attributedCode.insert(
                    AttributedString(String(insertion)),
                    at: insertionPoint
                )
            case .remove(let offset, _, _):
                let removalLowerBound = attributedCode.index(attributedCode.startIndex, offsetByCharacters: offset)
                let removalUpperBound = attributedCode.index(afterCharacter: removalLowerBound)
                attributedCode.removeSubrange(removalLowerBound..<removalUpperBound)
            }
        }
        
        try Task.checkCancellation()
        await MainActor.run {
            self.attributedCode = attributedCode
        }
    }
    
    private func immediateHighlight() async {
        do {
            try await highlight()
        } catch is CancellationError {
            // The task has been cancelled
        } catch {
            logger.error("\(String(describing: error), privacy: .public)")
        }
    }
    
    @Sendable
    nonisolated private func highlight() async throws {
        #if canImport(Highlightr)
        try Task.checkCancellation()
        let highlightr = Highlightr()!
        await highlightr.setTheme(to: theme.themeName(for: colorScheme))
        
        let specifiedLanguage = codeBlockConfiguration.language?.lowercased() ?? ""
        let language = highlightr.supportedLanguages()
            .first(where: { $0.localizedCaseInsensitiveCompare(specifiedLanguage) == .orderedSame })
        
        try Task.checkCancellation()
        
        let code = codeBlockConfiguration.code
        guard let highlightedCode = highlightr.highlight(code, as: language) else { return }
        let attributedCode = NSMutableAttributedString(
            attributedString: highlightedCode
        )
        attributedCode.removeAttribute(.font, range: NSMakeRange(0, attributedCode.length))
        
        try await MainActor.run {
            try Task.checkCancellation()
            self.attributedCode = AttributedString(attributedCode)
        }
        #endif
    }
    
    private var copyButton: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codeBlockConfiguration.code, forType: .string)
            #elseif os(iOS) || os(visionOS)
            UIPasteboard.general.string = codeBlockConfiguration.code
            #endif
            Task {
                withAnimation {
                    codeCopied = true
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation {
                    codeCopied = false
                }
            }
        } label: {
            HStack {
                if #available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
                    Text(codeCopied ? "Copied" : "Copy")
                        .textTransition()
                } else {
                    Text(codeCopied ? "Copied" : "Copy")
                        .contentTransition(.identity)
                }
                
                Group {
                    if codeCopied {
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "square.on.square")
                    }
                }
                .transition(copyCodeButtonIconTransition)
            }
            .contentShape(.rect)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .font(.callout.weight(.medium))
        .padding(.horizontal, -4)
    }
    
    private var copyCodeButtonTextTransition: AnyTransition {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) {
            AnyTransition(.blurReplace)
        } else {
            AnyTransition.opacity
        }
    }
    
    private var copyCodeButtonIconTransition: AnyTransition {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            AnyTransition(.symbolEffect(.drawOn).combined(with: .blurReplace))
        } else {
            copyCodeButtonTextTransition
        }
    }
}

extension DefaultMarkdownCodeBlock {
    struct CodeHighlightingConfiguration: Hashable, Sendable {
        var theme: CodeHighlighterTheme
        var colorScheme: ColorScheme
    }
    
    private var codeHighlightingConfiguration: CodeHighlightingConfiguration {
        CodeHighlightingConfiguration(
            theme: theme,
            colorScheme: colorScheme
        )
    }
}
