import Foundation
import Translation

/// On-device translation using Apple's Translation framework. Unlike the
/// cloud LLM translator this returns each sentence as a single chunk rather
/// than a token stream — `TranslationSession.translate(_:)` has no streaming
/// API, so the whole result is yielded at once.
@available(macOS 15.0, iOS 18.0, *)
final class AppleTranslationEngine: TranslationProvider, Sendable {
    /// `glossary` is ignored: `TranslationSession.translate(_:)` takes a string
    /// and nothing else, so there is no prompt to put it in.
    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String],
                   glossary: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source = Locale.Language(identifier: sourceLanguage)
                    let target = Locale.Language(identifier: targetLanguage)
                    // Boxed, because only the main actor can vend a session and
                    // `TranslationSession` is not `Sendable`. `translate` is a
                    // nonisolated `async` method, so it is awaited here rather
                    // than on the main actor, exactly as before.
                    let box = try await Self.session(source: source, target: target)
                    let response = try await box.session.translate(text)
                    continuation.yield(response.targetText)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `TranslationSession(installedSource:target:)` (macOS 26+) requires the
    /// language pair to already be installed — it never prompts a download,
    /// it just fails. So we only take that fast path once `LanguageAvailability`
    /// confirms the pair is installed; otherwise (including "supported but not
    /// installed yet") we go through the SwiftUI `.translationTask` bridge,
    /// which is what actually drives the system's download-language-pack UI.
    @MainActor
    private static func session(source: Locale.Language,
                                target: Locale.Language) async throws -> TranslationSessionBox {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .unsupported:
            throw EngineError.unsupported("macOS 本地翻译不支持该语言对(\(source.languageCode?.identifier ?? "?") → \(target.languageCode?.identifier ?? "?"))。")
        case .installed:
            if #available(macOS 26.0, iOS 26.0, *) {
                return TranslationSessionBox(session: TranslationSession(installedSource: source, target: target))
            }
            return await AppleTranslationBridge.shared.session(source: source, target: target)
        case .supported:
            let box = await AppleTranslationBridge.shared.session(source: source, target: target)
            do {
                try await Self.prepare(box)
            } catch {
                throw EngineError.unsupported("本地翻译语言包尚未安装。请在系统设置 > 通用 > 语言与地区 > 翻译语言 中下载 \(source.languageCode?.identifier ?? "?") → \(target.languageCode?.identifier ?? "?")。")
            }
            return box
        @unknown default:
            return await AppleTranslationBridge.shared.session(source: source, target: target)
        }
    }

    /// Deliberately not `@MainActor`: `prepareTranslation()` is a nonisolated
    /// `async` method, so awaiting it *from* the main actor would push the
    /// non-Sendable session out of that actor's region — the crossing the box
    /// exists to keep in one place. Unwrapping it here does that once.
    private static func prepare(_ box: TranslationSessionBox) async throws {
        try await box.session.prepareTranslation()
    }

    private static func mapError(_ error: Error) -> Error {
        if let translationError = error as? TranslationError {
            return EngineError.unsupported(translationError.localizedDescription)
        }
        return error
    }
}
