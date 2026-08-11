# ClassNote

macOS-native lecture recorder for US-bound study-abroad students. Records classroom audio (mic + Zoom/Teams/Meet system audio + imported video), streams it through configurable OpenAI-compatible APIs for transcription and translation, and organizes everything into searchable bilingual notes that live entirely on your Mac.

## Highlights

- **Three audio sources**: microphone (classroom), system audio via `ScreenCaptureKit` (online meetings), and file import (post-class recordings).
- **Real-time bilingual subtitles**: chunked transcription + streaming chat-completion translation, with the transcript rolling in as you speak.
- **Local-first storage**: GRDB + SQLite FTS5, everything stays in `~/Library/Application Support/ClassNote/` — audio, transcripts, notes.
- **Pluggable engines**: one global OpenAI-compatible `base_url` / `key`, independent model IDs for STT / translation / notes / QA. One-click presets for OpenAI, DeepSeek, Groq, SiliconFlow, Ollama, LM Studio.
- **Offline Chinese ASR (FunASR, 2-pass)**: fully local transcription with no API calls. `paraformer-zh-streaming` emits low-latency partials while FSMN-VAD finds sentence boundaries; each finished sentence is then re-transcribed offline by `paraformer-zh` + `ct-punc` and replaces the streaming text with a punctuated, more accurate version. Uses the Apple GPU for the streaming pass (~0.15 realtime factor on Apple Silicon), so subtitles keep pace with speech.
- **AI-generated structured notes**: one-shot Markdown summary from the lecture transcript, course-level organization, retranslate with a bigger model when you have time.
- **MenuBar mini + global shortcuts**: ⌘⇧R to start/stop, ⌘⇧M to bookmark a moment, ⌘⇧T to toggle translation — works even when the main window is hidden.
- **Full-text search** across every lecture you've ever recorded.

## Requirements

- macOS 14+ (Apple Silicon recommended)
- Xcode 26+ / Swift 5.10+
- `xcodegen` (`brew install xcodegen`)
- An OpenAI-compatible API endpoint (OpenAI official, DeepSeek, Groq, SiliconFlow, Ollama, LM Studio, etc.) — not needed if you only use the local FunASR engine
- For the local FunASR engine: `python3` on the system. The app creates its own venv under `~/Library/Application Support/ClassNote/pyenv/` on first use and downloads ~1 GB of models to `~/.cache/modelscope/`.

## Build

```sh
xcodegen generate
xcodebuild -project ClassNote.xcodeproj -scheme ClassNote -configuration Release -destination 'platform=macOS,arch=arm64' -skipMacroValidation build
```

The built `.app` lands in `~/Library/Developer/Xcode/DerivedData/ClassNote-*/Build/Products/Release/ClassNote.app`.

## Test

```sh
xcodebuild -project ClassNote.xcodeproj -scheme ClassNote -destination 'platform=macOS,arch=arm64' -skipMacroValidation test
```

14 unit + integration tests cover DB schema + FTS, WAV encoder, VAD, transcript buffer, OpenAI-compatible HTTP (SSE + multipart) against a local mock server, and a full file-import → transcribe → translate → persist → search end-to-end flow.

## Configure

1. Launch the app, open **Settings → API**.
2. Pick a provider preset or paste your own `base_url` + key.
3. Set model IDs for STT, translation, and notes/QA (they can differ).
4. Click **Test connection** to verify.

Your API key is stored only in the local SQLite DB, never transmitted except to the endpoint you specify.

## Roadmap

See `.claude/plans/macos-crispy-cerf.md` for the full design doc, milestone split, and risk register.

- **v1** (this): record + real-time bilingual subtitles + AI notes + course organization + FTS search + highlights + video import.
- **v1.1**: Speaker Diarization (FluidAudio), PPT-sync screenshots + OCR, personal vocabulary deck + Flashcards, knowledge-base QA.
- **v2**: Local WhisperKit + MLX (fully offline), self-hosted sync server, iOS review companion.

## License

Private / personal use. (Your own code — no license terms committed.)
