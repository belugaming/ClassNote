# 本地流式 ASR 引擎集成（FunASR / Nemotron）+ 实时字幕窗口改版

## 背景

现有 `SttBackend` 支持 OpenAI-compatible 云端分段 Whisper、WhisperKit（占位，回退到 OpenAI 路径）、Apple Speech。用户希望新增两个本地流式引擎：

- **FunASR**（阿里达摩院）：流式 Paraformer 边说边出字 + 断句后用 SenseVoice/离线 Paraformer 复核替换，即"2-pass"。
- **NVIDIA Nemotron Streaming ASR**：Cache-Aware FastConformer-RNNT，原生流式，英文场景延迟最低。

两者都是 Python/Linux 生态，没有官方 Swift/macOS SDK，因此走"本地 WebSocket 服务 + Swift 客户端"路线。

同时，用户反馈录音开始时弹出的实时会话窗口（`LiveSessionView` / `LiveSubtitleView`）排版难看：字号小、颜色淡，且当前草稿流式气泡从未被触发过（因为默认引擎不发非 final 事件）。

## 架构

### 本地 sidecar 进程

一个统一的 Python 脚本 `Scripts/asr_server.py`，启动参数 `--engine funasr|nemotron --port N`，跑一个 WebSocket 服务器：

- 接收：16kHz mono PCM16 二进制帧。
- 发送 JSON 事件：
  ```json
  {"type": "partial", "segmentId": 1, "startMs": 1200, "endMs": 1800, "text": "..."}
  {"type": "final",   "segmentId": 1, "startMs": 1200, "endMs": 2400, "text": "..."}
  {"type": "revised", "segmentId": 1, "startMs": 1200, "endMs": 2400, "text": "..."}
  ```
- 同一时间只运行一个引擎进程，随 `SttBackend` 选择启停。

### Swift 侧新增文件

- `Core/Engines/LocalASREnvironment.swift`：检测 `Application Support/ClassNote/pyenv` 下的专用 venv 是否存在、对应引擎的 pip 包是否已安装、模型权重是否已缓存；提供 `install(engine:) -> AsyncStream<InstallProgress>`。
- `Core/Engines/LocalASRProcessManager.swift`：**实现为 `actor`**（天然处理进程句柄的并发隔离，且 actor 类型自动满足 `Sendable`）。选取空闲本地端口，spawn/kill `asr_server.py`，等待其 stdout 打印就绪标记后才视为可连接；对外提供 `func start() async throws -> URL`（返回 ws 地址）与 `func shutdown() async`。进程异常退出时通过 continuation 把错误注入到 `LocalWebSocketSTT` 的流里（不静默重启，由 UI 层的错误 banner 提示用户重试）。
- `Core/Engines/LocalWebSocketSTT.swift`：`final class`，持有对上面 actor 的引用（引用本身即 `Sendable`），实现 `STTProvider`。**进程的实际启动（含首次就绪等待）延迟到 `transcribe(audio:language:)` 被调用时才发生**，而不是在 `EngineFactory.makeSTT` 构造时——这样不需要改动 `EngineFactory.makeSTT` 现有的同步、非 throwing 签名（`Providers.swift:92`）；启动失败直接通过 `continuation.finish(throwing:)` 反映到调用方已有的错误处理路径。通过 `URLSessionWebSocketTask` 收发协议消息，映射为 `TranscriptEvent`。**进程生命周期绑定到返回的 `AsyncThrowingStream` 上**：用 `continuation.onTermination = { _ in Task { await processManager.shutdown() } }` 保证无论是正常结束、抛错、还是外部 `Task.cancel()`（对应 `SessionOrchestrator.stop()` 里的 `sttTask?.cancel()`），子进程都会被清理，不需要改 `SessionOrchestrator.stop()` 本身。

### `SttBackend` 扩展

新增两个 case：

```swift
enum SttBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case whisperKitLocal = "whisperkit"
    case appleSpeech = "apple"
    case funasr = "funasr"
    case nemotronStreaming = "nemotron"
    ...
}
```

`EngineSettingsView`（`Features/Settings/SettingsView.swift:440`）的 Picker 直接多两个选项，不新增设置页面。

`EngineFactory.makeSTT(config:backend:)`（`Providers.swift:91-101`）保持同步、非 throwing 的现有签名不变：对 `.funasr`/`.nemotronStreaming` 两个新 case，直接返回一个尚未连接的 `LocalWebSocketSTT` 实例（构造本身不做任何 IO）。真正的进程启动、端口选取、就绪等待全部推迟到 `transcribe(audio:language:)` 被调用的那一刻，详见下节。

### 二次复核（2-pass revision）

**`TranscriptEvent` 需要携带修正所需的关联信息**（`Core/Engines/Providers.swift:9-24` 现状没有 segment 标识字段，无法定位要修正哪一行）。扩展该结构体：

```swift
struct TranscriptEvent: Sendable, Identifiable, Hashable {
    let id: UUID
    let startMs: Int64
    let endMs: Int64
    let text: String
    let isFinal: Bool
    let speakerId: String?
    let engineSegmentId: Int64?   // 新增，可选；仅本地流式引擎会填充
    let isRevision: Bool          // 新增，默认 false；true 表示这是对某个已 final 事件的修正
}
```

`LocalWebSocketSTT` 收到 `revised` 消息时，构造 `isRevision: true` 的事件，`engineSegmentId` 对应之前 `final` 消息里的 `segmentId`。`SessionOrchestrator` 自己维护一个 `[Int64: Int64] // engineSegmentId -> rowId` 的映射（在处理 `final` 分支、拿到数据库返回的 `rowId` 后写入这个字典），这样收到 `revised` 事件时能查到对应的 `rowId`——`TranscriptEvent` 本身不需要知道 App 内部的 `rowId`，`rowId` 始终由 `SessionOrchestrator` 生成/持有（沿用现状，`SessionOrchestrator.swift:323`）。

`TranscriptBuffer` 新增：

```swift
func reviseFinal(rowId: Int64, newText: String)
```

原地更新对应 `LiveSegment.original`，逻辑与 `updateTranslation` 相同的 `indexById` 查找模式（`TranscriptBuffer.swift:47`）。`LiveSegment` 新增瞬时字段 `wasRevised: Bool = false`（非持久化，仅用于 UI 短暂高亮，`LiveSubtitleView` 侧用 `Task.sleep` 或 `withAnimation` 延时后调用一个新增的 `clearRevisedFlag(rowId:)` 清除）。

数据库落盘调用已有的 `SegmentRepository.updateText(id:textOriginal:textTranslated:isFinal:)`（`Repositories.swift:208`，无需新增仓储方法）——译文参数传当前已有的 `translated` 值，`isFinal` 传 `true`。

`SessionOrchestrator` 的 STT 事件循环（`SessionOrchestrator.swift:283-340`）增加对 `event.isRevision == true` 的处理分支，查表拿到 `rowId` 后，和现有 `final` 分支一样用 `await MainActor.run { transcript.reviseFinal(...) }` 切回主线程再调用（`TranscriptBuffer` 是 `@MainActor`，`TranscriptBuffer.swift:8`），再异步调用 `SegmentRepository.shared.updateText(...)` 落盘，不阻塞事件循环。

### 首次安装 / 环境准备

用户在设置里选中 FunASR 或 Nemotron 并点击"开始"时：

1. `LocalASREnvironment.check(engine:)` 检查 venv/依赖/模型缓存。
2. 若缺失，`LiveSessionView` 展示内嵌安装提示条（而非直接开始录音），提供"立即安装"按钮。
3. 点击后触发 `pip install` 到独立 venv，进度通过 `AsyncStream` 回传显示进度条；模型权重下载由各引擎库首次加载时自动完成，同样展示"下载模型中"的不确定态提示。
4. 安装完成后自动继续原来的开始录音流程。

### 错误处理

- Python 未找到 / 版本不满足 → 提示用户安装 Python3（不自动装 Python 本体）。
- 端口绑定失败 → 换端口重试一次，仍失败则报错并中止启动。
- pip 安装失败 → 展示具体错误，不静默 fallback 到其他引擎。
- 进程运行中崩溃 → 显示错误 banner，停止当前会话，不自动重连（避免无限重启循环）。
- 进程清理：不依赖 `SessionOrchestrator.stop()`（`SessionOrchestrator.swift:216`）新增专门的清理调用——`sttTask?.cancel()` 会让 `LocalWebSocketSTT.transcribe` 返回的 `AsyncThrowingStream` 走到 `onTermination`，由它负责调用 `LocalASRProcessManager.shutdown()`。这样常规停止、异常抛错、App 强制退出前的 cancel 都走同一条清理路径，无需在 orchestrator 里为本地引擎特判。

## UI 改版：LiveSessionView / LiveSubtitleView

用户确认这是"点开始录音弹出来的窗口"（主窗口内的实时字幕区域，不是悬浮字幕条 OverlayView）。

改动：

- `SubtitleBubble` 原文：`.title3` → `.system(size: 20, weight: .medium)`，`lineSpacing` 加大到 4。
- 译文颜色：替换 `Theme.translation`（浅色模式下对比度不足的暗青色）为新增的、在浅色/深色模式下都有 AA 级对比度的 `Theme.translation` 取值调整（同一 token，调整具体色值，不改调用点）。
- 去掉译文 loading 态时不必要的 `.opacity(0.6)` 压暗，改为纯色圆点。
- 每条 `SubtitleBubble` 使用更明显的卡片背景（提高 `Theme.surfaceElevated` 的不透明度或改用带边框的卡片），让每一行在视觉上独立成块，而不是依赖当前几乎不可见的整页渐变背景。
- `DraftSubtitleBubble`（流式草稿气泡）同步放大字号，保持斜体/次要色以区分"未定稿"状态。
- 新增修正高亮：`reviseFinal` 触发后，对应 `SubtitleBubble` 短暂（约0.3秒）显示强调背景色后渐隐回正常，用于让用户注意到文字被 2-pass 修正过，但不会长期占用视觉焦点。
- 流式草稿气泡本身的机制（`updateDraft`/`draftText`）不需要改动 —— 一旦 `LocalWebSocketSTT` 发出 partial 事件，这条气泡会自动开始工作。之前"没有流式"是因为当前默认引擎（云端分段 Whisper）从不产生非 final 事件。

## 测试计划

- 单测 `TranscriptBuffer.reviseFinal`：原地替换文本、不影响其他行、`wasRevised` 正确置位后可清除。
- 单测 `LocalWebSocketSTT` 的 JSON 解码：partial/final/revised 三种消息正确映射为对应的 `TranscriptEvent` / revision 调用，使用固定 JSON 输入，不依赖真实 Python 进程。
- 手动验证：
  1. 全新环境下选择 FunASR，触发安装提示，走完安装流程。
  2. 开始一次真实会话，确认草稿气泡随语音流式更新，句子提交后出现至少一次修正高亮。
  3. 中途 kill 掉 Python 进程，确认 App 展示错误并干净停止，而不是卡死。
  4. 目测新 UI 在浅色/深色模式下的对比度和字号。

## 范围之外

- 不实现 WhisperKit 真正本地推理（现状的占位 fallback 保持不变）。
- 不做多引擎并行/自动切换。
- 不自动安装 Python 解释器本体，只管理其之上的 venv 和依赖包。
