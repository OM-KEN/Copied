# Copied

智能复制反馈工具——复制任意内容，在屏幕顶部弹窗展示复制的内容，并根据所复制的内容，快捷进行下一步操作。（注意：不是剪贴板工具）

<img width="414" height="172" alt="PixPin_2026-07-02_00-39-59" src="https://github.com/user-attachments/assets/c0a118a4-a140-468c-aa92-3043e8ba83f2" />

## 为什么做Copied？
有时候明明复制了，却总会怀疑到底成功了没，下意识再多按几次。在 Windows 上，我用 Quicker写过插件，让我的每次复制都会有 Toast 提醒，还有一个特别好用的功能：按住左键点右键就能复制。于是，我也在 Mac 上实现了复制提醒和左右键复制。作为 UI 设计师，我也尽量做到既原生又美观，先满足自己——**能让自己每天都能用得舒服的app才是好app**。

现在AI写代码更容易了，于是我也更进一步，增加了复制后的“**下一步操作**”。比如复制一个词，不用打开网页再粘贴搜索，只要再按一下快捷键（默认是Command）就能**直接搜**。遇到不会读的单词、生僻字，或者忘记单词意思，也是一样。作为设计师，我复制了某个色值，也不用打开设计软件粘贴再看了，现在复制后弹窗**直接显示颜色**。文件大小、图片尺寸等信息，也不用反复切视图或者右键“显示简介”，复制一下就能看到。

做这个 App 的唯一目标就是快。所以我尽量使用**原生功能**，让它保持**轻量、简洁**。左右键复制默认关闭，但我非常推荐打开，因为鼠标已经选中文本后，再去按 Command+C 已经慢了。选中内容，按住左键点一下右键，**马上复制、马上预览、马上进行下一步操作，唯快不破**。

## 功能特征

- **复制弹窗**：监听所有复制操作，弹窗显示已复制的内容
- **快捷操作按钮**：根据内容类型在弹窗右侧显示对应操作（打开链接、定位文件、计算、显示拼音、搜索、翻译）
- **文件、图片、颜色等预览**：复制文件、图片，显示预览小图；复制 #FF6B6B 或CSS颜色，左侧预览颜色
- 原生液态玻璃 UI和动效
- 纯 Swift + AppKit + SwiftUI，纯本地，零第三方依赖。
- CPU 占用极低

## 系统要求

目前暂只支持macOS 26+

## 使用

下载dmg，拖动app到Applications。复制任意内容，显示弹窗。

弹窗显示期间，**点击右侧按钮或按下 ⌘ 键**可触发右侧操作按钮（如计算、打开链接、搜索）。

## 支持的类型

普通文本、文件、URL、文件路径、邮箱、电话、算式、日期、汉字、英文、代码

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
