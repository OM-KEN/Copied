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
CopiedApp.swift             MenuBarExtra + reopen 设置桥接 + AppDelegate + Settings
ApplicationRelauncher.swift 授权完成后的非激活新实例启动 + 旧实例退出
ClipboardMonitor.swift      启动首响应 0.025s、首次有效读取/同一不可读写入 3 次/60s 后 0.075s 轮询（含黑名单过滤门）
ClipboardContentEnrichment.swift  后台补齐文件/图片信息 + 文件夹/包体大小数值进度
LitheIntegration.swift      Lithe Bundle/剪贴板契约 + 图片文件资格判断 + 非激活打开
ClipboardTextPolicy.swift   长文本阈值与纯文本主操作策略
PopupPresentationSettings.swift  默认/轻打扰模式偏好 + 内容映射 + 视觉呈现策略
PopupFilterSettingsView.swift    轻打扰自定义窗口（普通内容 + 识别类型）
CopySoundFeedback.swift     复制系统声音选择、默认值与异步串行播放
GlobalMouseEventCoordinator.swift  共享 CGEventTap + 系统设置暂停 + 权限失效保护
CopyGestureManager.swift    左+右 → ⌘C 手势（双路径 + R_UP 兜底）
DetectionRegistry.swift     全局检测器注册中心 + 优先级管道 + 限流
EntityDetectorWarmUp.swift  URL/电话/日期实体检测器的固定合成候选预热
MathExpressionEvaluator.swift  公式统一词法/解析 + Decimal 求值 + 精确/近似格式化
ContentKind.swift           统一类型标识（struct + 静态常量）
AppLanguage.swift           当前 Bundle 界面语言策略（英文环境过滤英文单词检测）
Detectors/                  15 个内置检测器（详见目录）
DictionaryLookupService.swift  DCSCopyTextDefinition 词典查询 + 启动异步预热
PluginLoader.swift          扫描/校验/加载 .copiedplugin 文件夹
PluginManifest.swift        插件清单 + Rule 模型 + CompiledRule
PluginAction.swift          插件动作执行（openURL/search/transform）
PluginActionTemplate.swift  插件动作模板（menuOnly/multiline 配置）
PluginRuntimeSafety.swift   插件目录/卸载约束 + 有界正则执行
AppFilterSettings.swift     应用黑名单单例 — 过滤判断 + 持久化
AppFilterView.swift         设置 → 黑名单 Tab（列表管理 + 运行中应用选择器）
BlacklistSourceAppAction.swift  右键"屏蔽此来源" Action
ClipboardAction.swift       Action 协议 + 内置 Action + ActionResolver
KeyboardShortcutSettings.swift  快速触发修饰键、双击/单击模式、侧键配置
QuickTriggerModifierKeyPolicy.swift  按实际 keyCode 维护左右修饰键状态
QuickTriggerCoordinator.swift  键盘/侧键快速触发监听、生命周期与上下文守卫
MouseButtonRecordingStateMachine.swift  侧键录制状态与取消/绑定决策
AppUpdateService.swift      GitHub Releases 检查、缓存、节流与提醒状态
FeedbackSupport.swift       问题反馈邮件模板、安全环境信息 + GitHub Issue 入口
ToastPanel.swift            nonactivating NSPanel + first-mouse hosting + 原生展开文本
ToastCommand.swift          弹窗内部命令 + 同步防重入分发
ToastWindowController.swift ToastPanel + Action + 展开文本分层 + 快速触发 Context/Command 路由
ToastViewModel.swift        @Observable 模型（含 sourceBundleID）
RelativeDateDescription.swift 日期/时间详情格式化（日历日语义 + 本地化时间）
ToastView.swift             SwiftUI 卡片 + glassEffect（macOS 26+）/ ultraThinMaterial（降级）+ 展开查看全文（if/else 双态）+ contextMenu
MetadataAutoScrollMetrics.swift 标签溢出距离、速度、时长与边缘渐隐参数
LightReminderController.swift 仅提醒模式浮标（NSWindow + NSHostingView + macOS 26+ drawOff / opacity 降级）
TypeSettingsView.swift      设置 → 智能识别 Tab（ContentKind 开关 + 插件管理）
SettingsView.swift           设置（弹窗模式/声音/开机启动/搜索引擎/快速触发/高级仅提醒/智能识别/手势/黑名单 + 底部退出入口）
FilePreviewGenerator.swift  QLThumbnailGenerator 异步缩略图
SourceAppDetector.swift     NSWorkspace.frontmostApplication（含 bundleIdentifier + App 图标缓存/预取）
Localizable.xcstrings       String Catalog（zh-Hans 源语言 + en / zh-Hant）
build.sh                    swiftc + xcstringstool + actool + codesign
run-tests.sh                统一运行现有与弹窗交互测试
```

UserDefaults 键：`searchEngine`, `launchAtLogin`, `isPaused`, `copyGestureEnabled`, `lightReminderEnabled`, `copyFeedbackSound`, `popupPresentationMode`, `popupShowShortPlainText`, `popupShowLongPlainText`, `popupShowImages`, `popupShowFiles`, `popupDisabledKindIDs`, `keyboardQuickTriggerModifier`, `keyboardQuickTriggerMode`, `mouseQuickTriggerButton`, `automaticUpdateRemindersEnabled`, `contentKindPriorities`, `disabledContentKinds`, `installedPlugins`, `popupFilterBlockedApps`。

**数据流**：`ClipboardMonitor` → `DetectionRegistry.detectAll()` → `SourceAppDetector.detect()` → `AppFilterSettings.shouldShowPopup()` 来源过滤门 → `CopySoundFeedback` 投递异步播放 → `PopupPresentationPolicy.shouldPresent()` 视觉筛选门 → 视觉去重 → 分支：仅提醒模式 → `LightReminderController.show()`，完整卡片 → `ToastWindowController.show()` → `ToastViewModel` → `ToastView`

**启动首响应预热**：App 必须先由 `ClipboardMonitor.start()` 捕获当前 `changeCount`，再以固定合成内容预热实体检测、完整检测管道和前台 App 图标，最后通过标准 `ToastPanel` 的生产布局、`orderFront` 与入场动画显示一次 1s“Copied 已启动”。启动提示不得读取或写入剪贴板、播放声音、参与视觉去重、解析 Action、启用快速触发或显示来源/详情/右键菜单；真实复制到达时必须递增 `dismissGeneration` 并立即重建窗口替换，旧定时器和退场回调不得关闭新 Toast。

**Lithe 图片压缩**：仅当剪贴板文件全部为本地普通 JPG/JPEG/PNG、Launch Services 能定位 `com.lithe.app`，且内容不带 Lithe 生成标记时，`ActionResolver` 才把“压缩”设为主操作并同时加入右键菜单。纯位图、混合或不支持的文件选择不触发；Lithe 回写 `com.lithe.generated-files` 与 `com.lithe.request-id`，Copied 用前者阻止压缩回环、用后者区分不同请求的视觉去重。打开 Lithe 时不得激活 App 或写入最近项目。

复制声音默认 Frog，固定使用 `AVAudioPlayer` 的 0.5 音量；设置试听与实际复制共用专用串行队列，声音文件的载入、停止和播放均不阻塞主线程，可选择其他系统声音或 `none`。声音在来源过滤后、视觉去重前投递；每个 revision 由门控最多投递一次，成功读取、连续 3 次不可读或硬超时的首个终态均提供听觉确认，因此 500ms 内重复复制相同内容仍会逐次发声；暂停和黑名单来源无声。

**插件系统**：声明式 JSON + 正则，不执行代码。目录为 `~/Library/Application Support/Copied/Plugins/`，只从设置手动安装；规则支持 `multiline`、`menuOnly`，无默认插件。只扫描插件根目录的直接 `.copiedplugin` 子目录，拒绝目录符号链接和不安全 identifier。卸载必须枚举根目录内的安全插件目录、读取 manifest 并精确匹配 identifier，再删除实际目录；禁止根据 identifier 拼接删除路径。通用检测熔断由 `DetectionRegistry` 管理，插件正则另由 `PluginRuntimeSafety` 主动限制。插件 manifest 的空 `label` 或空 `icon` 表示“不覆盖该展示字段”；分析 enrichment 必须分别保留 base content 已有的类型标签和图标，禁止用空字符串清掉基础视觉。

### 轻打扰模式（PopupPresentationPolicy）

菜单栏“轻打扰模式”和设置 → 通用 → 复制反馈的弹窗模式共用 `popupPresentationMode`；选择轻打扰后，通过独立标准窗口自定义普通短文本、普通长文本、图片、文件和每个可用 `ContentKind`。自定义类型开关只写 `popupDisabledKindIDs`，不得改写 `disabledContentKinds` 或关闭实际检测。

文本策略必须先区分是否存在 `primaryKindID`：URL、代码、插件等已识别文本只受对应类型开关控制，完全忽略普通文本长度开关；仅未识别文本按 `ClipboardTextPolicy.longTextThreshold` 的 49/50 边界分别读取普通短/长文本开关。颜色三种内部 ID 统一映射到 `colorHex`。默认模式无条件放行这些视觉筛选。

纯位图直接映射为图片；文件 URL 只有在集合非空且每个条目都是受支持扩展名的本地普通文件时才映射为图片，否则映射为文件。轻打扰筛选位于声音之后、视觉去重之前；被筛掉的内容不得更新 `lastHash` / `lastShowTime`，否则下一次允许显示的相同内容会被误吞。

插件只有在功能确实适用于输入时才能把普通文本提升为识别类型。示例“去除空行”必须检测到实际空行或仅含空白的行，不能把“任意包含换行的文本”视为命中。

### 仅提醒模式（LightReminderController）

设置 → 通用最底部“高级”中的“仅提醒模式”与轻打扰筛选正交：开启后，只把已经通过视觉筛选的完整卡片替换为鼠标右上方 24pt `checkmark.app.fill` 浮标，1s 自消。使用忽略鼠标的 borderless floating `NSWindow` + `NSHostingView`，每次 `show()` 重建。

**绘制动画陷阱**：Symbol 默认已是完整绘制态，`drawOn(isActive:)` 会反向擦除。必须用 `drawOff(isActive: !show)`：初始 `show=false` 隐藏，`onAppear` 后切为 true 反向播放；palette 使用白勾蓝底。macOS 26 以下改用 `.opacity` 淡入。

## 关键设计决策

### 窗口（glassEffect / 降级）

macOS 26+ 用 `.glassEffect(in: .rect(cornerRadius: cardCornerRadius))`；旧系统用 `.ultraThinMaterial` + 0.08s 延迟淡入，避免首帧灰闪。圆角统一为 32pt。

标准弹窗必须使用 `ToastPanel`：`NSPanel + .borderless + .nonactivatingPanel`，`canBecomeKey=true`、`canBecomeMain=false`、`becomesKeyOnlyIfNeeded=true`、`isFloatingPanel=true`、`hidesOnDeactivate=false`。折叠态 SwiftUI 控件位于 `needsPanelToBecomeKey=false` 的 first-mouse hosting 中，点击不得激活 Copied 或让 Panel 成为 key；用户主动展开后 Panel 默认成为 key，原生正文成为 first responder。

非 key 窗口用 `.stroke(.primary.opacity(0.15))` 补偿边缘高光。每次 `show()` 必须重建窗口；复用窗口在全屏 Space 长时间运行后可能无法 `orderFront`。

退场动画必须启用 `layerUsesCoreImageFilters`，让 `CIFilter.name` 匹配 keyPath，并覆盖动画回调、`cancelDismiss()`、非动画 dismiss 三条清理路径。已显示的缩略图必须保留到窗口 `orderOut` 后再清空；旧退场回调仍由 `dismissGeneration` 拦截，禁止清掉新 Toast 的缩略图。

### 鼠标交互

SwiftUI `Button` 是鼠标 `ToastCommand` 的唯一来源；禁止恢复窗口级左右键 monitor、hover 业务命中、手写矩形或百分比坐标分流。预览按钮发送 `.expand`，右侧按钮发送 `.performPrimary`，整卡背景按钮发送 `.dismiss`；折叠态为动画和防裁切保留的透明 padding 也必须由 SwiftUI `Button` 发送 `.dismiss`。图标和来源信息用 `allowsHitTesting(false)` 穿透到背景关闭，右侧按钮 label 必须用矩形 `contentShape` 覆盖完整视觉区域。hover 只负责视觉状态和暂停自动关闭。

本地 NSEvent monitor 只保留快速触发所需的 `.keyDown` / `.flagsChanged`；订阅 `.leftMouseDown` 会让 nonactivating Panel 只收到 mouseUp，破坏 SwiftUI 原生点击链。`dismissGeneration` 继续防止过期动画清理隐藏新 toast。

来源与详情标签各自使用独立的单行自动滚动区域，自然宽度必须参与卡片 fitting，卡片总宽仍以 360pt 为上限。仅有真实溢出时显示方向随位置变化的 14pt 边缘渐隐；卡片悬停 0.6s 后单次匀速滚到末端、停留并返回，移出复位。标签始终 `allowsHitTesting(false)`，禁止用 `ScrollView`、点击手势或鼠标坐标命中实现。

### 剪贴板检测

启动后先每 25ms 检查一次 `NSPasteboard.changeCount`，首次有效读取、同一不可读写入尝试 3 次或 60s 后恢复 75ms；有限重试可避免来源 App 首次分阶段写入时被永久跳过。不要在没有端到端 CPU 与延迟测量时继续缩短。用 `pasteboard.types` 判断内容类别，不用 `readObjects`。缩略图策略：`QLThumbnailGenerator` 异步 + SF Symbol 降级。详见 `ClipboardMonitor.swift`。

默认模式或轻打扰的全允许路径必须在观察到新 `changeCount` 后同步 `showPending`，再提交任何剪贴板正文读取；base、enrichment 与 Action 到达后按固有内容重新 fitting，禁止用固定整卡/普通图标/短按钮宽高掩盖异步尺寸变化。Action 更新不得紧接一次无内容变化的 `applyEnrichment`，也不得通过共享动态 `.id` 重建交互按钮。连续 3 次仍不可读时显示普通“已复制”+ `checkmark.circle.fill`，并复用 3 秒 `displayDuration`，不显示错误长文案。

文件夹和无法直接取得大小的包文件使用后台有界遍历：首条详情立即显示数值下界，之后最多每 250ms 且仅在格式化值变化时更新；最终精确值或“至少”下界立即发布并关闭 loading。`ProgressView` 只在 loading 时位于数值右侧，完成后不得保留固定空槽；当前 macOS 的不定进度环在深色玻璃卡片上仍可能按黑色绘制，深色外观只对该原生控件应用 `colorInvert()`，浅色外观保留系统原样；文件软截止到达时保留最后数值下界并移除 loading，不得覆盖成“文件信息不可用”。

生产诊断日志不得写入 `ClipboardContent.preview`、`rawText` 或其他剪贴板正文；只记录内容类型、计数和非敏感状态。需要内容级复现时使用明确的合成测试数据。

### 内容类型检测（DetectionRegistry）

按优先级管道执行所有已注册检测器。检测器实现 `ContentDetectorProtocol`，返回 `ContentDetection?`。

性能熔断（分层边界）：
- **实体候选预检**：无 scheme URL 最多 2,048 UTF-16 单元；电话和数字日期/时间最多 256；无数字自然语言日期最多 64。超出边界或结构明显不符时，不进入 `NSDataDetector`
- **100KB 文本截断**：>100KB → 仅运行内置语言检测器（跳过插件与实体检测器）
- **50ms 单检测器计时**：`DetectionRegistry` 在检测器返回后统计耗时；累计 >50ms → 限流 30s，该层不负责中断当前调用
- **50ms 插件正则预算**：一个 `PluginDetector` 的全部规则共享同一预算，transform 单独使用同一预算；通过正则进度回调主动停止，并限制最多 10,000 个匹配、1,000,000 UTF-16 单元输出，超限时不返回部分结果
- **3 次限流自动禁用**：连续 ≥3 次 → 永久禁用 + 系统通知

### 公式计算

`MathExpressionDetector` 与 `CalculateAction` 必须共用 `MathExpressionEvaluator`，禁止恢复 `NSExpression` 或检测/执行两套解析路径。求值使用有复杂度边界的严格解析器和 `Decimal`：精确加减乘先计算十进制系数并验证 `Decimal` 无损往返；循环小数除法携带绝对误差界，只有整个误差区间得到相同的最终显示值时才以 `≈` 返回。分数指数以及近似值继续参与乘、除、幂会被拒绝，禁止用无误差界的 `Double` 回退。界面值与复制值必须来自同一次舍入，复制文本固定使用 POSIX 小数点且不含分组符；无效表达式、除零、超界或不稳定结果不提供复制按钮和快速触发。

### 本地化

`Localizable.xcstrings` 以 `zh-Hans` 为源语言，支持 `en` / `zh-Hant`。App 只跟随系统或单 App 语言，不增加语言 UserDefaults/切换器；生成后的内置文案用 `String(localized:)`，剪贴板内容、插件文案、文件名和 App 名保持原文。

`AppLanguage.isContentKindAvailable(_:)` 是语言检测策略唯一入口：英文界面同时隐藏并跳过 `englishPhrase`，且不改写 `disabledContentKinds`；其他检测保持可用。输入识别不得依赖界面 Locale，中文年月日先转 ISO 候选再交给 `NSDataDetector`。

日期 `metadata["subtype"]` 必须按原文区分 `date` / `dateTime` / `time`，禁止从会补齐字段的 `DateComponents` 推断。`RelativeDateDescription` 对日期按 `Calendar.startOfDay` 生成日历日描述；日期时间附短时间，仅时间按真实时差。

### Action 系统

**内联更新**（`performsInlineUpdate = true`）：Action 后保留弹窗并显示 `ResultOverlay { displayText, copyText? }`；只有 `copyText` 非空时主按钮和快速触发才改为 `CopyTextAction`，错误结果不提供复制入口。结果逐行 `.lineLimit(1)`，滚动区上限 200pt。

**词典查询**：`LookupAction` 使用 `DCSCopyTextDefinition`。App 启动时只用固定合成词 `example` 在后台预热一次；预热与真实查询共用串行队列，预热失败不重试且不记录输入。预查只能在 `ActionResolver.makeAction()`，有释义显示翻译、无释义回退搜索；禁止放进受 50ms 熔断约束的检测器。

**优先级**：符合条件的 Lithe 图片文件优先占右侧唯一按钮并同时进入右键菜单；否则首个非颜色检测占按钮，其余进右键菜单。无检测时短文本默认搜索、长文本默认另存为，纯语言类型不产生按钮。规则以 `ClipboardAction.swift` 和各 `*Action.swift` 为准。

**视觉约束**：按钮背景在 macOS 26+ 用 `.glassEffect(.regular.interactive())`，旧系统用 `.fill(.quaternary)`；禁止硬编码白色。hover 图标必须以 `ZStack` + `opacity` 切换，条件替换不同宽度的 SF Symbol 会触发 HStack 重排和文本跳动。

### 开机自启

rebuild 后签名变化会使 macOS 清掉 `SMAppService` 登录项注册记录。启动时若 `launchAtLogin=true` 但 status ≠ `.enabled`，自动重新注册；注册失败则回写 UserDefaults 为 `false`。

### 展开查看全文（ToastView expand/collapse）

`ExpandedTextView` 固定宽 360、总高最多 300pt；主 host 只预留几何空间，controller 分层安装原生 `NSTextView/NSScrollView` 和独立按钮 host。正文视口必须从卡片顶边开始、在底栏上方结束；顶部两角按 `cardCornerRadius - horizontalInset` 裁切以贴合卡片外轮廓，但不得重新引入顶部位置偏移。`CALayer.isGeometryFlipped=true` 时视觉顶部对应 `minY` 两角，非 flipped 时对应 `maxY` 两角。初始 12pt 顶距放进可滚动正文的 `textContainerInset`，文档高度取 `NSLayoutManager.usedRect` 再加顶部 12pt 与底部 10pt。底栏高 54pt、左右内边距 16pt，两端按钮圆角 8pt，`updateWindowSize` 上限 340pt；`expandedText` 优先级为结果覆盖层 > 原文 > 文件名+路径。

超过 2,048 UTF-16 单元的展开文本禁止在点击路径同步执行全文 `boundingRect`：几何层先直接预留 300pt 最大高度，经原有展开过渡显示原生 loading 和“正在准备预览…”，再在下一次主队列调度中安装并布局 `NSTextView`。loading 只在原生正文布局完成后结束；期间正文 surface 隐藏、底栏全部禁用，展开/收起/关闭和新 Toast 必须通过 generation 状态使过期任务失效。同一展开文本的原生文档高度需要缓存，收起后再次展开不得重复布局；Reduce Motion 下保留 loading 文案但隐藏旋转动画，深色外观的系统进度环保持可读。

展开态在 `NSPanel` 左右和底部额外保留 16pt 透明阴影边界；顶部不留边界，以免 WindowServer 将窗口约束到屏幕顶边后让展开卡片下移。SwiftUI hosting 保持原尺寸并整体内移，原生正文与底栏继续通过 hosting 坐标换算同步定位，禁止在 SwiftUI 根视图上加 padding 代替窗口边界。

展开期间暂停全部快速触发。展开完成后 Panel 默认成为 key、原生正文成为 first responder，并通过 responder chain 支持拖选、⌘C 和右键菜单；收起时主动 resign key。底栏按钮保持 non-key、无独立背景，不强制 Liquid Glass；普通预览左侧使用纯文字“在文本编辑中打开”的原生 bordered 按钮，预览被截断时只把同一位置改为纯文字“在文本编辑中查看全部”的 bordered prominent 按钮，不添加图标或独立“预览已截断”提示。空白区域不响应点击，右下角提供明确的关闭按钮，禁止坐标命中，Escape 无操作。TextEdit 使用 UUID 临时文件、防重入并接收未截断全文。

展开期间不得启动自动关闭计时器；鼠标移出后保持展开，只有手动关闭、收起或打开 TextEdit 才结束展开态。收起完成后必须按窗口几何位置同步计时器：指针仍在折叠卡片内则保持暂停，已移出才重新开始 3 秒计时；不得依赖视图切换期间可能失效的 hover 回调。

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
- System Settings 成为前台时，`GlobalMouseEventCoordinator` 必须保留逻辑 listener、提前销毁活动过滤 Tap；离开后仅在权限仍有效时重建，否则走统一失效通知。禁止在用户撤销辅助功能权限时继续把活动 Tap 留在系统鼠标事件链中。

**重映射工具限制**：Mac Mouse Fix 等工具可能在 CGEvent/AppKit/HID 计数之前吞掉原生侧键或“修饰键 + 滚轮”。关闭对应映射或保留原生事件即可；不要增加重复监听或 raw IOHID 绕过路径。

### 版本与更新

`VERSION` 是构建版本单一来源，`build.sh` 写入 Bundle 版本。只检查 GitHub 最新稳定 Release；成功检查每天最多一次、失败一小时后重试，更新入口打开 GitHub，不做应用内安装。完整卡片可显示更新入口，仅提醒浮标不叠加更新提醒。

GitHub Release 的 DMG 资产名固定为 `Copied-<VERSION>.dmg`，版本前不带 `v`（例如 `Copied-3.3.0.dmg`）。`create-dmg.sh` 可继续生成 `.build/Copied.dmg`，但发布流程必须在上传前按 `VERSION` 改名，并通过 Release API 核对资产名、大小和 SHA-256。

### 问题反馈

设置 → 关于的“问题反馈”先让用户选择邮件或 GitHub Issue。邮件交给默认邮件 App，收件人为 `omken.feedback@gmail.com`，只预填 Copied 版本、macOS 版本和芯片架构；禁止读取或附带剪贴板内容、文件路径、用户设置、日志、设备名称或其他私人数据。GitHub 打开仓库的 Issue 模板选择页。两种渠道均不得由 Copied 自动提交，必须保留用户检查与确认步骤。

### 菜单栏

`MenuBarExtra` 使用 `Copied.svg` 模板图；`build.sh` 将白色填充转为黑色模板遮罩。暂停状态直接读 `UserDefaults`，版本项打开关于页；`LSUIElement = YES`。有新版本时，绿色 `arrow.up.circle.fill` 必须用 `Text(Image(...))` 内嵌在版本文字末尾；独立 `Image` 会被 `NSMenu` 强制提升到菜单项左侧并推移文字。

再次打开已运行的 App 时，`applicationShouldHandleReopen` 只发送设置请求，由常驻 `MenuBarLabel` 通过 SwiftUI `openSettings` 打开 `Settings` scene；禁止恢复返回成功但无法显示该 scene 的 `showSettingsWindow:` / `showPreferencesWindow:` selector。设置页底部退出入口使用 `.bar` 语义背景，不得用与 grouped Form 层级不一致的固定窗口背景色。App 图标同时依赖 `CFBundleIconName=Copied` 与 `CFBundleIconFile=Copied`；后者缺失时 Finder 会回退为通用 App 占位图。

通用页最底部“高级”保留原生 `DisclosureGroup` 箭头，但标题到行尾必须是全宽 `Button` 命中区；禁止退回只有小箭头可展开的默认标签行为，也不得用覆盖整个展开内容的手势导致内部 Toggle 点击时误收起。

### 左右键快捷复制（CopyGestureManager）

设置 → 手势中开启，默认关闭。CGEventTap 监听 4 事件（leftDown/leftUp/rightDown/rightUp）。

- **rightMouseDown** → `isLeftPressed && !gestureFired`：吞掉 + 15ms ⌘C + `gestureFired=true`
- **rightMouseUp 兜底** → `isLeftPressed && !gestureFired`：rightMouseDown 被 WindowServer 静默吞掉时补触发
- `gestureFired` 每次 leftDown/leftUp 重置，防双击发
- ⌘C 模拟：CGEvent keyboard source 传 `nil`，完整发送 Command down → C down → C up → Command up，末次释放清空 flags

**权限 UX（三重保障）**：用户请求开启时保存意图 → 授权成功后统一提示“退出并重新打开” → 启动时按真实权限恢复或回正为 OFF。`ApplicationRelauncher` 必须先确认非激活的新实例启动成功，再退出旧实例；启动失败时保留旧实例并显示错误。仅有权限但未主动开启的用户保持关闭。签名：Apple Development，Team ID `683MU5Q6FB`（TCC 凭 Team ID 识别）。

**已知限制**：先松左键 → WindowServer 在 HID 层独立发 secondary-click popup → 源 App 弹右键菜单（session-level tap 无法拦截）。

## Bug 调试方法（强制）

**禁止猜测式修 bug。必须先加文件日志定位根因。**

1. **加文件日志**：写私有 logger 到 `FileManager.default.temporaryDirectory`，每条日志含「事件类型 + 当前状态 + 关键变量」。启动时清空；禁止记录真实剪贴板正文，内容级诊断必须使用合成测试数据。
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
