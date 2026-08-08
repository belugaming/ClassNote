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

`project.yml` 里 `ClassNote` target 的 `platform: macOS` 改为多平台:

```yaml
targets:
  ClassNote:
    type: application
    platform: [macOS, iOS]
    deploymentTarget:
      macOS: "14.0"
      iOS: "17.0"
```

单 target 共享 `App/Core/Features` 全部源码,不新建独立 iOS target。新增
`App/ClassNote-iOS.entitlements`(iOS 沙盒 key 与 macOS 不同,不能共用同一份
entitlements 文件),Info.plist 权限描述按平台差异化(iOS 去掉屏幕录制、
AppleEvents 相关 key,保留麦克风/语音识别/本地网络)。

平台专属代码用 `#if os(iOS)` / `#if os(macOS)` 条件编译分叉,不引入额外抽象层
或协议;能直接共享的业务逻辑(`AppState`、引擎、数据库)不做改动。

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
- `MainWindowView` 的 `NavigationSplitView` 保持不变——SwiftUI 在 iPhone 上
  自动折叠为单列堆栈导航,iPad 上保留双栏/三栏,不需要重写。
- Live Session 独立窗口 → 同一个 `LiveSessionView` 通过
  `NavigationStack` push 或 `.fullScreenCover` 呈现。
- `Settings{}` scene → `SettingsView` 通过 `.sheet` 呈现,入口放在主界面
  工具条或列表页的设置按钮里。
- 悬浮字幕 Overlay 独立窗口 → 不做独立窗口,`OverlayView` 的内容作为
  `LiveSessionView` 内部顶部的浮动卡片(同一份视图逻辑换宿主容器,非"真正
  浮在其他 App 上面"的窗口)。
- `MenuBarExtra` 图标 → 无对应物,直接不编译进 iOS 分支。

`GlobalShortcuts.register()` 调用及 `Core/Hotkeys/GlobalShortcuts.swift` 整体
`#if os(macOS)`。iOS 上"开始录音 / 标记高光 / 切换翻译 / 切换字幕"复用
`AppState` 上已有的方法,触发入口换成主界面工具条按钮,不重写业务逻辑。

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

## 5. 权限与 Info.plist

iOS 保留:`NSMicrophoneUsageDescription`、
`NSSpeechRecognitionUsageDescription`、`NSLocalNetworkUsageDescription`。
去掉:`NSScreenCaptureUsageDescription`、`NSAppleEventsUsageDescription`
(iOS 无对应能力)。`project.yml` 里 target 级 `info.properties` 按
`#if`-等价的 XcodeGen 平台分支(或拆分 macOS/iOS 各自的 plist 覆盖)处理。

## 已知取舍

- iOS 版无法录制 Zoom/Teams 等会议系统音频,只支持现场麦克风录课堂。
- iOS 悬浮字幕是应用内浮层,不是独立跨 App 悬浮窗口。
- iOS 无全局快捷键,所有操作需在主界面内触发。
- 本设计不包含 iOS 版的视觉/交互细节打磨(如 iPad 分栏比例、iPhone 单列下的
  工具条布局),后续实现阶段按 SwiftUI 默认行为验证后再迭代。
