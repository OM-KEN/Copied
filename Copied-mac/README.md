# Copied

按下 ⌘C，屏幕顶部弹出一张精美的液态玻璃卡片 — 告诉你复制成功，还能一键操作。

## 亮点

- **漂亮** — macOS 26+ 原生液态玻璃，旧系统毛玻璃降级，弹簧动画，SF Symbols 图标
- **聪明** — 自动识别 URL、邮箱、电话、色值、公式、日期、汉字、英文、代码语言
- **高效** — 默认双击 Control 直接触发操作，也可改为单击修饰键或鼠标侧键
- **图片压缩** — 安装 Lithe 后，复制 Finder 中的 JPG/JPEG/PNG 文件即可一键压缩
- **克制** — 可按应用设置黑名单，不想被打扰的 App 里不弹窗
- **安静** — 折叠卡片 3 秒自动消失且不抢焦点，展开全文后保持显示并自动进入可选文本状态
- **轻打扰模式** — 菜单栏一键筛选视觉弹窗，可按普通长短文本、图片、文件和识别类型自定义；高级设置还可改为鼠标旁的仅提醒图标
- **声音反馈** — 默认用半音量 Frog 确认每次复制，异步播放不阻塞卡片显示，可在通用设置中更换系统声音或关闭
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

首次启动后，将 App 拖入 `/Applications` 以获得稳定权限。菜单栏出现剪贴板图标即开始工作；再次打开 Copied 会显示设置窗口，设置页底部可直接退出 App。

## 使用

复制任意内容 → 卡片弹出。图片详情会在尺寸后显示文件大小；来源或详情标签过长时，卡片会先按标签需要扩展至 360pt，仍有溢出则在悬停卡片后自动滚动一次，并用边缘渐隐避免生硬截断。标签不拦截点击。悬停保持，点击预览行展开全文，点击右侧按钮执行操作，点击图标、来源信息或其他空白区域关闭。展开全文后不会自动关闭，正文自动获得焦点，可立即拖选、复制，也可在文本编辑中打开、收起或关闭；收起时若指针仍在卡片内会继续保持，移出后重新开始 3 秒计时。默认在第一次 Control 松开后的 350ms 内再次按下并松开 Control，即可触发主操作；设置中也可选择单击模式、其他修饰键或原生鼠标侧键。

菜单栏可一键切换“轻打扰模式”，也可在“设置 → 通用 → 复制反馈 → 自定义…”中细分普通短文本、普通长文本、图片、文件和各识别类型。未识别文本按 50 字符边界分别服从普通短/长文本开关；URL、代码等已识别内容只服从自己的类型开关，不受普通文本长度开关影响。图片文件全部为有效图片时服从“图片”，普通文件和混合选择服从“文件”。这些选项只筛选视觉提示，不关闭内容识别或声音反馈。

需要更安静的反馈时，可在“设置 → 通用”最底部展开“高级”，开启“仅提醒模式”；所有通过上述筛选的完整卡片都会替换成鼠标旁短暂出现的确认图标。

若系统已安装 [Lithe](https://github.com/OM-KEN/Lithe)，在 Finder 中复制一张或多张本地 JPG/JPEG/PNG 普通文件，卡片右侧会显示“压缩”，右键菜单也保留该操作；多选内容必须全部受支持。纯位图剪贴板、混入不支持文件的选择以及 Lithe 自动复制的压缩结果不会再次提供压缩入口。

复制声音默认使用系统 Frog 提示音的 50% 音量，可在“设置 → 通用 → 复制反馈”中选择其他系统声音或“无”。声音异步播放，不会等待音频载入后才显示卡片；500ms 内重复复制相同内容仍会播放声音，但不会重复弹出视觉反馈。

公式计算用 `=` 标记精确结果、用 `≈` 标记有限精度近似结果；界面与复制内容使用同一次舍入，计算失败时不显示复制按钮。

左右键手势和侧键录制/触发需要辅助功能权限；授权成功后可在提示中一键退出并重新打开 Copied。进入系统设置期间，Copied 会临时暂停相关全局鼠标监听；离开后若权限仍在则自动恢复，若已撤销则关闭手势开关。Mac Mouse Fix 等鼠标重映射工具可能在事件到达 Copied 前拦截或改写原生侧键、“修饰键 + 滚轮”等输入；此时只需在该工具中关闭对应映射或保留原生事件，无需退出整个工具。

右键菜单提供搜索、另存为、类型专属操作，以及一键将当前 App 加入黑名单。设置中可开启左右键手势（按住左键+右键=⌘C）、管理检测类型、管理黑名单、安装插件。

没有识别出专属操作时，短文本的右侧按钮用于搜索，50 字符及以上的长文本改为另存为 TXT。

界面语言跟随 macOS 的系统语言或“语言与地区 → 应用程序”设置。中文界面可识别单个英文单词并查询系统词典；英文界面将普通英文文本直接用于搜索，其他内容检测和单字拼音保持不变。

## 架构

```
CopiedApp.swift             — 入口：MenuBarExtra + reopen 设置桥接 + AppDelegate + Settings
ApplicationRelauncher.swift — 辅助功能授权后的安全退出并重新打开
ClipboardMonitor.swift      — 每 75ms 轮询 NSPasteboard + 内容解析 + 黑名单过滤
LitheIntegration.swift      — Lithe 安装检测、图片资格判断与防回环剪贴板契约
ClipboardTextPolicy.swift   — 长文本阈值与纯文本主操作策略
PopupPresentationSettings.swift — 默认/轻打扰模式偏好与视觉呈现策略
PopupFilterSettingsView.swift — 轻打扰模式的普通内容和识别类型自定义窗口
CopySoundFeedback.swift     — 复制系统声音选择、默认值与异步串行播放
GlobalMouseEventCoordinator.swift — 共享全局鼠标 Event Tap + 系统设置暂停 + 权限失效保护
CopyGestureManager.swift    — 左右键手势 + ⌘C 模拟
DetectionRegistry.swift     — 全局检测器注册中心 + 优先级管道
MathExpressionEvaluator.swift — 公式统一解析、Decimal 求值与精确/近似格式化
ContentKind.swift           — 统一类型标识
AppLanguage.swift           — 界面语言相关的检测可用性策略
Detectors/                  — 15 个内置检测器
PluginLoader.swift          — .copiedplugin 扩展加载/管理
PluginRuntimeSafety.swift   — 插件目录约束与正则执行预算
AppFilterSettings.swift     — 应用黑名单过滤 + 持久化
ClipboardAction.swift       — Action 协议 + 内置 Action + ActionResolver
DictionaryLookupService.swift — 系统词典查询 + 启动异步预热
KeyboardShortcutSettings.swift — 快速触发修饰键、双击/单击模式和侧键配置
QuickTriggerModifierKeyPolicy.swift — 按实际键码处理修饰键状态与冲突
QuickTriggerCoordinator.swift — 键盘/侧键快速触发监听、生命周期与上下文保护
AppUpdateService.swift      — GitHub Releases 版本检查、缓存与提醒节流
FilePreviewGenerator.swift  — QLThumbnailGenerator 异步文件缩略图
SourceAppDetector.swift     — NSWorkspace 前台 App 检测（含 bundleIdentifier）
ToastPanel.swift            — nonactivating NSPanel + first-mouse hosting / 原生展开文本
ToastCommand.swift          — 弹窗内部命令与单次分发
ToastWindowController.swift — ToastPanel、展开文本分层与快速触发命令路由（标准模式）
LightReminderController.swift — 仅提醒模式浮标（NSWindow + drawOff 反向动画）
ToastView.swift             — SwiftUI 卡片 + 展开查看全文 + 色块 + 右键菜单
MetadataAutoScrollMetrics.swift — 来源与详情标签的溢出滚动参数
ToastViewModel.swift        — @Observable 模型（含展开状态管理）
RelativeDateDescription.swift — 日期/时间详情的日历语义与本地化格式化
SettingsView.swift          — 设置页（含弹窗模式、仅提醒高级项、快速触发、软件更新、关于页与退出入口）
Copied.icon                 — Liquid Glass 分层图标
Copied.svg                  — 菜单栏 template 图标
Localizable.xcstrings       — 简中、繁中、英文 String Catalog
build.sh                    — swiftc + xcstringstool + actool + codesign 一键构建
run-tests.sh                — 统一运行全部自动测试
create-dmg.sh               — DMG 安装包生成
```

## 性能报告

- [v3.1.7 剪贴板响应效率报告](Reports/clipboard-response-efficiency.html)
