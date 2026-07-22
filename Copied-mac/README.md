# Copied

按下 ⌘C，屏幕顶部弹出一张精美的液态玻璃卡片 — 告诉你复制成功，还能一键操作。

## 亮点

- **漂亮** — macOS 26+ 原生液态玻璃，旧系统毛玻璃降级，弹簧动画，SF Symbols 图标
- **聪明** — 自动识别 URL、邮箱、电话、色值、公式、日期、汉字、英文、代码语言
- **高效** — 默认双击 Control 直接触发操作，也可改为单击修饰键或鼠标侧键
- **克制** — 可按应用设置黑名单，不想被打扰的 App 里不弹窗
- **安静** — 折叠卡片 3 秒自动消失，展开全文后保持显示，不抢焦点，不打断工作流
- **轻提醒模式** — 菜单栏一键切换，复制时仅鼠标旁弹出绘制动画图标，零干扰
- **声音反馈** — 默认用半音量 Frog 确认每次复制，可在通用设置中更换系统声音或关闭
- **原生多语言** — 完全跟随 macOS，支持简体中文、繁体中文和英文
- **干净** — 零第三方依赖；除检查 GitHub Releases 更新外不联网，CPU ≈ 0%

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
pip3 install 'dmgbuild>=1.6.5'   # 首次需安装
./create-dmg.sh                  # 生成 .build/Copied.dmg
```

将 `.build/dmg_background.png`（440×240）放入项目根目录可自定义 DMG 背景。

首次启动后，将 App 拖入 `/Applications` 以获得稳定权限。菜单栏出现剪贴板图标即开始工作。

## 使用

复制任意内容 → 卡片弹出。悬停保持，点击预览行展开全文，点击右侧按钮执行操作，点击图标、来源信息或其他空白区域关闭。展开全文后不会自动关闭，可拖选、复制、在文本编辑中打开或手动收起。默认在第一次 Control 松开后的 350ms 内再次按下并松开 Control，即可触发主操作；设置中也可选择单击模式、其他修饰键或原生鼠标侧键。

复制声音默认使用系统 Frog 提示音的 50% 音量，可在“设置 → 通用 → 复制反馈”中选择其他系统声音或“无”。500ms 内重复复制相同内容仍会播放声音，但不会重复弹出视觉反馈。

公式计算用 `=` 标记精确结果、用 `≈` 标记有限精度近似结果；界面与复制内容使用同一次舍入，计算失败时不显示复制按钮。

左右键手势和侧键录制/触发需要辅助功能权限；撤销权限后，Copied 会立即停用相关鼠标监听并关闭手势开关。Mac Mouse Fix 等鼠标重映射工具可能在事件到达 Copied 前拦截或改写原生侧键、“修饰键 + 滚轮”等输入；此时只需在该工具中关闭对应映射或保留原生事件，无需退出整个工具。

右键菜单提供搜索、另存为、类型专属操作，以及一键将当前 App 加入黑名单。设置中可开启左右键手势（按住左键+右键=⌘C）、管理检测类型、管理黑名单、安装插件。

没有识别出专属操作时，短文本的右侧按钮用于搜索，50 字符及以上的长文本改为另存为 TXT。

界面语言跟随 macOS 的系统语言或“语言与地区 → 应用程序”设置。中文界面可识别单个英文单词并查询系统词典；英文界面将普通英文文本直接用于搜索，其他内容检测和单字拼音保持不变。

## 架构

```
CopiedApp.swift             — 入口：MenuBarExtra + AppDelegate + Settings
ClipboardMonitor.swift      — NSPasteboard 轮询 + 内容解析 + 黑名单过滤
ClipboardTextPolicy.swift   — 长文本阈值与纯文本主操作策略
CopySoundFeedback.swift     — 复制系统声音选择、默认值与播放
GlobalMouseEventCoordinator.swift — 共享全局鼠标 Event Tap + 权限失效保护
CopyGestureManager.swift    — 左右键手势 + ⌘C 模拟
DetectionRegistry.swift     — 全局检测器注册中心 + 优先级管道
MathExpressionEvaluator.swift — 公式统一解析、Decimal 求值与精确/近似格式化
ContentKind.swift           — 统一类型标识
AppLanguage.swift           — 界面语言相关的检测可用性策略
Detectors/                  — 15 个内置检测器
PluginLoader.swift          — .copiedplugin 扩展加载/管理
AppFilterSettings.swift     — 应用黑名单过滤 + 持久化
ClipboardAction.swift       — Action 协议 + 内置 Action + ActionResolver
KeyboardShortcutSettings.swift — 快速触发修饰键、双击/单击模式和侧键配置
QuickTriggerModifierKeyPolicy.swift — 按实际键码处理修饰键状态与冲突
QuickTriggerCoordinator.swift — 键盘/侧键快速触发监听、生命周期与上下文保护
AppUpdateService.swift      — GitHub Releases 版本检查、缓存与提醒节流
FilePreviewGenerator.swift  — QLThumbnailGenerator 异步文件缩略图
SourceAppDetector.swift     — NSWorkspace 前台 App 检测（含 bundleIdentifier）
ToastPanel.swift            — nonactivating NSPanel + first-mouse hosting / 原生展开文本
ToastCommand.swift          — 弹窗内部命令与单次分发
ToastWindowController.swift — ToastPanel、展开文本分层与快速触发命令路由（标准模式）
LightReminderController.swift — 轻提醒模式浮标（NSWindow + drawOff 反向动画）
ToastView.swift             — SwiftUI 卡片 + 展开查看全文 + 色块 + 右键菜单
ToastViewModel.swift        — @Observable 模型（含展开状态管理）
RelativeDateDescription.swift — 日期/时间详情的日历语义与本地化格式化
SettingsView.swift          — 设置页（含快速触发录制、软件更新与关于页）
Copied.icon                 — Liquid Glass 分层图标
Copied.svg                  — 菜单栏 template 图标
Localizable.xcstrings       — 简中、繁中、英文 String Catalog
build.sh                    — swiftc + xcstringstool + actool + codesign 一键构建
run-tests.sh                — 统一运行全部自动测试
create-dmg.sh               — DMG 安装包生成
```
