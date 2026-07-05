# CLAUDE.md

## 构建与运行

```bash
./build.sh                     # swiftc + actool + codesign → .build/Copied.app
./create-dmg.sh                # → .build/Copied.dmg（可选 dmg_background.png 440×240）
open .build/Copied.app
```

需 macOS 26+ 及 Xcode 26（供 `actool`）。无 Xcode 工程，纯 `swiftc` 编译。

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
AppFilterSettings.swift     应用黑名单单例 — 过滤判断 + 持久化
AppFilterView.swift         设置 → 黑名单 Tab（列表管理 + 运行中应用选择器）
BlacklistSourceAppAction.swift  右键"屏蔽此来源" Action
ClipboardAction.swift       Action 协议 + 内置 Action + ActionResolver
ToastWindowController.swift 浮动 NSWindow + NSHostingView + Action
ToastViewModel.swift        @Observable 模型（含 sourceBundleID）
ToastView.swift             SwiftUI 卡片 + glassEffect + ZStack 图标防抖 + contextMenu
TypeSettingsView.swift      设置 → 智能识别 Tab（ContentKind 开关 + 插件管理）
SettingsView.swift           设置（开机启动/搜索引擎/智能识别/手势/黑名单 Tab）
FilePreviewGenerator.swift  QLThumbnailGenerator 异步缩略图
SourceAppDetector.swift     NSWorkspace.frontmostApplication（含 bundleIdentifier）
build.sh                    swiftc + actool + codesign
```

UserDefaults 键：`searchEngine`, `launchAtLogin`, `isPaused`, `copyGestureEnabled`, `contentKindPriorities`, `disabledContentKinds`, `installedPlugins`, `popupFilterBlockedApps`。

**数据流**：`ClipboardMonitor` → `DetectionRegistry.detectAll()` → `SourceAppDetector.detect()` → `AppFilterSettings.shouldShowPopup()` 过滤门 → `ClipboardContent` → `ToastWindowController.show()` → `ToastViewModel` → `ToastView`（glassEffect + 缩略图 + 按钮 + contextMenu）

**插件系统**：声明式（JSON + 正则，不执行代码）。性能熔断：>100KB 文本截断、>50ms 单检测器限流 30s、连续 3 次限流自动禁用。

## 关键设计决策

### 窗口（glassEffect）

非 key 浮动窗口的边缘高光被 WindowServer 抑制 → `.stroke(.white.opacity(0.25))` 补偿。每次 `show()` 重建窗口（不复用）— 全屏 Space 长时间使用后复用窗口可能导致 `orderFront` 无效、toast 不出现。窗口配置见 `ToastWindowController.createWindow()`，动画参数见 `ToastView.swift`。

退场动画陷阱：`layerUsesCoreImageFilters = true` 必须设（AppKit 默认不启用）、`CIFilter.name` 必须匹配动画 keyPath、清理覆盖三条路径（动画回调 / `cancelDismiss()` / 非动画 dismiss）。

### 鼠标交互

SwiftUI `.onHover` + AppKit `NSEvent.addLocalMonitorForEvents(.leftMouseDown)`。borderless 浮动 `NSHostingView` 内 `.onTapGesture` 不可靠。`dismissGeneration` 防止过期的动画清理隐藏新 toast。交互状态在 controller 而非 ViewModel。

### 剪贴板检测

用 `pasteboard.types` 判断内容类别，不用 `readObjects`。缩略图策略：`QLThumbnailGenerator` 异步 + SF Symbol 降级。详见 `ClipboardMonitor.swift`。

### 内容类型检测（DetectionRegistry）

按优先级管道执行所有已注册检测器。检测器实现 `ContentDetectorProtocol`，返回 `ContentDetection?`。

性能熔断（硬边界）：
- **100KB 文本截断**：>100KB → 仅运行内置检测器（跳过插件）
- **50ms 单检测器超时**：累计 >50ms → 限流 30s
- **3 次限流自动禁用**：连续 ≥3 次 → 永久禁用 + 系统通知

### Action 系统

**内联更新模式**（`performsInlineUpdate = true`）：执行后弹窗保持显示，展示**结果覆盖层**（`ResultOverlay { displayText, copyText }`）。右侧按钮变为"复制"（`CopyTextAction`）。覆盖层 `\n` 拆分 VStack，每行 `.lineLimit(1)`。

**词典查询**（`LookupAction`）：`DCSCopyTextDefinition` 查询 macOS 内置牛津中英词典，零配置。返回格式：行1 = `{word} 英 {pron}`，行2 = 中文释义（≤5 字 CJK，≤8 条）。检测器仅匹配单个 ASCII 单词，词典预查在 `ActionResolver.makeAction()` 中进行：有释义→显示"翻译"按钮，无释义→兜底搜索。**预查不能放检测器**（检测器在主线程有 50ms 超时熔断，词典首次加载会触发）。

**优先级**：首个非颜色检测 → 右侧按钮（最多 1 个）。其余 → 右键菜单。无检测 → 默认搜索。纯语言类型（如 swift）不产生按钮。各 Action 触发条件和行为见 `ClipboardAction.swift` 及各 `*Action.swift`。

**按钮 hover 图标**：用 `ZStack` 叠加两个 SF Symbol + `opacity` 切换，不能用 `Image(systemName: condition ? "A" : "B")`——SF Symbol 宽度不同会导致按钮尺寸变化 → HStack 重排 → 左侧文本截断位置跳动。

### 点击处理

NSEvent 本地监听器 + SwiftUI Button 两层协作。异步延迟防 `dismissToast(animated:true)` 与 `cancelDismiss()` 竞争。`cancelDismiss()` 重置 `isDismissing=false`、递增 `dismissGeneration`、恢复 `alphaValue=1.0`。

### ⌘ 键快速触发

Toast 有主操作按钮（或结果覆盖层）时，按下并松开 ⌘ 触发。**三层防御**，无需 Accessibility 权限：

1. **`NSEvent.addLocalMonitorForEvents`** — 捕获 ⌘+key 组合键。⌘ 按住期间任何按键/鼠标事件 → `cmdCancelledByOtherEvent = true`。
2. **`CGEventSource.counterForEventType(.hidSystemState, .keyDown)`** — HID 级计数器，runloop 延迟对比。未变 → 触发；变化 → 中止。
3. **`dismissGeneration` 守卫** — 防止过期 ⌘ 释放触发新 toast 的 Action。

**转换检测**：`cmdCancelledByOtherEvent` 仅在 ⌘ 从未按下→按下转换时重置，不在每次 `flagsChanged` 重置。

**死路（勿重试）**：
- `addGlobalMonitorForEvents` — macOS 过滤 ⌘ 组合键
- `CGEvent.tapCreate` 用于 ⌘ 检测 — 过度复杂
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

- **边缘高光**：非 key 浮动窗口被 WindowServer 抑制 → `.stroke(.white.opacity(0.25))` 补偿
- **窗口位置**：WindowServer 限制在屏幕边界内，无法超出 `screen.frame.maxY`
- **窗口动画裁切**：`showResultOverlay` 展开时右边缘短暂裁切（AppKit ↔ SwiftUI 时序错配）。缓解：0.25s 动画 + 2 行结果 + ZStack 交叉淡入淡出
- **仅限 macOS 26+**：`.glassEffect()` 需 macOS 26
- **无 Xcode 工程**：`swiftc` + `actool` + `codesign`，Xcode 26 供 `actool`
- **词典查询**：仅支持单个单词（DCSCopyTextDefinition API 限制）
- **右键手势先松左键**：WindowServer HID 层 popup → 源 App 弹右键菜单（session tap 无法拦截）。CopyGestureManager 通过 rightMouseUp 兜底保证后续手势可靠触发
- **指纹**：覆盖 `SOURCES` + `RESOURCES` + `BUILD_FILES`。新增资源文件需 `rm .build/.source_fingerprint`
