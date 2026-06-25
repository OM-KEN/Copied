# Code Review: ContentKind 统一 + 插件系统重构

**日期**: 2026-06-25  
**范围**: 1153 行 diff，18 个新文件，6 个修改文件，1 个删除文件

---

## 🔴 需要修的正确性 Bug（3 个）

### 1. `PluginAction.openURL` 编码 bug

- **文件**: `Copied-mac/PluginAction.swift:20`
- **严重度**: MEDIUM
- **症状**: 对整个 URL 做 percent-encoding 而非仅对 `{value}` 部分。剪贴板值含 `&`、`=`、`+` 时这些字符不会被转义。

**失败场景**: 用户复制 `hello&world` → 插件 openURL 模板 `https://example.com?q={value}` → 生成 URL `q=hello&world`（`&` 被视为第二个查询参数分隔符）→ 服务器收到 `q=hello` 而非 `q=hello&world`

**修复方向**: 只对 `detection.value` 做 percent-encode，再替换进 template。参考 `SearchTextAction` 的做法。

---

### 2. `installExamplePluginsIfNeeded` 持久化时序

- **文件**: `Copied-mac/PluginLoader.swift:114`
- **严重度**: HIGH
- **症状**: flag 在写文件**之前**就设到 UserDefaults。写文件失败后 flag 永真，下次启动直接跳过 → 示例插件永久缺失，无 UI 提示。

**失败场景**: 首次启动磁盘满 → `manifest.json` 写成功但 `rules.json` 失败 → `flag=true` 已持久化 → `.copiedplugin` 目录存在（部分）→ 下次启动 early-return 触发 → `loadPlugin` 因 `rules.json` 缺失而失败 → 用户永远看不到示例插件，无 UI 可知

**修复方向**: flag 应在所有文件写入成功后再 set。或在 `writeExamplePlugin` 失败时 rollback flag。

---

### 3. `PluginAction.id` 不唯一

- **文件**: `Copied-mac/PluginAction.swift:10`
- **严重度**: MEDIUM
- **症状**: 同一插件的多条规则产生相同的 `id: "plugin-<identifier>"` → SwiftUI `ForEach` identity 碰撞。

**失败场景**: 插件有两条规则（json-object + json-array）→ 同时匹配后产生两个 action → 两 action 的 id 都是 `"plugin-com.example.plugin"` → SwiftUI `ForEach(id: \.id)` identity 碰撞 → 菜单按钮可能缺失或动画异常

**修复方向**: `id` 改为 `"plugin-\(detection.kind.id)-\(detection.metadata["ruleId"] ?? "")"`，带上 ruleId。

---

## 🟡 设计/健壮性问题（5 个）

### 4. `PluginAction.applyTransform` 正则选项不一致

- **文件**: `Copied-mac/PluginAction.swift:41` vs `PluginManifest.swift:64`
- **严重度**: MEDIUM
- **症状**: 检测时 `CompiledRule` 编译带 `.anchorsMatchLines`，变换时 `applyTransform` 用 `options: []`。同一 pattern 在两步行为不同。

**失败场景**: 插件 transform pattern `"^(.*)$"` 意图逐行替换 → 检测时 `.anchorsMatchLines` 使 `^`/`$` 匹配行边界 → 变换时 `[]` 使 `^`/`$` 仅匹配字符串首尾 → 多行文本只替换首尾之间的内容

**修复方向**: `applyTransform` 编译正则时也加 `.anchorsMatchLines`。

---

### 5. `ColorDetector` 只有一种 kind

- **文件**: `Copied-mac/Detectors/ColorDetector.swift:7`
- **严重度**: MEDIUM
- **症状**: `kind = ContentKind.colorHex` 固定。hex/rgb/hsl 三个子类型共用一个 `"colorHex"` key 做 throttle/disable。

**失败场景**: HSL 正则回溯慢触发 5ms 超时 → throttle/disable 作用于 `"colorHex"` key → 所有颜色检测（hex + rgb + hsl）一起被禁用 → 用户复制 `#ff0000` 不再显示色块，且 Settings 中看不到 RGB/HSL 的独立开关

**修复方向**: 拆为三个独立检测器（`ColorHexDetector`/`ColorRGBDetector`/`ColorHSLDetector`），或对 ColorDetector 内部按子类型分 key。

---

### 6. `unregister` 泄漏状态

- **文件**: `Copied-mac/DetectionRegistry.swift:107`
- **严重度**: MEDIUM
- **症状**: 移除检测器不清理 `throttledUntil` / `throttleCounts` / `disabledKinds` → 同 id 重新注册后立即被旧状态影响。

**失败场景**: 调用 `DetectionRegistry.shared.unregister(kind: .url)` → detector 移除但 `disabledKinds` 仍含 `"url"` → 同 id detector 重新注册 → 被 `activeDetectors` filter 掉 → 看似加载成功但从不运行

**修复方向**: `unregister(kind:)` 和 `unregisterPlugin(identifier:)` 中同时清理 `throttledUntil.removeValue` / `throttleCounts.removeValue` / `disabledKinds.remove`。

---

### 7. `loadPlugin` 静默丢弃无效规则

- **文件**: `Copied-mac/PluginLoader.swift:60`
- **严重度**: LOW
- **症状**: 3 条规则 2 条正则语法错 → 日志只报 `"loaded (1 rules)"` → 插件作者不知道丢了 2 条能力。

**失败场景**: `rules.json` 含 3 条规则，2 条正则语法错误 → `compactMap` 静默丢弃 → 成功日志仅报告存活数 → 用户以为 3 条都生效

**修复方向**: 加载成功后在日志中列出被跳过的规则 ID（如 "skipped 2 invalid rules: rule-id-1, rule-id-2"），或返回 warning 给 UI。

---

### 8. `PluginRule.priority` 解析了但从未使用

- **文件**: `Copied-mac/PluginManifest.swift:51`
- **严重度**: LOW
- **症状**: 插件作者在 rules.json 设 per-rule priority → 被静默忽略 → 只用 `manifest.priority`。

**失败场景**: 规则按 JSON 文件顺序而非期望优先级执行 → 无错误提示

**修复方向**: 要么在 `CompiledRule` 中存 `priority` 并在 `PluginDetector.detect` 中按优先级排序规则，要么在 manifest schema 文档中标注此字段为预留。

---

## 🟢 性能/清理（7 个）

### 9. `ClipboardContent.hashValue` 不含 detections

- **文件**: `Copied-mac/ClipboardMonitor.swift:23`
- **严重度**: LOW
- **症状**: hash 只含 `type`/`preview`/`detail`。相同文本 + 新安装插件 → 500ms 去重窗内被错误去重，用户看不到新类型标签。

**修复方向**: `hasher.combine(detections.map { $0.kind.id })` 纳入 hash。

---

### 10. `contentKind` 死存储

- **文件**: `Copied-mac/ClipboardMonitor.swift:17`
- **严重度**: LOW
- **症状**: 每次创建 `ClipboardContent` 赋值但代码中无任何读取。

**修复方向**: 如果有用就接线（如 `ToastViewModel` 直接读而非遍历 detections），否则删掉字段。

---

### 11. `CFAbsoluteTimeGetCurrent` 非单调

- **文件**: `Copied-mac/DetectionRegistry.swift:162`
- **严重度**: LOW
- **症状**: NTP 校时或系统唤醒 → 时钟跳变 → `elapsed` 计算异常 → 误熔断检测器。

**修复方向**: 改用 `mach_absolute_time()` 或 `DispatchTime.now()`。

---

### 12. `isOversize` 裁前判断

- **文件**: `Copied-mac/DetectionRegistry.swift:146`
- **严重度**: LOW
- **症状**: 100KB 门槛用原始 `text.utf8.count` 而非裁剪后的 → 尾部大段空白可误触发熔断。

**修复方向**: 把 `isOversize` 计算移到 trim 之后，或用 `trimmed.utf8.count`。

---

### 13. `NSDataDetector` 每次 detect 重建

- **文件**: `Copied-mac/Detectors/URLDetector.swift:9`
- **严重度**: LOW
- **症状**: 热路径上每次检测都分配新 `NSDataDetector` → 虽然 pre-warm 了 cache 但 Swift 对象仍被反复分配。

**修复方向**: 用 `private static let linkDetector = try? NSDataDetector(types: .link.rawValue)` 单例。

---

### 14. RGB alpha 正则接受 >1.0

- **文件**: `Copied-mac/Detectors/ColorDetector.swift:33`
- **严重度**: LOW
- **症状**: `[01]\.\d+` 匹配 `1.5` → `NSColor(alpha: 1.5)` 被钳制 → 色块与用户输入不一致。

**修复方向**: 限制为 `(0|1|0?\.[0-9]+|1\.0)`。

---

### 15. `installPlugin` 重复标识符

- **文件**: `Copied-mac/PluginLoader.swift:83`
- **严重度**: LOW
- **症状**: 用文件夹名去重但用 manifest identifier 注册 → 同名异 identifier / 同 identifier 异名都产生重复。

**修复方向**: 安装前检查 `DetectionRegistry` 中是否已存在同名 identifier，存在则拒绝或覆盖。

---

## 已验证但排除的候选（未确认的 bug）

- **数据竞争在 DetectionRegistry** → 排除。`Timer.scheduledTimer` 在 main RunLoop → 回调和 UI 都在主线程。
- **PluginAction URL 完全失效** → 部分排除。`urlQueryAllowed` 确实包含 `://?` 不会被破坏，但 `&`/`=`/`+` 在值中仍会出问题。
