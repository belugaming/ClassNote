# macOS UI 视觉与交互重做

## 背景

现有 UI 用学术蓝 + 卡片阴影的风格,信息密度低、导航层级偏深。目标是换成极简
编辑风(黑白高对比、分割线代替卡片阴影),并简化主界面导航层级和详情页 tab
数量。完成后同步产出 iOS/iPad 适配(基于新布局,不再基于旧的三栏结构)。

## 1. 视觉基础(`Core/Utils/Theme.swift`)

- `Theme.accent` 从学术蓝改为 `Color.primary`(浅色模式黑、深色模式白),
  `accentSoft`/`accentMuted` 相应改为 `Color.primary` 的不同透明度。
- `CardBackground` modifier 去掉填充背景色块,改为内容 + 底部 1px
  `Theme.hairline` 分割线,不再用 `RoundedRectangle.fill`。
- `PillStyle` 从彩色填充胶囊改为描边胶囊(`stroke` 代替 `fill`),只有
  `recording`(录制中)保留红色强调,其余状态(已转写/处理中等)用
  `Color.secondary` 描边,降低视觉噪音。
- 圆角值(`cornerSmall/Medium/Large` = 6/8/10px)保持不变。
- 字体维持系统默认 SF Pro,不引入衬线体。

## 2. 主界面导航(`MainWindowView.swift`):三栏改两栏

`NavigationSplitView` 的 `sidebar` + `content` 两栏合并成一栏:
- 新建 `CourseSessionSidebarView`,替换现有 `CourseListView` +
  `SessionListView` 的并列结构。用可折叠分组的 `List`(`DisclosureGroup`
  或 `Section` + `@State` 展开状态)展示"全部会话"(固定置顶,不可折叠)
  和各课程分组,每个课程分组展开后内嵌该课程下的会话行。
- `detail` 栏不变,占据剩余全部空间,承载 `SessionDetailView`。
- `MainWindowViewModel` 的数据获取逻辑(`courses`/`sessions(for:)`)不变,
  只是消费方从两个视图合并成一个。
- 新建会话 / 导入的入口(现在挂在 `SessionListView` 的 toolbar 上)移到
  新侧栏顶部的工具条。

## 3. 会话卡片精简(`SessionCard`)

由"图标色块 + 3 行文字(标题+时长 / 日期+来源 / 状态+高光数)"改为两行:
- 第一行:标题(左)+ 时长(右,等宽数字)
- 第二行:日期 + 状态 pill
- 去掉左侧图标色块和"来源"标签(mic/system/mixed 这些次要信息不再在列表
  展示,点进详情页仍可见)。

## 4. 详情页 tab 精简(`SessionDetailView.swift`):6 个减到 3 个

`DetailTab` 枚举从 `transcript/notes/tools/qa/flashcards/highlights` 改为
`transcript/notes/study`:
- **transcript**:原转写 tab 内容不变,高光标记内嵌显示——转写文本中被
  标记高光的片段加一个可点击星标图标,不再有独立的 `highlights` tab
  (`HighlightsPane` 的列表形式改造成转写视图内的锚点跳转,不单独渲染
  一个高光列表页)。
- **notes**:原 `NotesPane` 不变。
- **study**:合并原 `StudyToolsPane` + `QAPane` + `FlashcardsPane`。新建
  `StudyPane`,内部用 `Picker(.segmented)` 切换三个子区域(工具/问答/
  卡片),三块原有实现逻辑不变,只是外层包装成一个 tab 下的三个子视图。

Header 区域(标题、生成笔记按钮、播放/重新翻译/导出这些操作)保留现有
功能,导出菜单等次要操作视觉上收进一个更紧凑的分组,不铺满整行宽度。

## 5. 影响范围

改动集中在 `Core/Utils/Theme.swift`、`Features/Main/MainWindowView.swift`、
`Features/Main/CourseListView.swift`(合并进新侧栏视图,原文件可能删除)、
`Features/Main/SessionListView.swift`(同上)、
`Features/Main/SessionDetailView.swift`。不改动数据层、引擎、`AppState`
业务逻辑。

## 6. 与 iOS/iPad 支持的关系

本次重做的两栏导航结构(侧栏 + 详情)比旧的三栏结构更适合直接套用到
iPad(`NavigationSplitView` 两栏在 iPad 上自然工作)和 iPhone(折叠为单列
堆栈)。iOS/iPad 适配基于本设计完成后的新版结构展开,不再基于旧三栏结构
设计(此前 `2026-08-08-ios-ipados-support-design.md` 中涉及
`MainWindowView`/`CourseListView`/`SessionListView` 的部分需要在实现时
对照新结构调整,其余章节——音频捕获、窗口/快捷键裁剪、AppKit 跨平台
封装、权限——不受本次改动影响,继续有效)。

## 已知取舍

- 不引入新的第三方 UI 库,全部用 SwiftUI 原生组件实现。
- 不改动 `AppState`/数据库/引擎相关代码。
- 视觉细节(具体的分割线粗细、间距数值)在实现阶段按 SwiftUI 默认行为
  跑起来看效果微调,本设计不锁定像素级数值。
