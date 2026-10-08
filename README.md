# ClassNote

macOS-native lecture recorder for US-bound study-abroad students. Records classroom audio (mic + Zoom/Teams/Meet system audio + imported video), streams it through configurable OpenAI-compatible APIs for transcription and translation, and organizes everything into searchable bilingual notes that live entirely on your Mac.

## Highlights

- **Three audio sources**: microphone (classroom), system audio via `ScreenCaptureKit` (online meetings), or both mixed onto one timeline, plus file import (post-class recordings). Recordings are written as fragmented `.m4a`, so a crash or force-quit still leaves a playable file, and quitting mid-lecture finalises the recording first.
- **Real-time bilingual subtitles**: word-level streaming transcription + streaming translation, with the transcript rolling in as you speak. If the local engine dies mid-class it is restarted and subtitles resume; a translation that fails is marked and can be retried later, line by line or all at once.
- **Local-first storage**: GRDB + SQLite FTS5, everything stays in `~/Library/Application Support/ClassNote/` — audio, transcripts, notes. Full-text search works in Chinese as well as English, and a search hit opens the transcript at that line. Imported files are referenced where they are, not copied, and are followed if they are later moved or renamed.
- **Import from Voice Memos**: pick recordings from the Voice Memos library by title, date and length, including ones recorded on an iPhone and synced by iCloud. Each is referenced in place, so the recording is stored once. Needs Full Disk Access, because macOS protects the Voice Memos library; the library's layout is not public API, so titles are read defensively and the import still works from the audio files alone.
- **iCloud sync across Macs** (Settings → General, off by default): each lecture, with its transcript, notes, highlights, flashcards, Q&A and recording, is kept in iCloud Drive › ClassNote, and every Mac that turns it on merges it into its own database. The SQLite database itself is never put in iCloud, where two Macs writing it would corrupt it. A lecture changed on two Macs before they sync keeps the later change; a deletion reaches the other Macs unless the lecture was edited after it. Settings and API keys stay on each Mac.
- **Pluggable engines**: one OpenAI-compatible `base_url` / `key` with independent model IDs for STT / translation / notes, or fully local engines for each. One-click presets for OpenAI, DeepSeek, Groq, SiliconFlow, Ollama and LM Studio; the local servers need no API key, and presets say so when a provider serves no transcription endpoint. Notes, Q&A and highlight explanations can instead go to Claude through the Anthropic Messages API (its own base URL, key, model and thinking effort, so transcription can stay on Whisper or a local engine); Claude's thinking summary shows while it works. Notes, Q&A, flashcards, study tools and highlight explanations all open with the same prompt prefix (shared system prompt, then the transcript), so on Claude, and on providers that cache repeated prefixes on their own, they share one cached transcript per lecture instead of each paying for it again.
- **Two local recognisers**, both streaming, both installed on first use:
  - **Confucius4-R2T2** (NetEase Youdao, Qwen3-ASR 1.7B, run on MLX): committed text is only ever appended, never rewritten, and the course name and glossary terms go in as its prompt. Best for Chinese and English. It re-decodes a rolling 16 s window each step with the committed text as the prefix (a port of the reference `streaming_transcribe_no_reset`), so a two-hour lecture costs the same per step as its first minute.
  - **Nemotron 3.5** (below): lighter, CPU only, 40 languages.
- **Whole-sentence translation**: a line the recogniser breaks only for length is not translated on its own; the sentence is translated once it ends, with the two sentences before it as context and the course glossary terms that occur in it. Hy-MT2 gets these through its own trained templates (background information, terminology intervention).
- **Local simultaneous interpreting (Chinese ↔ English)**: **Confucius4-T3PO** (14B, run on mlx-lm) is fed the lecture line by line and decides for itself when it has heard enough to translate, keeping the lecture's translation history in view. Its output appears word by word as it is generated. First use downloads the 28 GB checkpoint and converts it to a ~8 GB 4-bit model; needs 32 GB of memory or more.
- **Nemotron details**: fully local transcription with no API calls. One model covers all languages, so there is no engine to pick per language:
  - NVIDIA `nemotron-3.5-asr-streaming-0.6b`, a cache-aware FastConformer transducer covering 40 languages with its own punctuation and casing, runs through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) on the CPU. At the default 160 ms chunk a word reaches the screen about 200 ms after it is spoken (measured RTF ≈ 0.15–0.19 on an M-series Mac), and the chunk size is a setting (80 ms – 1120 ms).
  - A CT-Transformer punctuation model (Chinese + English, 300 MB, a few milliseconds per call) restores punctuation and decides where sentences end. Streaming ASR models place sentence marks late or not at all in continuous speech; this one reads the text instead, so lines break at real sentence boundaries and carry punctuation and capitalisation.
  - Segmentation never resets the decoder: a line closes at a punctuation-model sentence end, on a pause (no voice energy for 0.8 s), or on a 6 s soft cut at a clause or word boundary, so nothing is lost at the seams — and the clock is sample-accurate, so a two-hour lecture segments as well as its first minute.
- **Offline translation and notes too**: `Hy-MT2-1.8B` translates locally through MLX, and a local `Qwen3-4B-Instruct` (mlx-lm) can generate notes, answer questions, make flashcards and explain highlights, so a fully local setup needs no API key at all. Long transcripts are summarised in parts and merged.
- **AI tutor beside the live transcript**: while a lecture runs, a side panel explains every minute or so (30 s / 1 min / 2 min, or only when asked) what the lecturer just said, in plain words and in your language, with the key terms a newcomer would not know and an intuition when one helps — formulas render as LaTeX. **Explain** covers the last minute including the sentence still being spoken, a question box answers from the lecture so far (follow-ups included), and any card can be kept as an explained highlight of the session. It runs on the notes & Q&A engine, cloud or local.
- **Class background before the AI writes**: each course says what kind of class it is (lecture, seminar, lab, one-on-one lesson, rehearsal) and carries a background in your words; each session can be introduced in a sentence or two (the pieces you played, the chapter, what the teacher stressed) with per-class sentence starters, carried over from the last session, or drafted by the AI from the transcript for you to correct. Notes, Q&A, flashcards, study tools and highlight explanations all read it, and the suggested note template follows the kind of class — lesson notes with feedback per piece and a practice plan, or discussion notes for a seminar.
- **AI-generated structured notes**: Markdown summaries from the lecture transcript, Q&A, flashcards and study tools, rendered as full CommonMark/GFM (nested lists, tables, highlighted code) with LaTeX formulas, all aware of the course: each course carries an instructor, term, notes and a glossary that is fed to the translator and every prompt so terms are rendered consistently.
- **Re-transcribe from the recording**: re-run a session's transcript from its saved audio with a better engine, or after a crash recovery; notes and highlights are kept.
- **MenuBar panel + global shortcuts**: ⌘⇧R to start/stop, ⌘⇧M to bookmark a moment, ⌘⇧T to toggle translation, ⌘⇧O for floating captions — all work with every window closed. In the app, ⌘N starts or stops a recording and ⌘B marks a moment.
- **Audio player** in every session: play/pause, scrub, and the line under the playhead follows along.

## Requirements

- macOS 14+ (Apple Silicon recommended)
- Xcode 26+ / Swift 5.10+
- `xcodegen` (`brew install xcodegen`)
- An OpenAI-compatible API endpoint (OpenAI official, DeepSeek, Groq, SiliconFlow, Ollama, LM Studio, etc.) — not needed if you use the local engines for transcription, translation and notes
- For the local ASR engine: an Apple Silicon Mac. **No Python setup required** — the app uses a system `python3` if one is 3.11 or newer, and otherwise downloads a self-contained CPython (pinned and SHA-256 verified) into Application Support. macOS's built-in `/usr/bin/python3` is 3.9 and has no `sherpa-onnx` wheel, so it is skipped.

  Install from **Settings → Engines**, which creates a venv under `~/Library/Application Support/ClassNote/pyenv/` and downloads the weights with progress. **Settings → Models** lists every model with its source, size on disk and a Delete button. The sidecars' direct dependencies are pinned to exact versions in `Scripts/requirements-local.txt`, so two machines installing a week apart get the same program:

  | model | role | size |
  |---|---|---|
  | `nemotron-3.5-asr-streaming-0.6b` (sherpa-onnx int8) | streaming ASR, one file per chunk size | 650 MB |
  | `sherpa-onnx-punct-ct-transformer-zh-en` | punctuation and sentence boundaries (Nemotron) | 300 MB |
  | `mlx-community/Confucius4-R2T2-8bit` | streaming ASR, append-only (optional) | ≈2.4 GB |
  | `Hy-MT2-1.8B-4bit` | local sentence translation (optional) | 1.0 GB |
  | `netease-youdao/Confucius4-T3PO` → 4-bit MLX | local simultaneous translation, zh ↔ en (optional) | 28 GB download → ≈8 GB |
  | `Qwen3-4B-Instruct-2507-4bit` | local notes / Q&A / flashcards (optional) | 2.4 GB |

  Weights live in `~/.cache/huggingface`, pinned to specific revisions so an upstream re-export cannot change a model under you. The ASR engine loads into memory at launch (about 3 GB resident) and stays warm, so recordings start instantly; the notes model is loaded on demand and freed after five idle minutes or when a recording starts.

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

## Release

1. On `main`, set `MARKETING_VERSION` to the new version in `project.yml` and bump `CURRENT_PROJECT_VERSION`.
2. Tag that commit and push the tag: `git tag v0.16.0 && git push origin v0.16.0`. The tag must match `MARKETING_VERSION`, or the release stops at its first step.

The Release workflow runs the tests, then builds two DMGs and attaches them to a GitHub Release: `ClassNote-<version>-arm64.dmg` for Apple Silicon and `ClassNote-<version>-x86_64.dmg` for Intel Macs. The local engines need Apple Silicon; on Intel, use the cloud API or Apple's on-device speech. The app is not notarized, so the first launch has to be allowed in System Settings → Privacy & Security.

## Configure

1. Launch the app, open **Settings → Cloud API**.
2. Pick a provider preset or paste your own `base_url` + key.
3. Set model IDs for STT, translation, and notes/QA (they can differ).
4. Click **Test connection** to verify.
5. Or skip the API entirely: in **Settings → Engines** pick Nemotron or R2T2 for transcription, Hy-MT2 or T3PO for translation, and Qwen3 for notes & Q&A.

Your API key is stored only in the local SQLite DB, never transmitted except to the endpoint you specify.

## Roadmap

The design docs, specs and plans live under `docs/superpowers/`.

- **v1** (this): record + real-time bilingual subtitles + AI notes + course organization + FTS search + highlights + video import.
- **v1.1**: Speaker Diarization (FluidAudio), PPT-sync screenshots + OCR, personal vocabulary deck + Flashcards, knowledge-base QA.
- **v2**: self-hosted sync server, iOS review companion.

## License

Private / personal use. (Your own code — no license terms committed.)
