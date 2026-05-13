# Highlight-Driven AI Explanation — Design

## Goal

When the user taps a highlight in the session detail view, an AI explanation of the surrounding transcript range appears in a side panel. Users pick from preset prompts ("explain", "example", "exam focus", "terms"). Every call sends the full transcript as background context. Results are streamed into the UI and persisted on the highlight row so the next click is instant.

Today `⌘⇧M` saves a bare timestamp, and clicking a row in the highlights tab does nothing — this spec fixes that.

## Non-goals

- No custom user-authored prompts (preset menu only, v1).
- No per-preset explanation history — latest explanation wins per highlight.
- No range picker that goes outside segment boundaries (always snapped to segments).
- No automatic explanation during live recording; explanation is a playback-time feature.
- No chat / follow-up turns — each preset click is a one-shot generation.
- No token-budget truncation of the full transcript; we trust the provider to surface a context-length error.

## Data model

Migration `v2_highlight_explanation` adds six nullable columns to `highlight`:

| column | type | purpose |
|---|---|---|
| `range_start_ms` | INTEGER | start of the explained range, snapped to a segment boundary |
| `range_end_ms` | INTEGER | end of the explained range |
| `explanation_md` | TEXT | Markdown produced by the LLM (NULL = not yet explained) |
| `explanation_prompt` | TEXT | preset key that produced it (`explain`/`example`/`exam`/`terms`) |
| `explanation_model` | TEXT | LLM model id used |
| `explanation_generated_at` | INTEGER | ms timestamp |

All columns stay NULL for rows created before the migration and for newly-marked highlights that have not been explained yet. Running a preset **overwrites** all six columns (latest-wins). "Clear explanation" sets them all back to NULL.

The `Highlight` Swift struct gains six optional properties matching the columns. `HighlightRepository` gains:

```swift
func updateExplanation(id: Int64,
                       rangeStartMs: Int64,
                       rangeEndMs: Int64,
                       promptKey: String,
                       model: String,
                       markdown: String,
                       generatedAt: Int64) async throws
func clearExplanation(id: Int64) async throws
```

No new table. No change to FTS, notes, or the export pipeline (exports can later include explanations; out of scope here).

## Range computation

When the user triggers a preset on a highlight, the view model computes the range once (or reuses the stored range on subsequent runs after expand/shrink):

1. Binary-search `segments` (already sorted by `start_ms`) for the segment containing `highlight.timestampMs` (`startMs ≤ ts ≤ endMs`). If the mark falls in silence, pick the segment with the smallest distance to the mark.
2. Anchor index = that segment's index. Take a window of `anchor - radius … anchor + radius`, where `radius = 2` (constant `Highlight.defaultRangeRadius`).
3. Clamp to `[0, count - 1]`.
4. `range_start_ms = window.first.startMs`, `range_end_ms = window.last.endMs`.

Expand/shrink in the UI increments/decrements the window by one segment on each side, rewrites `range_start_ms` / `range_end_ms`, and triggers a regeneration with the last prompt.

Edge case: session has zero segments. The preset buttons are disabled and the detail pane shows `highlight.error.noSegments`.

## Preset prompts

Four presets hardcoded in `Core/Prompts/HighlightPrompts.swift`:

| key | label (zh / en) | intent |
|---|---|---|
| `explain` | 讲解这段 / Explain | Chinese explanation of what the range covers; keep English terms inline |
| `example` | 举个例子 / Example | 1–2 analogies using scenarios familiar to a CN student studying in the US |
| `exam` | 考试重点 / Exam focus | 3–5 likely exam points + common traps |
| `terms` | 术语表 / Key terms | Glossary of jargon in the range, English ↔ Chinese, one-line definition each |

`HighlightPrompts.all: [PromptPreset]` drives the menu; adding another preset is one struct literal.

Every preset shares the same user-message structure:

```
Full transcript (for context only):
[timestamp] text_original
[timestamp] text_original
...

The range the student marked (explain THIS):
===
[timestamp] text_original
[timestamp] text_original
===
```

The system prompt per preset starts with a shared prefix — "The student marked a specific range. Treat everything outside the `===` fence as background context; focus your answer on the fenced range." — followed by the preset-specific instructions.

## UI

The highlights tab (`Features/Main/SessionDetailView.swift`) changes from a single list to a two-pane `HSplitView` (default 36% / 64%, user-resizable):

- **Left pane — highlight list**: same rows as today plus a small "已讲解" dot on rows where `explanation_md != nil`. Selection is driven by `SessionDetailViewModel.selectedHighlightId`.
- **Right pane — `HighlightDetailPane`**:
  - Header: `星 02:15` timestamp, range label `范围 02:15 — 03:40`, `缩小` and `扩大` range buttons.
  - Range preview: a compact scroll of the segments in `[range_start_ms, range_end_ms]`, each row reusing the existing `SegmentRowView` pattern (original + translation, tap to seek playback — playback wiring already exists).
  - Preset row: four buttons in a `HStack`, labels from `HighlightPrompts.all`. Disabled while any stream is in flight for this highlight.
  - Explanation area:
    - If `streamingHighlightId == this.id`: render `streamingBuffer` live as Markdown-ish text (fall back to `AttributedString(markdown:)` at stream end; during streaming we render plain text to avoid re-parsing every delta).
    - Else if `explanation_md != nil`: render it via `AttributedString(markdown:)`, and show a footer "由 `<model>` · `<relative time>` · prompt: `<preset label>`".
    - Else: `ContentUnavailableView` prompting the user to pick a preset.
  - Top-right actions: `重新生成` (reruns last prompt with current range) and `清空讲解` (calls `clearExplanation` + reloads).

Empty-state for the whole tab (no highlights at all) is unchanged — the split view only appears when `!vm.highlights.isEmpty`.

The Live-session highlight button (`LiveControlsView`) and the `⌘⇧M` shortcut keep their current behavior: write a bare timestamp. Explanation is strictly a playback-time feature.

## Streaming service

New `Core/Engines/HighlightExplanationService.swift`:

```swift
actor HighlightExplanationService {
    func generate(highlight: Highlight,
                  range: (start: Int64, end: Int64),
                  segments: [Segment],
                  preset: PromptPreset,
                  config: ApiConfig) -> AsyncThrowingStream<String, Error>
}
```

Internally it composes `[ChatMessage]` using `HighlightPrompts.systemPrefix + preset.systemBody` and the user-message template above, then forwards `OpenAIChatClient.chatStream`. Temperature = `0.3` to match `generateNotes`.

`SessionDetailViewModel` owns one instance. New published state:

```swift
@Published var selectedHighlightId: Int64?
@Published var streamingHighlightId: Int64?
@Published var streamingBuffer: String = ""
private var streamingTask: Task<Void, Never>?
```

Flow when a preset is tapped:

1. Cancel any in-flight `streamingTask`.
2. Compute range (first time) or reuse stored range (subsequent).
3. Reset `streamingBuffer = ""`, set `streamingHighlightId`.
4. `for try await delta in service.generate(...)`: append delta to `streamingBuffer`.
5. On normal completion: call `HighlightRepository.updateExplanation(...)`, reload `highlights`, clear `streamingHighlightId`.
6. On `CancellationError`: silently drop (user navigated away).
7. On any other error: route through `AppState.setError`; leave `explanation_md` untouched; clear streaming state.

Cancelling happens when (a) the user taps a different preset, (b) selects a different highlight, (c) leaves the tab or closes the session. Switching highlights does NOT auto-regenerate — cached explanation is shown if present, otherwise the empty-preset placeholder.

## Localization

Add to both `en` and `zh-Hans` dictionaries in `L10n.swift`:

```
highlight.detail.empty                 Select a highlight to see its explanation.
highlight.detail.pickPreset            Pick a preset below to generate an explanation.
highlight.detail.rangeLabel            Range %@ — %@
highlight.detail.expandRange           Expand
highlight.detail.shrinkRange           Shrink
highlight.preset.explain               Explain
highlight.preset.example               Example
highlight.preset.exam                  Exam focus
highlight.preset.terms                 Key terms
highlight.action.regenerate            Regenerate
highlight.action.clear                 Clear
highlight.status.streaming             Generating…
highlight.status.generatedBy           Generated by %@ · %@ · %@
highlight.error.noSegments             No transcript yet — record or import audio first.
```

(Chinese strings use parallel phrasing consistent with existing keys.)

## Files touched

- `Core/Storage/Database.swift` — add `v2_highlight_explanation` migration.
- `Core/Storage/Models/Segment.swift` — extend `Highlight` struct.
- `Core/Storage/Repositories/Repositories.swift` — add `updateExplanation` / `clearExplanation`.
- `Core/Prompts/HighlightPrompts.swift` — **new** file, `PromptPreset` + `HighlightPrompts.all`.
- `Core/Engines/HighlightExplanationService.swift` — **new** file.
- `Features/Main/SessionDetailView.swift` — refactor `HighlightsPane` into split view + detail pane; extend `SessionDetailViewModel` with streaming state. The file is already ~530 lines; extract `HighlightsPane` + `HighlightDetailPane` into `Features/Main/HighlightsPane.swift` to avoid growing it further.
- `Core/Utils/L10n.swift` — new keys (en + zh-Hans).
- `Tests/ClassNoteTests/CoreTests.swift` — assert the new columns exist after migration; unit test `computeRange` behavior (anchor in segment, anchor in silence, boundary clamping).

## Test strategy

- **Migration test**: run migrator on a freshly-created DB and also on a DB pre-populated with a v1 row, assert all six new columns present and NULL for old rows.
- **Range computation unit test**: table-driven cases — mark inside first segment, inside last, inside middle, in a silent gap between two segments, session with fewer than `2*radius+1` segments.
- **Repository test**: `updateExplanation` then `all()` returns the written values; `clearExplanation` resets all six columns.
- **Manual smoke** (documented, not automated): mark a highlight during recording, stop, open the tab, click each of the four presets, verify streaming renders, verify cached read on re-click, verify cancel on switch, verify expand/shrink rewrites the range and triggers a new generation.

No automated end-to-end test for the live LLM call — we already mock the OpenAI endpoint in integration tests; extending that to cover the explanation path is a nice-to-have follow-up, not a blocker.

## Risks

- **Token cost**: "always attach full transcript" can be expensive for long lectures. Acceptable for now; can be gated later by a setting or by switching to a tool-use / RAG flow.
- **Stream cancellation correctness**: must cancel `URLSession` bytes task when the user switches highlights mid-stream, otherwise deltas from a stale call will poison `streamingBuffer`. Guard with a per-stream token (compare `streamingHighlightId` before appending).
- **UI width on small windows**: a 36/64 split can feel cramped at ~900px. Set a sensible min-width on each pane and let the divider collapse the right pane into a placeholder below ~700px window width. (Defer if this complicates the first cut — flag for follow-up.)
