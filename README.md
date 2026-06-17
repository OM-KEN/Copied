# Copied（macOS）

macOS 智能复制反馈工具——按下 ⌘C，屏幕顶部弹出精美的液态玻璃 Toast，清晰展示复制内容。不再猜测「到底复制成功了吗」。

## 特性

- 监听所有复制操作（⌘C、右键复制、菜单复制、截图到剪贴板），无需键盘 Hook
- 支持多种内容类型：文本（含代码语言识别）、图片（含缩略图）、文件、HTML
- **智能内容检测**：自动识别 URL / 文件路径 / 色值 / 数学表达式 / 单个汉字 / 英文短语
- **快捷操作按钮**：根据内容类型显示对应操作（打开链接、定位文件、计算、显示拼音、搜索）
- **右键菜单**：搜索、翻译、另存为…，一站式操作
- **色值色块**：复制 #FF6B6B 或纯 6 位 hex，左侧自动显示颜色预览
- macOS 26 原生液态玻璃卡片 UI，SF Symbols 系统图标
- 智能代码语言检测：Swift / Python / JavaScript / CSS / HTML 自动识别
- 来源 App 真实图标 + 名称（Finder 显示文件夹名）
- Q 弹弹簧入场动画（缩放+飞入+模糊+淡入，~550ms）/ 简洁淡出退场（200ms）
- 鼠标悬停保持显示、点击立即关闭，交互自然不打扰
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

| 操作 | 图标 | 右侧按钮 | 详情 |
|------|------|:---:|------|
| 复制短文本 | `text.alignleft` | 搜索 | 来源行 |
| 复制长文本 (≥50字) | `text.quote` | 搜索 | "N字符" |
| 截图到剪贴板 (⌘⇧⌃4) | 图片缩略图 | — | "宽×高" |
| 复制单个图片文件 | 图片缩略图 | — | "宽×高" |
| 复制单个文件 | `doc.on.doc` | — | 文件大小（如 "25 KB"） |
| 复制多个文件 | `doc.on.doc` | — | "N个文件" |
| 复制 URL | SF Symbol | 打开 | NSWorkspace 打开浏览器 |
| 复制文件路径 | SF Symbol | 打开 | 在 Finder 中定位 |
| 复制色值（#RGB / 6位hex）| 色块 32×32 | — | 自动显示颜色 |
| 复制数学表达式（1+1）| SF Symbol | 计算 | 点击显示 =2（不写剪贴板）|
| 复制单个汉字 | SF Symbol | 拼音 | 点击显示拼音（带音调）|
| 复制英文短语 | SF Symbol | 搜索 | 可配置搜索引擎 |
| 复制 Swift 代码 | `{ }` | — | "Swift · 120字符" |
| 复制 HTML | `</>` | — | "HTML · 90字符" |
| 复制 CSS | `{ }` | — | "CSS · 152字符" |

## 架构

```
CopiedApp.swift             — 入口：MenuBarExtra + AppDelegate
ClipboardMonitor.swift      — NSPasteboard 轮询 + 内容解析 + 代码检测
ContentDetector.swift       — 智能内容检测（URL/路径/色值/数学/汉字/英文）
ClipboardAction.swift       — 操作协议 + 6 个操作 + 优先级解析
SourceAppDetector.swift     — NSWorkspace 前台 App 检测
ToastWindowController.swift — NSWindow + NSHostingView 管理 + 操作执行
ToastView.swift             — SwiftUI 卡片布局 + 按钮 + 色块 + 右键菜单
ToastViewModel.swift        — @Observable 数据模型 + 操作状态
Info.plist                  — LSUIElement 隐藏 Dock
build.sh                    — swiftc 一键构建
```
