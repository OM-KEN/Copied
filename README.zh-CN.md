# Copied

### 适用于 macOS 的复制确认提示与智能剪贴板操作

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift\&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

<img width="414" height="172" alt="PixPin_2026-07-02_00-39-59" src="https://github.com/user-attachments/assets/c0a118a4-a140-468c-aa92-3043e8ba83f2" />

**确认已经复制。查看复制内容。智能推荐下一步操作。**

Copied 是一款轻量、开源的 macOS 工具。每当你复制内容时，它都会立即在屏幕顶部显示一条提示，确认复制操作已经完成。它可以预览复制的所有内容，并根据内容推荐合适的下一步操作，例如打开链接、显示文件位置、搜索、翻译或计算。

Copied 不是一款传统意义上的剪贴板历史管理工具。它只给你复制后的视觉反馈、有用的内容预览，以及更快捷的下一步操作。

## 为什么做 Copied？
有时候明明复制了，却总会怀疑到底成功了没，然后下意识再多按几次。在 Windows 上，我用 Quicker 写过插件，让我的每次复制都会有 Toast 提醒，还有一个特别好用的功能：按住左键点右键就能复制。于是，我也在 Mac 上实现了复制提醒和左右键复制。作为 UI 设计师，我也尽量做到既原生又美观，先满足自己——**能让自己每天都能用得舒服的 app 才是好 app**。

现在 AI 写代码更容易了，于是我也更进一步，增加了复制后的“**下一步操作**”。比如复制一句话，不用打开网页再粘贴搜索，只要再双击一下快捷键（默认是control ⌃）就能**直接搜**。遇到不会读的单词、生僻字，或者忘记单词意思，也是一样。作为设计师，我复制了某个色值，也不用打开设计软件粘贴再看了，现在复制后弹窗**直接显示颜色**。文件大小、图片尺寸等信息，也不用反复切视图或者右键“显示简介”，复制一下就能看到。

做这个 App 的唯一目标就是快。所以我尽量使用**原生功能**，让它保持**轻量、简洁**。左右键复制默认关闭，但我非常推荐打开，因为鼠标已经选中文本后，再去按 ⌘+C 已经慢了。选中内容，按住左键点一下右键，**马上复制、马上预览、马上进行下一步操作，唯快不破**。

## 功能特征

- **复制弹窗**：监听所有复制操作，弹窗预览已复制的内容
- **快捷操作按钮**：根据内容类型在弹窗右侧显示对应操作按钮（打开链接、定位文件、计算、显示拼音、搜索、翻译）
- **文件、图片、颜色等预览**：复制文件、图片，显示预览小图；复制 #FF6B6B 或CSS颜色，显示预览颜色
- 原生液态玻璃 UI和动效、深色模式适配
- 纯 Swift + AppKit + SwiftUI，纯本地（检查更新除外），零第三方依赖
- 使用 Apple SF Symbols 作为图标系统
- CPU 占用极低

## 系统要求

目前支持 macOS 14+

## 使用

[下载 `dmg`](https://github.com/OM-KEN/Copied/releases/latest)，拖动 app 到 Applications。复制任意内容，显示弹窗。

弹窗显示期间，**点击右侧按钮或双击 ⌃ 键**可触发右侧操作按钮（如计算、打开链接、搜索）。

## 支持的类型

普通文本、文件、URL、文件路径、邮箱、电话、算式、日期、汉字、英文、代码

## 构建

纯 Swift 编译，macOS 26+ 无需 Xcode 工程。git clone 后进入 Copied-mac 目录，执行 `./build.sh` 即可构建（macOS 26 之前可能需安装 Xcode control Line Tools）。

## 架构

```
CopiedApp.swift             MenuBarExtra + AppDelegate + Settings
ClipboardMonitor.swift      每 0.15s 轮询 NSPasteboard.changeCount（含黑名单过滤门）
CopyGestureManager.swift    共享 CGEventTap 左+右 → ⌘C 手势（双路径 + R_UP 兜底）
DetectionRegistry.swift     全局检测器注册中心 + 优先级管道 + 限流
ContentKind.swift           统一类型标识（struct + 静态常量）
AppLanguage.swift           当前 Bundle 界面语言策略（英文环境过滤英文单词检测）
Detectors/                  15 个内置检测器（详见目录）
DictionaryLookupService.swift  DCSCopyTextDefinition 词典查询
PluginLoader.swift          扫描/校验/加载 .copiedplugin 文件夹
PluginManifest.swift        插件清单 + Rule 模型 + CompiledRule
PluginAction.swift          插件动作执行（openURL/search/transform）
PluginActionTemplate.swift  插件动作模板（menuOnly/multiline 配置）
AppFilterSettings.swift     应用黑名单单例 — 过滤判断 + 持久化
AppFilterView.swift         设置 → 黑名单 Tab（列表管理 + 运行中应用选择器）
BlacklistSourceAppAction.swift  右键"屏蔽此来源" Action
ClipboardAction.swift       Action 协议 + 内置 Action + ActionResolver
KeyboardShortcutSettings.swift  快速触发修饰键、双击/单击模式、侧键配置
QuickTriggerModifierKeyPolicy.swift  按实际 keyCode 维护左右修饰键状态
MouseButtonRecordingStateMachine.swift  侧键录制状态与取消/绑定决策
AppUpdateService.swift      GitHub Releases 检查、缓存、节流与提醒状态
ToastWindowController.swift 浮动 NSWindow + NSHostingView + Action + 键盘/侧键快速触发
ToastViewModel.swift        @Observable 模型（含 sourceBundleID）
RelativeDateDescription.swift 日期/时间详情格式化（日历日语义 + 本地化时间）
ToastView.swift             SwiftUI 卡片 + glassEffect（macOS 26+）/ ultraThinMaterial（降级）+ 展开查看全文（if/else 双态）+ contextMenu
LightReminderController.swift 轻提醒模式浮标（NSWindow + NSHostingView + macOS 26+ drawOff / opacity 降级）
TypeSettingsView.swift      设置 → 智能识别 Tab（ContentKind 开关 + 插件管理）
SettingsView.swift           设置（开机启动/搜索引擎/快速触发修饰键/智能识别/手势/黑名单/轻提醒 Tab）
FilePreviewGenerator.swift  QLThumbnailGenerator 异步缩略图
SourceAppDetector.swift     NSWorkspace.frontmostApplication（含 bundleIdentifier）
Localizable.xcstrings       String Catalog（zh-Hans 源语言 + en / zh-Hant）
build.sh                    swiftc + xcstringstool + actool + codesign
```

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
