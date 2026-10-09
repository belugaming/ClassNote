import Foundation
import AVFoundation
import Speech

/// On-device speech recognition with macOS's built-in engine,
/// `SpeechAnalyzer` + `SpeechTranscriber` (WWDC25): fully on-device, low
/// latency, the "new dictation" engine. It only emits an event once a segment
/// is finalized, matching the "whole utterance lands at once" semantics the
/// cloud Whisper engine uses.
final class AppleSpeechSTT: STTProvider, Sendable {
    init() {}

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        Self.transcribeModern(audio: audio, language: language)
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        Self.transcribeFileModern(url: url, language: language)
    }

    static func localeFor(_ languageCode: String?) -> Locale {
        guard let languageCode, !languageCode.isEmpty else { return Locale(identifier: "en-US") }
        return Locale(identifier: languageCode)
    }
}
