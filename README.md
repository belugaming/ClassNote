# ClassNote

macOS-native lecture recorder for US-bound study-abroad students. Records classroom audio (mic + Zoom/Teams/Meet system audio + imported video), streams it through configurable OpenAI-compatible APIs for transcription and translation, and organizes everything into searchable bilingual notes that live entirely on your Mac.

## Highlights

- **Three audio sources**: microphone (classroom), system audio via `ScreenCaptureKit` (online meetings), and file import (post-class recordings).
- **Real-time bilingual subtitles**: chunked transcription + streaming chat-completion translation, with the transcript rolling in as you speak.
- **Local-first storage**: GRDB + SQLite FTS5, everything stays in `~/Library/Application Support/ClassNote/` — audio, transcripts, notes.
- **Pluggable engines**: one global OpenAI-compatible `base_url` / `key`, independent model IDs for STT / translation / notes / QA. One-click presets for OpenAI, DeepSeek, Groq, SiliconFlow, Ollama, LM Studio.
- **Offline ASR, word by word in every language**: fully local transcription with no API calls, installed automatically on first use. One model covers all languages, so there is no engine to pick per language:
  - NVIDIA `nemotron-3.5-asr-streaming-0.6b`, a cache-aware FastConformer transducer covering 40 languages with its own punctuation and casing, runs through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) on the CPU. At the default 160 ms chunk a word reaches the screen about 200 ms after it is spoken (measured RTF ≈ 0.15–0.19 on an M-series Mac), and the chunk size is a setting (80 ms – 1120 ms).
  - A CT-Transformer punctuation model (Chinese + English, 300 MB, a few milliseconds per call) restores punctuation and decides where sentences end. Streaming ASR models place sentence marks late or not at all in continuous speech; this one reads the text instead, so lines break at real sentence boundaries and carry punctuation and capitalisation.
  - Segmentation never resets the decoder: a line closes at a punctuation-model sentence end, on a pause (no voice energy for 0.8 s), or on a 6 s soft cut at a clause or word boundary, so nothing is lost at the seams.
  - The earlier two-pass design (MLX streaming draft + Qwen3-ASR re-transcription) is gone: the ONNX runtime is fast enough at small chunks that the correction pass no longer paid for its delay and 2–4 GB of memory.
- **AI-generated structured notes**: one-shot Markdown summary from the lecture transcript, course-level organization, retranslate with a bigger model when you have time.
- **MenuBar mini + global shortcuts**: ⌘⇧R to start/stop, ⌘⇧M to bookmark a moment, ⌘⇧T to toggle translation — works even when the main window is hidden.
- **Full-text search** across every lecture you've ever recorded.

## Requirements

- macOS 14+ (Apple Silicon recommended)
- Xcode 26+ / Swift 5.10+
- `xcodegen` (`brew install xcodegen`)
- An OpenAI-compatible API endpoint (OpenAI official, DeepSeek, Groq, SiliconFlow, Ollama, LM Studio, etc.) — not needed if you only use the local MLX engine
- For the local ASR engine: an Apple Silicon Mac. **No Python setup required** — the app uses a system `python3` if one is 3.11 or newer, and otherwise downloads a self-contained CPython (pinned and SHA-256 verified) into Application Support. macOS's built-in `/usr/bin/python3` is 3.9 and has no `sherpa-onnx` wheel, so it is skipped.

  Install from **Settings → Engines**, which creates a venv under `~/Library/Application Support/ClassNote/pyenv/` and downloads the weights with progress. The sidecar's direct dependencies are pinned to exact versions in `Scripts/requirements-*.txt`, so two machines installing a week apart get the same program:

  | model | role | size |
  |---|---|---|
  | `nemotron-3.5-asr-streaming-0.6b` (sherpa-onnx int8) | streaming ASR, one file per chunk size | 650 MB |
  | `sherpa-onnx-punct-ct-transformer-zh-en` | punctuation and sentence boundaries | 300 MB |
  | `Hy-MT2-1.8B-4bit` | local translation (optional) | 1.0 GB |

  Weights live in `~/.cache/huggingface`. The engine loads into memory at launch (about 3 GB resident) and stays warm, so recordings start instantly.

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

The Swift suite mixes unit, integration and per-bug regression tests: DB schema + FTS, WAV encoder, VAD, transcript buffer, OpenAI-compatible HTTP (SSE + multipart) against a local mock server, and a full file-import → transcribe → translate → persist → search end-to-end flow. It runs against a throwaway data directory and a throwaway `UserDefaults` suite, so it never touches your own recordings, database or API key.

The Python sidecars have their own tests:

```sh
python3 -m unittest discover -s Tests/PythonTests
```

## Configure

1. Launch the app, open **Settings → API**.
2. Pick a provider preset or paste your own `base_url` + key.
3. Set model IDs for STT, translation, and notes/QA (they can differ).
4. Click **Test connection** to verify.

Your API key is stored only in the local SQLite DB, never transmitted except to the endpoint you specify.

## Roadmap

The design docs, specs and plans live under `docs/superpowers/`.

- **v1** (this): record + real-time bilingual subtitles + AI notes + course organization + FTS search + highlights + video import.
- **v1.1**: Speaker Diarization (FluidAudio), PPT-sync screenshots + OCR, personal vocabulary deck + Flashcards, knowledge-base QA.
- **v2**: self-hosted sync server, iOS review companion.

## License

Private / personal use. (Your own code — no license terms committed.)
