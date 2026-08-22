# 全 MLX 本地转写 + 翻译管线（仅 macOS）

## 背景

### 前提变更

**放弃移动端，全部目标收敛到 macOS + Apple Silicon。** 这推翻了
`2026-08-11-local-asr-engines-design.md` 里"模型要小、要能塞进手机"的隐含约束，
也让之前考虑的 sherpa-onnx / Swift 化不再是必需项——Python sidecar 可以保留。
选型标准从"最小"改为"最准"。

### 现状的四个问题

排查 `Scripts/asr_server.py` 与 `nemotron_asr_mlx` 包后确认：

1. **英文没有第二遍。** `Models.needs_offline_pass`（asr_server.py:199-210）在
   Nemotron 加载成功时返回 `False`，英文把流式草稿直接当 `final` 提交。中文却有
   paraformer-zh + ct-punc 的整句重转。这是"英文还不如 Apple 自带"的主因——
   拿草稿在跟别人的成稿比。
2. **带空洞的文本被提交为最终结果。** `drop_holed_text` 的判据是
   `self.models.offline is not None`（asr_server.py:738），英文恒为 `None`，
   所以掉帧后残缺的文本照样落库。
3. **流式模型 O(n²) 重算。** `StreamSession.push()` 每 160ms 把整个 `_pcm_buffer`
   重新算一遍 log-mel 且从不裁剪，单次耗时随句子长度线性增长，长句必然触发
   `MAX_STREAM_BACKLOG_MS` 掉帧，再叠加问题 2 就是肉眼可见的丢词。
4. **中英两套模型、两条代码路径。** `is_chinese` 分支贯穿 `Models` 与 `Session`，
   中英混说（讲课最常见）无法处理，且必须提前选语言。

问题 1、2 是逻辑 bug；问题 3 是上游库的实现缺陷；问题 4 是选型导致的架构债。
本方案通过换模型一次性解决 4，同时顺带消除 1、2、3 的成因。

## 选型结论

| 环节 | 模型 | 引擎 | 协议 |
|---|---|---|---|
| VAD | Silero VAD | mlx-audio | MIT |
| 第一遍（流式草稿） | `mlx-community/nemotron-3.5-asr-streaming-0.6b` | mlx-audio | NVIDIA `other` ⚠️ |
| 第二遍（权威文本） | `Qwen/Qwen3-ASR-1.7B` (MLX 8bit) | mlx-audio | Apache 2.0 |
| 翻译 | `mlx-community/Hy-MT2-1.8B-4bit` | mlx-lm | Apache 2.0 |

选型理由：

- **Qwen3-ASR** 一个模型覆盖中/英/粤 + 22 种中文方言（共 52 语言），
  WenetSpeech 4.97% / AISHELL-2 2.71% / LibriSpeech 1.63% clean。
  它是 LLM 解码器架构（AuT 音频编码器 → Qwen3 decoder），**自带标点和大小写**，
  所以 ct-punc 可以一并删掉。官方流式仅支持 vLLM 后端，因此在 MLX 上只用作
  离线第二遍——这恰好是当前架构缺的那一环。
- **Nemotron 3.5 Streaming** 是 cache-aware FastConformer-RNNT，缓存跨 chunk
  流动而非重算，直接规避问题 3；多语言版含中文，一个模型出中英 partial。
  暴露 `att_context_size` 作为延迟/准确度旋钮（见下）。
- **Hy-MT2-1.8B** 是专用翻译模型而非通用 LLM 兼职，33 语言 1056 个方向，
  中英是最强项；"fast-thinking" 设计不会先吐一堆推理再给译文，适合逐句字幕。

## 管线

```
麦克风 PCM 16kHz mono
   │
   ├─► Silero VAD ──────────────► 端点检测 / 段边界
   │
   ├─► 第一遍：Nemotron 3.5 Streaming 0.6B
   │      chunk 320ms, att_context_size=[56,3]
   │      → partial 事件（草稿，可随时丢弃）
   │
   └─► utt_buf 整段 ─► 第二遍：Qwen3-ASR-1.7B
                         → final 事件（权威文本，自带标点大小写）
                         │
                         └─► 第三遍：Hy-MT2-1.8B
                                → 译文，走现有 updateTranslation 路径
```

关键性质：**第一遍的输出永远只是草稿，永远不会成为最终文本。**
这条不变式一旦成立，问题 1、2 自动消失——掉帧、重置、缺词都无所谓，
因为第二遍看的是完整的 `utt_buf`，而不是流式模型的累积状态。
`drop_holed_text` 这个判断本身可以删除。

### `att_context_size` 旋钮

Nemotron 3.5 提供四组训练过的 look-ahead：`[56,0]` / `[56,3]` / `[56,6]` / `[56,13]`。
当前代码把 `chunk_ms=160` 硬编码在 `Models.NEMOTRON_CHUNK_MS`，没有这个维度。

**实测结果推翻了"小右上下文=低延迟"的直觉**（M 系列，10.8s 英文样本，320ms 推流）：

| att_context_size | RTF | 输出 |
|---|---|---|
| `[56,13]`（默认） | **0.38** | 与离线 `generate()` 逐 token 相同 |
| `[56,3]` | 0.91 | 少量标点丢失 |
| `[56,0]` | 1.64 ❌ | "Then me to Chandria"（明显退化） |

右上下文越小反而**越慢**：chunk 越碎，encoder 调用次数越多，每秒音频的固定开销越大。
`[56,0]` 的 RTF 1.64 意味着它根本跟不上实时，必然触发掉帧。

**结论：默认用 `[56,13]`，它同时是最准和最快的。** 这个旋钮只在用户明确想降低
"首字延迟"时才下调，且不应低于 `[56,3]`。作为对照，同一段音频上
`Model.generate()`（离线全量）耗时 4.97s，而流式 `[56,13]` 只要 4.15s ——
流式路径是 O(n) 增量，离线路径反而在重算。

## 依赖变化

删掉 FunASR 也就删掉了整条 PyTorch 依赖链：

| | 现状 | 新方案 |
|---|---|---|
| `Scripts/requirements-*.txt` | funasr, torch, torchaudio, soundfile, websockets, nemotron-asr-mlx, mlx | mlx, mlx-audio, mlx-lm, numpy, soundfile, websockets |
| 安装体积 | ~3–4 GB | 数百 MB + 模型权重 |
| 模型来源 | ModelScope（国内快，海外慢/偶发超时） | Hugging Face |

`requirements-funasr.txt` 与 `requirements-nemotron.txt` 合并为单一
`requirements-mlx.txt`——两个引擎共用一套依赖的注释（见现有
`requirements-nemotron.txt` 开头）说明这个拆分本来就没起作用。

## 分档

统一内存是硬约束，按机器给三档（设置页可选）：

| 档位 | 流式 | 离线 | 翻译 | 常驻内存 |
|---|---|---|---|---|
| 轻量 | Nemotron `[56,13]` | Qwen3-ASR-0.6B-8bit | Apple Translation | ~1.5 GB |
| 标准（默认） | Nemotron `[56,13]` | Qwen3-ASR-1.7B-8bit | Hy-MT2-1.8B-4bit | ~4 GB |
| 最高 | Nemotron `[56,13]` | Qwen3-ASR-1.7B-8bit | Hy-MT2-7B-4bit | ~8 GB |

`att_context_size` 三档都用 `[56,13]`——见上一节，它是帕累托最优，没有理由下调。
分档只改模型大小。

轻量档保留 Apple Translation 是因为它零内存、零下载、系统原生，
在 8GB 机器上比塞第三个模型更合理。

## Swift 侧改动

改动面比预期小——WebSocket 协议、`LocalASRProcessManager`、`LocalWebSocketSTT`、
`LocalASREnvironment` 的 venv 管理逻辑**全部不变**，只是 sidecar 内部换了实现。

### `SttBackend`（AppState.swift:475）

`funasr` 与 `nemotronStreaming` 两个 case 合并为一个：

```swift
enum SttBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case whisperKitLocal = "whisperkit"
    case appleSpeech = "apple"
    case localMLX = "mlx"        // 取代 funasr + nemotron
}
```

原因：中英不再需要选引擎，语言由模型自动处理。旧的两个 rawValue 需要在
读取设置时迁移映射到 `"mlx"`，避免升级后设置失效。

### `TranslationBackend`（AppState.swift:502）

新增本地档：

```swift
enum TranslationBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai"
    case appleTranslation = "apple"
    case localMLX = "mlx"        // 新增：Hy-MT2
}
```

翻译走 sidecar 意味着 `asr_server.py` 需要新增一个消息类型：

```json
{"type": "translate", "segmentId": 1, "text": "...", "targetLang": "zh"}
{"type": "translation", "segmentId": 1, "text": "..."}
```

复用同一个 WebSocket 连接和同一个 MLX 运行时，避免再起一个进程。

### 设置页

`EngineSettingsView`（SettingsView.swift:440）Picker 选项少一个（两个本地引擎合一）、
多一个"质量档位"Picker 和一个"字幕延迟"Picker（映射到 `att_context_size`）。

## 迁移步骤

每一步单独可发布、可回滚、可独立验证：

**Step 1 — 换第二遍（解决"英文不准"）**
- `Models._load()` 的 offline 分支改用 Qwen3-ASR，删除 paraformer-zh / paraformer-en / ct-punc
- `needs_offline_pass` 恒为 `True`，删除 `drop_holed_text` 判断
- 流式那一遍暂时保持现状不动

这一步就应该能消除用户感知到的绝大部分"不准"。

**Step 2 — 换第一遍**
- 流式模型换 Nemotron 3.5 Streaming，删除 `paraformer-zh-streaming`
- 删除 `Models.is_chinese` 及其所有下游分支
- 暴露 `att_context_size`

**Step 3 — 换 VAD，卸掉 FunASR**
- FSMN-VAD → Silero VAD（mlx-audio）
- 此时 funasr / torch / torchaudio 依赖归零，改 requirements 并让
  `LocalASREnvironment` 的 `.installed-*` marker 失效以触发重装

**Step 4 — 本地翻译**
- 接入 Hy-MT2，新增 translate/translation 消息类型与 `TranslationBackend.localMLX`

## 实测验证（2026-08-22）

环境：`python3.14` + `pip install git+https://github.com/Blaizzy/mlx-audio.git`。
注意 **PyPI 上的 `mlx-audio` 太旧**（只有 glmasr/parakeet/voxtral/whisper 四个后端），
必须装 git main 才有 `qwen3_asr` / `nemotron_asr` / `sensevoice` 等 27 个后端。
另外该包要求 Python ≥ 3.10。

样本：`say` 合成的 10.8s 英文 + 一段中文。

| 路径 | RTF | 输出 |
|---|---|---|
| Nemotron 3.5 流式 `[56,13]` | 0.38 | `The Mitchandria is the powerhouse of the cell. …` |
| Qwen3-ASR-0.6B（英文） | 0.22 | `The mitochondria is the powerhouse of the cell. …` ✅ |
| Qwen3-ASR-0.6B（中文） | **0.07** | 全对，标点齐全，无需 ct-punc |
| Hy-MT2-1.8B-4bit | 1.19s/句 | `线粒体是细胞的能量工厂。今天，我们将讨论细胞呼吸…` |

两个结论：

1. **第二遍确实值得做**——Qwen3-ASR 把 Nemotron 听错的 "Mitchandria" 纠正为
   "mitochondria"，且它更快。
2. **Qwen3-ASR 快到不构成瓶颈**：6s 的段落中文只要 0.4s、英文 1.3s，
   远小于段长，不会堆积。1.7B 会慢一些但仍有很大余量。

### 推流适配

mlx-audio 只暴露 pull 式的 `stream_generate(whole_audio)`，而 sidecar 需要 push
（PCM 从 socket 来）。已验证可以用公开原语自行组装 push 会话：

- `StreamingLogMelSpectrogram.push(samples, final=)` —— 增量 mel，**不重算**
- `ConformerStreamingState.push(mel, final=)` —— 跨 chunk 保持 encoder/conv cache
- RNNT 贪心解码循环（照搬 `Model._decode_prompted_chunks`，把 `last_token` /
  `decoder_hidden` / `hypothesis` 提升为实例字段）

已跑通并与离线输出逐 token 比对一致。

## 剩余风险

1. **Nemotron 3.5 协议是 `other`（NVIDIA）**，Qwen3-ASR 与 Hy-MT2 都是 Apache 2.0。
   若将来要分发，需先审 NVIDIA 条款；必要时流式那一遍换成 Voxtral Mini Realtime
   （Apache 2.0，但 4.4B，更重）。
2. **VAD 尚未实测。** `mlx_audio.vad` 提供 `fsmn` / `silero_vad` / `smart_turn` /
   `sortformer`，另有 `mlx_audio.realtime_vad`（`StreamingVad` / `TurnDetector`）。
   `fsmn` 可用意味着能保持与现状完全一致的切段行为，同时甩掉 FunASR。
3. **中文流式路径未单独实测**（只测了 Qwen3-ASR 的中文离线）。Nemotron 3.5
   标称含中文，但中文流式质量需要用真实课堂录音验证。

## 范围之外

- 不做 Swift 化 / 不引入 mlx-audio-swift（移动端已出局，Python sidecar 够用）
- 不做 sherpa-onnx（同上；且它解决的是 iOS 和去 Python，都不再是目标）
- 不做说话人分离（Sortformer 可用，但属于独立特性）
- 不改动 WebSocket 协议的 partial/final/revised 三段式语义
- 不自动安装 Python 解释器本体
