# Copied 设计规范（macOS）

## 设计理念

Apple 风格的浮动通知卡片——轻盈、克制、不打扰。macOS 26 原生液态玻璃材质，SF Symbols 系统图标，San Francisco 字体，Spring 弹性动画。不抢焦点，不打断工作流。

## 视觉系统

### 材质

使用 SwiftUI 原生 `.glassEffect(in: .rect(cornerRadius: 32))` modifier（macOS 26 公开 API），提供液态玻璃基底。边缘高光受 WindowServer compositor 限制仅在 key window 上完整渲染——本 Toast 为 floating 非 key 窗口，用 SwiftUI `.stroke(.white.opacity(0.25), lineWidth: 0.8)` 补上伪高光。

### 色彩

| 用途 | 色值 | 说明 |
|------|------|------|
| 玻璃基底 | `.glassEffect()` `.regular` | 系统自适应亮/暗 |
| 边缘描边 | `white.opacity(0.25)` | 伪高光补偿 |
| 预览文字 | `.primary` | 系统自适应 |
| Meta 文字 | `.secondary` | 来源、详情 |
| 图标 | `.secondary` | SF Symbol 统一着色 |

### 字体

| 层级 | 字号 | 字重 | 颜色 |
|------|------|------|------|
| 预览文字 | 14pt | Medium (500) | `.primary` |
| 来源应用 | 12pt | Medium (500) | `.secondary` |
| 详情信息 | 12pt | Medium (500) | `.secondary` |

字体系列：系统 San Francisco（SwiftUI 默认），自动适应简体中文。

### 阴影

由 `.glassEffect()` 原生处理——液态玻璃材质自带环境光遮蔽和深度感，无需额外 SwiftUI shadow。

### 圆角

`.glassEffect(in: .rect(cornerRadius: 32))`，原生平滑圆角（`.continuous` 等效 iOS Squircle）。

### 间距

```
┌── 卡片 32pt 平滑圆角 ────────┐
│ 内边距 16                     │
│                               │
│ [图标 32pt]  12px  文字区     │
│                 ↑ 垂直居中    │
│                               │
│ 预览文字（最多2行）            │
│ ↕ 8px                        │
│ 来源图标 16pt + 来源名        │
│ ↕ 4px                        │
│ 详情（字符数/尺寸/大小）       │
│                               │
│ 内边距 16                     │
└───────────────────────────────┘
```

最大宽度 360pt，自适应内容尺寸。

## 图标系统

使用 Apple SF Symbols（系统内置，零依赖），32pt，`.secondary` 着色。

图标选择优先级：**色块 > detection.kind.icon > content type 回退**。所有类型（语言+实体）统一通过 `ContentKind.icon` 提供图标。

| 内容类型 | SF Symbol / 视觉 | 说明 |
|----------|-----------|------|
| 色值 (#RGB/hex) | **色块 32×32pt** | 圆角 8，同色调阴影，替代 SF Symbol |
| URL 检测 | `safari` | Safari 浏览器 |
| 文件路径检测 | `folder` | 文件夹 |
| 日期时间检测 | `calendar` | 日历 |
| 公式检测 | `function` | 函数符号 |
| 汉字检测 | `waveform` | 音波（拼音） |
| 文件夹（访达复制） | `folder` | 文件夹 |
| 短文本 (<50字) | `text.alignleft` | 左对齐文字 |
| 长文本 (≥50字) | `text.quote` | 引用段落 |
| 图片 | 缩略图 64×64pt / `photo` | 截图或剪贴板图片，缩略图优先 |
| 单文件 | Quick Look 缩略图 64×64pt / `doc.on.doc` | PDF/视频/Office 内容缩略图；加载失败或非预览类型降级为 SF Symbol |
| 多文件 | `doc.on.doc` | 多文档 |
| HTML | `chevron.left.forwardslash.chevron.right` | `</>` 标签 |
| 代码 (Swift/CSS/JS等) | `curlybraces` | `{ }` 花括号 |

## 操作按钮

Toast 右侧最多 1 个按钮，样式：`[SF Symbol 12pt] 文案(≤3字) 12pt Medium`，水平内边距 10，垂直 6，圆角 8，`.white.opacity(0.12)` 背景，`.buttonStyle(.plain)`。

按钮优先级（取最高匹配）：
1. 打开（URL / 文件路径）→ `safari` / `folder`
2. 日历（日期时间）→ `calendar`
3. 计算（数学表达式）→ `function`
4. 拼音（单个汉字）→ `waveform`
5. 搜索（英文短语 / 普通文本）→ `magnifyingglass`

## 右键菜单

始终显示：**搜索** | **翻译** | **另存为…**，分隔线后追加内容专属操作。使用 SwiftUI `.contextMenu` modifier。翻译需先在设置中下载模型（macOS 15 Translation 框架）。

## 内容检测系统（ContentKind + DetectionRegistry）

所有类型（语言 + 内容实体）统一为 `ContentKind` struct，通过 `DetectionRegistry` 优先级管道检测。内置 13 个检测器（`Detectors/` 目录），支持声明式插件扩展。

| 类型 | 检测器 | 优先级 | 检测方式 |
|------|--------|--------|---------|
| 色值 | `ColorDetector` | 300 | 正则 + 手动 NSColor 解析（hex/rgb/hsl）|
| URL | `URLDetector` | 250 | `NSDataDetector(.link)` |
| 文件路径 | `FilePathDetector` | 200 | 前缀 + `FileManager.fileExists` |
| 日期时间 | `DateTimeDetector` | 190 | 预处理（M.D→M月D日 等）+ `NSDataDetector(.date)` |
| 数学表达式 | `MathExpressionDetector` | 180 | 字符白名单 + 括号平衡 + 结构验证 |
| 单个汉字 | `ChineseCharDetector` | 100 | U+4E00–U+9FFF |
| 英文短语 | `EnglishPhraseDetector` | 80 | 2-10 ASCII 单词 |
| HTML | `HTMLDetector` | 70 | `</?[a-zA-Z]+\b` |
| Swift | `SwiftDetector` | 60 | 关键字 + import 模式 |
| Python | `PythonDetector` | 50 | def/import/elif 关键字 |
| JavaScript | `JavaScriptDetector` | 40 | function/=>/export 关键字 |
| CSS | `CSSDetector` | 30 | 大括号 + 冒号 + CSS 单位/属性 |
| 通用代码 | `CodeDetector` | 20 | 代码结构特征回退 |

检测结果存储为 `[ContentDetection]`（kind + value + color + pluginActionTemplate），由 `ActionResolver` 分配操作。

**性能熔断**：100KB 文本门槛（仅内置语言检测器运行）、50ms 单检测器超时、3 次连续超时自动禁用。

**插件扩展**：`.copiedplugin` 文件夹（manifest.json + rules.json），声明式 JSON + 正则，不执行代码。安装到 `~/Library/Application Support/Copied/Plugins/`。

## 动画

### 入场（~550ms，interpolatingSpring）

四个属性同步弹簧动画，全部在 `ToastView` 内由 SwiftUI `.onAppear` 触发：

| 属性 | 起始值 | 结束值 |
|------|--------|--------|
| `scaleEffect` | 0.2 | 1.0 |
| `offset(y:)` | -56 | 0 |
| `blur(radius:)` | 12 | 0 |
| `opacity` | 0 | 1 |

弹簧参数：`mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3`（阻尼比 ~0.58，2-3 次可见弹跳）。

动画外层 `.padding(.top, 20).padding(.bottom, 12).padding(.horizontal, 18)` 吸收弹簧过冲（scale ~1.08、offset 回弹 ~-5pt），防止窗口边缘裁切。

动画开始时卡片 scale 仅 0.2 + blur 12 + opacity 0——肉眼不可见，因此 offset 超出窗口上边界导致的裁切完全无感。卡片可见时已在窗口内。

### 退场（200ms，EaseIn）

| 属性 | 起始值 | 结束值 |
|------|--------|--------|
| Opacity | 1.0 | 0.0 |

`NSAnimationContext` AppKit 原生动画，`CAMediaTimingFunction(name: .easeIn)`。

## 显示模式

固定在主屏幕顶部居中，定位使用 `screen.frame.maxY`（屏幕物理顶部），卡片紧贴菜单栏下方。不实现光标跟随——对 Toast 通知来说，固定位置比跟随鼠标更可预测。

## 鼠标交互

Toast 窗口 `ignoresMouseEvents = false`，支持三层交互：

- **悬停保持**：`.onHover` → 暂停 / 重启 3 秒计时器。
- **点击关闭**：`NSEvent.addLocalMonitorForEvents(.leftMouseDown)` 拦截窗口内点击 → 触发退场。**返回 event（不消费）**，确保 SwiftUI Button 也能收到同一事件。
- **按钮点击**：SwiftUI Button 收到同一事件。结果类操作（计算/拼音）调用 `cancelDismiss()` 撤销关闭动画 → 显示结果 → 重启计时器。其他操作直接执行后关闭。

`cancelDismiss()`：重置 `isDismissing=false`，`dismissGeneration += 1` 作废旧动画回调，恢复 `alphaValue=1.0`。

退场动画期间悬停/点击被 `isDismissing` 守卫忽略。

## 键盘交互

Toast 显示期间，**按下并松开 ⌘ 键**触发右侧操作按钮，无需鼠标。

- **触发机制**：`NSEvent.addGlobalMonitorForEvents(.flagsChanged)` 检测 ⌘ 按下/松开；`CGEventSource.counterForEventType(.hidSystemState, .keyDown)` HID 键盘计数器快照，⌘ 松开时若计数器未变则触发。
- **快捷键保护**：⌘ 按住期间若其他键被按（计数器变了），不触发。⌘+C/⌘+A 等不会误触发。
- **按钮反馈**：⌘ 按下时按钮缩放至 0.92、背景增亮、"松开"文案 + ⌘ SF Symbol；spring 动画 0.2s。
- **预存 ⌘**：⌘C 复制后若 ⌘ 仍未松开，Toast 按钮不高亮、不触发。

## 内容展示规则

详情行由 `ToastViewModel.typeLabel` 统一驱动，优先级：**图片格式 → 文件类型/文件夹 → 检测类型 → 代码语言**。

- **特殊检测文本**：检测类型图标（`safari`/`folder`/`function`/`waveform`）+ 类型标签（"链接"/"路径"/"公式"/"汉字"）+ 字符数。右侧按钮图标改为 ⌘ 避免与左侧重复
- **短文本**（< 50 字符，无检测）：`text.alignleft` 图标，无字符数，仅来源行
- **长文本**（≥ 50 字符，无检测）：`text.quote` 图标，来源行 + "N字符"
- **代码**（无特殊检测）：`curlybraces` 图标，来源行 + "Swift · 120字符"（语言标签 + 字符数）；HTML 用 `</>` 图标
- **剪贴板图片**（截图等）：`photo` 图标 + 缩略图，"PNG 图片 · W×H"（从 pasteboard types 检测格式）
- **单图片文件**（访达复制）：读取文件内容生成缩略图，"JPG 图片 · W×H"（从扩展名检测格式）
- **单文件夹**（访达复制）：`folder` 图标，"文件夹"
- **单文件**（非图片）：异步 Quick Look 缩略图，"PDF 文件 · 2.5 MB"（从扩展名检测类型 + 文件大小）
- **多文件**：文件名逗号分隔（最多 3 个），详情显示"N个文件"，来源显示**文件夹名**而非"访达"
- **来源行**："复制自" + App 图标 16pt + App 名称，Finder→文件夹名、Safari→Safari、VS Code→Code 等

## 设计决策

1. **SwiftUI `.glassEffect()` 而非 NSGlassEffectView**：macOS 26 原生 SwiftUI API，与 SwiftUI 动画系统无缝协作（`NSGlassEffectView` 是 AppKit view，无法被 SwiftUI `scaleEffect` 缩放）。唯一的局限是非 key 窗口边缘高光被 compositor 抑制，用 SwiftUI 描边补偿。

2. **SF Symbols 而非自绘矢量**：系统内置数千图标，任意 DPI 清晰，自动跟随亮/暗模式。零维护成本。

3. **pasteboard types 判类型，不用 readObjects 猜测**：`readObjects(forClasses:)` 会误判（RichText 有 NSImage 表示 → 误识别为图片）。用 `pasteboard.types` 直接读取类型列表精确判断。

4. **代码语言检测**：基于正则启发式（无 ML），通过 DetectionRegistry 优先级管道管理 6 个语言检测器。不依赖文件扩展名——用户可能在编辑器里复制代码片段。用户可在 Settings 中调整优先级和启用/禁用。

5. **固定位置 + 响应悬停点击**：Toast 固定屏幕顶部居中（不跟随鼠标移动——macOS 无官方 API 获取全局鼠标位置，且对通知而言固定位置更可预测）。但窗口响应鼠标悬停（暂停自动消失）和点击（立即退场），在保持通知式克制的同时提供交互便利。

6. **不用键盘 Hook**：`NSPasteboard.changeCount` 轮询 0.15s，覆盖所有复制路径（⌘C、菜单、右键、Screenshot.app），无需 Accessibility 权限。

7. **MenuBarExtra 菜单栏常驻**：SwiftUI 原生 API，`LSUIElement` 隐藏 Dock 图标，纯菜单栏应用。

8. **swiftc 增量编译**：无 Xcode 工程、无 SPM、零第三方依赖。~30 个 Swift 文件，链接 QuickLookThumbnailing + ServiceManagement 系统框架。build.sh 使用 SHA-256 指纹跳过未变编译 + 多线程并行。

9. **操作 + 类型双可扩展**：`ClipboardAction` 协议可新增操作类型，`PluginAction` 执行声明式动作模板（openURL/search/transform）。类型系统通过 `.copiedplugin` 文件夹扩展（JSON + 正则），插件在 Settings 中管理。`showCommandIcon` 在检测类型有 primaryDetection 时按钮图标切为 ⌘。

10. **计算不写剪贴板**：`CalculateAction` 仅在 toast 内联显示结果（`showResultOverlay`），不触碰 `NSPasteboard`，避免触发新一轮复制检测导致双弹窗。

11. **拼音保留音调**：`CFStringTransform` 仅做 `kCFStringTransformToLatin`，不调 `StripDiacritics`，保留 ā/á/ǎ/à。

12. **异步文件缩略图**：`QLThumbnailGenerator`（QuickLookThumbnailing）异步生成任意 macOS 可预览文件的缩略图（PDF 首页、视频关键帧等）。Toast 先显示 SF Symbol，缩略图完成时淡入替换，窗口自动 resize。无 loading 指示器——显示过快会让用户困惑，显示已有的文件图标更自然。加载失败静默降级为 SF Symbol。
