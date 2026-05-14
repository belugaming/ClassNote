import Foundation
import SwiftUI

/// Lightweight i18n. Detects the user's preferred system language at app start
/// and exposes a single `t()` lookup. We support zh-Hans and en — when locale is
/// Chinese-anything, we use zh; otherwise English.
///
/// For something this personal, hand-rolled beats Localizable.strings: zero
/// build-system friction, key+value live next to each other, easy to grep.
enum L10n {
    /// User-overridable language preference. nil = follow system.
    private static let userOverrideKey = "uiLanguageOverride"

    static var override: LanguageOverride {
        get {
            let raw = UserDefaults.standard.string(forKey: userOverrideKey) ?? "system"
            return LanguageOverride(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userOverrideKey)
        }
    }

    static var isChinese: Bool {
        switch override {
        case .zh: return true
        case .en: return false
        case .system:
            // `Locale.current` is gated by the app's CFBundleLocalizations and
            // can wrongly fall back to English. `Locale.preferredLanguages`
            // reflects what the user actually picked in System Settings.
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("zh")
        }
    }

    enum LanguageOverride: String, CaseIterable {
        case system, zh, en
        var displayName: String {
            switch self {
            case .system: return L10n.t("settings.appearance.lang.system")
            case .zh: return L10n.t("settings.appearance.lang.zh")
            case .en: return L10n.t("settings.appearance.lang.en")
            }
        }
    }

    /// Look up a key. If we don't have a Chinese translation, fall back to the
    /// English value silently — never show the raw key to the user.
    static func t(_ key: String) -> String {
        guard isChinese else { return en[key] ?? key }
        return zh[key] ?? en[key] ?? key
    }

    private static let en: [String: String] = [
        // Common
        "common.cancel": "Cancel",
        "common.save": "Save",
        "common.delete": "Delete",
        "common.create": "Create",
        "common.close": "Close",
        "common.ok": "OK",
        "common.error": "Error",
        "common.loading": "Loading…",

        // App
        "app.name": "ClassNote",
        "app.tagline": "Record, transcribe, translate, organize your lectures.",

        // Main window
        "main.search.prompt": "Search transcripts…",
        "main.allSessions": "All sessions",
        "main.courses": "Courses",
        "main.newCourse": "New course",
        "main.newCourse.prompt": "Course name (e.g. CS 6.001 SICP)",
        "main.empty.title": "Pick or start a session",
        "main.empty.description": "Use the Record button to begin, or import a video. ⌘N starts a new mic session, ⌘⇧O toggles the floating overlay.",
        "main.deleteCourse": "Delete course",
        "main.deleteSession": "Delete session",
        "main.moveSession": "Move to course",
        "main.unfiled": "No course",
        "recovery.banner.title": "Previous recording was interrupted",
        "recovery.banner.subtitle": "ClassNote found a recording that did not stop cleanly. Recover it to keep the captured audio and transcript.",
        "recovery.action.recover": "Recover",
        "recovery.action.dismiss": "Dismiss",

        // Toolbar
        "toolbar.record": "Record",
        "toolbar.stop": "Stop",
        "toolbar.record.menu.mic": "Microphone only",
        "toolbar.record.menu.system": "System audio (Zoom / YouTube)",
        "toolbar.record.menu.mixed": "Both (mic + system)",
        "toolbar.overlay": "Overlay",
        "toolbar.overlay.help": "Toggle floating translation overlay (⌘⇧O)",
        "toolbar.newSession": "New session",
        "toolbar.import": "Import…",
        "toolbar.translateOnly": "Translate only",
        "toolbar.translateOnly.menu.mic": "Translate mic only",
        "toolbar.translateOnly.menu.system": "Translate system audio",
        "toolbar.translateOnly.menu.mixed": "Translate both",
        "toolbar.translateOnly.help": "Live translation without saving audio or transcript.",
        "toolbar.help.configureKey": "Configure API key in Settings first",
        "toolbar.help.recordHint": "Click to mic-record. ▽ for other sources.",

        // Session
        "session.state.recording": "Recording",
        "session.state.transcribed": "Transcribed",
        "session.state.summarized": "Summarized",
        "session.state.interrupted": "Interrupted",
        "session.state.failed": "Failed",
        "session.state.idle": "Idle",
        "session.source.mic": "Microphone",
        "session.source.system": "System audio",
        "session.source.mixed": "Mic + System",
        "session.source.file": "Imported file",
        "session.tab.transcript": "Bilingual transcript",
        "session.tab.notes": "AI notes",
        "session.tab.highlights": "Highlights",
        "session.action.play": "Play audio",
        "session.action.stop": "Stop",
        "session.action.generateNotes": "Generate AI notes",
        "session.action.generatingNotes": "Generating…",
        "session.action.retranslate": "Retranslate",
        "session.action.retranslating": "Retranslating…",
        "session.action.export": "Export",
        "session.export.transcriptMd": "Transcript (Markdown)",
        "session.export.transcriptTxt": "Transcript (Plain text)",
        "session.export.transcriptSrt": "Transcript (SRT subtitles)",
        "session.export.notes": "AI notes (Markdown)",
        "session.export.audio": "Audio recording",
        "session.export.bundle": "Everything (folder)",
        "session.export.done": "Exported.",
        "session.export.failed": "Export failed",
        "session.export.unavailable.audio": "No audio file for this session.",
        "session.export.unavailable.notes": "Generate AI notes first.",
        "session.export.unavailable.transcript": "Transcript is empty.",
        "session.empty.transcript.title": "No transcript yet",
        "session.empty.transcript.desc": "Start recording or import a video to populate the transcript.",
        "session.empty.notes.title": "No AI notes yet",
        "session.empty.notes.desc": "Generate a structured Markdown summary from the transcript.",
        "session.empty.highlights.title": "No highlights",
        "session.empty.highlights.desc": "Press ⌘⇧M during a live session to bookmark a moment.",

        // Highlight AI explanation
        "highlight.detail.empty": "Select a highlight on the left to see its explanation.",
        "highlight.detail.pickPreset": "Pick a preset below to generate an explanation.",
        "highlight.detail.rangeLabel": "Range",
        "highlight.detail.expandRange": "Expand",
        "highlight.detail.shrinkRange": "Shrink",
        "highlight.detail.rangePreview": "Marked range",
        "highlight.preset.explain": "Explain",
        "highlight.preset.example": "Example",
        "highlight.preset.exam": "Exam focus",
        "highlight.preset.terms": "Key terms",
        "highlight.action.regenerate": "Regenerate",
        "highlight.action.clear": "Clear",
        "highlight.status.streaming": "Generating…",
        "highlight.status.cached": "Cached",
        "highlight.error.noSegments": "No transcript yet — record or import audio first.",
        "highlight.error.generateFailed": "Explanation failed",

        // Live session
        "live.title": "Live session",
        "live.statusLive": "Live · translating",
        "live.statusEphemeral": "Live · not saved",
        "live.statusIdle": "Idle",
        "live.statusImporting": "Importing · transcribing",
        "live.ephemeral.badge": "Not saved",
        "live.ephemeral.title": "Temporary translation",
        "live.ephemeral.description": "Audio and transcript are not saved. Stopping clears this session.",
        "live.translation.toggle": "Translate",
        "live.highlight": "Highlight",
        "live.start": "Start",
        "live.stop": "Stop",
        "live.import.preparing": "Preparing…",
        "live.import.cancel": "Cancel import",
        "live.empty.title": "Waiting for the first sentence…",
        "live.empty.subtitle": "Speak, share a Zoom call, or play a video.",

        // Overlay
        "overlay.empty.title": "Start a session to see live translation.",
        "overlay.empty.tip": "Tip: pick System audio to capture YouTube playing next to it.",
        "overlay.startSystem": "Start system-audio session",
        "overlay.close": "Close overlay (⌘⇧O)",

        // Settings
        "settings.tab.api": "API",
        "settings.tab.engines": "Engines",
        "settings.tab.shortcuts": "Shortcuts",
        "settings.tab.appearance": "Appearance",
        "settings.tab.about": "About",
        "settings.api.presets": "Provider presets",
        "settings.api.endpoint": "Endpoint & key",
        "settings.api.baseUrl": "Base URL",
        "settings.api.key": "API Key",
        "settings.api.privacy": "Stored locally in SQLite. Never transmitted except to the endpoint you specify.",
        "settings.api.models": "Per-capability model IDs",
        "settings.api.stt": "STT model",
        "settings.api.translation": "Translation model",
        "settings.api.llm": "Notes / QA model",
        "settings.api.languages": "Languages",
        "settings.api.source": "Source (lecture)",
        "settings.api.target": "Target (translation)",
        "settings.api.langHelp": "ISO 639-1 codes. Leave source blank for auto-detect.",
        "settings.api.test": "Test connection",
        "settings.api.testing": "Testing…",
        "settings.api.testOk": "OK",
        "settings.api.testFail": "Failed",
        "settings.api.saved": "Saved.",
        "settings.engines.stt": "Speech-to-text backend",
        "settings.engines.sttPicker": "STT engine",
        "settings.engines.whisperKitNote": "Local WhisperKit is planned for v1.1. For now, switch to OpenAI Compatible.",
        "settings.engines.translationSection": "Translation",
        "settings.engines.liveTranslationToggle": "Enable live translation",
        "settings.engines.liveHelp": "When off, only the original transcript is captured. You can retranslate later.",
        "settings.engines.storage": "Storage",
        "settings.engines.appSupport": "Application Support",
        "settings.engines.recordings": "Recordings",
        "settings.engines.reveal": "Reveal in Finder",
        "settings.shortcuts.global": "Global shortcuts",
        "settings.shortcuts.toggleRecording": "Toggle recording",
        "settings.shortcuts.markHighlight": "Mark highlight",
        "settings.shortcuts.toggleTranslation": "Toggle translation",
        "settings.shortcuts.toggleOverlay": "Toggle overlay window",
        "settings.shortcuts.note": "These work anywhere on macOS, even when ClassNote is hidden.",
        "settings.appearance.language": "Language",
        "settings.appearance.languageNote": "Restart the app for language changes to take full effect.",
        "settings.appearance.lang.system": "Follow system",
        "settings.appearance.lang.zh": "中文",
        "settings.appearance.lang.en": "English",
        "settings.about.version": "v0.3.0 — personal build",
        "settings.about.tagline": "Record, transcribe, translate, and organize your US lectures. Your data stays local.",

        // Menubar
        "menubar.idle": "ClassNote",
        "menubar.recording": "Recording",
        "menubar.duration": "Duration",
        "menubar.recordMic": "Record · Microphone",
        "menubar.recordSystem": "Record · System audio",
        "menubar.recordMixed": "Record · Mic + System",
        "menubar.translateOnlyMic": "Translate only · Microphone",
        "menubar.translateOnlySystem": "Translate only · System audio",
        "menubar.translateOnlyMixed": "Translate only · Mic + System",
        "menubar.stopSession": "Stop session",
        "menubar.toggleOverlay": "Toggle overlay window",
        "menubar.markHighlight": "Mark highlight",
        "menubar.liveTranslation": "Live translation",
        "menubar.openMain": "Open main window",
        "menubar.settings": "Settings…",
        "menubar.quit": "Quit ClassNote",
    ]

    private static let zh: [String: String] = [
        // 通用
        "common.cancel": "取消",
        "common.save": "保存",
        "common.delete": "删除",
        "common.create": "新建",
        "common.close": "关闭",
        "common.ok": "好",
        "common.error": "错误",
        "common.loading": "加载中…",

        "app.name": "ClassNote",
        "app.tagline": "录制、转写、翻译、整理你的课堂",

        // 主窗口
        "main.search.prompt": "搜索逐字稿…",
        "main.allSessions": "全部会话",
        "main.courses": "课程",
        "main.newCourse": "新建课程",
        "main.newCourse.prompt": "课程名称(如 CS 6.001 SICP)",
        "main.empty.title": "选择或开启一个会话",
        "main.empty.description": "点右上角 Record 开始录制,或导入一个视频。⌘N 麦克风一键录制,⌘⇧O 切换浮窗。",
        "main.deleteCourse": "删除课程",
        "main.deleteSession": "删除会话",
        "main.moveSession": "移动到课程",
        "main.unfiled": "未归档",
        "recovery.banner.title": "上次录音未正常结束",
        "recovery.banner.subtitle": "ClassNote 发现一条没有正常停止的录音。恢复后会保留已捕获的音频和逐字稿。",
        "recovery.action.recover": "恢复",
        "recovery.action.dismiss": "忽略",

        // 工具栏
        "toolbar.record": "录制",
        "toolbar.stop": "停止",
        "toolbar.record.menu.mic": "仅麦克风",
        "toolbar.record.menu.system": "系统音频(Zoom / YouTube)",
        "toolbar.record.menu.mixed": "麦克风 + 系统音频",
        "toolbar.overlay": "浮窗",
        "toolbar.overlay.help": "切换始终置顶的翻译浮窗(⌘⇧O)",
        "toolbar.newSession": "新建会话",
        "toolbar.import": "导入…",
        "toolbar.translateOnly": "只翻译",
        "toolbar.translateOnly.menu.mic": "只翻译麦克风",
        "toolbar.translateOnly.menu.system": "只翻译系统音频",
        "toolbar.translateOnly.menu.mixed": "只翻译两路音频",
        "toolbar.translateOnly.help": "实时翻译,不保存录音和逐字稿。",
        "toolbar.help.configureKey": "请先在设置中配置 API key",
        "toolbar.help.recordHint": "点击=麦克风,▽=选择音源",

        // 会话
        "session.state.recording": "录制中",
        "session.state.transcribed": "已转写",
        "session.state.summarized": "已整理",
        "session.state.interrupted": "可恢复",
        "session.state.failed": "失败",
        "session.state.idle": "空闲",
        "session.source.mic": "麦克风",
        "session.source.system": "系统音频",
        "session.source.mixed": "麦克风+系统音频",
        "session.source.file": "导入文件",
        "session.tab.transcript": "双语逐字稿",
        "session.tab.notes": "AI 笔记",
        "session.tab.highlights": "重点标记",
        "session.action.play": "播放录音",
        "session.action.stop": "停止",
        "session.action.generateNotes": "生成 AI 笔记",
        "session.action.generatingNotes": "生成中…",
        "session.action.retranslate": "重新翻译",
        "session.action.retranslating": "重译中…",
        "session.action.export": "导出",
        "session.export.transcriptMd": "逐字稿(Markdown)",
        "session.export.transcriptTxt": "逐字稿(纯文本)",
        "session.export.transcriptSrt": "字幕文件(SRT)",
        "session.export.notes": "AI 笔记(Markdown)",
        "session.export.audio": "录音文件",
        "session.export.bundle": "全部导出(文件夹)",
        "session.export.done": "导出成功",
        "session.export.failed": "导出失败",
        "session.export.unavailable.audio": "本次会话没有录音文件。",
        "session.export.unavailable.notes": "请先生成 AI 笔记。",
        "session.export.unavailable.transcript": "逐字稿为空。",
        "session.empty.transcript.title": "还没有逐字稿",
        "session.empty.transcript.desc": "开始录制或导入视频后,这里会出现内容。",
        "session.empty.notes.title": "还没有 AI 笔记",
        "session.empty.notes.desc": "点击上方按钮,从逐字稿生成结构化的 Markdown 总结。",
        "session.empty.highlights.title": "暂无重点标记",
        "session.empty.highlights.desc": "录制中按 ⌘⇧M 标记一个重要瞬间。",

        // 重点标记 AI 讲解
        "highlight.detail.empty": "从左侧选择一个标记,查看 AI 讲解。",
        "highlight.detail.pickPreset": "点击下面任一按钮生成讲解。",
        "highlight.detail.rangeLabel": "范围",
        "highlight.detail.expandRange": "扩大",
        "highlight.detail.shrinkRange": "缩小",
        "highlight.detail.rangePreview": "标记范围原文",
        "highlight.preset.explain": "讲解这段",
        "highlight.preset.example": "举个例子",
        "highlight.preset.exam": "考试重点",
        "highlight.preset.terms": "术语表",
        "highlight.action.regenerate": "重新生成",
        "highlight.action.clear": "清空",
        "highlight.status.streaming": "生成中…",
        "highlight.status.cached": "已缓存",
        "highlight.error.noSegments": "还没有逐字稿 — 请先录制或导入音频。",
        "highlight.error.generateFailed": "讲解失败",

        // 实时会话
        "live.title": "实时会话",
        "live.statusLive": "正在直播 · 翻译中",
        "live.statusEphemeral": "实时 · 不保存",
        "live.statusIdle": "空闲",
        "live.statusImporting": "正在导入 · 转写中",
        "live.ephemeral.badge": "不保存",
        "live.ephemeral.title": "临时翻译",
        "live.ephemeral.description": "录音和逐字稿都不会保存。停止后本次内容会清空。",
        "live.translation.toggle": "翻译",
        "live.highlight": "标记",
        "live.start": "开始",
        "live.stop": "停止",
        "live.import.preparing": "准备中…",
        "live.import.cancel": "取消导入",
        "live.empty.title": "等待第一句话…",
        "live.empty.subtitle": "对着麦克风说话,或共享 Zoom 会议,或播放视频",

        // 浮窗
        "overlay.empty.title": "开始会话即可看到实时翻译",
        "overlay.empty.tip": "提示:选系统音频可以抓旁边的 YouTube 视频",
        "overlay.startSystem": "用系统音频开始录制",
        "overlay.close": "关闭浮窗(⌘⇧O)",

        // 设置
        "settings.tab.api": "API",
        "settings.tab.engines": "引擎",
        "settings.tab.shortcuts": "快捷键",
        "settings.tab.appearance": "外观",
        "settings.tab.about": "关于",
        "settings.api.presets": "供应商预设",
        "settings.api.endpoint": "终端与密钥",
        "settings.api.baseUrl": "Base URL",
        "settings.api.key": "API Key",
        "settings.api.privacy": "仅存储在本地 SQLite 中,只发送到你指定的终端。",
        "settings.api.models": "各能力的模型 ID",
        "settings.api.stt": "转写模型",
        "settings.api.translation": "翻译模型",
        "settings.api.llm": "笔记 / 问答 模型",
        "settings.api.languages": "语言",
        "settings.api.source": "原文(讲课语言)",
        "settings.api.target": "译文",
        "settings.api.langHelp": "ISO 639-1 代码。原文留空表示自动检测。",
        "settings.api.test": "测试连接",
        "settings.api.testing": "测试中…",
        "settings.api.testOk": "正常",
        "settings.api.testFail": "失败",
        "settings.api.saved": "已保存",
        "settings.engines.stt": "语音识别后端",
        "settings.engines.sttPicker": "语音识别引擎",
        "settings.engines.whisperKitNote": "本地 WhisperKit 计划在 v1.1 集成。当前请使用 OpenAI 兼容后端。",
        "settings.engines.translationSection": "翻译",
        "settings.engines.liveTranslationToggle": "启用实时翻译",
        "settings.engines.liveHelp": "关闭后,仅捕获原文,可随时回过头来重译。",
        "settings.engines.storage": "存储",
        "settings.engines.appSupport": "Application Support",
        "settings.engines.recordings": "录音文件",
        "settings.engines.reveal": "在访达中显示",
        "settings.shortcuts.global": "全局快捷键",
        "settings.shortcuts.toggleRecording": "开始/停止录制",
        "settings.shortcuts.markHighlight": "标记重点",
        "settings.shortcuts.toggleTranslation": "切换翻译开关",
        "settings.shortcuts.toggleOverlay": "切换浮窗",
        "settings.shortcuts.note": "全局快捷键在 macOS 任何位置都生效,即便 ClassNote 没在前台。",
        "settings.appearance.language": "语言",
        "settings.appearance.languageNote": "切换语言后请重启 App 完整生效。",
        "settings.appearance.lang.system": "跟随系统",
        "settings.appearance.lang.zh": "中文",
        "settings.appearance.lang.en": "English",
        "settings.about.version": "v0.3.0 · 个人构建",
        "settings.about.tagline": "录课、转写、翻译、整理 — 留学一站式。所有数据留在你电脑上。",

        // 菜单栏
        "menubar.idle": "ClassNote",
        "menubar.recording": "录制中",
        "menubar.duration": "时长",
        "menubar.recordMic": "录制 · 麦克风",
        "menubar.recordSystem": "录制 · 系统音频",
        "menubar.recordMixed": "录制 · 麦克风+系统",
        "menubar.translateOnlyMic": "只翻译 · 麦克风",
        "menubar.translateOnlySystem": "只翻译 · 系统音频",
        "menubar.translateOnlyMixed": "只翻译 · 麦克风+系统",
        "menubar.stopSession": "停止录制",
        "menubar.toggleOverlay": "切换浮窗",
        "menubar.markHighlight": "标记重点",
        "menubar.liveTranslation": "实时翻译",
        "menubar.openMain": "打开主窗口",
        "menubar.settings": "设置…",
        "menubar.quit": "退出 ClassNote",
    ]
}

extension String {
    /// Sugar: `"main.empty.title".t` — but use `L10n.t(...)` directly when key is dynamic.
    var t: String { L10n.t(self) }
}
