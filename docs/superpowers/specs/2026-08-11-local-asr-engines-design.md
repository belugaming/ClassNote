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
- `Core/Engines/LocalASRProcessManager.swift`：选取空闲本地端口，spawn/kill `asr_server.py`，等待其 stdout 打印就绪标记后才视为可连接，进程异常退出时上抛错误（不静默重启，由 orchestrator 决定是否提示用户重试）。
- `Core/Engines/LocalWebSocketSTT.swift`：实现 `STTProvider`，通过 `URLSessionWebSocketTask` 收发上面的二进制/JSON 协议，映射为 `TranscriptEvent`（沿用现有 `isFinal` 字段表达 partial/final），并通过新增的 revision 通道上报修正。

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

`EngineSettingsView` 的 Picker 直接多两个选项，不新增设置页面。

### 二次复核（2-pass revision）

`TranscriptBuffer` 新增：

```swift
func reviseFinal(rowId: Int64, newText: String)
```

原地更新对应 `LiveSegment.original`，并触发 `SegmentRepository` 更新数据库该行文本。`LiveSegment` 新增瞬时字段 `wasRevised: Bool`（非持久化，仅用于 UI 短暂高亮后自动清除）。

`SessionOrchestrator` 的 STT 事件循环增加对 `revised` 类事件的处理分支，与现有 `isFinal` 分支并列，调用 `reviseFinal` 而不是 `appendFinal`。

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
