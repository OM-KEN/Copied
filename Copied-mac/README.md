# Copied

按下 ⌘C，屏幕顶部弹出一张精美的液态玻璃卡片 — 告诉你复制成功，还能一键操作。

## 亮点

- **漂亮** — macOS 26+ 原生液态玻璃，旧系统毛玻璃降级，弹簧动画，SF Symbols 图标
- **聪明** — 自动识别 URL、邮箱、电话、色值、公式、日期、汉字、英文、代码语言
- **高效** — ⌘ 键直接触发操作（打开链接、计算、翻译、搜索），无需鼠标
- **克制** — 可按应用设置黑名单，不想被打扰的 App 里不弹窗
- **安静** — 3 秒自动消失，不抢焦点，不打断工作流
- **轻提醒模式** — 菜单栏一键切换，复制时仅鼠标旁弹出绘制动画图标，零干扰
- **干净** — 零第三方依赖，无网络请求，CPU ≈ 0%

## 安装

需 macOS 14+（macOS 26+ 享受液态玻璃效果）。从源码构建：

```bash
git clone <repo>
cd Copied/Copied-mac
./build.sh
open .build/Copied.app
```

构建 DMG 安装包：

```bash
./create-dmg.sh                # 生成 .build/Copied.dmg
```

将 `.build/dmg_background.png`（440×240）放入项目根目录可自定义 DMG 背景。

首次启动后，将 App 拖入 `/Applications` 以获得稳定权限。菜单栏出现剪贴板图标即开始工作。

## 使用

复制任意内容 → 卡片弹出。悬停保持，点击预览行展开全文，点击其他区域关闭，⌘ 键触发操作。

右键菜单提供搜索、另存为、类型专属操作，以及一键将当前 App 加入黑名单。设置中可开启左右键手势（按住左键+右键=⌘C）、管理检测类型、管理黑名单、安装插件。

## 架构

```
CopiedApp.swift             — 入口：MenuBarExtra + AppDelegate + Settings
ClipboardMonitor.swift      — NSPasteboard 轮询 + 内容解析 + 黑名单过滤
CopyGestureManager.swift    — 全局鼠标手势（CGEventTap）+ ⌘C 模拟
DetectionRegistry.swift     — 全局检测器注册中心 + 优先级管道
ContentKind.swift           — 统一类型标识
Detectors/                  — 15 个内置检测器
PluginLoader.swift          — .copiedplugin 扩展加载/管理
AppFilterSettings.swift     — 应用黑名单过滤 + 持久化
ClipboardAction.swift       — Action 协议 + 内置 Action + ActionResolver
KeyboardShortcutSettings.swift — ShortcutModifier 枚举（快速触发修饰键）
FilePreviewGenerator.swift  — QLThumbnailGenerator 异步文件缩略图
SourceAppDetector.swift     — NSWorkspace 前台 App 检测（含 bundleIdentifier）
ToastWindowController.swift — NSWindow + NSHostingView 管理（标准模式）
LightReminderController.swift — 轻提醒模式浮标（NSWindow + drawOff 反向动画）
ToastView.swift             — SwiftUI 卡片 + 展开查看全文 + 色块 + 右键菜单
ToastViewModel.swift        — @Observable 模型（含展开状态管理）
SettingsView.swift          — 设置页（通用/类型/手势/黑名单，含快速触发修饰键配置）
Copied.icon                 — Liquid Glass 分层图标
Copied.svg                  — 菜单栏 template 图标
build.sh                    — swiftc + actool + codesign 一键构建
create-dmg.sh               — DMG 安装包生成
```

