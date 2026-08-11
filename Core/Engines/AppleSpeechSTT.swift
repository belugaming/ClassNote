import Foundation
import AVFoundation
import Speech

/// On-device speech recognition using macOS's built-in engines. Picks between
/// two backends at runtime because Apple's newer, faster engine only ships
/// starting macOS 26:
///   - macOS 26+  : `SpeechAnalyzer` + `SpeechTranscriber` (WWDC25), fully
///                  on-device, low latency, the "new dictation" engine.
///   - macOS 14-25: `SFSpeechRecognizer` with `requiresOnDeviceRecognition`
///                  set whenever the recognizer supports it.
/// Both paths only emit an event once a segment is finalized, matching the
/// "whole utterance lands at once" semantics the cloud Whisper engine uses.
final class AppleSpeechSTT: STTProvider, Sendable {
    init() {}

    func transcribe(audio: AsyncStream<AudioChunk>,
                    language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
        if #available(macOS 26.0, iOS 26.0, *) {
            return Self.transcribeModern(audio: audio, language: language)
        } else {
            return Self.transcribeLegacy(audio: audio, language: language)
        }
    }

    func transcribeFile(url: URL,
                        language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
        if #available(macOS 26.0, iOS 26.0, *) {
            return Self.transcribeFileModern(url: url, language: language)
        } else {
            return Self.transcribeFileLegacy(url: url, language: language)
        }
    }

    static func localeFor(_ languageCode: String?) -> Locale {
        guard let languageCode, !languageCode.isEmpty else { return Locale(identifier: "en-US") }
        return Locale(identifier: languageCode)
    }
}
