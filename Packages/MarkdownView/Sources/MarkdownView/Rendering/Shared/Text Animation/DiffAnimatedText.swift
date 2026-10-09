//
//  DiffAnimatedText.swift
//  MarkdownView
//
//  Created by Yanan Li on 2026/7/4.
//

import SwiftUI

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
struct DiffAnimatedText: View {
    let text: String

    @State private var sourceText: String
    @Environment(\.textDiffer) private var textDiffer
    @Environment(\.textTransition) private var textTransition

    nonisolated init(_ text: String) {
        self.text = text
        _sourceText = State(wrappedValue: text)
    }

    var body: some View {
        TransitionContent(
            sourceText: $sourceText,
            targetText: text,
            progress: sourceText != text ? 1 : 0,
            differ: textDiffer,
            transition: textTransition
        )
    }
    
    struct TransitionContent: View, @MainActor Animatable {
        @Binding var sourceText: String
        let targetText: String
        let differ: any TextDiffer
        let transition: any TextTransition

        var progress: Double
        var animatableData: Double {
            get { progress }
            set {
                progress = newValue
                scheduleSourceTextUpdateIfNeeded()
            }
        }

        init(
            sourceText: Binding<String>,
            targetText: String,
            progress: Double,
            differ: any TextDiffer,
            transition: any TextTransition
        ) {
            _sourceText = sourceText
            self.targetText = targetText
            self.progress = progress
            self.differ = differ
            self.transition = transition
        }

        var body: some View {
            let difference = differ.difference(from: sourceText, to: targetText)
            let sourceRenderer = DiffAnimatedTextRenderer(
                progress: 1 - progress,
                changedCharacterRanges: difference.changedSourceCharacterRanges,
                drawsUnchangedText: false,
                transition: transition
            )
            let targetRenderer = DiffAnimatedTextRenderer(
                progress: progress,
                changedCharacterRanges: difference.changedTargetCharacterRanges,
                transition: transition
            )

            ZStack {
                Text(sourceText)
                    .textRenderer(sourceRenderer)
                    .contentTransition(.identity)
                    .fixedSize()
                
                Text(targetText)
                    .textRenderer(targetRenderer)
                    .contentTransition(.identity)
                    .layoutPriority(1)
            }
        }
        
        private func scheduleSourceTextUpdateIfNeeded() {
            guard progress >= 1 else { return }
            
            let sourceText = $sourceText
            let targetText = targetText
            
            DispatchQueue.main.async {
                guard sourceText.wrappedValue != targetText else { return }
                sourceText.wrappedValue = targetText
            }
        }
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
#Preview {
    @Previewable @State var text = "Hello World"
    let textOptions = [
        "Hello World",
        "Welcome Hello World",   // Leading insertion
        "Welcome Swift World",   // Middle replacement
        "Welcome Swift",         // Trailing deletion
        "Swift"                  // Completely different
    ]
    
    Form {
        Section {
            Picker("Text", selection: $text.animation(.smooth)) {
                ForEach(textOptions, id: \.self) { textOption in
                    Text(textOption).tag(textOption)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }
    .safeAreaInset(edge: .top) {
        Text(text)
            .textTransition()
            .font(.title.bold())
            .containerRelativeFrame(.vertical, count: 2, span: 1, spacing: 0)
    }
}
