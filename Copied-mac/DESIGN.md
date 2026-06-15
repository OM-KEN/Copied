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

| 内容类型 | SF Symbol | 说明 |
|----------|-----------|------|
| 短文本 (<50字) | `text.alignleft` | 左对齐文字 |
| 长文本 (≥50字) | `text.quote` | 引用段落 |
| 图片 | 缩略图 64×64pt | 中央裁剪正方形 |
| 文件 | `doc.on.doc` | 多文档 |
| HTML | `chevron.left.forwardslash.chevron.right` | `</>` 标签 |
| 代码 (Swift/CSS/JS等) | `curlybraces` | `{ }` 花括号 |

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

固定在主屏幕顶部居中，定位使用 `screen.frame.maxY`（屏幕物理顶部），卡片紧贴菜单栏下方。窗口上方伸入菜单栏区域（透明、不响应鼠标事件）。不实现光标跟随——对 Toast 通知来说，固定位置比跟随鼠标更可预测。

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

5. **不跟随鼠标**：macOS 无官方 API 获取全局鼠标位置（需 CGEvent 轮询），对 Toast 而言，固定顶部居中比跟随鼠标更符合 macOS 通知设计惯例。

6. **不用键盘 Hook**：`NSPasteboard.changeCount` 轮询 0.15s，覆盖所有复制路径（⌘C、菜单、右键、Screenshot.app），无需 Accessibility 权限。

7. **MenuBarExtra 菜单栏常驻**：SwiftUI 原生 API，`LSUIElement` 隐藏 Dock 图标，纯菜单栏应用。

8. **swiftc 直接编译**：无 Xcode 工程、无 SPM、零第三方依赖。6 个 Swift 文件，build.sh 一键构建。
