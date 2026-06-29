# Copied（macOS）

macOS 智能复制反馈工具——按下 ⌘C，屏幕顶部弹出精美的液态玻璃 Toast，清晰展示复制内容。不再猜测「到底复制成功了吗」。

## 特性

- 监听所有复制操作（⌘C、右键复制、菜单复制、截图到剪贴板），无需键盘 Hook
- 支持多种内容类型：文本（含代码语言识别）、图片（含缩略图）、文件（含 Quick Look 内容缩略图）、HTML
- **Quick Look 文件预览**：PDF 首页、视频关键帧、Office 文档等，自动显示内容缩略图
- **智能内容检测**：自动识别 URL / 文件路径 / 色值 / 数学表达式 / 单个汉字 / 英文单词（系统词典翻译）
- **快捷操作按钮**：根据内容类型显示对应操作（打开链接、定位文件、计算、显示拼音、搜索）
- **右键菜单**：搜索、另存为…，一站式操作
- **色值色块**：复制 #FF6B6B 或纯 6 位 hex，左侧自动显示颜色预览
- macOS 26 原生液态玻璃卡片 UI，SF Symbols 系统图标
- 智能代码语言检测：Swift / Python / JavaScript / CSS / HTML 自动识别
- 来源 App 真实图标 + 名称（Finder 显示文件夹名）
- 弹簧入场动画（缩放+飞入+模糊+淡入，~550ms）/ 模糊淡出退场（200ms，高斯模糊 0→4px）
- 鼠标悬停保持显示、点击立即关闭，交互自然不打扰
- 500ms 去重窗口，避免重复弹窗
- 菜单栏自定义图标常驻，支持暂停/恢复
- **设置页**：开机自启、搜索引擎选择（Google/Baidu/Bing/DuckDuckGo）
- 纯 Swift + AppKit + SwiftUI，swiftc + actool 编译，零第三方依赖。Xcode 26 用于图标编译和代码签名
- CPU 占用接近 0%

## 系统要求

- macOS 26+

## 安装

### 从源码构建

```bash
cd Copied-mac
./build.sh
open .build/Copied.app
```

`build.sh` 使用 `swiftc` 编译，生成自包含 `.app` bundle。

## 使用

启动后，菜单栏出现剪贴板图标。按下 ⌘C 复制任意内容，Toast 即出现在屏幕顶部。

菜单栏菜单：
- **暂停** — 临时关闭通知
- **设置…** — 开机自启、搜索引擎
- **退出** — 关闭应用

Toast 显示期间，**再次按下 ⌘ 键并松开**可快速触发右侧操作按钮（如计算、打开链接、搜索），无需鼠标点击。

### 支持的内容类型

| 操作 | 图标 | 右侧按钮 | 详情 |
|------|------|:---:|------|
| 复制短文本 | `text.alignleft` | 搜索 | 来源行 |
| 复制长文本 (≥50字) | `text.quote` | 搜索 | "N字符" |
| 复制 URL | `safari` | ⌘ 打开 | "链接 · N字符" |
| 复制文件路径 | `folder` | ⌘ 打开 | "路径 · N字符" |
| 复制公式 | `function` | ⌘ 计算 | 结果弹出，按钮变「复制」 |
| 复制单个汉字 | `waveform` | ⌘ 拼音 | 拼音弹出，按钮变「复制」 |
| 截图到剪贴板 (⌘⇧⌃4) | `photo` | — | "PNG 图片 · W×H" |
| 复制单个图片文件 | 缩略图 | — | "JPG 图片 · W×H" |
| 复制单个 PDF | Quick Look 缩略图 | — | "PDF 文件 · 25 KB" |
| 复制单个普通文件 | `doc.on.doc` | — | "ZIP 文件 · 5 MB" |
| 复制文件夹 | `folder` | — | "文件夹" |
| 复制多个文件 | `doc.on.doc` | — | "N个文件" |
| 复制色值（#RGB / 6位hex）| 色块 32×32 | — | 自动显示颜色 |
| 复制 Swift 代码 | `{ }` | ⌘ 搜索 | "Swift · 120字符" |
| 复制 HTML | `</>` | ⌘ 搜索 | "HTML · 90字符" |
| 复制 CSS | `{ }` | ⌘ 搜索 | "CSS · 152字符" |

## 架构

```
CopiedApp.swift             — 入口：MenuBarExtra + AppDelegate + Settings 场景
ClipboardMonitor.swift      — NSPasteboard 轮询 + 内容解析 + 代码检测
CopyGestureManager.swift    — 全局鼠标手势（CGEventTap）+ ⌘C 模拟
DetectionRegistry.swift     — 全局检测器注册中心 + 优先级管道
ContentKind.swift           — 统一类型标识（16 内置 + 插件动态）
Detectors/                  — 13 个内置检测器（Color/URL/File/DateTime/Math/语言等）
PluginLoader.swift          — .copiedplugin 扩展加载/管理
ClipboardAction.swift       — 操作协议 + 9 个操作 + 优先级解析
FilePreviewGenerator.swift  — QLThumbnailGenerator 异步文件缩略图
SourceAppDetector.swift     — NSWorkspace 前台 App 检测
ToastWindowController.swift — NSWindow + NSHostingView 管理 + 模糊退场
ToastView.swift             — SwiftUI 卡片布局 + 按钮 + 色块 + 右键菜单
ToastViewModel.swift        — @Observable 数据模型 + 异步缩略图 + 操作状态
SettingsView.swift          — 设置页（通用/类型/手势三个 Tab）
Copied.icon                 — Liquid Glass 分层图标（Icon Composer）
Copied.svg                  — 菜单栏 template 图标
Info.plist                  — LSUIElement + CFBundleIconName
build.sh                    — swiftc + actool + codesign 一键构建
```
