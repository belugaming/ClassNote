import Foundation
import Translation

/// On-device translation using Apple's Translation framework. Unlike the
/// cloud LLM translator this returns each sentence as a single chunk rather
/// than a token stream — `TranslationSession.translate(_:)` has no streaming
/// API, so the whole result is yielded at once.
@available(macOS 15.0, *)
final class AppleTranslationEngine: TranslationProvider, Sendable {
    func translate(text: String,
                   sourceLanguage: String,
                   targetLanguage: String,
                   context: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source = Locale.Language(identifier: sourceLanguage)
                    let target = Locale.Language(identifier: targetLanguage)
                    let session = try await Self.session(source: source, target: target)
                    let response = try await session.translate(text)
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
    private static func session(source: Locale.Language, target: Locale.Language) async throws -> TranslationSession {
        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .unsupported:
            throw EngineError.unsupported("macOS 本地翻译不支持该语言对(\(source.languageCode?.identifier ?? "?") → \(target.languageCode?.identifier ?? "?"))。")
        case .installed:
            if #available(macOS 26.0, *) {
                return TranslationSession(installedSource: source, target: target)
            }
            return await AppleTranslationBridge.shared.session(source: source, target: target)
        case .supported:
            let session = await AppleTranslationBridge.shared.session(source: source, target: target)
            do {
                try await session.prepareTranslation()
            } catch {
                throw EngineError.unsupported("本地翻译语言包尚未安装。请在系统设置 > 通用 > 语言与地区 > 翻译语言 中下载 \(source.languageCode?.identifier ?? "?") → \(target.languageCode?.identifier ?? "?")。")
            }
            return session
        @unknown default:
            return await AppleTranslationBridge.shared.session(source: source, target: target)
        }
    }

    private static func mapError(_ error: Error) -> Error {
        if let translationError = error as? TranslationError {
            return EngineError.unsupported(translationError.localizedDescription)
        }
        return error
    }
}
