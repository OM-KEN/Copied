# CLAUDE.md

此文件为 Claude Code 提供本仓库的编码指引。

## 构建与运行

```bash
./build.sh                     # 编译 → .build/Copied.app
./create-dmg.sh                # 编译 → .build/Copied.dmg（含拖拽安装背景）
open .build/Copied.app      # 启动（菜单栏显示，无 Dock 图标）
```

`build.sh` 使用 `swiftc` + `actool`（Liquid Glass 图标）+ `codesign`（Apple Development）。需 macOS 26+ 及 Xcode 26（供 `actool` 使用）。

DMG 背景图放在 `.build/dmg_background.png`（可选，440×240），有则自动打包进 DMG；无则跳过。

## 架构

```
CopiedApp.swift             MenuBarExtra + AppDelegate + Settings 入口
ClipboardMonitor.swift      Timer 每 0.15s 轮询 NSPasteboard.changeCount
CopyGestureManager.swift    全局左键按住 + 右键 → ⌘C 手势（CGEventTap）
DetectionRegistry.swift        全局注册中心：管理所有检测器 + 限流/优先级
ContentKind.swift              统一类型标识（struct + 静态常量）
ContentDetection.swift         检测结果结构体（kind + value + color + metadata）
Detectors/                     13 个内置检测器（Color, URL, FilePath, DateTime, Math 等）
DictionaryLookupService.swift  系统词典查询（DCSCopyTextDefinition，零配置）
LookupAction.swift             词典查询 Action — 内联展示结果，同拼音模式
PluginManifest.swift           manifest.json / rules.json Codable 模型
PluginActionTemplate.swift     Action 模板类型（openURL, search, transform, none）
PluginAction.swift             执行插件定义的 Action 模板
PluginLoader.swift             扫描、校验、加载、安装 .copiedplugin 文件夹
ClipboardAction.swift          Action 协议 + 8 个内置 Action + ActionResolver（LookupAction.swift、PluginAction.swift 另有 2 个）
FilePreviewGenerator.swift     QLThumbnailGenerator 封装 — 异步内容缩略图
ToastWindowController.swift    管理浮动 NSWindow + NSHostingView + Action
ToastViewModel.swift           @Observable 模型，图标/类型标签/Action/异步缩略图逻辑
ToastView.swift                SwiftUI 卡片布局 + glassEffect + 按钮 + 色块 + 菜单
SourceAppDetector.swift     NSWorkspace.frontmostApplication → 名称 + 图标
SettingsView.swift              设置（开机启动、搜索引擎、类型、手势 Tab）
TypeSettingsView.swift         类型优先级列表 + 插件管理
```

UserDefaults 键：`searchEngine`, `launchAtLogin`, `isPaused`, `copyGestureEnabled`, `contentKindPriorities`, `disabledContentKinds`, `installedPlugins`。

**数据流**：`ClipboardMonitor` → `DetectionRegistry.detectAll()` → `ClipboardContent`（+ `[ContentDetection]`）→ `ToastWindowController.show()` → `ToastViewModel` 解析 Action + 触发异步缩略图 → `NSHostingView` → `ToastView`（`.glassEffect()` + 缩略图 + 按钮 + 色块 + contextMenu）

**内容类型系统**：统一 `ContentKind`（struct + 静态常量）。检测通过 `DetectionRegistry` 优先级管道执行，每个检测器实现 `ContentDetectorProtocol`，返回 `ContentDetection?`（kind + value + 可选 color + 可选 pluginActionTemplate）。

**插件系统**：声明式（JSON + 正则，不执行代码）。`.copiedplugin` 文件夹从 `~/Library/Application Support/Copied/Plugins/` 加载。性能熔断：100KB 文本截断、50ms 单检测器超时、3 次超时自动禁用。详见下方插件系统章节。

## 关键设计决策

### 窗口：SwiftUI `.glassEffect()`（macOS 26+）

`ToastView` 内应用 `.glassEffect(in: .rect(cornerRadius: 32))`。非 key 浮动窗口的边缘高光会被 WindowServer 抑制 → 用 `.stroke(.white.opacity(0.25))` 补偿。

窗口配置：`.borderless`、`.floating` 层级、`ignoresMouseEvents = false`（接收悬停/点击）、`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`。

每次 `show()` 重建窗口（不复用），确保 Space 关联始终正确 — 全屏 Space 长时间使用后复用窗口可能导致 `orderFront` 无效、toast 不出现。

### 入场动画：SwiftUI 弹簧

`ToastView` 内通过 `@State + .onAppear + withAnimation(.interpolatingSpring(mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3))` 触发：

| 属性 | 起始 | 结束 |
|------|------|------|
| `scaleEffect` | 0.2 | 1 |
| `offset(y:)` | -56 | 0 |
| `blur(radius:)` | 12 | 0 |
| `opacity` | 0 | 1 |

非对称 padding（top:20, bottom:12, horizontal:18）吸收弹簧过冲。窗口定位用 `screen.frame.maxY`。

退场：200ms `easeIn` 淡出 + `CIGaussianBlur` 0→4px（`CABasicAnimation`，keyPath `"filters.dismissBlur.inputRadius"`），`DispatchQueue.main.asyncAfter`（+0.25s）清理。Content view 需 `layerUsesCoreImageFilters = true`。`CIFilter.name` 必须匹配动画 keyPath。清理覆盖三条路径：动画回调、`cancelDismiss()`、非动画 dismiss。

### 鼠标交互：悬停暂停 + 点击关闭

SwiftUI `.onHover` + AppKit `NSEvent.addLocalMonitorForEvents(.leftMouseDown)`（borderless 浮动 `NSHostingView` 内 `.onTapGesture` 不可靠）。悬停 → 暂停 dismiss 计时器；窗口内点击 → 关闭。`isDismissing` 标志在退场动画期间阻止交互。`dismissGeneration` 防止过期的动画清理隐藏新弹出的 toast。`onHoverChanged` + `onTap` 闭包由 controller 注入；交互状态在 controller 而非 ViewModel。

### 剪贴板检测：pasteboard types，不用 readObjects

`readClipboardContent` 直接用 `pasteboard.types` 判断内容类别。优先级：

1. `.fileURL` → 文件（存储 `fileURLs: [URL]`，SourceAppDetector 用于文件夹名）
2. `.tiff` / `.png` → 图片（生成 64×64 方形缩略图）
3. `.string` → 文本（含语言检测）

- **单图片文件**：同步 `NSImage(contentsOf:)` → 方形裁剪缩略图。
- **单非图片文件**：异步 `QLThumbnailGenerator`（`FilePreviewGenerator`），PDF 首页、视频关键帧等；失败降级为 SF Symbol。缩略图到达后窗口自动 resize。

### 内容类型检测（DetectionRegistry）

文本解析后，`DetectionRegistry.shared.detectAll(in:)` 按优先级运行所有已注册检测器。Registry 管理：

- **13 个内置检测器**（`Detectors/`）：`ColorDetector`, `URLDetector`, `FilePathDetector`, `DateTimeDetector`, `MathExpressionDetector`, `ChineseCharDetector`, `EnglishPhraseDetector`, `HTMLDetector`, `SwiftDetector`, `PythonDetector`, `JavaScriptDetector`, `CSSDetector`, `CodeDetector`
- **插件检测器**从 `~/Library/Application Support/Copied/Plugins/*.copiedplugin/` 加载（每个插件 = 一个 `PluginDetector`）

| 优先级 | 检测器 | 类型 | 方法 |
|--------|--------|------|------|
| 300 | `ColorDetector` | `.colorHex/.colorRGB/.colorHSL` | 正则 + 手动 NSColor 解析（hex, rgb, hsl）|
| 250 | `URLDetector` | `.url` | `NSDataDetector(.link)` |
| 200 | `FilePathDetector` | `.filePath` | `^(~\|/).+` → `expandingTildeInPath` → `FileManager.fileExists` |
| 190 | `DateTimeDetector` | `.dateTime` | 预处理（M.D→M月D日, H点→H:00）+ `NSDataDetector(.date)` 全文匹配；`RelativeDateTimeFormatter` 详情 |
| 180 | `MathExpressionDetector` | `.mathExpr` | 数字+运算符、括号平衡、结构验证 |
| 100 | `ChineseCharDetector` | `.chineseChar` | 恰好 1 字符，U+4E00–U+9FFF |
| 80 | `EnglishPhraseDetector` | `.englishPhrase` | 单个 ASCII 单词，无代码分隔符 |
| 70 | `HTMLDetector` | `.html` | `</?[a-zA-Z]+\b` 标签 |
| 60 | `SwiftDetector` | `.swift` | `func\|var\|let\|struct\|class\|import SwiftUI…` |
| 50 | `PythonDetector` | `.python` | `def\|import\|elif\|yield…` |
| 40 | `JavaScriptDetector` | `.javascript` | `function\|const \|=>\|export \|console.…` |
| 30 | `CSSDetector` | `.css` | 大括号+冒号+分号+CSS 单位/属性 |
| 20 | `CodeDetector` | `.code` | 泛用大括号/分号/关键字 |
| — | (无) | `.plain` | 无匹配时的默认值 |

**性能熔断**：
- **100KB 文本截断**：>100KB → 仅运行内置 `.language` 检测器（跳过所有 `.entity` 和插件）
- **50ms 单检测器超时**：每个检测器运行后，若累计耗时 >50ms → 限流 30s
- **3 次限流自动禁用**：连续限流 ≥3 → 检测器永久禁用并弹出系统通知

检测结果存储在 `ClipboardContent.detections: [ContentDetection]`。每条含 `kind`、`value`、可选 `color`、可选 `pluginActionTemplate`。

### 图标映射（ToastViewModel.iconSymbolName）

图标选择优先级：**色块 → 检测图标 → 内容类型回退**。

`detectedColor != nil` 时返回 `""`，色块完全替代图标。

| 条件 | 图标 |
|------|------|
| 颜色检测到 | （色块，无 SF Symbol）|
| 检测结果含非空 `.icon` | 使用 `ContentKind.icon`（如 `link`, `folder`, `function`, `character`）|
| `.image`（截图、剪贴板图片）| `photo` |
| `.file` 单文件（无预览）| `document` |
| `.file` 多文件 | `doc.on.doc` |
| 短文本 | `text.bubble` |
| 长文本 | `text.page` |

`.chineseChar`→`character`，`.englishPhrase`→`textformat`。优先级由检测顺序决定（最先匹配 = 最高优先级）。

### 详情行格式

由 `ToastViewModel.typeLabel` 驱动（优先级：图片格式 → 文件类型/文件夹 → 检测标签 → 空）。

| 内容 | 详情行 |
|------|--------|
| 剪贴板图片（PNG 截图）| `PNG 图片 · 1920×1080` |
| 单图片文件（JPG）| `JPG 图片 · 800×600` |
| 单文件夹（访达复制）| `文件夹 · 128.5 MB` |
| 单非图片文件（PDF）| `PDF 文件 · 2.5 MB` |
| URL 检测文本 | `链接 · 120字符` |
| 文件路径检测文本 | `路径 · 80字符` |
| 日期时间检测文本 | `日期 · 3天后` / `日期 · 2小时前` |
| 数学表达式文本 | `公式 · 45字符` |
| 单个汉字文本 | `汉字` |
| 英文单词文本 | `英文` / `英文 · N字符` |
| 代码文本（Swift 等）| `Swift · 120字符` |
| 插件检测到（JSON）| `JSON · 120字符` |
| 短文本（<50 字）| （空，不显示）|
| 长文本 | `N字符` |
| 多个文件 | `N个文件` |

### Action 系统（`ClipboardAction` 协议）

```swift
protocol ClipboardAction: Identifiable {
    var id: String { get }
    var title: String { get }            // 按钮文案，≤3 个汉字
    var systemImage: String { get }      // SF Symbol
    var menuTitle: String { get }        // 右键菜单标签
    var performsInlineUpdate: Bool { get } // true → 执行后保持弹窗
    func perform(content:, controller:)
}
// 默认：performsInlineUpdate = false
```

**9 个内置 Action + PluginAction**（由 `ActionResolver.resolve(for:)` 解析）：

| Action | 触发条件（ContentKind）| 按钮 | 行为 |
|--------|-----------------------|:----:|------|
| `OpenURLAction` | `.url` | 打开 | `NSWorkspace.shared.open` |
| `RevealFileAction` | `.filePath` | 打开 | `NSWorkspace.shared.activateFileViewerSelecting` |
| `OpenCalendarAction` | `.dateTime` | 日历 | `Process`/osascript → Calendar `view calendar at` |
| `CalculateAction` | `.mathExpr` | 计算 | NSExpression 求值 → `showResultOverlay`，行1=表达式，行2==结果 |
| `ShowPinyinAction` | `.chineseChar` | 拼音 | `CFStringTransform` → `showResultOverlay` |
| `LookupAction` | `.englishPhrase` | 翻译 | `DCSCopyTextDefinition` → 系统词典（牛津中英）→ `showInlineResult`，行1=单词+音标，行2=中文释义 |
| `SearchTextAction` | 纯文本（回退）| 搜索 | `NSWorkspace.open` 搜索引擎 URL |
| `SaveFileAction` | 右键菜单 | — | `NSSavePanel` → 写入文件 |
| `CopyTextAction` | 结果覆盖层（计算/拼音/翻译后）| 复制 | `NSPasteboard.general.setString` |
| `PluginAction` | 插件定义（任意）| 模板 | openURL / searchWithEngine / transform / none |

**内联更新模式**（`performsInlineUpdate = true`）：执行后弹窗保持显示，展示**结果覆盖层**（`ResultOverlay { displayText, copyText }`）。右侧按钮变为"复制"（`CopyTextAction`）。`CalculateAction`、`ShowPinyinAction` 调用 `showResultOverlay`，`LookupAction` 调用 `prepareForAsyncInlineAction()` + `showInlineResult`，插件 `.transform` Action 类似。

**结果覆盖层布局**：`displayText` 按 `\n` 拆分为 `VStack`，每个 `Text` 设 `.lineLimit(1)`，防止首行溢出挤占次行。支持两行格式（单词+音标 / 释义，表达式 / =结果，汉字 / 拼音）。

**词典查询**（`LookupAction`）：`DCSCopyTextDefinition`（CoreServices/DictionaryServices）查询 macOS 内置牛津中英词典。无下载、无网络、零配置。返回：行1 = "`{word} 英 {pron}`"，行2 = 中文释义（≤5 字 CJK 片段，过滤核心释义，最多 8 条，逗号分隔）。检测器（`EnglishPhraseDetector`）仅匹配单个 ASCII 单词 — 短语级查询不被词典 API 支持。

**优先级**：首个非颜色检测 → 右侧按钮（最多 1 个）。其余 → 右键菜单。无检测但有文本 → 默认 搜索。`ContentKind.source == .plugin(...)` 时从 `ContentDetection.pluginActionTemplate` 创建 PluginAction。纯语言类型（swift, python 等）不产生按钮 — 仅添加标签/图标。

### 插件系统

声明式（JSON + 正则，不执行代码）。`.copiedplugin` 文件夹格式：
- `manifest.json` — name, identifier, version, category（`"language"`|`"entity"`）, icon, label, priority
- `rules.json` — `{id, pattern, extractValue?, action?}` 数组

Action 类型：`openURL`（含 `{value}` 模板）、`searchWithEngine`、`transform`（正则替换 + 内联结果）、`none`。

安装：通过设置页打开 `.copiedplugin` 文件夹 → 复制到 `~/Library/Application Support/Copied/Plugins/`。应用启动时由 `PluginLoader.loadAllPlugins()` 加载。

### 点击处理（NSEvent 监听器 + SwiftUI Button 共存）

两层协作：

1. **NSEvent 本地监听器**（`leftMouseDown`）：先触发。窗口内点击 → `handleTap()` 设置 `isDismissing=true`，通过 `DispatchQueue.main.async` 延迟关闭。
2. **SwiftUI Button**：同步收到同一点击。内联更新 Action（`performsInlineUpdate = true`）→ 调用 `cancelDismiss()` 设置 `isDismissing=false`（异步关闭 block 自行跳过）。其他 Action → 执行后关闭继续。

后台点击：仅第 1 层触发 → 异步关闭执行 → toast 消失。内联 Action 按钮点击：第 1 层设脏标志 → 按钮 handler 清除 → 异步 block 发现标志干净，跳过。

异步延迟防止监听器的即时 `dismissToast(animated:true)` 与 `cancelDismiss()` 的 `alphaValue=1.0` 恢复发生竞争。`cancelDismiss()` 重置 `isDismissing=false`、递增 `dismissGeneration`（作废旧动画）、恢复 `alphaValue=1.0`。

### ⌘ 键快速触发

Toast 有主操作按钮（或结果覆盖层）时，按下并松开 ⌘ 触发。**三层防御**，无需 Accessibility 权限：

1. **`NSEvent.addLocalMonitorForEvents(.keyDown + 鼠标事件)`** — `localOtherEventMonitor`。捕获 ⌘+key 组合键（全局监听器会过滤这些事件）。⌘ 按住期间任何按键/鼠标事件 → `cmdCancelledByOtherEvent = true`。

2. **`CGEventSource.counterForEventType(.hidSystemState, .keyDown)`** — HID 级 keyDown 计数器。⌘ 按下时快照、延迟到 `DispatchQueue.main.async` 对比（一个 runloop 延迟给 HID 计数器时间反映组合键事件）。未变 → 触发；变化 → 中止。

3. **`dismissGeneration` 守卫** — ⌘ 释放时捕获，async block 中校验。防止过期 ⌘ 释放触发新 toast 的 Action。

**转换检测**：`cmdCancelledByOtherEvent` 仅在 ⌘ 从未按下→按下转换时重置（`wasCmdPressed` 守卫），不在 ⌘ 按住期间的每次 `flagsChanged` 重置。防止其他修饰键变化（Shift 等）误清取消标志。

预存 ⌘（⌘C 复制后）通过 `show()` 中 `NSEvent.modifierFlags` 检测 → `cmdIsPreExisting = true` → 按钮不高亮、释放不触发。

**结果态**：`viewModel.resultOverlay != nil`（计算/拼音后）时，⌘ 释放触发 `CopyTextAction(text: overlay.copyText)` 而非 `primaryAction`。监听器守卫条件为 `primaryAction != nil || resultOverlay != nil`。

按钮视觉反馈：`ToastViewModel.isCommandPressed` 驱动条件 SF Symbol（`"command"`）、文案（`"松开"`）、背景透明度（0.12→0.2）、缩放（1.0→0.92），`.spring(response:0.2, dampingFraction:0.6)` 动画。结果态图标为 `"doc.on.doc"`、文案为 `"复制"`。

**死路（勿重试）**：
- `addGlobalMonitorForEvents(.keyDown/.keyUp)` — macOS 在全局监听器中过滤 ⌘+key 快捷键。本地监听器（`addLocalMonitorForEvents`）能收到。
- `CGEvent.tapCreate` 用于 ⌘ 检测 — 仅 CopyGestureManager 使用，对 ⌘ quick-action 过度复杂
- 时序推断 — 快速 ⌘+A 与慢速 ⌘ 点击时间重叠

### Toast 布局

```
[色块/图标/缩略图 32/64] [12] [VStack: 预览(或结果覆盖) + 来源] [Spacer] [按钮: 图标+≤3字文案]
```

- **色块**：32×32 圆角矩形（corner 8），`detectedColor != nil` 时替代 SF Symbol。
- **缩略图**：图片 64×64。
- **文字区**：ZStack 交叉淡入淡出。预览：`.lineLimit(2)`。结果覆盖层：`\n` 拆分 `VStack`，每个 `.lineLimit(1)`。
- **操作按钮**：`HStack(spacing:4)` SF Symbol 12pt + 文字 12pt，`.white.opacity(0.12)` 背景，corner 8。悬停/⌘ 按下 → 图标 `"command"`、文案 `"松开"`（悬停退出 100ms 防抖，`Task.sleep` 实现）。结果态 → 图标 `"doc.on.doc"`、文案 `"复制"`。
- **右键菜单**：搜索 / 另存为… + 分隔线后内容专属项。

### 菜单栏

`MenuBarExtra(content:label:)` + 自定义 `Copied.svg` 模板图像（`NSImage` 加载，`isTemplate = true`，18×18pt）。`build.sh` 将 `fill="white"` 替换为 `fill="black"` 用作模板遮罩。暂停/恢复通过 `@AppStorage("isPaused")` → `ClipboardMonitor` 直接读 `UserDefaults`（避免绑定传播复杂度）。`Info.plist` 中 `LSUIElement = YES` 隐藏 Dock 图标。

### App 图标

Liquid Glass `.icon` 格式（Icon Composer）— 2 层：背景形状 + 前景剪贴板符号，半透明 + 中性阴影。`actool` 编译 → `Assets.car` + `Copied.icns`。`Info.plist` 中 `CFBundleIconName = Copied`。图标变更纳入构建指纹。

### 左右键快捷复制（CopyGestureManager）

设置 → 手势中开启，**默认关闭**。`CGEventTap` 拦截鼠标事件。

- `.leftMouseDown` → `isLeftPressed = true`（透传）
- `.leftMouseUp` → `isLeftPressed = false`（透传）
- `.rightMouseDown` → 若 `isLeftPressed`：吞掉事件（return nil）+ 15ms 后发送 ⌘C

**权限 UX（三重保障）**：
1. **无权限时 Toggle 强制 OFF**：getter = `copyGestureEnabled && isGestureTrusted`，`AXIsProcessTrusted() == false` 时显示 OFF
2. **重启引导 Alert**：尝试无权限开启 → 弹窗"授权后请重启 Copied 使权限生效" → [请求权限] 调用 `AXIsProcessTrustedWithOptions`
3. **权限丢失自动回正**：`CopiedApp.applicationDidFinishLaunching` — 若 `copyGestureEnabled && !AXIsProcessTrusted()` → 设为 `false`

**签名**：Apple Development 证书（`TeamIdentifier = 683MU5Q6FB`）。TCC 使用 Team ID（稳定）而非 CDHash（每次构建变化）。需钥匙串中有 WWDR G3 中间证书。无正确签名时 ad-hoc CDHash 每次重建变化 → 权限丢失。

**关键文件**：`CopyGestureManager.swift`（CGEventTap + ⌘C）、`CopiedApp.swift`（生命周期 + 自动回正）、`SettingsView.swift`（手势 Tab + 守卫 + Alert）、`build.sh`（codesign + actool）。

### 文件/文件夹大小计算

`ClipboardMonitor.swift` 中 `formatFileSize` 使用三层次策略：
1. `totalFileSizeKey` — 快速递归大小（适用于多数包/目录）
2. `fileSizeKey` — 普通文件
3. `calculateRecursiveSize()` — `FileManager.enumerator` 回退（totalFileSize 返回 0 时用于目录/包）

## GitHub 推送规则（硬性）

**任何 git 操作前必须先调用 `git-push` skill。** 只改/只传 `Copied-mac/`，根 `README.md` 不可修改。

## 已知限制

- **边缘高光**：非 key 浮动窗口上被 WindowServer 抑制 → `.stroke(.white.opacity(0.25))` 补偿。
- **窗口位置**：WindowServer 将窗口限制在屏幕边界内；无法超出 `screen.frame.maxY`。
- **窗口动画裁切**：`showResultOverlay` 展开时有短暂右边缘裁切（AppKit ↔ SwiftUI 时序错配）。缓解：0.25s 动画 + 2 行结果格式 + ZStack 交叉淡入淡出。
- **仅限 macOS 26+**：`.glassEffect()` 需 macOS 26。
- **无 Xcode 工程**：`swiftc` + `actool` + `codesign` 通过 `build.sh`。Xcode 26 供 `actool` 使用。
- **词典查询**：仅支持单个单词（DCSCopyTextDefinition API 限制）。
- **指纹**：覆盖 `SOURCES` + `RESOURCES` + `BUILD_FILES`（`build.sh`、`Copied.svg`）。这些数组之外的变化（如新增资源文件）需手动 `rm .build/.source_fingerprint`。
