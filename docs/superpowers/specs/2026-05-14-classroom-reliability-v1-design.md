# Classroom Reliability V1 - Design

## Goal

Make ClassNote trustworthy during a real lecture, where the user does not get a second take.

Reliability V1 covers three failure classes:

1. **Crash recovery**: if the app, process, or Mac dies during recording, previously captured audio should still be recoverable after relaunch. The user manually chooses whether to recover it.
2. **API failure recovery**: STT, translation, and notes jobs retry automatically first; if the error is not recoverable or retry budget is exhausted, the UI asks the user what to do.
3. **Health checks and live alerts**: before and during recording, ClassNote warns about disk, battery, and permission problems that could interrupt capture.

This spec intentionally treats these as one milestone because they share the same underlying shape: durable session state, durable work items, and user-visible recovery.

## Non-goals

- No automatic resume of live recording after relaunch. Recovery creates a saved session from the audio already captured; the user can start a new recording separately.
- No cloud backup or sync.
- No perfect recovery of the last in-flight audio buffer. V1 targets "lose at most the currently open rolling segment", not sample-perfect crash persistence.
- No background daemon that records when the app is not running.
- No new scheduling / "auto start class" feature.
- No local Whisper fallback in this milestone. Local STT remains a v2 roadmap item.
- No full observability dashboard. Health status appears only where it helps the user act.

## Current State

Relevant implementation details today:

- `Session.state` is a free-form `String`. Existing code uses `recording`, `transcribed`, and `summarized`; the model comment still mentions older names (`transcribing`, `summarizing`, `ready`).
- `SessionRepository.setEnded(...)` writes `ended_at`, `duration_ms`, `audio_path`, and sets state to `transcribed`.
- `SessionOrchestrator.startNewSession(...)` inserts a `session` row before capture starts, but `audio_path` is only written on normal `stop()`.
- `AudioSourceManager` writes one `.m4a` file via `FileWriter.finish()`. If the process crashes before `finishWriting()`, the single file may not have a complete container footer and may be unplayable.
- Live STT and translation are in-memory tasks. When a provider call throws, the app shows an error and does not persist retryable work.
- There is no preflight system for disk, battery, or permissions beyond ad hoc errors from `AudioSourceManager`.

One important recorder bug should be handled while touching this area: mixed mode currently skips file writing on both mic and system callbacks because both branches check for single-source mode. Reliability V1 should make "what audio is persisted?" explicit for all source kinds.

## User Experience

### Startup Recovery Banner

On launch, the app checks for sessions that look incomplete and have recoverable audio:

- `state IN ('recording', 'transcribing', 'summarizing', 'interrupted')`
- `ended_at IS NULL`
- `source_kind != 'file'`
- `audio_path` points to a recording directory with at least one closed segment

Those sessions are marked `interrupted` and surfaced at the top of the main window:

> Previous recording was interrupted - Session 2026-05-14 09:15, about 47 min captured. [Recover] [Dismiss]

`Recover` enqueues transcription and translation jobs for the closed audio segments and opens the session detail view. `Dismiss` hides the banner after a confirmation and marks the session `failed`; audio files are moved to Trash when possible, not silently deleted.

If multiple interrupted sessions exist, show the newest one in the banner with "View all" opening a small recovery list.

### API Failure Queue

Provider calls no longer fail only inside transient `Task`s. Failed STT, translation, and notes work becomes visible:

- Retryable failures retry automatically with backoff.
- Permanent failures go straight to `needs_user`.
- Exhausted retryable failures also become `needs_user`.

Session detail shows a compact warning row when jobs need attention:

> 3 tasks need attention [Review]

The review sheet lists each job with context, error, and actions:

- `Retry now`
- `Skip`
- `Open API Settings` when the failure is auth/config related

For live sessions, the first failure still routes through `AppState.setError(...)` so the user gets immediate feedback instead of a silent queue.

### Start Preflight

When the user starts recording, run a short health preflight before opening capture:

| Check | Applies to | Behavior |
|---|---|---|
| Microphone permission | microphone, mixed | Block until granted |
| Screen recording permission | system, mixed | Block until granted |
| Disk < 500 MB | all live capture | Block |
| Disk 500 MB - 1 GB | all live capture | Warn, allow "Start anyway" |
| Battery < 20% and unplugged | all live capture | Warn, do not block |

The preflight appears as a compact sheet only when there is at least one warning or blocker. Clean preflight should not add friction.

### Recording Alerts

During recording, `HealthMonitor` publishes signals every 10 seconds and on capture errors. The live view and menu bar surface the highest active severity:

- Warning banner for low disk or low battery.
- Critical alert for revoked permissions, capture stream failure, or disk below hard-stop threshold.
- Menu bar item gets a warning/critical visual state while the main window is hidden.

Critical alerts can interrupt the user because they mean the recording may already be compromised.

## Session State Machine

Keep `Session.state` as `String` for a small migration, but centralize values in a new helper:

```swift
enum SessionState: String, Codable, Sendable {
    case recording
    case transcribing
    case transcribed
    case summarizing
    case summarized
    case interrupted
    case failed
}
```

Expected transitions:

```text
recording -> transcribing -> transcribed -> summarizing -> summarized
recording -> interrupted -> transcribing -> transcribed
recording -> failed
transcribing -> failed
summarizing -> failed
```

Compatibility rules:

- Treat old `ready` as `transcribed` when reading display state.
- Existing sessions with `transcribed` / `summarized` require no migration.
- `setEnded(...)` should keep setting `transcribed`, but should not be the only place that can update `audio_path`.

Add repository helpers:

```swift
func setAudioPath(_ id: String, audioPath: String) async throws
func markInterrupted(_ id: String) async throws
func findRecoverableInterruptedSessions() async throws -> [Session]
func setFailed(_ id: String) async throws
```

## Durable Recording

### Storage Layout

Change live recording storage from one file:

```text
recordings/<session_id>.m4a
```

to a directory:

```text
recordings/<session_id>/
  segment_000001.m4a
  segment_000002.m4a
  segment_000003.m4a
  current.m4a
```

`AppBootstrap.recordingURL(sessionId:)` should either become `recordingDirectoryURL(sessionId:)` or gain a clearly named sibling. `session.audio_path` stores the directory path for live recordings. Imported files keep storing the original file path.

`startNewSession(...)` must write `audio_path` immediately after capture starts successfully:

1. Insert session as today.
2. Start capture.
3. Persist the recording directory path with `SessionRepository.setAudioPath(...)`.
4. Start ticker and pipeline.

This closes the current recovery hole where audio may exist on disk but the DB row does not know where it is.

### Recording Segment Table

Add migration `v3_reliability_v1`:

```sql
CREATE TABLE recording_segment (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  path TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'closed',
  created_at INTEGER NOT NULL,
  UNIQUE(session_id, sequence)
);

CREATE INDEX idx_recording_segment_session
ON recording_segment(session_id, sequence);
```

Only closed, playable files are inserted into this table. The currently open file is intentionally not durable until `finishWriting()` completes.

On startup, run a repair pass for interrupted recording directories:

- Enumerate `segment_*.m4a`.
- Drop or ignore `current.m4a`.
- Reconcile missing `recording_segment` rows by sequence.
- Use file duration from `AVURLAsset` when the DB row is missing.

### Rolling Writer

Replace `FileWriter` with a rolling writer wrapper:

```swift
final class RollingAudioFileWriter: @unchecked Sendable {
    init(directoryURL: URL, segmentDuration: TimeInterval = 30)
    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer)
    func appendPCMBuffer(_ buffer: AVAudioPCMBuffer)
    func finishCurrentSegment() async throws -> RecordingSegment
    func finish() async throws -> [RecordingSegment]
}
```

Behavior:

- Rotate approximately every 30 seconds.
- Close a segment with `finishWriting()`, rename it from `current.m4a` to `segment_000123.m4a`, then insert `recording_segment`.
- If the app crashes, only `current.m4a` is expected to be invalid. Closed segments should be playable.
- Mixed mode must persist a deliberate mix. The simplest V1 choice is to route both mic and system audio into one PCM mixing path for file persistence, then feed that mixed PCM to the rolling writer. If that is too large for the first PR, explicitly persist system audio in mixed mode and document mic-only loss as a temporary limitation; do not leave the current "writes neither" behavior.

Playback/export code must treat `audio_path` as either:

- a file path for old recordings and imports, or
- a directory path for rolling live recordings.

For directory playback, build an `AVMutableComposition` from sorted `recording_segment` files.

## Recovery Flow

On app launch:

1. `RecoveryCoordinator.scan()` runs after `Database.setup()`.
2. It finds incomplete live sessions with a valid recording directory.
3. It reconciles `recording_segment` rows.
4. It marks those sessions `interrupted`.
5. `AppState` exposes `@Published var interruptedSessions: [Session]`.

When the user taps `Recover`:

1. Set session state to `transcribing`.
2. For each closed `recording_segment`, enqueue `transcribe_recording_segment` unless there is already transcript coverage for that time range.
3. Start `JobQueueRunner`.
4. When all transcription jobs for the session are done, update `duration_ms` to the max recovered `end_ms`, set `ended_at = started_at + duration_ms`, and set state to `transcribed`.
5. Translation jobs continue independently; rows with missing translations remain visible in the job attention sheet if they fail.

Coverage rule for V1:

- A recording segment is considered covered if at least one `segment` row overlaps `[start_ms, end_ms]`.
- This is intentionally conservative. It may skip retranscribing a partially covered segment, but avoids obvious duplicates. A later version can add `recording_segment_id` to `segment` for exact accounting.

## Job Queue

### Data Model

Create `pending_job` in the same `v3_reliability_v1` migration:

```sql
CREATE TABLE pending_job (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  payload_key TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'queued',
  attempts INTEGER NOT NULL DEFAULT 0,
  max_attempts INTEGER NOT NULL DEFAULT 4,
  next_run_at INTEGER NOT NULL,
  last_error TEXT,
  last_error_code TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  locked_at INTEGER,
  UNIQUE(session_id, kind, payload_key)
);

CREATE INDEX idx_pending_job_ready
ON pending_job(state, next_run_at);

CREATE INDEX idx_pending_job_session
ON pending_job(session_id, state);
```

States:

| state | Meaning |
|---|---|
| `queued` | Ready when `next_run_at <= now` |
| `running` | Claimed by the local runner |
| `retry_wait` | Waiting for backoff |
| `needs_user` | No more automatic retries |
| `done` | Completed |
| `skipped` | User chose to skip |
| `cancelled` | No longer relevant |

Kinds:

| kind | Payload |
|---|---|
| `transcribe_recording_segment` | `recordingSegmentId`, `path`, `startMs`, `endMs`, `language`, `model` |
| `translate_segment` | `segmentId`, `text`, `sourceLanguage`, `targetLanguage`, `model` |
| `generate_notes` | `sessionId`, `model` |

`payload_key` provides idempotency:

- `recording_segment:<id>` for STT
- `segment:<id>:<targetLanguage>:<model>` for translation
- `notes:<sessionId>:<model>` for notes

### Runner

Add `Core/Pipeline/JobQueue.swift`:

```swift
actor JobQueue {
    func enqueue(_ job: PendingJob) async throws
    func ready(limit: Int) async throws -> [PendingJob]
    func markRunning(_ id: String) async throws
    func markDone(_ id: String) async throws
    func markRetry(_ id: String, error: Error, nextRunAt: Int64) async throws
    func markNeedsUser(_ id: String, error: Error) async throws
    func retryNow(_ id: String) async throws
    func skip(_ id: String) async throws
}
```

Add `Core/Pipeline/JobQueueRunner.swift`:

```swift
actor JobQueueRunner {
    func start()
    func stop()
    func wake()
}
```

The runner polls ready jobs, executes them serially at first, and can later grow a small concurrency limit. V1 should prefer correctness over parallel throughput because translation streaming updates UI state.

Backoff:

```text
1s, 4s, 16s, 60s
```

After `max_attempts`, mark `needs_user`.

Error classification:

| Error | Handling |
|---|---|
| Network timeout / offline | Retry |
| HTTP 408, 409, 425, 429 | Retry |
| HTTP 500-599 | Retry |
| HTTP 400 | Needs user |
| HTTP 401 / 403 | Needs user + API settings action |
| Missing API key / invalid base URL | Needs user + API settings action |
| Context length / unsupported model | Needs user |
| Cancellation because user stopped session | Cancelled |

### Pipeline Integration

Live recording keeps the low-latency STT stream, but durable jobs become the recovery path:

- When live STT emits a segment, insert it as today.
- Instead of starting an untracked translation `Task`, enqueue `translate_segment`.
- If the live STT stream throws while recording continues, enqueue `transcribe_recording_segment` for closed recording segments without transcript coverage.
- On recovery, enqueue `transcribe_recording_segment` for all uncovered closed recording segments.

`translate_segment` execution:

1. Load the segment and recent context from DB.
2. Stream translation from `TranslationProvider`.
3. If the segment is visible in the current live transcript, append deltas to `TranscriptBuffer`.
4. On completion, persist `SegmentRepository.updateTranslation(...)`.

`generate_notes` execution:

1. Load all segments for the session.
2. Call the existing note generation path.
3. Upsert `note`.
4. Set state to `summarized`.

Manual `retranslateSession(...)` should enqueue translation jobs instead of doing a long sequential loop in memory.

## Health Monitor

Add `Core/Capture/HealthMonitor.swift`.

```swift
enum HealthLevel: Int, Comparable, Sendable {
    case ok
    case warning
    case critical
}

enum HealthKind: String, Sendable {
    case disk
    case battery
    case microphonePermission
    case screenRecordingPermission
    case captureStream
}

struct HealthSignal: Identifiable, Sendable {
    var id: String { kind.rawValue }
    let kind: HealthKind
    let level: HealthLevel
    let title: String
    let detail: String
    let observedAt: Int64
    let action: HealthAction?
}
```

Use dependency injection for testability:

- `DiskCapacityProvider`
- `BatteryStateProvider`
- `PermissionProvider`
- `Clock`

Production implementations:

- Disk: `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` on `AppBootstrap.recordingsURL`.
- Battery: `IOPSCopyPowerSourcesInfo` / `IOPSCopyPowerSourcesList`.
- Mic permission: `AVCaptureDevice.authorizationStatus(for: .audio)`.
- Screen recording: `CGPreflightScreenCaptureAccess()`.

Publishing:

- `HealthMonitor.preflight(source:) async -> HealthPreflightResult`
- `HealthMonitor.startMonitoring(source:)`
- `HealthMonitor.stopMonitoring()`
- `@Published private(set) var activeSignals: [HealthSignal]`

`SessionOrchestrator.startNewSession(...)` should call preflight before creating the DB session. If a permission dialog is needed, request it before capture starts.

`AudioSourceManager` should forward capture stream failures into `HealthMonitor` or `AppState` as `captureStream` critical signals instead of only setting a generic toast.

## UI Changes

### Main Window

Add a recovery banner above the main content when `AppState.interruptedSessions` is non-empty.

Buttons:

- `Recover`
- `Dismiss`
- `View all` when count > 1

### Session Detail

Add a job attention banner near the top of `SessionDetailView`:

- Visible when `PendingJobRepository.needsUserCount(sessionId:) > 0`.
- Opens `JobAttentionSheet`.

The sheet is session-scoped. It should not become a global job center in V1.

### Live Session

Add a compact health banner to `LiveSessionView` / `LiveControlsView` using the highest active health level.

Keep text short:

- "Low disk space - recording may stop soon"
- "Battery low - plug in if possible"
- "Screen recording permission was revoked"

### Menu Bar

`MenuBarExtraView` should show the same highest-severity signal while a recording is active. If the current menu bar icon cannot be colored easily, add a short warning row at the top of the menu; do not block the milestone on icon tinting.

### Localization

Add English and Chinese keys in `L10n.swift` for:

```text
recovery.banner.title
recovery.banner.subtitle
recovery.action.recover
recovery.action.dismiss
recovery.action.viewAll
recovery.confirmDismiss.title
recovery.confirmDismiss.body
jobs.attention.title
jobs.attention.review
jobs.action.retryNow
jobs.action.skip
jobs.action.openAPISettings
health.preflight.title
health.action.startAnyway
health.action.openSettings
health.disk.warning
health.disk.critical
health.battery.warning
health.permission.microphone
health.permission.screenRecording
health.capture.critical
```

## Files Touched

- `App/AppBootstrap.swift` - recording directory helper.
- `App/AppState.swift` - interrupted sessions, health signals, job runner lifecycle.
- `Core/Storage/Database.swift` - `v3_reliability_v1` migration.
- `Core/Storage/Models/Session.swift` - `SessionState` helper or adjacent file.
- `Core/Storage/Models/RecordingSegment.swift` - new model.
- `Core/Storage/Models/PendingJob.swift` - new model.
- `Core/Storage/Repositories/Repositories.swift` - session recovery helpers, recording segment repository, pending job repository.
- `Core/Capture/AudioSourceManager.swift` - rolling writer integration and mixed-mode persistence fix.
- `Core/Capture/RollingAudioFileWriter.swift` - new file.
- `Core/Capture/HealthMonitor.swift` - new file.
- `Core/Pipeline/SessionOrchestrator.swift` - preflight, early audio path persistence, queue integration.
- `Core/Pipeline/JobQueue.swift` - new file.
- `Core/Pipeline/JobQueueRunner.swift` - new file.
- `Features/Main/MainWindowView.swift` - recovery banner.
- `Features/Main/SessionDetailView.swift` - job attention banner / sheet entry.
- `Features/LiveSession/LiveControlsView.swift` - live health banner.
- `Features/MenuBar/MenuBarExtraView.swift` - active health warning.
- `Core/Utils/L10n.swift` - strings.
- `Tests/ClassNoteTests/CoreTests.swift` - migration/repository/state tests.
- `Tests/ClassNoteTests/EndToEndFlowTests.swift` - retry queue integration where practical.

## Implementation Plan

Ship as one reliability milestone split into three reviewable PRs.

### PR 1 - Crash Recovery Foundation

- Add `SessionState`.
- Add `recording_segment` table and repository.
- Add recording directory helper.
- Implement rolling audio writer.
- Persist `audio_path` immediately after capture starts.
- Add startup scan / `RecoveryCoordinator`.
- Add recovery banner and manual recover/dismiss actions.
- Update playback/export to support audio directories.

Acceptance:

- Start a recording, wait for at least two closed segments, force-quit the app, relaunch, recover the session, and play the recovered audio.
- Existing single-file recordings still play and export.

### PR 2 - Durable Job Queue

- Add `pending_job` table and repository.
- Add queue runner and retry classification.
- Route translation through jobs.
- Route recovered STT through jobs.
- Route notes generation through jobs.
- Add session-scoped needs-user sheet.

Acceptance:

- Simulated 500/429 failures retry automatically.
- Simulated 401 becomes `needs_user` with an API settings action.
- Relaunching the app resumes queued jobs.

### PR 3 - Health Checks

- Add `HealthMonitor`.
- Add start preflight.
- Add recording-time health signals.
- Add live/menu UI warnings.
- Convert capture stream failures into critical health signals.

Acceptance:

- Missing mic/screen permissions block start with a settings action.
- Low disk warning appears before and during recording.
- Low battery warning appears without blocking recording.

## Test Strategy

### Unit Tests

- Migration creates `recording_segment` and `pending_job`.
- Old sessions with file `audio_path` still decode as playable file sessions.
- `SessionState` display handles `ready` as `transcribed`.
- `PendingJobRepository.enqueue` is idempotent on `(session_id, kind, payload_key)`.
- Backoff schedule produces `1s, 4s, 16s, 60s`.
- Error classifier maps retryable vs needs-user failures.
- `HealthMonitor.preflight` thresholds using fake disk/battery/permission providers.

### Integration Tests

- Queue runner executes a translation job against the existing mock OpenAI endpoint and persists `text_translated`.
- Queue runner retries mock 500 responses, then succeeds.
- Queue runner marks mock 401 as `needs_user`.
- Recovery scan reconciles files in a fake recording directory into `recording_segment` rows.

### Manual QA

- Record microphone for 70 seconds, force-quit, relaunch, recover, verify at least the first 60 seconds are playable.
- Repeat with system audio.
- Repeat with mixed audio and confirm a playback file actually exists.
- Turn network off during translation, confirm automatic retry and later success.
- Use a bad API key, confirm `needs_user` and API settings action.
- Start with screen recording permission missing, confirm blocked start and settings action.
- Hide main window during a health warning, confirm menu bar warning is visible.

## Risks

- **Rolling writer complexity**: rotating AAC containers from both mic and ScreenCaptureKit paths is the riskiest implementation piece. Keep the writer API narrow and test with real recordings early.
- **Mixed-mode persistence**: correctly mixing mic and system audio for the saved file may be larger than the recovery foundation itself. If needed, ship system-audio persistence first but explicitly track mic persistence as a blocker before calling mixed mode reliable.
- **Duplicate transcripts after recovery**: time-range coverage can skip or duplicate edge cases. V1 favors avoiding obvious duplicates. A later migration can add exact `recording_segment_id` provenance to `segment`.
- **Queue/UI synchronization**: streamed translation jobs must not append deltas into a stale live transcript after the user switches sessions. Guard UI updates by current session id and segment id.
- **Permission APIs are awkward**: screen recording permission often requires relaunch after grant. Copy must be clear when the OS needs the user to restart ClassNote.

## Rollout Notes

Reliability V1 should be enabled by default. There is no settings toggle because the feature is primarily data protection.

After PR 1, update the README "Highlights" or "Roadmap" to mention crash-recoverable rolling recordings. After all three PRs, add a short "Reliability" section to the README with the exact guarantees:

- closed audio segments survive crashes;
- failed provider work retries and remains visible;
- recording preflight checks disk, battery, and permissions.
