# CLAUDE.md

## 构建与运行

```bash
./build.sh                     # swiftc + actool + codesign → .build/Copied.app
./create-dmg.sh                # → .build/Copied.dmg（需 pip3 install 'dmgbuild>=1.6.5'）
open .build/Copied.app
```

DMG 背景图：放 `.build/dmg_background.png`（440×240），由 `dmg_settings.py` 配置窗口布局。macOS 26.2+ 存在 Finder 回归 bug，DMG 背景图可能不显示（Apple 已知 bug）。

需 macOS 14+。macOS 26+ 自动享受液态玻璃（`.glassEffect`），旧系统降级为毛玻璃材质。需 Xcode 26（供 `actool` 编译 Liquid Glass 图标）。

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
ToastPanel.swift            nonactivating NSPanel + first-mouse hosting + 原生展开文本
ToastCommand.swift          弹窗内部命令 + 同步防重入分发
ToastWindowController.swift ToastPanel + Action + 展开文本分层 + 键盘/侧键快速触发
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
run-tests.sh                统一运行现有与弹窗交互测试
```

UserDefaults 键：`searchEngine`, `launchAtLogin`, `isPaused`, `copyGestureEnabled`, `lightReminderEnabled`, `keyboardQuickTriggerModifier`, `keyboardQuickTriggerMode`, `mouseQuickTriggerButton`, `automaticUpdateRemindersEnabled`, `contentKindPriorities`, `disabledContentKinds`, `installedPlugins`, `popupFilterBlockedApps`。

**数据流**：`ClipboardMonitor` → `DetectionRegistry.detectAll()` → `SourceAppDetector.detect()` → `AppFilterSettings.shouldShowPopup()` 过滤门 → `ClipboardContent` → 分支：轻提醒模式 → `LightReminderController.show()`，标准模式 → `ToastWindowController.show()` → `ToastViewModel` → `ToastView`

**插件系统**：声明式（JSON + 正则，不执行代码）。插件目录 `~/Library/Application Support/Copied/Plugins/`，通过设置 → 智能识别手动安装。规则支持 `multiline`（默认 false）、`menuOnly`（强制进右键菜单）字段。无默认插件，不自动安装。性能熔断：>100KB 文本仅运行内置语言检测器（跳过插件与实体检测器）、>50ms 单检测器限流 30s、连续 3 次限流自动禁用。

### 轻提醒模式（LightReminderController）

菜单栏右键 / 设置页 Toggle 切换。开启后复制只显示鼠标右上方的 24pt `checkmark.app.fill` 浮标，1s 自消。浮标用忽略鼠标的 borderless floating `NSWindow` + `NSHostingView`，每次 `show()` 重建且不跟踪鼠标。

**绘制动画陷阱**：Symbol 默认已是完整绘制态，`drawOn(isActive:)` 会反向擦除。必须用 `drawOff(isActive: !show)`：初始 `show=false` 隐藏，`onAppear` 后切为 true 反向播放；palette 使用白勾蓝底。macOS 26 以下改用 `.opacity` 淡入。

## 关键设计决策

### 窗口（glassEffect / 降级）

**macOS 26+**：`.glassEffect(in: .rect(cornerRadius: cardCornerRadius))` — 液态玻璃。**pre-macOS 26**：ZStack 内 `RoundedRectangle.fill(.ultraThinMaterial)` + 0.08s 延迟淡入，避免 WindowServer 材质合成首帧灰色闪烁。统一常量 `cardCornerRadius: CGFloat = 32`。

标准弹窗必须使用 `ToastPanel`：`NSPanel + .borderless + .nonactivatingPanel`，`canBecomeKey=true`、`canBecomeMain=false`、`becomesKeyOnlyIfNeeded=true`、`isFloatingPanel=true`、`hidesOnDeactivate=false`。普通 SwiftUI 控件位于 `needsPanelToBecomeKey=false` 的 first-mouse hosting 中，点击不得激活 Copied 或让 Panel 成为 key；只有原生展开文本交互可按需成为 key。

非 key 浮动窗口的边缘高光被 WindowServer 抑制 → `.stroke(.primary.opacity(0.15))` 补偿（`.primary` 自适应亮/暗模式）。每次 `show()` 重建窗口（不复用）— 全屏 Space 长时间使用后复用窗口可能导致 `orderFront` 无效、toast 不出现。窗口配置见 `ToastWindowController.createWindow()`，动画参数见 `ToastView.swift`。

退场动画陷阱：`layerUsesCoreImageFilters = true` 必须设（AppKit 默认不启用）、`CIFilter.name` 必须匹配动画 keyPath、清理覆盖三条路径（动画回调 / `cancelDismiss()` / 非动画 dismiss）。

### 鼠标交互

SwiftUI `Button` 是鼠标 `ToastCommand` 的唯一来源；禁止恢复窗口级左右键 monitor、hover 业务命中、手写矩形或百分比坐标分流。预览按钮发送 `.expand`，右侧按钮发送 `.performPrimary`，整卡背景按钮发送 `.dismiss`；图标和来源信息用 `allowsHitTesting(false)` 穿透到背景关闭，右侧按钮 label 必须用矩形 `contentShape` 覆盖完整视觉区域。hover 只负责视觉状态和暂停自动关闭。

本地 NSEvent monitor 只保留快速触发所需的 `.keyDown` / `.flagsChanged`；订阅 `.leftMouseDown` 会让 nonactivating Panel 只收到 mouseUp，破坏 SwiftUI 原生点击链。`dismissGeneration` 继续防止过期动画清理隐藏新 toast。

### 剪贴板检测

用 `pasteboard.types` 判断内容类别，不用 `readObjects`。缩略图策略：`QLThumbnailGenerator` 异步 + SF Symbol 降级。详见 `ClipboardMonitor.swift`。

### 内容类型检测（DetectionRegistry）

按优先级管道执行所有已注册检测器。检测器实现 `ContentDetectorProtocol`，返回 `ContentDetection?`。

性能熔断（硬边界）：
- **100KB 文本截断**：>100KB → 仅运行内置语言检测器（跳过插件与实体检测器）
- **50ms 单检测器超时**：累计 >50ms → 限流 30s
- **3 次限流自动禁用**：连续 ≥3 次 → 永久禁用 + 系统通知

### 本地化

`Localizable.xcstrings` 以 `zh-Hans` 为源语言，完整支持 `en` 和 `zh-Hant`。App 完全跟随 macOS 系统语言或单 App 语言设置，不增加语言 UserDefaults 或 App 内切换器。SwiftUI 字面量由 `LocalizedStringKey` 查询；先生成 `String` 的内置文案使用 `String(localized:)`；剪贴板内容、插件作者文案、文件名和 App 名称保持原文。

`AppLanguage.isContentKindAvailable(_:)` 是语言相关检测策略的唯一入口：英文界面在检测管道和设置页同时隐藏 `englishPhrase`，且不改写 `disabledContentKinds`；中文界面保留英文单词翻译，所有语言都保留拼音及其他检测。中文年月日会先生成 ISO 候选再交给 `NSDataDetector`，禁止让输入识别结果依赖界面 Locale。

日期检测的 `metadata["subtype"]` 必须按原始文本区分 `date` / `dateTime` / `time`，不能从解析后的 `DateComponents` 推断（`NSDataDetector` 会补齐缺失字段并给纯日期分配时刻）。`RelativeDateDescription` 对纯日期和日期时间按 `Calendar.startOfDay` 的日历组件生成“今天/明天/后天”等命名结果，日期时间再附本地化短时间；仅时间保留真实时差。

### Action 系统

**内联更新模式**（`performsInlineUpdate = true`）：执行后弹窗保持显示，展示**结果覆盖层**（`ResultOverlay { displayText, copyText }`）。右侧按钮变为"复制"（`CopyTextAction`）。覆盖层 `\n` 拆分 VStack，每行 `.lineLimit(1)`，`ScrollView` + `.frame(maxHeight: 200)` 防止超长内容撑爆屏幕。

**词典查询**（`LookupAction`）：`DCSCopyTextDefinition` 查询 macOS 内置牛津中英词典，零配置。返回格式：行1 = `{word} 英 {pron}`，行2 = 中文释义（≤5 字 CJK，≤8 条）。检测器仅匹配单个 ASCII 单词，词典预查在 `ActionResolver.makeAction()` 中进行：有释义→显示"翻译"按钮，无释义→兜底搜索。**预查不能放检测器**（检测器在主线程有 50ms 超时熔断，词典首次加载会触发）。

**优先级**：首个非颜色检测 → 右侧按钮（最多 1 个）。其余 → 右键菜单。无检测 → 默认搜索。纯语言类型（如 swift）不产生按钮。各 Action 触发条件和行为见 `ClipboardAction.swift` 及各 `*Action.swift`。

**按钮背景**：`actionButtonBackground` 双路径——macOS 26+ `.glassEffect(.regular.interactive())` 原生液态玻璃，pre-26 `.fill(.quaternary)` 语义色。不再用 `.white.opacity()` 硬编码（浅色模式不可见）。

**按钮 hover 图标**：用 `ZStack` 叠加两个 SF Symbol + `opacity` 切换，不能用 `Image(systemName: condition ? "A" : "B")`——SF Symbol 宽度不同会导致按钮尺寸变化 → HStack 重排 → 左侧文本截断位置跳动。

### 开机自启

rebuild 后签名变化会使 macOS 清掉 `SMAppService` 登录项注册记录。启动时若 `launchAtLogin=true` 但 status ≠ `.enabled`，自动重新注册；注册失败则回写 UserDefaults 为 `false`。

### 展开查看全文（ToastView expand/collapse）

`ExpandedTextView` 固定宽 360、总高最多 300pt，只在主 SwiftUI host 中预留几何空间。controller 在卡片背景上方安装原生 `NSTextView + NSScrollView`，再叠加不接收鼠标的玻璃视觉 host 和独立 SwiftUI 按钮 host；正文因此可在底栏后方滚动，底部圆角由 scroll layer 裁剪。文档高度必须取 `NSLayoutManager.usedRect` 后再额外加 52pt，不能只依赖 `boundingRect` 或在排版前设置 frame，否则 `NSTextView` 会收缩并遮住最后一两行。`updateWindowSize` 上限 340pt。所有内容类型均可展开，`expandedText` 优先级为结果覆盖层 > 原文 > 文件名+路径。

展开态交互：进入展开态时移除键盘/侧键快速触发监听，收起后重新安装。只有原生文本需要 Panel 成为 key，并直接使用 responder chain 支持拖选、⌘C 和右键菜单；普通底栏按钮仍保持 Panel non-key。按钮栏中间透明 SwiftUI Button 负责关闭，不使用坐标命中。Escape 不提供操作。TextEdit 操作写 UUID 临时文件后用 `NSWorkspace` 打开，且动作入口必须防重入。

过渡必须使用全窗口 CIGaussianBlur + alpha 两段式切换，并由 `isExpandingOrCollapsing` 防重入；窗口 resize 不做动画。

### 点击处理

所有入口统一发送 `ToastCommand`（主 Action、具体 Action、展开、收起、关闭、TextEdit、更新页），由 `ToastCommandDispatcher` 同步防重入并交给 controller 执行。不得恢复主 Action 手动 mouseUp、`ManualPrimaryActionEventGuard`、`CollapsedToastMouseUpPolicy` 或 hover/坐标命中。`cancelDismiss()` 仍需重置 `isDismissing=false`、递增 `dismissGeneration`、恢复 `alphaValue=1.0`。

### 快速触发（修饰键）

Toast 有主操作按钮（或结果覆盖层）时，默认在第一次 Control 松开后的 350ms 内再次按下并松开 Control 触发。设置 → 通用 → 快速触发可改为 Command/Option/Shift、关闭键盘触发，或启用单击（高级）模式；原生鼠标侧键可作为并行触发。按钮 hover 时动态显示对应图标。

普通鼠标输入取消快速触发时，只有视觉状态实际变化才写 `quickTriggerVisualState`，禁止在 idle → idle 时触发 SwiftUI 重绘。展开态没有主操作按钮，因此暂停全部快速触发监听；收起或新 toast 出现时恢复，不改变折叠态的键盘/侧键行为。

**输入边界**：从第一次按下到第二次松开之间，出现普通键、其他修饰键、鼠标点击或滚轮即取消。键盘路径不需要辅助功能权限；侧键录制/触发与左右键复制共享 `GlobalMouseEventCoordinator` 的 CGEventTap，需要辅助功能权限。

1. **实际 keyCode 策略** — `QuickTriggerModifierKeyPolicy` 按左右修饰键 keyCode 转换状态；不要用聚合 flags 推断按键，因为 macOS 可能携带残留 Function/NumericPad flags。
2. **本地事件 + HID 计数器** — 捕获组合键、鼠标与滚轮输入；事件计数变化即中止。
3. **`dismissGeneration` 守卫** — 防止旧弹窗的延迟释放触发新 toast Action。

**侧键限制**：只绑定 button number ≥3 的原生 `otherMouseDown`。Mac Mouse Fix 等重映射工具可能在 Copied 前拦截或改写事件；此时需关闭对应映射或保留原生侧键。

### 版本与更新

`VERSION` 是构建版本单一来源，`build.sh` 同步写入 `CFBundleShortVersionString`。菜单栏显示实际版本并可打开关于页；有更新时显示绿色圆点和“有新版本”。关于页可手动检查，自动提醒最多每天成功检查一次、失败一小时后重试；只读取 GitHub 最新稳定 Release，更新按钮打开 GitHub，不做应用内下载安装。标准 Toast 右上角用 `arrow.up.circle.fill` 提醒，点击进入关于页；轻提醒模式不叠加更新提醒。

### 菜单栏

`MenuBarExtra` + `Copied.svg` 模板图像。`build.sh` 将 `fill="white"` 替换为 `fill="black"` 做模板遮罩。设置与版本放在同一区域，版本项位于退出上方，点击打开关于页。暂停/恢复直接读 `UserDefaults`。`Info.plist` 设 `LSUIElement = YES`。

### 左右键快捷复制（CopyGestureManager）

设置 → 手势中开启，默认关闭。CGEventTap 监听 4 事件（leftDown/leftUp/rightDown/rightUp）。

- **rightMouseDown** → `isLeftPressed && !gestureFired`：吞掉 + 15ms ⌘C + `gestureFired=true`
- **rightMouseUp 兜底** → `isLeftPressed && !gestureFired`：rightMouseDown 被 WindowServer 静默吞掉时补触发
- `gestureFired` 每次 leftDown/leftUp 重置，防双击发
- ⌘C 模拟：CGEvent keyboard source 传 `nil`，完整发送 Command down → C down → C up → Command up，末次释放清空 flags

**权限 UX（三重保障）**：无权限 Toggle 强制 OFF → 重启引导 Alert → 权限丢失自动回正。签名：Apple Development，Team ID `683MU5Q6FB`（TCC 凭 Team ID 识别）。

**已知限制**：先松左键 → WindowServer 在 HID 层独立发 secondary-click popup → 源 App 弹右键菜单（session-level tap 无法拦截）。

## Bug 调试方法（强制）

**禁止猜测式修 bug。必须先加文件日志定位根因。**

1. **加文件日志**：写私有 logger 到 `FileManager.default.temporaryDirectory`，每条日志含「事件类型 + 当前状态 + 关键变量」。启动时清空。
2. **复现 + `cat` 读日志**：严格按步骤触发，对比正常/异常日志差异。
3. **确认根因后改码**：日志必须明确显示断点。不确定就加更多日志。
4. **修复后清理日志代码**。

**为什么不用 Console.app**：CGEventTap/NSEvent 每秒数百条，混在全系统日志中无法定位。文件日志只含关心的状态，一行一事。

模板：
```swift
private static let logURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("copied_debug.log")
private func dlog(_ s: String) {
    let line = "\(Date().timeIntervalSince1970) \(s)\n"
    if let d = line.data(using: .utf8) {
        if let fh = try? FileHandle(forWritingTo: logURL) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? d.write(to: logURL, options: .atomic) }
    }
}
// 启动时：try? Data().write(to: logURL, options: .atomic)
```

## GitHub 推送规则（硬性）

**任何 git 操作前必须先调用 `git-push` skill。** 只改/只传 `Copied-mac/`，根 `README.md` 不可修改。

## 已知限制

- **窗口位置**：WindowServer 限制在屏幕边界内，无法超出 `screen.frame.maxY`
- **窗口动画裁切**：`showResultOverlay` 展开时右边缘短暂裁切（AppKit ↔ SwiftUI 时序错配）。缓解：0.25s 动画 + 2 行结果 + ZStack 交叉淡入淡出
- **无 Xcode 工程**：`swiftc` + `actool` + `codesign`，Xcode 26 供 `actool` 编译 Liquid Glass 图标
- **指纹**：覆盖 `SOURCES` + `RESOURCES` + `BUILD_FILES`。新增资源文件需 `rm .build/.source_fingerprint`
