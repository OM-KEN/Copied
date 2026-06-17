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

| 内容类型 | SF Symbol / 视觉 | 说明 |
|----------|-----------|------|
| 短文本 (<50字) | `text.alignleft` | 左对齐文字 |
| 长文本 (≥50字) | `text.quote` | 引用段落 |
| 图片 | 缩略图 64×64pt | 中央裁剪正方形，圆角 16 |
| 文件 | `doc.on.doc` | 多文档 |
| HTML | `chevron.left.forwardslash.chevron.right` | `</>` 标签 |
| 代码 (Swift/CSS/JS等) | `curlybraces` | `{ }` 花括号 |
| **色值 (#RGB/6位hex)** | **色块 32×32pt** | **圆角 8，同色调阴影，替代 SF Symbol** |

## 操作按钮

Toast 右侧最多 1 个按钮，样式：`[SF Symbol 12pt] 文案(≤3字) 12pt Medium`，水平内边距 10，垂直 6，圆角 8，`.white.opacity(0.12)` 背景，`.buttonStyle(.plain)`。

按钮优先级（取最高匹配）：
1. 打开（URL / 文件路径）→ `safari` / `folder`
2. 计算（数学表达式）→ `function`
3. 拼音（单个汉字）→ `waveform`
4. 搜索（英文短语 / 普通文本）→ `magnifyingglass`

## 右键菜单

始终显示：**搜索** | **翻译**（灰色占位）| **另存为…**，分隔线后追加内容专属操作。使用 SwiftUI `.contextMenu` modifier。

## 内容检测类型

在编程语言检测之外，新增 7 种内容识别：

| 类型 | 检测方式 | API |
|------|---------|-----|
| 色值 Hex | `#RGB` / `#RRGGBB` / 纯6位hex → NSColor | 正则 + 手动解析 |
| 色值 RGB/HSL | `rgb()` / `hsl()` → NSColor | 正则 + HSL→RGB 转换 |
| URL | 整段文本为链接 | `NSDataDetector` |
| 文件路径 | `~` 或 `/` 开头 + 文件存在 | `expandingTildeInPath` + `FileManager` |
| 数学表达式 | 数字+运算符，无字母，括号平衡 | 清洗后 `NSExpression` |
| 单个汉字 | 1 个 Unicode U+4E00–U+9FFF 字符 | Swift stdlib |
| 英文短语 | 2-10 个纯 ASCII 单词 | 正则 |

检测结果存储在 `ClipboardContent.detections`，由 `ActionResolver` 分配操作。

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

## 内容展示规则

- **短文本**（< 50 字符）：`text.alignleft` 图标，无字符数，仅来源行
- **长文本**（≥ 50 字符）：`text.quote` 图标，来源行 + "N字符"
- **代码**：`curlybraces` 图标，来源行 + "Swift · 120字符"（语言标签 + 字符数）；HTML 用 `</>` 图标
- **图片**：64×64 圆角缩略图 + 尺寸信息。截图（⌘⇧⌃4）和 app 内复制图片均可识别
- **单图片文件**（Finder 复制图片文件）：读取文件内容生成缩略图，显示图片尺寸（W×H）
- **单文件**（非图片）：显示文件大小（ByteCountFormatter，如 "25 KB"）
- **多文件**：文件名逗号分隔（最多 3 个），详情显示"N个文件"，来源显示**文件夹名**而非"访达"
- **来源行**："复制自" + App 图标 16pt + App 名称，Finder→文件夹名、Safari→Safari、VS Code→Code 等

## 设计决策

1. **SwiftUI `.glassEffect()` 而非 NSGlassEffectView**：macOS 26 原生 SwiftUI API，与 SwiftUI 动画系统无缝协作（`NSGlassEffectView` 是 AppKit view，无法被 SwiftUI `scaleEffect` 缩放）。唯一的局限是非 key 窗口边缘高光被 compositor 抑制，用 SwiftUI 描边补偿。

2. **SF Symbols 而非自绘矢量**：系统内置数千图标，任意 DPI 清晰，自动跟随亮/暗模式。零维护成本。

3. **pasteboard types 判类型，不用 readObjects 猜测**：`readObjects(forClasses:)` 会误判（RichText 有 NSImage 表示 → 误识别为图片）。用 `pasteboard.types` 直接读取类型列表精确判断。

4. **代码语言检测**：基于正则启发式（无 ML），按优先级：HTML 标签 → Swift 关键字 → Python 关键字 → JS/TS 关键字 → CSS 属性/单位 → 通用代码特征。不依赖文件扩展名——用户可能在编辑器里复制代码片段。

5. **固定位置 + 响应悬停点击**：Toast 固定屏幕顶部居中（不跟随鼠标移动——macOS 无官方 API 获取全局鼠标位置，且对通知而言固定位置更可预测）。但窗口响应鼠标悬停（暂停自动消失）和点击（立即退场），在保持通知式克制的同时提供交互便利。

6. **不用键盘 Hook**：`NSPasteboard.changeCount` 轮询 0.15s，覆盖所有复制路径（⌘C、菜单、右键、Screenshot.app），无需 Accessibility 权限。

7. **MenuBarExtra 菜单栏常驻**：SwiftUI 原生 API，`LSUIElement` 隐藏 Dock 图标，纯菜单栏应用。

8. **swiftc 直接编译**：无 Xcode 工程、无 SPM、零第三方依赖。8 个 Swift 文件，build.sh 一键构建。

9. **操作协议可扩展**：`ClipboardAction` 协议定义 `id/title/systemImage/menuTitle/perform`，新增操作类型只需实现协议 + 在 `ActionResolver` 注册优先级。为未来插件体系预留接口。

10. **计算不写剪贴板**：`CalculateAction` 仅在 toast 内联显示结果（`showResultOverlay`），不触碰 `NSPasteboard`，避免触发新一轮复制检测导致双弹窗。

11. **拼音保留音调**：`CFStringTransform` 仅做 `kCFStringTransformToLatin`，不调 `StripDiacritics`，保留 ā/á/ǎ/à。
