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
ClipboardTextPolicy.swift   长文本阈值与纯文本主操作策略
CopySoundFeedback.swift     复制系统声音选择、默认值与播放
GlobalMouseEventCoordinator.swift  共享 CGEventTap + 权限失效保护
CopyGestureManager.swift    左+右 → ⌘C 手势（双路径 + R_UP 兜底）
DetectionRegistry.swift     全局检测器注册中心 + 优先级管道 + 限流
MathExpressionEvaluator.swift  公式统一词法/解析 + Decimal 求值 + 精确/近似格式化
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
QuickTriggerCoordinator.swift  键盘/侧键快速触发监听、生命周期与上下文守卫
MouseButtonRecordingStateMachine.swift  侧键录制状态与取消/绑定决策
AppUpdateService.swift      GitHub Releases 检查、缓存、节流与提醒状态
ToastPanel.swift            nonactivating NSPanel + first-mouse hosting + 原生展开文本
ToastCommand.swift          弹窗内部命令 + 同步防重入分发
ToastWindowController.swift ToastPanel + Action + 展开文本分层 + 快速触发 Context/Command 路由
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

UserDefaults 键：`searchEngine`, `launchAtLogin`, `isPaused`, `copyGestureEnabled`, `lightReminderEnabled`, `copyFeedbackSound`, `keyboardQuickTriggerModifier`, `keyboardQuickTriggerMode`, `mouseQuickTriggerButton`, `automaticUpdateRemindersEnabled`, `contentKindPriorities`, `disabledContentKinds`, `installedPlugins`, `popupFilterBlockedApps`。

**数据流**：`ClipboardMonitor` → `DetectionRegistry.detectAll()` → `SourceAppDetector.detect()` → `AppFilterSettings.shouldShowPopup()` 过滤门 → `CopySoundFeedback` → 视觉去重 → 分支：轻提醒模式 → `LightReminderController.show()`，标准模式 → `ToastWindowController.show()` → `ToastViewModel` → `ToastView`

复制声音默认 Frog，固定使用 `NSSound` 的 0.5 音量；设置试听与实际复制共用同一播放路径，可选择其他系统声音或 `none`。声音在来源过滤后、视觉去重前播放，因此 500ms 内重复复制相同内容仍会逐次发声；暂停、不可读内容和黑名单来源无声。

**插件系统**：声明式 JSON + 正则，不执行代码。目录为 `~/Library/Application Support/Copied/Plugins/`，只从设置手动安装；规则支持 `multiline`、`menuOnly`，无默认插件。性能边界统一由 `DetectionRegistry` 管理。

### 轻提醒模式（LightReminderController）

开启后只显示鼠标右上方的 24pt `checkmark.app.fill` 浮标，1s 自消。使用忽略鼠标的 borderless floating `NSWindow` + `NSHostingView`，每次 `show()` 重建。

**绘制动画陷阱**：Symbol 默认已是完整绘制态，`drawOn(isActive:)` 会反向擦除。必须用 `drawOff(isActive: !show)`：初始 `show=false` 隐藏，`onAppear` 后切为 true 反向播放；palette 使用白勾蓝底。macOS 26 以下改用 `.opacity` 淡入。

## 关键设计决策

### 窗口（glassEffect / 降级）

macOS 26+ 用 `.glassEffect(in: .rect(cornerRadius: cardCornerRadius))`；旧系统用 `.ultraThinMaterial` + 0.08s 延迟淡入，避免首帧灰闪。圆角统一为 32pt。

标准弹窗必须使用 `ToastPanel`：`NSPanel + .borderless + .nonactivatingPanel`，`canBecomeKey=true`、`canBecomeMain=false`、`becomesKeyOnlyIfNeeded=true`、`isFloatingPanel=true`、`hidesOnDeactivate=false`。普通 SwiftUI 控件位于 `needsPanelToBecomeKey=false` 的 first-mouse hosting 中，点击不得激活 Copied 或让 Panel 成为 key；只有原生展开文本交互可按需成为 key。

非 key 窗口用 `.stroke(.primary.opacity(0.15))` 补偿边缘高光。每次 `show()` 必须重建窗口；复用窗口在全屏 Space 长时间运行后可能无法 `orderFront`。

退场动画必须启用 `layerUsesCoreImageFilters`，让 `CIFilter.name` 匹配 keyPath，并覆盖动画回调、`cancelDismiss()`、非动画 dismiss 三条清理路径。

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

### 公式计算

`MathExpressionDetector` 与 `CalculateAction` 必须共用 `MathExpressionEvaluator`，禁止恢复 `NSExpression` 或检测/执行两套解析路径。求值使用有复杂度边界的严格解析器和 `Decimal`：精确加减乘先计算十进制系数并验证 `Decimal` 无损往返；循环小数除法携带绝对误差界，只有整个误差区间得到相同的最终显示值时才以 `≈` 返回。分数指数以及近似值继续参与乘、除、幂会被拒绝，禁止用无误差界的 `Double` 回退。界面值与复制值必须来自同一次舍入，复制文本固定使用 POSIX 小数点且不含分组符；无效表达式、除零、超界或不稳定结果不提供复制按钮和快速触发。

### 本地化

`Localizable.xcstrings` 以 `zh-Hans` 为源语言，支持 `en` / `zh-Hant`。App 只跟随系统或单 App 语言，不增加语言 UserDefaults/切换器；生成后的内置文案用 `String(localized:)`，剪贴板内容、插件文案、文件名和 App 名保持原文。

`AppLanguage.isContentKindAvailable(_:)` 是语言检测策略唯一入口：英文界面同时隐藏并跳过 `englishPhrase`，且不改写 `disabledContentKinds`；其他检测保持可用。输入识别不得依赖界面 Locale，中文年月日先转 ISO 候选再交给 `NSDataDetector`。

日期 `metadata["subtype"]` 必须按原文区分 `date` / `dateTime` / `time`，禁止从会补齐字段的 `DateComponents` 推断。`RelativeDateDescription` 对日期按 `Calendar.startOfDay` 生成日历日描述；日期时间附短时间，仅时间按真实时差。

### Action 系统

**内联更新**（`performsInlineUpdate = true`）：Action 后保留弹窗并显示 `ResultOverlay { displayText, copyText? }`；只有 `copyText` 非空时主按钮和快速触发才改为 `CopyTextAction`，错误结果不提供复制入口。结果逐行 `.lineLimit(1)`，滚动区上限 200pt。

**词典查询**：`LookupAction` 使用 `DCSCopyTextDefinition`。预查只能在 `ActionResolver.makeAction()`，有释义显示翻译、无释义回退搜索；禁止放进受 50ms 熔断约束的检测器。

**优先级**：首个非颜色检测占右侧唯一按钮，其余进右键菜单；无检测时短文本默认搜索、长文本默认另存为，纯语言类型不产生按钮。规则以 `ClipboardAction.swift` 和各 `*Action.swift` 为准。

**视觉约束**：按钮背景在 macOS 26+ 用 `.glassEffect(.regular.interactive())`，旧系统用 `.fill(.quaternary)`；禁止硬编码白色。hover 图标必须以 `ZStack` + `opacity` 切换，条件替换不同宽度的 SF Symbol 会触发 HStack 重排和文本跳动。

### 开机自启

rebuild 后签名变化会使 macOS 清掉 `SMAppService` 登录项注册记录。启动时若 `launchAtLogin=true` 但 status ≠ `.enabled`，自动重新注册；注册失败则回写 UserDefaults 为 `false`。

### 展开查看全文（ToastView expand/collapse）

`ExpandedTextView` 固定宽 360、总高最多 300pt；主 host 只预留几何空间，controller 分层安装原生 `NSTextView/NSScrollView`、无命中玻璃 host 和独立按钮 host。文档高度必须取 `NSLayoutManager.usedRect` 再加 64pt，底栏高 54pt、左右内边距 16pt，两端按钮圆角 8pt，`updateWindowSize` 上限 340pt；`expandedText` 优先级为结果覆盖层 > 原文 > 文件名+路径。

展开态在 `NSPanel` 四周额外保留 16pt 透明阴影边界；SwiftUI hosting 保持原尺寸并整体内移，原生正文与底栏继续通过 hosting 坐标换算同步定位，禁止在 SwiftUI 根视图上加 padding 代替窗口边界。

展开期间暂停全部快速触发。只有原生正文按需让 Panel 成为 key，并通过 responder chain 支持拖选、⌘C 和右键菜单；底栏按钮保持 non-key，中间透明 SwiftUI Button 负责关闭，禁止坐标命中，Escape 无操作。TextEdit 使用 UUID 临时文件并防重入。

展开期间不得启动自动关闭计时器；鼠标移出后保持展开，只有手动关闭、收起或打开 TextEdit 才结束展开态。收起后恢复折叠态原有的自动关闭行为。

展开/收起必须用全窗口 CIGaussianBlur + alpha 两段式切换，以 `isExpandingOrCollapsing` 防重入；resize 不做动画。展开态直接关闭时，原生正文与底栏必须保持可见直到模糊淡出完成，禁止在启动退场动画前隐藏分层 surface。

### 点击处理

所有入口统一发送 `ToastCommand`（主 Action、具体 Action、展开、收起、关闭、TextEdit、更新页），由 `ToastCommandDispatcher` 同步防重入并交给 controller 执行。不得恢复主 Action 手动 mouseUp、`ManualPrimaryActionEventGuard`、`CollapsedToastMouseUpPolicy` 或 hover/坐标命中。`cancelDismiss()` 仍需重置 `isDismissing=false`、递增 `dismissGeneration`、恢复 `alphaValue=1.0`。

### 快速触发（修饰键）

`QuickTriggerCoordinator` 独占键盘/侧键监听、状态机、350ms timeout、20ms HID poll、设置快照和视觉去重。`ToastWindowController` 只提供以 `dismissGeneration` 为 ID 的有效性/可执行 Context，并把执行回调路由到 `ToastCommand.performPrimary`；禁止把 token、状态机或定时任务放回 controller。

`start` / `suspend` / `resume` / `stop` 必须幂等：折叠可执行态 start，展开前 suspend，收起完成 resume，关闭或换代 stop。context/monitor epoch 必须使旧 modifier release、mouseUp、timeout 和 poll 永久失效；视觉回调禁止 idle → idle。

默认在第一次 Control 松开后的 350ms 内再次按下并松开触发；支持其他修饰键、高级单击、禁用键盘和 button number ≥3 的原生侧键。从第一次按下到第二次松开之间出现普通键、其他修饰键、鼠标点击或滚轮即取消。

- `QuickTriggerModifierKeyPolicy` 必须按左右真实 keyCode 维护状态，禁止用可能夹带 Function/NumericPad 的聚合 flags 推断。
- 本地只监听 `.keyDown` / `.flagsChanged`；普通鼠标输入走共享 `GlobalMouseEventCoordinator` + HID 计数，禁止另建 Event Tap 或左键 NSEvent monitor。
- 键盘路径无需辅助功能权限；侧键录制/触发与左右键复制共享 CGEventTap，需要权限。
- CGEventTap 仅可在 `.tapDisabledByTimeout` 且权限仍有效时重新启用；`.tapDisabledByUserInput` 或权限失效必须保持禁用并异步回正手势开关，禁止无条件 `tapEnable(true)`。

**重映射工具限制**：Mac Mouse Fix 等工具可能在 CGEvent/AppKit/HID 计数之前吞掉原生侧键或“修饰键 + 滚轮”。关闭对应映射或保留原生事件即可；不要增加重复监听或 raw IOHID 绕过路径。

### 版本与更新

`VERSION` 是构建版本单一来源，`build.sh` 写入 Bundle 版本。只检查 GitHub 最新稳定 Release；成功检查每天最多一次、失败一小时后重试，更新入口打开 GitHub，不做应用内安装。标准 Toast 可显示更新入口，轻提醒不叠加提醒。

### 菜单栏

`MenuBarExtra` 使用 `Copied.svg` 模板图；`build.sh` 将白色填充转为黑色模板遮罩。暂停状态直接读 `UserDefaults`，版本项打开关于页；`LSUIElement = YES`。有新版本时，绿色 `arrow.up.circle.fill` 必须用 `Text(Image(...))` 内嵌在版本文字末尾；独立 `Image` 会被 `NSMenu` 强制提升到菜单项左侧并推移文字。

### 左右键快捷复制（CopyGestureManager）

设置 → 手势中开启，默认关闭。CGEventTap 监听 4 事件（leftDown/leftUp/rightDown/rightUp）。

- **rightMouseDown** → `isLeftPressed && !gestureFired`：吞掉 + 15ms ⌘C + `gestureFired=true`
- **rightMouseUp 兜底** → `isLeftPressed && !gestureFired`：rightMouseDown 被 WindowServer 静默吞掉时补触发
- `gestureFired` 每次 leftDown/leftUp 重置，防双击发
- ⌘C 模拟：CGEvent keyboard source 传 `nil`，完整发送 Command down → C down → C up → Command up，末次释放清空 flags

**权限 UX（三重保障）**：用户请求开启时保存意图 → 授权成功后醒目提示重启 → 启动时按真实权限恢复或回正为 OFF。仅有权限但未主动开启的用户保持关闭。签名：Apple Development，Team ID `683MU5Q6FB`（TCC 凭 Team ID 识别）。

**已知限制**：先松左键 → WindowServer 在 HID 层独立发 secondary-click popup → 源 App 弹右键菜单（session-level tap 无法拦截）。

## Bug 调试方法（强制）

**禁止猜测式修 bug。必须先加文件日志定位根因。**

1. **加文件日志**：写私有 logger 到 `FileManager.default.temporaryDirectory`，每条日志含「事件类型 + 当前状态 + 关键变量」。启动时清空。
2. **复现 + `cat` 读日志**：严格按步骤触发，对比正常/异常日志差异。
3. **确认根因后改码**：日志必须明确显示断点。不确定就加更多日志。
4. **修复后清理日志代码**。

**为什么不用 Console.app**：CGEventTap/NSEvent 每秒数百条，混在全系统日志中无法定位。文件日志只含关心的状态，一行一事。

## GitHub 推送规则（硬性）

**任何 git 操作前必须先调用 `git-push` skill。** 只改/只传 `Copied-mac/`，根 `README.md` 不可修改。

## 已知限制

- **窗口位置**：WindowServer 限制在屏幕边界内，无法超出 `screen.frame.maxY`
- **窗口动画裁切**：`showResultOverlay` 展开时右边缘短暂裁切（AppKit ↔ SwiftUI 时序错配）。缓解：0.25s 动画 + 2 行结果 + ZStack 交叉淡入淡出
- **无 Xcode 工程**：`swiftc` + `actool` + `codesign`，Xcode 26 供 `actool` 编译 Liquid Glass 图标
- **指纹**：覆盖 `SOURCES` + `RESOURCES` + `BUILD_FILES`。新增资源文件需 `rm .build/.source_fingerprint`
