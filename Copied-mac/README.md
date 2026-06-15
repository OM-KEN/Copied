# Copied（macOS）

macOS 智能复制反馈工具——按下 ⌘C，屏幕顶部弹出精美的液态玻璃 Toast，清晰展示复制内容。不再猜测「到底复制成功了吗」。

## 特性

- 监听所有复制操作（⌘C、右键复制、菜单复制、截图到剪贴板），无需键盘 Hook
- 支持四种内容类型：文本（含代码语言识别）、图片（含缩略图）、文件、HTML
- macOS 26 原生液态玻璃卡片 UI，SF Symbols 系统图标
- 智能代码语言检测：Swift / Python / JavaScript / CSS / HTML 自动识别
- 来源 App 真实图标 + 名称（Finder 显示文件夹名）
- Q 弹弹簧入场动画（缩放+飞入+模糊+淡入，~550ms）/ 简洁淡出退场（200ms）
- 500ms 去重窗口，避免重复弹窗
- 菜单栏图标常驻，支持暂停/恢复
- 零依赖、零框架、纯 Swift + AppKit + SwiftUI
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
- **退出** — 关闭应用

### 支持的内容类型

| 操作 | 图标 | 详情 |
|------|------|------|
| 复制短文本 | `text.alignleft` | 来源行 |
| 复制长文本 (≥50字) | `text.quote` | "N字符" |
| 截图到剪贴板 (⌘⇧⌃4) | 图片缩略图 | "宽×高" |
| 复制单个图片文件 | 图片缩略图 | "宽×高" |
| 复制单个文件 | `doc.on.doc` | 文件大小（如 "25 KB"） |
| 复制多个文件 | `doc.on.doc` | "N个文件" |
| 复制 Swift 代码 | `{ }` | "Swift · 120字符" |
| 复制 HTML | `</>` | "HTML · 90字符" |
| 复制 CSS | `{ }` | "CSS · 152字符" |

## 架构

```
CopiedApp.swift          — 入口：MenuBarExtra + AppDelegate
ClipboardMonitor.swift      — NSPasteboard 轮询 + 内容解析 + 代码检测
SourceAppDetector.swift     — NSWorkspace 前台 App 检测
ToastWindowController.swift — NSWindow + NSHostingView 管理
ToastView.swift             — SwiftUI 卡片布局
ToastViewModel.swift        — @Observable 数据模型
Info.plist                  — LSUIElement 隐藏 Dock
build.sh                    — swiftc 一键构建
```
