# macOS 本地语音识别/翻译引擎 + 本地网络权限修复

## 背景

ClassNote 目前只支持通过 OpenAI 兼容云端 API 做语音转写和翻译。用户希望能接入
macOS 系统自带的语音识别与翻译能力(近期系统听写效果显著提升),并解决"设置里
找不到本地网络权限开关"的问题。

## 1. 本地网络权限

macOS 只有在应用**实际发起**一次本地网络连接(私有网段 IP / `.local` / `localhost`)
且声明了 `NSLocalNetworkUsageDescription` 时,才会弹出权限请求,进而在
系统设置 > 隐私与安全性 > 本地网络 中出现该应用的开关。仅声明 Info.plist 不会
触发弹窗。

- `Info.plist` / `project.yml` 新增 `NSLocalNetworkUsageDescription`。
- 新增 `Core/Utils/LocalNetworkAccess.swift`:
  - `isLocalNetworkHost` 判断 Base URL 的 host 是否为局域网地址。
  - `probe(baseUrlString:)` 用 `NWConnection` 对该 host 发起一次 TCP 连接,
    根据 `NWError` (`PolicyDenied` / `EPERM`)判断是否被拒绝。
  - `openSystemSettings()` 用 `x-apple.systempreferences:` 深链跳转到本地网络
    权限页面。
- `ApiSettingsView` 保存配置时,如果 Base URL 是局域网地址,调用探测;
  探测结果为拒绝时展示提示条 + "打开系统设置"按钮。

## 2. 本地语音识别(STT)

新增 `SttBackend.appleSpeech`,通过 `EngineFactory.makeSTT` 返回
`AppleSpeechSTT`,内部按系统版本自动选择底层实现:

- **macOS 26+**: `SpeechAnalyzer` + `SpeechTranscriber`(WWDC25 新 API),
  全端上处理,速度快、准确率高。需要通过 `AssetInventory` 检查/下载语言模型。
- **macOS 14-25**: `SFSpeechRecognizer`,在支持的情况下设置
  `requiresOnDeviceRecognition = true`。由于
  `SFSpeechAudioBufferRecognitionRequest` 只在 `endAudio()` 后报告一次
  `isFinal`,为了保持和云端引擎一致的"按静音边界分句"体验,在
  `AppleSpeechSTT+Legacy.swift` 里实现了 `SilenceChunker`,复用与
  `OpenAICompatibleSTT` 相同的阈值(`minVoicedSec`/`silenceHoldSec`/
  `maxChunkSec`)在静音处主动结束当前请求、开启新请求。

两条路径都只在拿到 final 结果时才 `yield TranscriptEvent`,与云端引擎的语义
保持一致;`transcribeFile` 复用同一套引擎处理整份文件。

权限:新增 entitlement
`com.apple.security.personal-information.speech-recognition` +
`NSSpeechRecognitionUsageDescription`,首次使用前调用
`SFSpeechRecognizer.requestAuthorization`。

## 3. 本地翻译

新增 `TranslationBackend`(`openai` | `apple`),`EngineFactory.makeTranslator`
按此参数选择引擎。`AppleTranslationEngine`(macOS 15+)使用 Apple
Translation 框架:

- **macOS 26+**:直接用 `TranslationSession(installedSource:target:)`,
  无需 UI 依赖。
- **macOS 15-25**:`TranslationSession` 只能通过 SwiftUI 的
  `.translationTask` modifier 获取。为此新增 `AppleTranslationBridge`
  (`@MainActor` 单例)+ `AppleTranslationBridgeView`(0×0 隐藏视图,挂在
  主窗口背景里,和现有的 `LiveSessionOpener` 同样的桥接手法),按需切换
  `TranslationSession.Configuration` 触发 modifier 拿到新 session。

翻译结果是整句一次性返回(Apple API 无流式接口),不像云端 LLM 那样逐字流式。

## 4. 数据模型 & 设置界面

- `ApiConfig` 新增字段 `translationBackend`,数据库迁移 `v7_translation_backend`
  加列,默认值 `"openai"`。
- `AppState` 新增 `translationBackend: TranslationBackend`,随
  `loadConfig`/`saveConfig` 同步。
- `EngineSettingsView`:STT 分段选择器加入"macOS 系统(本地)";翻译区块在
  开关基础上新增引擎选择器(云端 LLM / macOS 系统本地),选中 Apple 引擎时
  显示语言包自动下载的提示文案。

## 已知取舍

- 未做真机编译验证(环境中 SDK/工具链版本不匹配,且未安装 Xcode.app),仅通过
  `swiftc -parse` 语法检查、`xcodegen generate` 项目文件生成验证,以及对照
  真实 SDK `.swiftinterface` 文件核对 API 签名。建议在能跑 Xcode 的机器上
  clean build 一次。
- Apple 本地翻译无流式输出,长句翻译体验会比云端 LLM "一次性出现"而不是逐字滚动。
- 语言包下载失败/语言不受支持时,统一走 `EngineError.unsupported` 的文案提示,
  未做更细的重试/进度 UI。
