# CLAUDE.md

## 构建与运行

```bash
./build.sh                     # swiftc + actool + codesign → .build/Copied.app
./create-dmg.sh                # → .build/Copied.dmg（可选 dmg_background.png 440×240）
open .build/Copied.app
```

需 macOS 14+。macOS 26+ 自动享受液态玻璃（`.glassEffect`），旧系统降级为毛玻璃材质。需 Xcode 26（供 `actool` 编译 Liquid Glass 图标）。

## 架构

```
CopiedApp.swift             MenuBarExtra + AppDelegate + Settings
ClipboardMonitor.swift      每 0.15s 轮询 NSPasteboard.changeCount（含黑名单过滤门）
CopyGestureManager.swift    CGEventTap 左+右 → ⌘C 手势（双路径 + R_UP 兜底）
DetectionRegistry.swift     全局检测器注册中心 + 优先级管道 + 限流
ContentKind.swift           统一类型标识（struct + 静态常量）
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
KeyboardShortcutSettings.swift  ShortcutModifier 枚举（快速触发修饰键配置）
ToastWindowController.swift 浮动 NSWindow + NSHostingView + Action + 可配置修饰键快速触发
ToastViewModel.swift        @Observable 模型（含 sourceBundleID）
ToastView.swift             SwiftUI 卡片 + glassEffect（macOS 26+）/ ultraThinMaterial（降级）+ 展开查看全文（if/else 双态）+ contextMenu
LightReminderController.swift 轻提醒模式浮标（NSWindow + NSHostingView + macOS 26+ drawOff / opacity 降级）
TypeSettingsView.swift      设置 → 智能识别 Tab（ContentKind 开关 + 插件管理）
SettingsView.swift           设置（开机启动/搜索引擎/快速触发修饰键/智能识别/手势/黑名单/轻提醒 Tab）
FilePreviewGenerator.swift  QLThumbnailGenerator 异步缩略图
SourceAppDetector.swift     NSWorkspace.frontmostApplication（含 bundleIdentifier）
build.sh                    swiftc + actool + codesign
```

UserDefaults 键：`searchEngine`, `launchAtLogin`, `isPaused`, `copyGestureEnabled`, `lightReminderEnabled`, `quickTriggerModifier`, `contentKindPriorities`, `disabledContentKinds`, `installedPlugins`, `popupFilterBlockedApps`。

**数据流**：`ClipboardMonitor` → `DetectionRegistry.detectAll()` → `SourceAppDetector.detect()` → `AppFilterSettings.shouldShowPopup()` 过滤门 → `ClipboardContent` → 分支：轻提醒模式 → `LightReminderController.show()`，标准模式 → `ToastWindowController.show()` → `ToastViewModel` → `ToastView`

**插件系统**：声明式（JSON + 正则，不执行代码）。插件目录 `~/Library/Application Support/Copied/Plugins/`，通过设置 → 智能识别手动安装。规则支持 `multiline`（默认 false）、`menuOnly`（强制进右键菜单）字段。无默认插件，不自动安装。性能熔断：>100KB 文本仅运行内置语言检测器（跳过插件与实体检测器）、>50ms 单检测器限流 30s、连续 3 次限流自动禁用。

### 轻提醒模式（LightReminderController）

菜单栏右键 / 设置页 Toggle 切换。开启后所有复制仅显示 24pt `checkmark.app.fill` 浮标（鼠标右上方 4pt），1s 自消，不弹完整 Toast。

**浮标实现**：`NSWindow`（borderless, `.floating`, `ignoresMouseEvents`）+ `NSHostingView<CheckmarkIcon>`。每次 `show()` 重建窗口（不复用），不跟踪鼠标移动。

**绘制入场动画（关键陷阱）**：`checkmark.app.fill` 不支持 `drawOn(isActive:)` 正向触发——Symbol 默认已处于 100% 绘制态，任何 `isActive` 切换都会解释为 100%→0%（反向擦除）。**解法**：用 `drawOff(isActive: !show)`，初始 `!show=true`（drawOff 活跃 → 符号不可见），`onAppear` 后 `show=true`（drawOff 不活跃 → 反向播放 → 效果等同 drawOn 正向绘制）。颜色用 `.symbolRenderingMode(.palette)` + `.foregroundStyle(.white, .blue)` 实现蓝底白勾。**pre-macOS 26 降级**：`drawOff` 仅 macOS 26+ 可用，旧系统用 `.opacity` 淡入替代。

## 关键设计决策

### 窗口（glassEffect / 降级）

**macOS 26+**：`.glassEffect(in: .rect(cornerRadius: cardCornerRadius))` — 液态玻璃。**pre-macOS 26**：ZStack 内 `RoundedRectangle.fill(.ultraThinMaterial)` + 0.08s 延迟淡入，避免 WindowServer 材质合成首帧灰色闪烁。统一常量 `cardCornerRadius: CGFloat = 32`。

非 key 浮动窗口的边缘高光被 WindowServer 抑制 → `.stroke(.primary.opacity(0.15))` 补偿（`.primary` 自适应亮/暗模式）。每次 `show()` 重建窗口（不复用）— 全屏 Space 长时间使用后复用窗口可能导致 `orderFront` 无效、toast 不出现。窗口配置见 `ToastWindowController.createWindow()`，动画参数见 `ToastView.swift`。

退场动画陷阱：`layerUsesCoreImageFilters = true` 必须设（AppKit 默认不启用）、`CIFilter.name` 必须匹配动画 keyPath、清理覆盖三条路径（动画回调 / `cancelDismiss()` / 非动画 dismiss）。

### 鼠标交互

SwiftUI `.onHover` + AppKit `NSEvent.addLocalMonitorForEvents(.leftMouseDown)`。borderless 浮动 `NSHostingView` 内 `.onTapGesture` 不可靠。`dismissGeneration` 防止过期的动画清理隐藏新 toast。交互状态在 controller 而非 ViewModel。

### 剪贴板检测

用 `pasteboard.types` 判断内容类别，不用 `readObjects`。缩略图策略：`QLThumbnailGenerator` 异步 + SF Symbol 降级。详见 `ClipboardMonitor.swift`。

### 内容类型检测（DetectionRegistry）

按优先级管道执行所有已注册检测器。检测器实现 `ContentDetectorProtocol`，返回 `ContentDetection?`。

性能熔断（硬边界）：
- **100KB 文本截断**：>100KB → 仅运行内置语言检测器（跳过插件与实体检测器）
- **50ms 单检测器超时**：累计 >50ms → 限流 30s
- **3 次限流自动禁用**：连续 ≥3 次 → 永久禁用 + 系统通知

### Action 系统

**内联更新模式**（`performsInlineUpdate = true`）：执行后弹窗保持显示，展示**结果覆盖层**（`ResultOverlay { displayText, copyText }`）。右侧按钮变为"复制"（`CopyTextAction`）。覆盖层 `\n` 拆分 VStack，每行 `.lineLimit(1)`，`ScrollView` + `.frame(maxHeight: 200)` 防止超长内容撑爆屏幕。

**词典查询**（`LookupAction`）：`DCSCopyTextDefinition` 查询 macOS 内置牛津中英词典，零配置。返回格式：行1 = `{word} 英 {pron}`，行2 = 中文释义（≤5 字 CJK，≤8 条）。检测器仅匹配单个 ASCII 单词，词典预查在 `ActionResolver.makeAction()` 中进行：有释义→显示"翻译"按钮，无释义→兜底搜索。**预查不能放检测器**（检测器在主线程有 50ms 超时熔断，词典首次加载会触发）。

**优先级**：首个非颜色检测 → 右侧按钮（最多 1 个）。其余 → 右键菜单。无检测 → 默认搜索。纯语言类型（如 swift）不产生按钮。各 Action 触发条件和行为见 `ClipboardAction.swift` 及各 `*Action.swift`。

**按钮背景**：`actionButtonBackground` 双路径——macOS 26+ `.glassEffect(.regular.interactive())` 原生液态玻璃，pre-26 `.fill(.quaternary)` 语义色。不再用 `.white.opacity()` 硬编码（浅色模式不可见）。

**按钮 hover 图标**：用 `ZStack` 叠加两个 SF Symbol + `opacity` 切换，不能用 `Image(systemName: condition ? "A" : "B")`——SF Symbol 宽度不同会导致按钮尺寸变化 → HStack 重排 → 左侧文本截断位置跳动。

### 开机自启

rebuild 后签名变化会使 macOS 清掉 `SMAppService` 登录项注册记录。启动时若 `launchAtLogin=true` 但 status ≠ `.enabled`，自动重新注册；注册失败则回写 UserDefaults 为 `false`。

### 展开查看全文（ToastView expand/collapse）

点击预览文本行 → `isExpanded = true` → 切换到 `ExpandedTextView` 布局：ZStack overlay（`.frame(width: 360)` 固定宽度），ScrollView（`.frame(maxHeight: 300)`）包含 Text（`.fixedSize(vertical: true)` 自然高度 + `.lineSpacing(4)` 行距 + `.padding(.bottom, 52)` 避让按钮栏），底部 HStack 按钮栏（`.background(.regularMaterial)` 毛玻璃）。短文本 ScrollView 收缩到内容高度无滚动，长文本 capped at 300pt 自动滚动。`updateWindowSize` 中含 340pt 安全上限。展开/收起通过 `updateWindowSize(animated: false)` 即时 resize + 全窗口 `CIGaussianBlur` + `alpha` 两段式过渡（blur out → 切换内容 → blur in，0.2s × 2）。

所有内容类型（文本/图片/文件/内联结果覆盖层）均可展开。`ToastViewModel.expandedText` 优先级：结果覆盖层 > 原文 > 文件名+路径。图片/文件不显示类型和格式标签。

**折叠态悬浮效果**：预览行和结果覆盖层均有悬浮变暗（`Color.primary.opacity(0.1)` 背景叠加 + 0.15s easeInOut），替代旧的 `.opacity(0.7)` 方案（浅色玻璃上不可见）。

**按钮栏空白区关闭**：展开态 `handleTap()` 检测点击距窗口底部 < 60pt 且 x 在 42%~78% 宽度（Spacer 区域）→ `DispatchQueue.main.async` 延迟 dismiss（给 SwiftUI 按钮 mouseUp 留时间），走 `dismissToast` 退场动画。

**⌘C 复制选中文本**：borderless 窗口非 key，系统 ⌘C 无法路由到 `.textSelection(.enabled)` 的 NSTextView。解法：`NSEvent.addLocalMonitorForEvents(.keyDown)` 拦截 ⌘C → `findTextView(in:)` 递归查找 view hierarchy 中的 NSTextView → 调用 `textView.copy(nil)`，只复制选中部分。

**Escape 收起**：独立 keyDown 监听器，keyCode 53 时触发 `handleCollapse()`。

**TextEdit 编辑**：`handleEditInTextEdit()` 写临时文件到 `NSTemporaryDirectory()`（UUID 文件名）→ `NSWorkspace.shared.open(url)` → 自动 dismiss toast。

**展开/收起过渡**：全窗口模糊淡入淡出——`handleExpand()`/`handleCollapse()` 先 blur(0→4) + alpha(1→0)，切换 `isExpanded` + `updateWindowSize`，再 blur(4→0) + alpha(0→1)。和 `dismissToast` 同一套 CIGaussianBlur + alpha 机制。`isExpandingOrCollapsing` 标志防重入。

### 点击处理

NSEvent 本地监听器 + SwiftUI Button 两层协作。异步延迟防 `dismissToast(animated:true)` 与 `cancelDismiss()` 竞争。`cancelDismiss()` 重置 `isDismissing=false`、递增 `dismissGeneration`、恢复 `alphaValue=1.0`。

### 快速触发（修饰键）

Toast 有主操作按钮（或结果覆盖层）时，按下并松开修饰键触发。修饰键可配置（设置 → 通用 → 快速触发），默认 ⌘，支持 ⌥/⌃/⇧。`ShortcutModifier` 枚举提供 `nseventFlags`、`sfSymbolName`、`displayName`，从 UserDefaults `quickTriggerModifier` 读取。按钮 hover 时动态显示对应 SF Symbol 图标（`viewModel.triggerModifierIcon`）。

**三层防御**，无需 Accessibility 权限（仅用 `addGlobalMonitorForEvents(.flagsChanged)`）：

1. **`NSEvent.addLocalMonitorForEvents`** — 捕获修饰键+key 组合键。修饰键按住期间任何按键/鼠标事件 → `modifierCancelledByOtherEvent = true`。
2. **`CGEventSource.counterForEventType(.hidSystemState, .keyDown)`** — HID 级计数器，runloop 延迟对比。未变 → 触发；变化 → 中止。
3. **`dismissGeneration` 守卫** — 防止过期修饰键释放触发新 toast 的 Action。

**转换检测**：`modifierCancelledByOtherEvent` 仅在修饰键从未按下→按下转换时重置，不在每次 `flagsChanged` 重置。

**变量命名**（2026-07-12 泛化重命名）：`isCommandPressed` → `isTriggerModifierPressed`、`localCmdMonitor` → `localTriggerModifierMonitor`、`cmdKeyDownCount` → `modifierKeyDownCount`、`cmdIsPreExisting` → `modifierIsPreExisting`、`cmdCancelledByOtherEvent` → `modifierCancelledByOtherEvent`。

**死路（勿重试）**：
- `addGlobalMonitorForEvents(.keyDown)` — macOS 过滤修饰键组合键，需要 Accessibility 权限
- `CGEvent.tapCreate` 用于快速触发 — 过度复杂
- 时序推断 — 不可靠

### 菜单栏

`MenuBarExtra` + `Copied.svg` 模板图像。`build.sh` 将 `fill="white"` 替换为 `fill="black"` 做模板遮罩。暂停/恢复直接读 `UserDefaults`（避免绑定传播复杂度）。`Info.plist` 设 `LSUIElement = YES`。

### 左右键快捷复制（CopyGestureManager）

设置 → 手势中开启，默认关闭。CGEventTap 监听 4 事件（leftDown/leftUp/rightDown/rightUp）。

- **rightMouseDown** → `isLeftPressed && !gestureFired`：吞掉 + 15ms ⌘C + `gestureFired=true`
- **rightMouseUp 兜底** → `isLeftPressed && !gestureFired`：rightMouseDown 被 WindowServer 静默吞掉时补触发
- `gestureFired` 每次 leftDown/leftUp 重置，防双击发
- ⌘C 模拟：CGEvent keyboard source 传 `nil`，仅发 C 键 + `.maskCommand`

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

- **边缘高光**：非 key 浮动窗口被 WindowServer 抑制 → `.stroke(.primary.opacity(0.15))` 补偿
- **窗口位置**：WindowServer 限制在屏幕边界内，无法超出 `screen.frame.maxY`
- **窗口动画裁切**：`showResultOverlay` 展开时右边缘短暂裁切（AppKit ↔ SwiftUI 时序错配）。缓解：0.25s 动画 + 2 行结果 + ZStack 交叉淡入淡出
- **macOS 版本兼容**：部署目标 14.0。`.glassEffect()` 和 `.symbolEffect(.drawOff)` 仅 macOS 26+；旧系统自动降级为 `.ultraThinMaterial` / `.opacity` 淡入
- **无 Xcode 工程**：`swiftc` + `actool` + `codesign`，Xcode 26 供 `actool` 编译 Liquid Glass 图标
- **词典查询**：仅支持单个单词（DCSCopyTextDefinition API 限制）
- **右键手势先松左键**：WindowServer HID 层 popup → 源 App 弹右键菜单（session tap 无法拦截）。CopyGestureManager 通过 rightMouseUp 兜底保证后续手势可靠触发
- **指纹**：覆盖 `SOURCES` + `RESOURCES` + `BUILD_FILES`。新增资源文件需 `rm .build/.source_fingerprint`
