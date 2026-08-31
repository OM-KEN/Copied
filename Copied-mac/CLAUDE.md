# CLAUDE.md

## 文档与事实源

- `build.sh` 是编译输入、资源和最低系统版本的事实源；新增源文件或资源必须同步 `SOURCES` / `RESOURCES`，必要时删除 `.build/.source_fingerprint`。
- `DESIGN.md` 记录产品行为与取舍，`UI_GUIDELINES.md` 记录界面规范；本文件只保留跨模块契约和高风险回归约束。
- `AGENTS.md` 必须继续是指向本文件的符号链接。不要维护两份规则副本。
- 不在这里复制完整 UserDefaults 键表或穷举所有文件；新增行为只补会影响实现、隐私、兼容性或发布的约束。

## 构建与运行

```bash
./build.sh                     # swiftc + xcstringstool + actool + codesign → .build/Copied.app
./run-tests.sh                 # 统一测试入口
./create-dmg.sh                # → .build/Copied.dmg（需 dmgbuild>=1.6.5）
open .build/Copied.app
```

- 运行需 macOS 14+；源码构建需 Xcode 26，项目没有 Xcode 工程。
- macOS 26+ 使用 Liquid Glass，旧系统降级为毛玻璃材质。
- DMG 背景图放在 `.build/dmg_background.png`（440×240）。macOS 26.2+ 的 Finder 可能不显示自定义背景；发布验收不得只依赖背景是否出现。

## 核心结构与数据流

- `ClipboardMonitor.swift`：观察 revision、来源过滤、视觉策略和各异步 lane 调度。
- `ClipboardPipeline.swift`：revision gate、会话生命周期、latest-only worker、读取与安全边界。
- `ClipboardContentEnrichment.swift` / `ClipboardDetectionDisplayFacts.swift`：文件、图片补齐与稳定展示事实。
- `DetectionRegistry.swift` / `Detectors/`：内置和插件检测管道。
- `PopupPresentationSettings.swift`：默认/轻打扰偏好和分类策略。
- `ToastPanel.swift` / `ToastWindowController.swift` / `ToastView.swift`：完整卡片窗口、命令路由和视图。
- `QuickTriggerCoordinator.swift` / `GlobalMouseEventCoordinator.swift` / `CopyGestureManager.swift`：快速触发与全局鼠标输入。
- `PluginLoader.swift` / `PluginRuntimeSafety.swift`：声明式插件加载与运行时约束。
- `AppUpdateService.swift` / `FeedbackSupport.swift`：更新检查与用户主动反馈。

主流程：

`changeCount` → 缓存来源与黑名单门 → 快照设置并做候选判断 → 默认/全允许路径同步显示 pending 或仅提醒浮标 → base read → 每个 revision 的声音终态 → enrichment / detection / action → 展示分类 → 轻打扰去重 → 更新完整卡片或显示浮标。

- revision 身份只用 `ClipboardRevision(generation, changeCount)`；内容指纹只用于轻打扰视觉去重。
- `SourceAppDetector` 先提供缓存快照，base content 到达后再补齐来源信息；不要把来源检测排在剪贴板读取之后。

## 启动首响应

- 启动先清理过期 TextEdit 临时文件、异步预热词典、注册检测器并加载插件；`ClipboardMonitor.start()` 必须先捕获当前 `changeCount`，再执行实体检测、完整管道和前台 App 图标预热。
- 预热后用生产 `ToastPanel` 布局和动画显示一次 1 秒“Copied 已启动”。启动提示不得读取/写入剪贴板、播放声音、进入视觉去重、解析 Action、启动快速触发或显示来源/详情/菜单。
- 真实复制到达时递增 generation 并立即替换启动提示；所有旧定时器、异步结果和退场回调都必须因 generation/revision 失效。

## 剪贴板、隐私与后台工作

- 只用 `pasteboard.types` 判定类别，不用 `readObjects`。启动阶段每 25ms 检查 `changeCount`；首次有效读取、同一不可读 revision 尝试 3 次或启动 60 秒后恢复 75ms。
- 新 revision 必须在访问 representation 前被确认。base/analysis/file/image 各用一个不可抢占 active + 一个可替换 pending 的有界 lane；阻塞的系统调用不得造成无界排队。
- 默认模式和轻打扰全允许的完整卡片路径必须在提交 base read 前同步 `showPending`；仅提醒路径同步显示浮标。base、enrichment、Action 到达后按真实内容重新 fitting，不用固定尺寸遮掩异步变化。
- 三次不可读或 3 秒硬超时的默认模式完整卡片显示普通“已复制”与 `checkmark.circle.fill`，沿用 3 秒时长；轻打扰不显示错误长文案。
- 文件夹/包体大小用后台有界遍历；立即发布数值下界，最多每 250ms 且格式化值变化时更新，完成或软截止后移除 loading 并保留最终值/“至少”下界。`ProgressView` 不留完成后的固定空槽，深色外观只对该原生环使用 `colorInvert()`。
- Action 更新不得紧接一次无内容变化的 `applyEnrichment`，也不得用共享动态 `.id` 重建交互按钮。
- 图片解码和缩略图必须遵守 `ClipboardImageSafety`；Quick Look 异步生成，失败回退 SF Symbol。
- 生产日志不得写 `preview`、`rawText`、路径或其他剪贴板正文。内容级复现只用明确的合成数据。
- “在文本编辑中打开”使用 UUID 临时文件，权限固定为仅当前用户读写（0600）。成功交给 TextEdit 后保留；Copied 下次启动只清理自己创建且超过 7 天的文件。

## 视觉筛选、声音与仅提醒

- 默认模式无条件通过视觉筛选。轻打扰中，有 `primaryKindID` 的识别文本只受对应类型开关控制；未识别文本按 `ClipboardTextPolicy.longTextThreshold` 的 49/50 边界读取普通短/长文本开关。自定义只写 `popupDisabledKindIDs`，不得改写 `disabledContentKinds`。
- `colorHex` / `colorRGB` / `colorHSL` 统一按 `colorHex`。纯位图是图片；文件集合只有在非空、分类完成且全部为受支持的本地普通图片文件时才是图片，否则是文件。
- 轻打扰筛选位于声音之后、0.5 秒视觉去重之前；被筛掉或仍待分类的内容不得更新去重状态。
- “仅提醒模式”与轻打扰正交：只把已经允许的完整卡片换成鼠标右上方 24pt `checkmark.app.fill` 浮标，1 秒自消。每次重建忽略鼠标的 borderless floating window；macOS 26+ 用 `drawOff(isActive: !show)`，旧系统用 opacity。
- 复制声音默认 Frog、音量 0.5；试听和实际复制共用异步串行播放器。声音在来源过滤后，每个 revision 的成功读取、三次不可读或硬超时首个终态最多一次；暂停、黑名单来源无声。

## 窗口与点击契约

- 完整卡片只能使用 `ToastPanel`：borderless nonactivating `NSPanel`，`canBecomeKey=true`、`canBecomeMain=false`、`becomesKeyOnlyIfNeeded=true`、floating 且不随失焦隐藏。折叠控件使用 first-mouse hosting 并保持 Panel non-key；每次 `show()` 重建窗口。
- macOS 26+ 用 `.glassEffect(in: .rect(cornerRadius: 32))`，旧系统用 `.ultraThinMaterial` 和 0.08 秒延迟淡入；卡片始终绘制 `.primary.opacity(0.15)` 的细描边。
- 折叠态所有鼠标命令只来自 SwiftUI `Button` → `ToastCommand`：预览展开、主操作、背景关闭。透明防裁切 padding 也属于背景按钮；图标和来源标签必须穿透。禁止窗口级左右键 monitor、手写坐标/矩形命中或 hover 业务分流。
- 本地 NSEvent monitor 只保留快速触发的 `.keyDown` / `.flagsChanged`；订阅 `.leftMouseDown` 会破坏 nonactivating Panel 的原生点击链。
- 退场使用全窗口 Core Image 过滤器；动画回调、取消关闭和非动画关闭都必须清理 filter。缩略图保留到 `orderOut` 后，旧回调由 `dismissGeneration` 拦截。
- 来源和详情各自单行自动滚动：自然宽度参与 fitting，总宽上限 360pt；仅真实溢出时渐隐，悬停 0.6 秒后单次滚到末端再返回。禁止用 `ScrollView` 或点击命中实现。

### 展开全文

- `ExpandedTextView` 固定宽 360、内容区总高最多 300pt；原生 `NSTextView/NSScrollView` 与底栏由 controller 分层安装。展开窗口左右和底部各留 16pt 阴影边界，顶部不留；窗口总高上限 340pt。
- 超过 2,048 UTF-16 单元时，点击路径不得同步全文测量：先预留最大高度并显示原生 loading，再在下一次主队列调度安装正文。正文高度按文本缓存；generation 使过期任务失效。
- 展开完成后 Panel 可成为 key，正文成为 first responder，支持拖选、⌘C 和右键菜单；底栏按钮保持 non-key。Escape 无操作，右下角有明确关闭按钮。
- 展开期间停止自动关闭并 suspend 快速触发；鼠标移出不关闭。收起完成后按实际指针几何决定是否恢复 3 秒计时并 resume。
- 展开/收起用全窗口模糊 + alpha 两段切换，resize 不动画；直接关闭时原生正文和底栏保持到退场完成。

## 检测、Action 与插件

- `DetectionRegistry` 按优先级运行全部注册检测器。候选预检边界：无 scheme URL 2,048 UTF-16；电话/数字日期 256；无数字自然语言日期 64。超过 100KB 只运行内置语言检测。
- 单检测器返回后耗时超过 50ms 会限流 30 秒；连续 3 次限流永久禁用并通知。该层不承诺中断当前调用。
- 插件单次全部正则共享 50ms 主动中断预算；最多 10,000 个匹配和 1,000,000 UTF-16 输出，超限不返回部分结果。
- 公式检测和计算必须共用 `MathExpressionEvaluator` 与 `Decimal`。精确值验证无损往返；近似值必须携带误差界，显示与复制来自同一次舍入，复制固定 POSIX 小数点。
- Action 优先级：符合条件的 Lithe 图片文件独占主按钮并进入菜单；否则首个非颜色检测为主按钮，其余进菜单。无检测时短文本搜索、长文本另存为，纯语言类型无按钮。
- 内联 Action 只在 `copyText` 非空时把主按钮/快速触发改为复制；错误结果不提供复制入口。词典预查只在 `ActionResolver.makeAction()`，不得塞进 50ms 检测器。
- Lithe 仅接收全部为本地普通 JPG/JPEG/PNG、能定位 `com.lithe.app` 且无生成标记的文件；打开时不激活 App、不写最近项目，使用生成标记和 request ID 防回环与误去重。
- 插件仅为声明式 JSON + 正则，不执行代码，无默认插件，只从设置手动安装；只扫描插件根目录直接 `.copiedplugin` 子目录。拒绝目录符号链接和不安全 identifier；卸载按枚举到的实际目录与 manifest 精确匹配，禁止拼接路径删除。
- 插件空 `label` / `icon` 表示不覆盖。enrichment 必须分别保留 base 类型标签与图标；规则只有确实适用于输入时才能提升类型。

## 本地化、生命周期与全局输入

- `Localizable.xcstrings` 以 `zh-Hans` 为源，支持 `en` / `zh-Hant`。新增内置文案使用 `String(localized:)`；App 只跟随系统/单 App 语言，剪贴板、插件、文件名和 App 名保持原文。
- `AppLanguage.isContentKindAvailable(_:)` 是语言检测策略唯一入口；英文界面隐藏并跳过 `englishPhrase`，不改写用户禁用项。日期 subtype 按原文区分，日期描述按日历日语义生成。
- 登录项以 `launchAtLogin` 意图为准；签名变化导致 `SMAppService` 失效时启动自动重注册，失败则回写 false。
- 快速触发状态机、350ms timeout、20ms HID poll 和设置快照只归 `QuickTriggerCoordinator`。controller 只提供 generation context 与 `ToastCommand.performPrimary` 回调；start/suspend/resume/stop 必须幂等。
- 修饰键按左右真实 keyCode 跟踪。第一次按下至最终松开间出现普通键、其他修饰键、鼠标或滚轮即取消；键盘路径不要求辅助功能权限。
- 鼠标输入统一走 `GlobalMouseEventCoordinator` 与 HID 计数；不得新增 Event Tap 或左键 NSEvent monitor。System Settings 前台时销毁活动 Tap；只有 timeout 且权限仍有效才重启，用户输入禁用或权限失效保持关闭。
- 侧键和左右键复制需要辅助功能权限。授权成功后提示退出重开；`ApplicationRelauncher` 必须先确认非激活新实例启动成功，再退出旧实例。
- 左+右复制只监听四类鼠标事件；rightDown 命中时吞掉并在 15ms 后发送完整 ⌘C，rightUp 仅作 WindowServer 吞掉 down 的兜底。先松左键导致源 App 菜单无法拦截是已知限制。

## 设置、更新与反馈

- 菜单栏和设置共享同一 UserDefaults；再次打开 App 只通过 `SettingsNavigation` 请求和 SwiftUI `openSettings` 打开 Settings scene。有新版本时菜单项图标必须用 `Text(Image(...))` 内嵌，避免 `NSMenu` 把独立 `Image` 移到左侧。
- 更新只检查 GitHub 最新稳定 Release：成功每天一次，失败一小时后重试；不做应用内安装。仅完整卡片可显示更新入口。
- `VERSION` 是构建版本单一来源。Release 资产名固定为 `Copied-<VERSION>.dmg`，tag/标题为 `v<VERSION>`；发布后用 API 核对名字、大小和 SHA-256。
- 问题反馈只打开默认邮件 App 或 GitHub Issue 模板选择页，让用户检查并手动提交。邮件仅预填 Copied 版本、macOS 版本和芯片；不得附带剪贴板、路径、设置、日志、设备名或其他私人数据。
- 菜单栏图标使用 `Copied.svg` 模板；App 图标同时依赖 `CFBundleIconName=Copied` 和 `CFBundleIconFile=Copied`。

## 调试、Git 与已知限制

- 修 Bug 禁止猜测：先在临时目录加最小文件日志（事件、状态、关键非敏感变量），复现并对比正常/异常路径，确认根因后修复并删除日志。不得记录真实剪贴板正文。
- 任何会修改 Git 状态或创建 Release 的操作前读取 `git-push` skill。默认只改/暂存 `Copied-mac/`；根目录双 README 仅限用户对当前任务明确授权。未经同意不得 push，提交与发布也分别需要明确授权。
- WindowServer 会把窗口限制在屏幕边界内；结果覆盖层展开时可能短暂裁切，现有缓解为 0.25 秒动画、两行结果和 ZStack 交叉淡入。
- Mac Mouse Fix 等重映射工具可能在 CGEvent/AppKit/HID 前吞掉原生侧键或“修饰键 + 滚轮”；让用户关闭对应映射，不增加 raw IOHID 绕过路径。
