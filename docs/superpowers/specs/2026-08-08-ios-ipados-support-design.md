# iPad / iOS 支持

## 背景

ClassNote 目前是纯 macOS 应用,深度依赖 AppKit(菜单栏、独立窗口、`NSSavePanel`
等)和 `ScreenCaptureKit`(录制会议系统音频)。目标是让 iPad/iPhone 用户也能用:
能力对等的功能尽量搬过去,平台原生没有的能力(系统音频、全局快捷键、多窗口)按
平台差异自然裁剪,不做变通实现。

核心限制先达成一致:
- iOS/iPadOS 无 `ScreenCaptureKit` 系统音频捕获,iOS 端只支持麦克风录音,
  定位是"举着 iPad/iPhone 现场录课堂",不支持录 Zoom/Teams 会议音频。
- 菜单栏图标(`MenuBarExtra`)、独立悬浮字幕窗口(Overlay)、全局快捷键
  (`KeyboardShortcuts`)在 iOS 上没有对应物,全部去掉,改用主界面内的等效入口。

## 1. 工程结构

XcodeGen 的多平台 `platform: [macOS, iOS]` 语法实际会为**每个平台生成独立的
Xcode target**(例如 `ClassNote_macOS` / `ClassNote_iOS`),而不是一个物理上
单一的 target。两者共享同一份 `sources`(`App`/`Core`/`Features`),但
`dependencies`(SPM 包)、`settings`、`info.properties`、`entitlements` 需要
按平台分别声明——具体键名/写法(是用 XcodeGen 的平台后缀 key,还是拆成两个
`targets` 条目共享 `sources` 路径)在实现阶段用一份最小 `project.yml` 验证
`xcodegen generate` 的实际产出后再定稿,这里先明确方向,不假定语法细节。

`deploymentTarget` 分别为 macOS 14.0 / iOS 17.0。

**SPM 依赖逐个确认平台兼容性**(而非只看调用点代码):
- `KeyboardShortcuts` 的 `Package.swift` 声明 `platforms: [.macOS(.v10_15)]`,
  是纯 macOS 包,**无法链接进 iOS target**。因此 iOS target 的依赖列表里不
  包含它;`Core/Hotkeys/GlobalShortcuts.swift` 这个文件本身只归属于 macOS
  target 的 `sources`(而不是靠 `#if os(macOS)` 包裹内容——这样即使不链接
  KeyboardShortcuts,该文件也不会参与 iOS 编译)。
- `GRDB` 和 `LaTeXSwiftUI` 均声明了 iOS 支持,可在两个 target 间共享。

新增 `App/ClassNote-iOS.entitlements`(iOS 沙盒 key 与 macOS 不同,不能共用
同一份 entitlements 文件)。iOS target 的 Info.plist 只保留会用到的权限描述
(麦克风/语音识别/本地网络),不包含 `NSScreenCaptureUsageDescription`、
`NSAppleEventsUsageDescription`,也不包含 macOS 专属的
`LSMinimumSystemVersion`、`NSPrincipalClass`、`LSUIElement`、
`NSSupportsAutomaticTermination`/`NSSupportsSuddenTermination` 等
AppKit/`NSApplication` 语境下的 key。

跨平台共享文件内部用 `#if os(iOS)` / `#if os(macOS)` 条件编译分叉,不引入
额外抽象层或协议;能直接共享的业务逻辑(`AppState`、引擎、数据库)不做改动。

## 2. 音频捕获(`AudioSourceManager`)

`ScreenCaptureKit` 相关代码(`SCStream`、系统音频、mixed 混音路径)整体包
`#if os(macOS)`。`AudioSourceKind` 枚举保留 `.system`/`.mixed` case(避免影响
已持久化的会话数据/序列化),但源选择器 UI 在 iOS 上通过
`AudioSourceKind.availableCases(for: currentPlatform)` 之类的过滤,只展示
`.microphone` 和 `.file`。麦克风路径(`AVAudioEngine` tap)本身跨平台可用,
无需改动。

## 3. App 外壳与导航(`ClassNoteApp.swift`)

`body: some Scene` 按 `#if os(iOS)` 分两条路径:

**macOS(现状不变)**:多 `WindowGroup`(main / live-session)、独立
`Window("Overlay")`、`MenuBarExtra`、`Settings{}`、`.commands` 全局菜单项。

**iOS(新增)**:单一 `WindowGroup`,根视图 `MainWindowView`。具体映射:
- `MainWindowView` 的 `NavigationSplitView` 结构预期可以直接复用,SwiftUI
  在 iPhone 上会将其折叠为单列堆栈导航,iPad 上保留双栏/三栏。但这只是
  预期,不是保证——具体折叠后的返回手势、`selection` 绑定行为、以及
  `.navigationSplitViewColumnWidth` 在 compact 宽度下的表现,需要在实现
  阶段实际跑起来验证,不排除需要针对 iPhone 单列场景做局部调整。
- Live Session 独立窗口 → 同一个 `LiveSessionView` 通过
  `NavigationStack` push 或 `.fullScreenCover` 呈现。
- `Settings{}` scene → `SettingsView` 通过 `.sheet` 呈现,入口放在主界面
  工具条或列表页的设置按钮里。
- 悬浮字幕 Overlay 独立窗口 → 不做独立窗口。`OverlayView.swift` 当前依赖
  AppKit 的 `WindowAccessor`(`NSViewRepresentable` + `NSWindow`,用于把
  背景设为透明/取消标题栏),这部分**不能直接复用**。字幕文案渲染部分
  (`OverlayCaptionView` 等纯 SwiftUI 视图)可以拆出来给 iOS 复用,但
  `WindowAccessor` 及窗口外观设置逻辑保留在 macOS-only 代码里,iOS 端
  的浮动卡片只是普通 SwiftUI `overlay`/`ZStack`,不需要也无法用同一套
  窗口访问逻辑。
- `MenuBarExtra` 图标 → 无对应物,归属 macOS target 的 `sources`,不参与
  iOS 编译。

`Core/Hotkeys/GlobalShortcuts.swift` 依赖 `KeyboardShortcuts` 包(见第 1 节,
该包不支持 iOS),因此这个文件本身只归属于 macOS target 的 `sources` 列表,
不是靠 `#if os(macOS)` 包裹内容。iOS 上"开始录音 / 标记高光 / 切换翻译 /
切换字幕"复用 `AppState` 上已有的方法,触发入口换成主界面工具条按钮,不
重写业务逻辑。

## 4. AppKit → 跨平台系统集成

新增 `Core/Utils/PlatformBridge.swift`,收拢现有散落各处的 AppKit 直接调用:

| 用途 | macOS | iOS |
|---|---|---|
| 复制到剪贴板 | `NSPasteboard.general` | `UIPasteboard.general` |
| 导出文件(转写稿/flashcards) | `NSSavePanel` | `.fileExporter` modifier |
| 打开本地存储目录 | `NSWorkspace.shared.open` | 隐藏该入口(iOS 无 Finder 概念) |
| 定位文件(`activateFileViewerSelecting`) | 现状不变 | 隐藏该入口 |
| 跳转系统设置(本地网络权限) | `x-apple.systempreferences:` deep link | `UIApplication.openSettingsURLString` |

调用方(`SessionExporter`、`SessionDetailView`、`LocalNetworkAccess`、
`MainWindowView`/`SettingsView` 里的 `NSWorkspace` 调用)改为调用
`PlatformBridge` 上的封装函数,而不是直接 import AppKit。iOS 上没有对应物的
操作(打开 Finder)在调用侧通过 `#if os(macOS)` 隐藏按钮,不提供空实现。

## 5. 版本可用性标注(`@available`)

`AppleSpeechSTT+Modern.swift`、`AppleTranslationBridge.swift`、
`AppleTranslationEngine.swift` 现有的 `@available(macOS 26.0, *)` /
`@available(macOS 15.0, *)` 标注只约束了 macOS 版本,`*` 通配符对 iOS
不设下限——意味着编译进 iOS target 后,这些用到 `SpeechAnalyzer`/
`SpeechTranscriber`/`Translation` 框架新 API 的代码会被当作"iOS 全版本
可用",在旧 iOS 上运行时会崩溃而非编译期/运行期优雅降级。实现阶段需要
把这些标注改成同时声明两个平台的下限,例如
`@available(macOS 26.0, iOS 26.0, *)`(对应 iOS 版本以实际 API 引入版本
为准,需要查阅当年 WWDC 的 iOS 对应发布版本号,不能直接照抄 macOS 版本号)。

## 6. 数据存储路径(GRDB / 录音文件)

`App/AppBootstrap.swift` 的 `applicationSupportURL` 用
`FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)`
定位数据库和录音文件目录。这段代码本身跨平台可编译,但 iOS 沙盒下
`.applicationSupportDirectory` 位于 App 私有容器内,且不参与 iCloud 备份
默认排除逻辑与 macOS 不同;此外 iOS 后台执行受限,长录音时 App 切到后台
可能被系统暂停写入。这两点在本设计范围内不展开解决方案,列为实现阶段
需要专门验证的风险点,不假定"无需改动"。

## 7. 权限与 Info.plist

iOS 保留:`NSMicrophoneUsageDescription`、
`NSSpeechRecognitionUsageDescription`、`NSLocalNetworkUsageDescription`。
去掉:`NSScreenCaptureUsageDescription`、`NSAppleEventsUsageDescription`
(iOS 无对应能力)。`project.yml` 里 target 级 `info.properties` 按
`#if`-等价的 XcodeGen 平台分支(或拆分 macOS/iOS 各自的 plist 覆盖)处理。

## 已知取舍

- iOS 版无法录制 Zoom/Teams 等会议系统音频,只支持现场麦克风录课堂。
- iOS 悬浮字幕是应用内浮层,不是独立跨 App 悬浮窗口。
- iOS 无全局快捷键,所有操作需在主界面内触发。
- XcodeGen 生成 iOS/macOS 两个独立 target 的具体 `project.yml` 写法(平台级
  `sources`/`dependencies`/`info`/`entitlements` 覆盖语法),需要在实现阶段
  用最小示例跑 `xcodegen generate` 验证后确定,本设计只定方向。
- `@available` 标注的 iOS 版本号需要逐个核对 API 文档后再定,不能照抄
  macOS 版本号。
- iOS 沙盒下的数据存储路径行为(iCloud 备份排除、后台录音写入限制)是待验证
  风险点,本设计未给出解决方案。
- 本设计不包含 iOS 版的视觉/交互细节打磨(如 iPad 分栏比例、iPhone 单列下的
  工具条布局),后续实现阶段按 SwiftUI 实际运行表现验证后再迭代。
