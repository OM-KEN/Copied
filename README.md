# Copied

智能复制反馈工具——复制任意内容，在屏幕顶部弹窗展示复制的内容，并根据所复制的内容，快捷进行下一步操作。

## 功能特征

- **复制弹窗**：监听所有复制操作，弹窗显示已复制的内容
- **快捷操作按钮**：根据内容类型在弹窗右侧显示对应操作（打开链接、定位文件、计算、显示拼音、搜索、翻译）
- **颜色预览**：复制 #FF6B6B 或CSS颜色，左侧预览颜色
- 原生液态玻璃 UI和动效
- 纯 Swift + AppKit + SwiftUI，纯本地，零第三方依赖。
- CPU 占用极低

## 系统要求

- 目前暂只支持macOS 26+

## 使用

下载dmg，拖动app到Applications。复制任意内容，显示弹窗。

弹窗显示期间，**点击右侧按钮或再次按下 ⌘ 键**可触发右侧操作按钮（如计算、打开链接、搜索）。

### 支持的内容类型

| 操作                      | 图标                 | 快捷按钮 | 显示详情           |
| ------------------------- | -------------------- | :------: | ------------------ |
| 复制短文本                | `text.alignleft`     |   搜索   | 来源               |
| 复制长文本 (≥50字)        | `text.quote`         |   搜索   | 字符数             |
| 复制 URL                  | `safari`             |  ⌘ 打开  | 字符数             |
| 复制文件路径              | `folder`             |  ⌘ 打开  | 字符数             |
| 复制公式                  | `function`           |  ⌘ 计算  | 可复制「结果」     |
| 复制单个汉字              | `waveform`           |  ⌘ 拼音  | 可复制「结果」     |
| 截图到剪贴板 (⌘⇧⌃4)       | `photo`              |    —     | 图片类型、尺寸     |
| 复制单个图片文件          | 缩略图               |    —     | 图片类型、尺寸     |
| 复制单个普通文件          | `doc.on.doc`或缩略图 |    —     | 文件类型、文件大小 |
| 复制文件夹                | `folder`             |    —     | 文件夹大小         |
| 复制多个文件              | `doc.on.doc`         |    —     | 文件数量           |
| 复制色值（#RGB / 6位hex） | 色块 32×32           |    —     | 预览颜色           |
| 复制代码                  | `{ }` `</>`          |  ⌘ 搜索  | 代码类型、字符数   |

## 安装

### 从源码构建

```bash
cd Copied-mac
./build.sh
open .build/Copied.app
```

`build.sh` 使用 `swiftc` 编译，生成自包含 `.app` bundle。

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
