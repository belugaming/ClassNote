# 本地流式 ASR 引擎集成（FunASR / Nemotron）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 集成 FunASR 和 Nemotron 本地流式 ASR 引擎，支持 2-pass 修正，并改版实时字幕窗口 UI。

**Architecture:** Python WebSocket sidecar 进程（Scripts/asr_server.py）负责音频识别，Swift 侧通过 LocalWebSocketSTT（STTProvider）与之通信。进程生命周期由 AsyncThrowingStream.onTermination 管理，TranscriptEvent 新增 engineSegmentId/isRevision 字段支持修正流。

**Tech Stack:** Swift/SwiftUI (existing), Python 3 + websockets + funasr/nemotron-asr-mlx (sidecar), URLSessionWebSocketTask, GRDB (existing storage), XCTest.

---

### Task 1: 扩展 TranscriptEvent 支持修正事件

**Files:**
- Modify: `Core/Engines/Providers.swift:9-24`

- [ ] **Step 1:** 在 `TranscriptEvent` 中新增 `engineSegmentId: Int64?` 和 `isRevision: Bool` 字段，更新 init 提供默认值 `nil` / `false`，保持所有现有调用点（`OpenAICompatibleSTT.swift`、`AppleSpeechSTT*.swift`）不需要改动。
- [ ] **Step 2:** `swift build` 确认现有调用点仍编译通过。
- [ ] **Step 3:** 提交：`git commit -m "feat: add revision fields to TranscriptEvent"`

### Task 2: TranscriptBuffer.reviseFinal + LiveSegment.wasRevised

**Files:**
- Modify: `Core/Pipeline/TranscriptBuffer.swift`
- Test: `Tests/ClassNoteTests/CoreTests.swift`

- [ ] **Step 1:** 写失败测试：新建 `TranscriptBufferTests`（或加入 CoreTests.swift），`appendFinal` 后调用 `reviseFinal(rowId:newText:)`，断言 `segments[0].original == newText` 且 `wasRevised == true`，其它行不受影响。
- [ ] **Step 2:** 运行测试确认失败（`reviseFinal` 尚不存在）。
- [ ] **Step 3:** 在 `LiveSegment` 加 `var wasRevised: Bool = false`；`TranscriptBuffer` 加：
  ```swift
  func reviseFinal(rowId: Int64, newText: String) {
      guard let idx = indexById[rowId], idx < segments.count else { return }
      segments[idx].original = newText
      segments[idx].wasRevised = true
  }

  func clearRevisedFlag(rowId: Int64) {
      guard let idx = indexById[rowId], idx < segments.count else { return }
      segments[idx].wasRevised = false
  }
  ```
- [ ] **Step 4:** 运行测试确认通过。
- [ ] **Step 5:** 提交：`git commit -m "feat: support in-place revision of committed transcript segments"`

### Task 3: SttBackend 新增 funasr/nemotronStreaming

**Files:**
- Modify: `App/AppState.swift:401-413`
- Modify: `Features/Settings/SettingsView.swift:440-463`

- [ ] **Step 1:** 在 `SttBackend` 枚举加 `case funasr = "funasr"` 和 `case nemotronStreaming = "nemotron"`，`displayName` 补充对应文案（"FunASR (Local, 2-Pass)" / "Nemotron Streaming (Local, English)"）。
- [ ] **Step 2:** `EngineSettingsView` 的 Picker 无需改动（`ForEach(SttBackend.allCases)` 自动包含新 case）；为两个新引擎各加一条 `Label(...)` 提示（类似现有 `whisperKitNote`），说明首次使用需要下载依赖。
- [ ] **Step 3:** `swift build` 确认通过。
- [ ] **Step 4:** 提交：`git commit -m "feat: add funasr/nemotron backend options to settings"`

### Task 4: Python sidecar 脚本 asr_server.py

**Files:**
- Create: `Scripts/asr_server.py`
- Create: `Scripts/requirements-funasr.txt`
- Create: `Scripts/requirements-nemotron.txt`

- [ ] **Step 1:** 编写 `Scripts/asr_server.py`：
  ```python
  #!/usr/bin/env python3
  """Local streaming ASR sidecar. Usage: asr_server.py --engine funasr|nemotron --port N"""
  import argparse
  import asyncio
  import json
  import sys

  import websockets


  class EngineAdapter:
      """Wraps a streaming ASR backend behind a uniform partial/final/revised API."""

      def __init__(self, name: str):
          self.name = name
          self._segment_id = 0

      async def load(self):
          raise NotImplementedError

      async def feed(self, pcm_bytes: bytes):
          """Yields dicts: {"type": "partial"|"final"|"revised", "segmentId", "startMs", "endMs", "text"}"""
          raise NotImplementedError


  class FunASREngine(EngineAdapter):
      async def load(self):
          from funasr import AutoModel
          self.streaming_model = AutoModel(model="paraformer-zh-streaming")
          self.offline_model = AutoModel(model="iic/SenseVoiceSmall")
          self.chunk_buffer = bytearray()
          self.utterance_buffer = bytearray()
          self.ms_offset = 0

      async def feed(self, pcm_bytes: bytes):
          # Streaming pass: emit partials as chunks accumulate.
          self.chunk_buffer.extend(pcm_bytes)
          self.utterance_buffer.extend(pcm_bytes)
          events = []
          if len(self.chunk_buffer) >= 9600:  # ~300ms @16kHz/16bit mono
              text = self._run_streaming_chunk(bytes(self.chunk_buffer))
              self.chunk_buffer.clear()
              if text:
                  events.append({
                      "type": "partial", "segmentId": self._segment_id,
                      "startMs": self.ms_offset, "endMs": self.ms_offset, "text": text,
                  })
          return events

      def _run_streaming_chunk(self, chunk: bytes) -> str:
          res = self.streaming_model.generate(input=chunk, is_final=False)
          return res[0]["text"] if res else ""

      async def finalize_utterance(self, end_ms: int):
          """Called on VAD silence boundary: run offline pass, emit final then revised."""
          seg_id = self._segment_id
          self._segment_id += 1
          streaming_text = self._run_streaming_chunk(bytes(self.utterance_buffer))
          final_event = {
              "type": "final", "segmentId": seg_id,
              "startMs": self.ms_offset, "endMs": end_ms, "text": streaming_text,
          }
          offline_res = self.offline_model.generate(input=bytes(self.utterance_buffer))
          revised_text = offline_res[0]["text"] if offline_res else streaming_text
          self.utterance_buffer.clear()
          self.ms_offset = end_ms
          revised_event = None
          if revised_text and revised_text != streaming_text:
              revised_event = {
                  "type": "revised", "segmentId": seg_id,
                  "startMs": final_event["startMs"], "endMs": end_ms, "text": revised_text,
              }
          return final_event, revised_event


  class NemotronEngine(EngineAdapter):
      async def load(self):
          from nemotron_asr_mlx import StreamingRecognizer
          self.recognizer = StreamingRecognizer()
          self.ms_offset = 0

      async def feed(self, pcm_bytes: bytes):
          events = []
          for res in self.recognizer.feed(pcm_bytes):
              events.append({
                  "type": "final" if res.is_final else "partial",
                  "segmentId": res.segment_id,
                  "startMs": res.start_ms, "endMs": res.end_ms,
                  "text": res.text,
              })
          return events


  ENGINES = {"funasr": FunASREngine, "nemotron": NemotronEngine}


  def _is_silent(pcm_bytes: bytes, threshold: int = 400) -> bool:
      """Cheap RMS-based silence check on Int16LE mono PCM, mirrors VADGate.rms on the Swift side."""
      import struct
      if not pcm_bytes:
          return True
      count = len(pcm_bytes) // 2
      if count == 0:
          return True
      samples = struct.unpack(f"<{count}h", pcm_bytes[: count * 2])
      mean_sq = sum(s * s for s in samples) / count
      return mean_sq ** 0.5 < threshold


  async def handle_connection(websocket, engine_name: str):
      adapter = ENGINES[engine_name](engine_name)
      await adapter.load()
      silence_run_ms = 0
      async for message in websocket:
          if not isinstance(message, (bytes, bytearray)):
              continue
          events = await adapter.feed(message)
          for ev in events:
              await websocket.send(json.dumps(ev))
          if engine_name == "funasr":
              # ~10ms per 320-byte frame at 16kHz/16-bit mono is too fine-grained
              # to reason about per network message; approximate using the chunk
              # size actually received instead of a fixed constant.
              chunk_ms = int(len(message) / (16000 * 2) * 1000)
              if _is_silent(message):
                  silence_run_ms += chunk_ms
              else:
                  silence_run_ms = 0
              # Trailing ~500ms of silence after at least some voiced audio marks
              # an utterance boundary — trigger the offline 2-pass revision.
              if silence_run_ms >= 500 and adapter.utterance_buffer:
                  final_ev, revised_ev = await adapter.finalize_utterance(adapter.ms_offset + chunk_ms)
                  await websocket.send(json.dumps(final_ev))
                  if revised_ev:
                      await websocket.send(json.dumps(revised_ev))
                  silence_run_ms = 0


  async def main():
      parser = argparse.ArgumentParser()
      parser.add_argument("--engine", required=True, choices=ENGINES.keys())
      parser.add_argument("--port", type=int, required=True)
      args = parser.parse_args()

      async def handler(ws):
          await handle_connection(ws, args.engine)

      async with websockets.serve(handler, "127.0.0.1", args.port):
          print(f"READY {args.port}", flush=True)
          await asyncio.Future()


  if __name__ == "__main__":
      asyncio.run(main())
  ```
  注：`finalize_utterance` 现在由 `handle_connection` 里的静音时长检测实际触发（简单 RMS 阈值 + 500ms 静音累计判定句子边界），不再是死代码；`_is_silent` 的阈值/窗口是简化实现，真实项目应换成 FunASR 自带 VAD 模型，属于后续优化（见文末"已知限制"）。核心协议（partial/final/revised 三种 JSON 消息 + `READY <port>` 就绪标记）已完整，足以让 Swift 侧对接和测试。
- [ ] **Step 2:** 创建 `Scripts/requirements-funasr.txt`：
  ```
  funasr
  websockets
  ```
- [ ] **Step 3:** 创建 `Scripts/requirements-nemotron.txt`：
  ```
  nemotron-asr-mlx
  websockets
  ```
- [ ] **Step 4:** `python3 -m py_compile Scripts/asr_server.py` 确认语法正确。
- [ ] **Step 5:** 提交：`git commit -m "feat: add Python ASR sidecar server (FunASR/Nemotron)"`

### Task 5: LocalASREnvironment

**Files:**
- Create: `Core/Engines/LocalASREnvironment.swift`

- [ ] **Step 1:** 实现环境检测与安装：
  ```swift
  import Foundation

  enum LocalASREngineKind: String {
      case funasr, nemotron

      var requirementsFile: String {
          switch self {
          case .funasr: return "requirements-funasr.txt"
          case .nemotron: return "requirements-nemotron.txt"
          }
      }
  }

  enum InstallProgress: Sendable {
      case checkingEnvironment
      case installingPackages
      case downloadingModel
      case ready
      case failed(String)
  }

  enum LocalASREnvironment {
      static var pyenvURL: URL {
          AppBootstrap.applicationSupportURL.appendingPathComponent("pyenv", isDirectory: true)
      }

      static var pythonBinURL: URL {
          pyenvURL.appendingPathComponent("bin/python3")
      }

      static func isReady(engine: LocalASREngineKind) -> Bool {
          FileManager.default.fileExists(atPath: pythonBinURL.path)
              && markerExists(engine: engine)
      }

      private static func markerFileURL(engine: LocalASREngineKind) -> URL {
          pyenvURL.appendingPathComponent(".installed-\(engine.rawValue)")
      }

      private static func markerExists(engine: LocalASREngineKind) -> Bool {
          FileManager.default.fileExists(atPath: markerFileURL(engine: engine).path)
      }

      static func install(engine: LocalASREngineKind) -> AsyncThrowingStream<InstallProgress, Error> {
          AsyncThrowingStream { continuation in
              let task = Task {
                  do {
                      continuation.yield(.checkingEnvironment)
                      try FileManager.default.createDirectory(at: pyenvURL, withIntermediateDirectories: true)
                      if !FileManager.default.fileExists(atPath: pythonBinURL.path) {
                          try await run("/usr/bin/python3", ["-m", "venv", pyenvURL.path])
                      }
                      continuation.yield(.installingPackages)
                      guard let reqURL = Bundle.main.url(forResource: engine.requirementsFile.replacingOccurrences(of: ".txt", with: ""),
                                                          withExtension: "txt") else {
                          throw EngineError.unsupported("Missing bundled \(engine.requirementsFile)")
                      }
                      try await run(pythonBinURL.path, ["-m", "pip", "install", "-q", "-r", reqURL.path])
                      continuation.yield(.downloadingModel)
                      // Model weights download lazily on first server start; we
                      // don't pre-fetch here to keep this step fast and simple.
                      try Data().write(to: markerFileURL(engine: engine))
                      continuation.yield(.ready)
                      continuation.finish()
                  } catch {
                      continuation.yield(.failed(error.localizedDescription))
                      continuation.finish(throwing: error)
                  }
              }
              continuation.onTermination = { _ in task.cancel() }
          }
      }

      private static func run(_ launchPath: String, _ args: [String]) async throws {
          try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
              let process = Process()
              process.executableURL = URL(fileURLWithPath: launchPath)
              process.arguments = args
              let pipe = Pipe()
              process.standardError = pipe
              process.terminationHandler = { proc in
                  if proc.terminationStatus == 0 {
                      cont.resume()
                  } else {
                      let data = pipe.fileHandleForReading.readDataToEndOfFile()
                      let msg = String(data: data, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                      cont.resume(throwing: EngineError.unsupported(msg))
                  }
              }
              do {
                  try process.run()
              } catch {
                  cont.resume(throwing: error)
              }
          }
      }
  }
  ```
- [ ] **Step 2:** `project.yml` 目前没有把 `Scripts/` 打包进任何 target（只有 `App`/`Features`/`Core`/`Resources` 出现在 `sources` 里，`Resources` 才有 `buildPhase: resources`）。给 `ClassNote`（macOS）target 的 `sources` 列表新增一项，让 `asr_server.py` 和两个 requirements 文件被打进 app bundle 供 `Bundle.main.url(forResource:...)` 读取：
  ```yaml
    targets:
      ClassNote:
        sources:
          - path: App
            excludes:
              - "Info-iOS.plist"
              - "ClassNote-iOS.entitlements"
          - path: Features
          - path: Core
          - path: Resources
            buildPhase: resources
          - path: Scripts
            buildPhase: resources
  ```
  只加到 `ClassNote`（macOS）target，不加到 `ClassNote_iOS`——本地 ASR sidecar 只在 macOS 上跑。加完后运行 `xcodegen generate` 重新生成工程文件。
- [ ] **Step 3:** `xcodegen generate && xcodebuild -project ClassNote.xcodeproj -scheme ClassNote -configuration Debug build`，确认 `Scripts/asr_server.py` 出现在 `build/DerivedData/.../ClassNote.app/Contents/Resources/` 下（可用 `find build -name asr_server.py` 验证）。
- [ ] **Step 3:** `swift build` 确认编译通过。
- [ ] **Step 4:** 提交：`git commit -m "feat: add LocalASREnvironment for venv/package install"`

### Task 6: LocalASRProcessManager (actor)

**Files:**
- Create: `Core/Engines/LocalASRProcessManager.swift`

- [ ] **Step 1:** 实现进程管理 actor：
  ```swift
  import Foundation

  actor LocalASRProcessManager {
      private var process: Process?
      private let engine: LocalASREngineKind

      init(engine: LocalASREngineKind) {
          self.engine = engine
      }

      /// Spawns the sidecar, waits for its READY marker on stdout, returns the ws URL.
      func start() async throws -> URL {
          guard process == nil else {
              throw EngineError.unsupported("Process already running")
          }
          let port = try Self.findFreePort()
          let scriptURL = Bundle.main.url(forResource: "asr_server", withExtension: "py")
              ?? URL(fileURLWithPath: "Scripts/asr_server.py")

          let proc = Process()
          proc.executableURL = URL(fileURLWithPath: LocalASREnvironment.pythonBinURL.path)
          proc.arguments = [scriptURL.path, "--engine", engine.rawValue, "--port", "\(port)"]
          let stdout = Pipe()
          proc.standardOutput = stdout

          let ready: URL = try await withCheckedThrowingContinuation { cont in
              var resumed = false
              stdout.fileHandleForReading.readabilityHandler = { handle in
                  let data = handle.availableData
                  guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                  if line.contains("READY"), !resumed {
                      resumed = true
                      cont.resume(returning: URL(string: "ws://127.0.0.1:\(port)")!)
                  }
              }
              proc.terminationHandler = { p in
                  if !resumed {
                      resumed = true
                      cont.resume(throwing: EngineError.unsupported("ASR sidecar exited with status \(p.terminationStatus)"))
                  }
              }
              do {
                  try proc.run()
              } catch {
                  if !resumed {
                      resumed = true
                      cont.resume(throwing: error)
                  }
              }
          }
          self.process = proc
          return ready
      }

      func shutdown() async {
          process?.terminate()
          process = nil
      }

      private static func findFreePort() throws -> UInt16 {
          // Bind to port 0, read the assigned ephemeral port, then release it —
          // a small TOCTOU race window is acceptable for a localhost dev sidecar.
          let socketFD = socket(AF_INET, SOCK_STREAM, 0)
          guard socketFD >= 0 else { throw EngineError.unsupported("Could not create socket") }
          defer { close(socketFD) }
          var addr = sockaddr_in()
          addr.sin_family = sa_family_t(AF_INET)
          addr.sin_addr.s_addr = INADDR_ANY.bigEndian
          addr.sin_port = 0
          let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
              ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                  bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
              }
          }
          guard bindResult == 0 else { throw EngineError.unsupported("Could not bind ephemeral port") }
          var len = socklen_t(MemoryLayout<sockaddr_in>.size)
          var boundAddr = sockaddr_in()
          let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
              ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                  getsockname(socketFD, sockaddrPtr, &len)
              }
          }
          guard nameResult == 0 else { throw EngineError.unsupported("Could not read bound port") }
          return UInt16(bigEndian: boundAddr.sin_port)
      }
  }
  ```
- [ ] **Step 2:** `swift build` 确认编译通过。
- [ ] **Step 3:** 提交：`git commit -m "feat: add LocalASRProcessManager actor for sidecar lifecycle"`

### Task 7: LocalWebSocketSTT (STTProvider)

**Files:**
- Create: `Core/Engines/LocalWebSocketSTT.swift`
- Test: `Tests/ClassNoteTests/CoreTests.swift`

- [ ] **Step 1:** 写失败测试：给 JSON 解码逻辑单独抽出一个纯函数 `LocalWebSocketSTT.decodeEvent(_ json: Data) -> TranscriptEvent?`，测试三种消息类型（partial/final/revised）解码出正确的 `isFinal`/`isRevision`/`engineSegmentId` 组合。
- [ ] **Step 2:** 运行测试确认失败。
- [ ] **Step 3:** 实现：
  ```swift
  import Foundation

  final class LocalWebSocketSTT: STTProvider, Sendable {
      private let engine: LocalASREngineKind

      init(engine: LocalASREngineKind) {
          self.engine = engine
      }

      func transcribe(audio: AsyncStream<AudioChunk>,
                      language: String?) -> AsyncThrowingStream<TranscriptEvent, Error> {
          AsyncThrowingStream { continuation in
              let manager = LocalASRProcessManager(engine: engine)
              let task = Task {
                  do {
                      let wsURL = try await manager.start()
                      let session = URLSession(configuration: .default)
                      let wsTask = session.webSocketTask(with: wsURL)
                      wsTask.resume()

                      let sender = Task {
                          for await chunk in audio {
                              try Task.checkCancellation()
                              try await wsTask.send(.data(chunk.pcmData))
                          }
                      }

                      while true {
                          try Task.checkCancellation()
                          let message = try await wsTask.receive()
                          guard case .string(let text) = message,
                                let data = text.data(using: .utf8),
                                let event = Self.decodeEvent(data) else { continue }
                          continuation.yield(event)
                      }
                      sender.cancel()
                  } catch {
                      continuation.finish(throwing: error)
                      return
                  }
              }
              continuation.onTermination = { _ in
                  task.cancel()
                  Task { await manager.shutdown() }
              }
          }
      }

      func transcribeFile(url: URL, language: String?) -> AsyncThrowingStream<FileTranscriptionEvent, Error> {
          AsyncThrowingStream { continuation in
              continuation.finish(throwing: EngineError.unsupported("File import not supported for local streaming engines"))
          }
      }

      // MARK: - Protocol decoding (pure, unit-testable)

      private struct WireEvent: Decodable {
          let type: String
          let segmentId: Int64
          let startMs: Int64
          let endMs: Int64
          let text: String
      }

      static func decodeEvent(_ json: Data) -> TranscriptEvent? {
          guard let wire = try? JSONDecoder().decode(WireEvent.self, from: json) else { return nil }
          switch wire.type {
          case "partial":
              return TranscriptEvent(startMs: wire.startMs, endMs: wire.endMs, text: wire.text,
                                      isFinal: false, speakerId: nil,
                                      engineSegmentId: wire.segmentId, isRevision: false)
          case "final":
              return TranscriptEvent(startMs: wire.startMs, endMs: wire.endMs, text: wire.text,
                                      isFinal: true, speakerId: nil,
                                      engineSegmentId: wire.segmentId, isRevision: false)
          case "revised":
              return TranscriptEvent(startMs: wire.startMs, endMs: wire.endMs, text: wire.text,
                                      isFinal: true, speakerId: nil,
                                      engineSegmentId: wire.segmentId, isRevision: true)
          default:
              return nil
          }
      }
  }
  ```
  注：`TranscriptEvent` 的 `init` 需要允许显式传入 `engineSegmentId`/`isRevision`（Task 1 已加字段，若原 init 是 memberwise 则直接可用；若有自定义 init，需要同步加参数）。
- [ ] **Step 4:** 运行测试确认通过。
- [ ] **Step 5:** 提交：`git commit -m "feat: implement LocalWebSocketSTT provider"`

### Task 8: EngineFactory 接入新引擎

**Files:**
- Modify: `Core/Engines/Providers.swift:90-101`

- [ ] **Step 1:** 在 `EngineFactory.makeSTT` 的 switch 里加：
  ```swift
  case .funasr:
      return LocalWebSocketSTT(engine: .funasr)
  case .nemotronStreaming:
      return LocalWebSocketSTT(engine: .nemotron)
  ```
- [ ] **Step 2:** `swift build` 确认编译通过。
- [ ] **Step 3:** 提交：`git commit -m "feat: wire funasr/nemotron backends into EngineFactory"`

### Task 9: SessionOrchestrator 处理 revision 事件

**Files:**
- Modify: `Core/Pipeline/SessionOrchestrator.swift:283-340`

- [ ] **Step 1:** 在 `SessionOrchestrator` 加私有属性 `private var engineSegmentToRowId: [Int64: Int64] = [:]`，在 `startNewSession`/`startEphemeralTranslation` 的 reset 逻辑处清空。
- [ ] **Step 2:** 在事件循环里，`final` 分支拿到 `rowId` 后追加：
  ```swift
  if let segId = event.engineSegmentId {
      self.engineSegmentToRowId[segId] = rowId
  }
  ```
  在 `guard event.isFinal else { ... continue }` 之前插入 revision 分支：
  ```swift
  if event.isRevision, let segId = event.engineSegmentId,
     let rowId = engineSegmentToRowId[segId] {
      let polishedText = TranscriptTextPolisher.polish(event.text)
      let existingTranslation = await MainActor.run {
          transcript.reviseFinal(rowId: rowId, newText: polishedText)
          return transcript.translatedText(rowId: rowId)
      }
      if persistSegments {
          try? await SegmentRepository.shared.updateText(id: rowId, textOriginal: polishedText,
                                                          textTranslated: existingTranslation, isFinal: true)
      }
      continue
  }
  ```
  这里读回已有译文再一并写入，避免覆盖掉修正发生前已经翻译好的文本（`updateText` 会整行覆盖，没有单独更新 `textOriginal` 的方法）。为此需要在 `TranscriptBuffer` 加一个小的只读访问器：
  ```swift
  // TranscriptBuffer.swift，紧邻 reviseFinal 之后
  func translatedText(rowId: Int64) -> String {
      guard let idx = indexById[rowId], idx < segments.count else { return "" }
      return segments[idx].translated
  }
  ```
- [ ] **Step 3:** `swift build` 确认编译通过。
- [ ] **Step 4:** 提交：`git commit -m "feat: handle 2-pass revision events in SessionOrchestrator"`

### Task 10: 实时字幕窗口 UI 改版

**Files:**
- Modify: `Features/LiveSession/LiveSubtitleView.swift`
- Modify: `Core/Utils/Theme.swift:31`

- [ ] **Step 1:** `Theme.translation` 色值调整为浅色/深色模式下都有更高对比度（例如换成 `Color(red: 0.05, green: 0.42, blue: 0.38)` 或改用 `Color(light:dark:)` 动态色 helper，若 Theme.swift 里已有类似 pattern 则复用，否则用 `Color(nsColor: NSColor(name: nil) { appearance in ... })`）。
- [ ] **Step 2:** `SubtitleBubble` 原文字体从 `.font(.title3)` 改为 `.font(.system(size: 20, weight: .medium))`，`VStack` 加 `.lineSpacing(4)`；卡片背景从纯 `cardBackground`（只有描边）改为额外叠加 `Theme.surfaceElevated.opacity(0.55)` 填充。
- [ ] **Step 3:** loading 态三个圆点去掉 `.opacity(0.6)` 的整体压暗，圆点 fill 保持 `Theme.translation` 纯色。
- [ ] **Step 4:** `DraftSubtitleBubble` 原文字体同步从 `.title3.italic()` 改为 `.system(size: 20, weight: .medium).italic()`。
- [ ] **Step 5:** 加修正高亮：`SubtitleBubble` 增加 `@State private var flashRevision = false`，`.background` 叠加条件色 `Theme.accentSoft`，`.onChange(of: segment.wasRevised)` 在变 true 时 `withAnimation(.easeOut(duration: 0.3)) { flashRevision = true }`，随后 `Task { try? await Task.sleep(...); withAnimation { flashRevision = false } }`，并调用 `TranscriptBuffer.clearRevisedFlag` 清除逻辑态。
- [ ] **Step 6:** 手动在 Xcode 预览/浅深色模式下确认字号、对比度、修正闪烁效果符合预期。
- [ ] **Step 7:** 提交：`git commit -m "feat: revamp live subtitle bubble typography, contrast, and revision highlight"`

### Task 11: 构建与测试验证

**Files:**
- (no new files)

- [ ] **Step 1:** 运行 `xcodebuild -project ClassNote.xcodeproj -scheme ClassNote -destination 'platform=macOS' build` 确认整体构建通过。
- [ ] **Step 2:** 运行 `xcodebuild test -project ClassNote.xcodeproj -scheme ClassNote -destination 'platform=macOS'`（或对应测试 scheme）确认新增单测通过。
- [ ] **Step 3:** 若构建失败，定位并修复，重复 Step 1-2 直至通过。
- [ ] **Step 4:** 提交（如有修复）：`git commit -m "fix: build/test fixes for local ASR integration"`

### Task 12: 本地构建验证 + 打 tag 触发 GitHub Release 构建

**Files:**
- (no new files; uses existing `.github/workflows/release.yml`)

`.github/workflows/release.yml:3-7` 只在 push tag（`v*`）或手动 `workflow_dispatch` 时触发，push 到 `main` 分支**不会**触发它。因此：

- [ ] **Step 1:** 本地跑一次完整 Release 构建确认没有回归：
  ```bash
  xcodegen generate
  xcodebuild -project ClassNote.xcodeproj -scheme ClassNote -configuration Release build
  ```
- [ ] **Step 2:** 确认 `git status` 干净、所有改动已提交到当前分支，并已推送到远程（`git push origin main`，仅同步代码，不会触发 release workflow）。
- [ ] **Step 3:** 检查 `project.yml` 里的 `MARKETING_VERSION`（当前 `0.3.0`）与 `App/Info.plist` 里的 `CFBundleShortVersionString`，是否需要递增版本号；若需要，两处同步更新并提交。
- [ ] **Step 4:** **需要用户明确授权**：打 tag（例如 `v0.4.0`）并推送触发 release workflow：
  ```bash
  git tag v0.4.0
  git push origin v0.4.0
  ```
  这一步会触发真实的 CI 构建 + 在 GitHub 上创建 Release，属于对外可见的操作，执行前必须与用户确认版本号和目标分支。
- [ ] **Step 5:** 用 `gh run list --workflow=release.yml --limit 1` 和 `gh run watch <run-id>` 跟踪构建状态，确认 DMG 构建、打包、上传 Release 附件全部成功。
- [ ] **Step 6:** 若失败，读取 `gh run view <run-id> --log-failed` 定位问题，修复后删除失败的 tag（`git push --delete origin v0.4.0 && git tag -d v0.4.0`，需再次确认后执行）、重新打 tag 推送，重复 Step 4-5。

---

## 已知限制 / 后续增强点

- `asr_server.py` 的 FunASR 句子边界检测使用简化的 RMS 静音检测（500ms 阈值），真实生产质量需要接入 FunASR 自带的 VAD 模型；当前实现足以让协议闭环工作（partial → 静音 → final + revised），但边界判断的准确度有限。
- Nemotron 引擎的 `nemotron-asr-mlx` 包名/API 为设计阶段基于公开信息的假设，实现时需要对照该库实际发布的 API 调整 `NemotronEngine` 内部实现（不影响 Swift 侧协议，因为协议契约在 sidecar 边界已经固定）。
- `LocalASREnvironment.install` 不预下载模型权重，权重下载发生在 sidecar 首次真正加载模型时（`asr_server.py` 内的 `AutoModel(...)`/`from_pretrained(...)` 调用），因此用户看到的"下载模型中"提示是一个不确定态阶段，没有真实进度百分比。
