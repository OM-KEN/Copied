# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
./build.sh                     # Compile → .build/Copied.app
open .build/Copied.app      # Launch (appears in menu bar, no Dock)
```

`build.sh` uses `swiftc` directly (no Xcode project). Requires macOS 26+ for `.glassEffect()` (Liquid Glass).

## Architecture

```
CopiedApp.swift             Entry point: MenuBarExtra + AppDelegate + Settings scene
ClipboardMonitor.swift      Timer polls NSPasteboard.changeCount every 0.15s
CopyGestureManager.swift    Global left-hold + right-click → ⌘C gesture (CGEventTap)
DetectionRegistry.swift        Global registry: manages all detectors + throttle/priority
ContentKind.swift              Unified type identifier (replaces old TextKind + DetectedContent)
ContentDetection.swift         Detection result struct (kind + value + color + metadata)
Detectors/                     Built-in detector files (13 total: Color, URL, FilePath, DateTime, Math, etc.)
DictionaryLookupService.swift  System dictionary lookup (DCSCopyTextDefinition, zero-config)
LookupAction.swift             Dictionary lookup action — inline result like pinyin
PluginManifest.swift           manifest.json / rules.json Codable models
PluginActionTemplate.swift     Action template types (openURL, search, transform, none)
PluginAction.swift             Executes plugin-defined action templates
PluginLoader.swift             Scans, validates, loads, installs .copiedplugin folders
ClipboardAction.swift          Action protocol + 9 concrete actions (incl. LookupAction) + resolver
FilePreviewGenerator.swift     QLThumbnailGenerator wrapper — async content thumbnails
ToastWindowController.swift Manages the floating NSWindow + NSHostingView + actions
ToastViewModel.swift           @Observable model, icon/type-label/action/async-thumbnail logic
ToastView.swift                SwiftUI card layout + glassEffect + button + swatch + menu
SourceAppDetector.swift     NSWorkspace.frontmostApplication → name + icon
SettingsView.swift              Settings (launch-at-login, search engine, types, gesture tabs)
TypeSettingsView.swift         Type priority list + plugin management
```

**Data flow:** `ClipboardMonitor` → `DetectionRegistry.detectAll()` → `ClipboardContent` (+ `[ContentDetection]`) → `ToastWindowController.show()` → `ToastViewModel` resolves actions + triggers async thumbnail → `NSHostingView` → `ToastView` (`.glassEffect()` + thumbnail + button + swatch + contextMenu)

**Content type system:** Unified `ContentKind` (struct with static constants) replaces both old `TextKind` (enum, 7 cases) and `DetectedContent` (enum, 8 cases). Detection runs through `DetectionRegistry` — a priority-ordered pipeline of `ContentDetectorProtocol` instances. Each detector produces a `ContentDetection` with kind + extracted value + optional color + optional plugin action template.

**Plugin system:** Declarative only (JSON + regex, no code execution). Format: `.copiedplugin` folder with `manifest.json` (name, icon, label, priority, category) + `rules.json` (regex patterns + action templates). Plugins loaded from `~/Library/Application Support/Copied/Plugins/`. Performance safeguards: 100KB text cutoff (only built-in language detectors run), 5ms per-detector timeout, 3-strike auto-disable.

## Key design decisions

### Window: SwiftUI `.glassEffect()` (macOS 26+)

The toast uses SwiftUI's native `.glassEffect(in: .rect(cornerRadius: 32))` modifier (Liquid Glass), applied directly to the card inside `ToastView`. The window uses a plain `NSView` as content view — no `NSGlassEffectView` needed. The pseudo edge highlight is drawn as a SwiftUI `.stroke(.white.opacity(0.25))` overlay because the real edge highlight is suppressed by the WindowServer compositor on non-key floating windows.

Window config: `.borderless`, `.floating` level, `ignoresMouseEvents = false` (to receive hover/click), `collectionBehavior = [.canJoinAllSpaces, .stationary]`.

### Entry animation: SwiftUI spring

All entry animation lives in `ToastView` via `@State + .onAppear + withAnimation(.interpolatingSpring)`:

| Property | Start | End |
|----------|-------|-----|
| `scaleEffect` | 0.2 | 1 |
| `offset(y:)` | -56 | 0 |
| `blur(radius:)` | 12 | 0 |
| `opacity` | 0 | 1 |

Spring: `mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3` (~550ms perceptual). Asymmetric padding (top:20, bottom:12, horizontal:18) outside the animation absorbs spring overshoot. Window positioned via `screen.frame.maxY` for tight-to-top placement.

Exit animation: 200ms AppKit `easeIn` fade-out via `NSAnimationContext.runAnimationGroup`, cleanup via `DispatchQueue.main.asyncAfter` (+0.25s) — GCD timer used instead of animation `completionHandler` to prevent stale callbacks leaving window onscreen at alpha=0 after long runtime.

### Mouse interaction: hover-to-pause + click-to-dismiss

The toast supports mouse interaction via a combination of SwiftUI `.onHover` and AppKit `NSEvent.addLocalMonitorForEvents`:

- **Hover**: `.onHover` modifier on `ToastView` fires on pointer enter/exit. On enter → pause dismiss timer. On exit → restart full 3s timer.
- **Click**: `NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown)` intercepts clicks at the AppKit event-dispatch level (SwiftUI's `.onTapGesture` is unreliable inside borderless floating `NSHostingView`). If the click location falls within the window frame → trigger dismiss.
- **Pre-positioned mouse**: After `orderFront`, `isMouseInsideWindow()` checks `NSEvent.mouseLocation` against the window frame. If the mouse is already inside → `isHovering = true`, timer not started.
- **Dismiss guard**: `isDismissing` flag prevents hover/click callbacks from interfering during the 200ms exit animation.
- **Generation guard**: `dismissGeneration` counter prevents a stale animated-dismiss completion from ordering out a newly-shown toast (when a new clipboard event arrives during the exit animation).

Closures `onHoverChanged` + `onTap` are injected from `ToastWindowController` into `ToastView`. Interaction state lives in the controller, not the ViewModel.

### Clipboard detection: pasteboard types, not readObjects

`readClipboardContent` checks `pasteboard.types` directly to determine the content category. Detection priority:

1. `.fileURL` → file (stores `fileURLs: [URL]`, used by `SourceAppDetector` for folder names)
2. `.tiff` / `.png` → image (generates 64×64 square thumbnail)
3. `.string` → text (with language detection)

- **Single image files**: synchronous `NSImage(contentsOf:)` thumbnail (fast, legacy path).
- **Single non-image files**: async `QLThumbnailGenerator` thumbnail via `FilePreviewGenerator`. Loads content preview (PDF first page, video keyframe, etc.) in background; falls back to SF Symbol on failure. Toast window auto-resizes when thumbnail arrives.

### Content type detection (DetectionRegistry)

After text is parsed, `DetectionRegistry.shared.detectAll(in:)` runs all registered detectors in priority order. Detectors implement `ContentDetectorProtocol` and return `ContentDetection?`. The registry manages:

- **13 built-in detectors** under `Detectors/`: `ColorDetector`, `URLDetector`, `FilePathDetector`, `DateTimeDetector`, `MathExpressionDetector`, `ChineseCharDetector`, `EnglishPhraseDetector`, `HTMLDetector`, `SwiftDetector`, `PythonDetector`, `JavaScriptDetector`, `CSSDetector`, `CodeDetector`
- **Plugin detectors** loaded from `~/Library/Application Support/Copied/Plugins/*.copiedplugin/` (each plugin = one `PluginDetector`)

| Priority | Detector | Type | Method |
|----------|---------|------|--------|
| 300 | `ColorDetector` | `.colorHex/.colorRGB/.colorHSL` | Regex + manual NSColor parse (hex, rgb, hsl) |
| 250 | `URLDetector` | `.url` | `NSDataDetector` with `.link` |
| 200 | `FilePathDetector` | `.filePath` | `^(~\|/).+` → `expandingTildeInPath` → `FileManager.fileExists` |
| 190 | `DateTimeDetector` | `.dateTime` | Preprocessing (M.D→M月D日, H点→H:00) + `NSDataDetector(.date)` full-text match; `RelativeDateTimeFormatter` detail |
| 180 | `MathExpressionDetector` | `.mathExpr` | Digits+operators, balanced parens, structure validation |
| 100 | `ChineseCharDetector` | `.chineseChar` | Exactly 1 char, U+4E00–U+9FFF |
| 80 | `EnglishPhraseDetector` | `.englishPhrase` | Single ASCII word, no code delimiters |
| 70 | `HTMLDetector` | `.html` | `</?[a-zA-Z]+\b` tags |
| 60 | `SwiftDetector` | `.swift` | `func\|var\|let\|struct\|class\|import SwiftUI…` |
| 50 | `PythonDetector` | `.python` | `def\|import\|elif\|yield…` |
| 40 | `JavaScriptDetector` | `.javascript` | `function\|const \|=>\|export \|console.…` |
| 30 | `CSSDetector` | `.css` | braces+colons+semicolons+CSS units/props |
| 20 | `CodeDetector` | `.code` | Generic braces/semicolons/keywords |
| — | (none) | `.plain` | Default when nothing matches |

**Performance safeguards:**
- **100KB text cutoff**: Text >100KB → only built-in `.language` detectors run (skip all `.entity` and plugins)
- **50ms per-detector timeout**: After each detector runs, if elapsed >50ms → throttled for 30s
- **3-strike auto-disable**: Consecutive throttles ≥3 → detector permanently disabled with system notification

Detection results stored in `ClipboardContent.detections: [ContentDetection]`. Each detection carries `kind`, `value`, optional `color`, optional `pluginActionTemplate`.

### Icon mapping (ToastViewModel.iconSymbolName)

Icon selection priority: **color swatch → detection icon → content type fallback**.

When `detectedColor != nil`, returns `""` — the color swatch replaces the icon entirely.

| Condition | Icon |
|-----------|------|
| Color detected | (color swatch, no SF Symbol) |
| Detection with non-empty `.icon` | Uses `ContentKind.icon` (e.g. `safari`, `folder`, `function`, `character`) |
| `.image` (screenshot, clipboard image) | `photo` |
| `.file` (generic) | `doc.on.doc` |
| Plain short text (<50 chars) | `text.alignleft` |
| Plain long text | `text.quote` |

`.chineseChar` icon=`character`, `.englishPhrase` icon=`abc`. Prioritization is determined by detection order (first = highest priority).

### Detail line format

Driven by `ToastViewModel.typeLabel` (priority: image format → file type/folder → detection label → empty).

| Content | Detail line |
|---------|------------|
| Clipboard image (PNG screenshot) | `PNG 图片 · 1920×1080` |
| Single image file (JPG) | `JPG 图片 · 800×600` |
| Single folder (Finder copy) | `文件夹 · 128.5 MB` |
| Single non-image file (PDF) | `PDF 文件 · 2.5 MB` |
| URL detected text | `链接 · 120字符` |
| File path detected text | `路径 · 80字符` |
| Date/time detected text | `日期 · 3天后` / `日期 · 2小时前` |
| Math expression text | `公式 · 45字符` |
| Chinese character text | `汉字` |
| Code text (Swift) | `Swift · 120字符` |
| Plugin-detected (JSON) | `JSON · 120字符` |
| Plain short text (<50 chars) | (empty — not shown) |
| Plain long text | `N字符` |
| Multiple files | `N个文件` |

### Action system (`ClipboardAction` protocol)

```swift
protocol ClipboardAction: Identifiable {
    var id: String { get }
    var title: String { get }            // ≤3 Chinese chars for button
    var systemImage: String { get }      // SF Symbol
    var menuTitle: String { get }        // context menu label
    var performsInlineUpdate: Bool { get } // true → keep popup open after perform
    func perform(content:, controller:)
}
// Default: performsInlineUpdate = false
```

**9 built-in actions + PluginAction** (resolved by `ActionResolver.resolve(for:)`):

| Action | Trigger (ContentKind) | Button text | Behavior |
|--------|---------|:---:|------|
| `OpenURLAction` | `.url` | 打开 | `NSWorkspace.shared.open` |
| `RevealFileAction` | `.filePath` | 打开 | `NSWorkspace.shared.activateFileViewerSelecting` |
| `OpenCalendarAction` | `.dateTime` | 日历 | `Process`/osascript → Calendar `view calendar at` |
| `CalculateAction` | `.mathExpr` | 计算 | NSExpression eval → `showResultOverlay` — inline, line 1=expression, line 2==result |
| `ShowPinyinAction` | `.chineseChar` | 拼音 | `CFStringTransform` → `showResultOverlay` — inline |
| `LookupAction` | `.englishPhrase` | 翻译 | `DCSCopyTextDefinition` → system dictionary (Oxford CN-EN) → `showInlineResult` — inline, line 1=word+pron, line 2=Chinese translations |
| `SearchTextAction` | plain text (fallback) | 搜索 | `NSWorkspace.open` search engine URL |
| `SaveFileAction` | context menu | — | `NSSavePanel` → write to file |
| `CopyTextAction` | result overlay (after Calculate/Pinyin/Translate) | 复制 | `NSPasteboard.general.setString` |
| `PluginAction` | Plugin-defined (any) | Template | openURL / searchWithEngine / transform / none |

**Inline update pattern** (`performsInlineUpdate = true`): After performing, the popup stays open and shows a **result overlay** (`ResultOverlay { displayText, copyText }`). The right button changes to "复制" (`CopyTextAction`). Used by `CalculateAction`, `ShowPinyinAction`, `LookupAction`, and plugin `.transform` actions. All are synchronous — `showInlineResult(displayText:copyText:)` is called directly.

**Result overlay layout**: The overlay's `displayText` is split by `\n` and each segment is rendered in its own `Text` with `.lineLimit(1)` — preventing first-line overflow from pushing into the second line. This supports two-line formats (word+pronunciation / translations, expression / =result, character / pinyin).

**Dictionary lookup** (`LookupAction`): Uses `DCSCopyTextDefinition` from CoreServices/DictionaryServices to query macOS's built-in Oxford Chinese-English dictionary. No download, no network, zero configuration. Returns: line 1 = "`{word} 英 {pron}`", line 2 = Chinese translations (≤5-char CJK groups, filtered for core definitions, max 8, comma-separated). The detector (`EnglishPhraseDetector`) triggers on single ASCII words only — phrase-level lookup is not supported by the dictionary API.

**Priority**: first non-color detection → right-side button (max 1). Others → context menu. If no detection but text exists → button defaults to 搜索. Plugin actions are created from `ContentDetection.pluginActionTemplate` when `ContentKind.source == .plugin(...)`. Language-only types (swift, python, etc.) produce no button — they only add a label/icon.

### Plugin system

Declarative-only (JSON + regex, no code execution). Format: `.copiedplugin` folder:
- `manifest.json` — name, identifier, version, category (`"language"`|`"entity"`), icon, label, priority
- `rules.json` — array of `{id, pattern, extractValue?, action?}`

Action types: `openURL` (with `{value}` template), `searchWithEngine`, `transform` (regex-replace + inline result), `none`.

Install: open `.copiedplugin` folder via Settings → copied to `~/Library/Application Support/Copied/Plugins/`. Loaded at app startup via `PluginLoader.loadAllPlugins()`.

### Click handling (NSEvent monitor + SwiftUI Button coexistence)

Click handling uses TWO layers working together:

1. **NSEvent local monitor** (`leftMouseDown`): fires first. If click inside window → calls `handleTap()` which sets `isDismissing=true` then schedules dismiss via `DispatchQueue.main.async` (deferred to next run loop).
2. **SwiftUI Button**: receives the same click synchronously. For inline-update actions (`performsInlineUpdate = true`) → calls `cancelDismiss()` which sets `isDismissing=false` (the async dismiss block then skips itself). For other actions → performs action; dismiss proceeds when the async block fires.

Background click: only layer 1 fires → async dismiss fires → toast dismisses. Button click on inline-update action: layer 1 sets dirty flag → button handler clears it → async block sees clean flag and skips.

The async deferral (added 2026-06-25) eliminates a race condition where the monitor's immediate `dismissToast(animated:true)` animation competed with `cancelDismiss()`'s `alphaValue=1.0` restoration.

`cancelDismiss()` resets `isDismissing=false`, increments `dismissGeneration` (invalidates stale animation), restores `alphaValue=1.0`.

### ⌘ key quick-action

When the toast has a primary action button (or a result overlay), pressing and releasing ⌘ triggers it. Uses two mechanisms that work **without Accessibility permission**:

1. **`NSEvent.addGlobalMonitorForEvents(.flagsChanged)`** — detects ⌘ press/release.
2. **`CGEventSource.counterForEventType(.hidSystemState, .keyDown)`** — HID-level key-down counter. Snapshot at ⌘ press; if unchanged at ⌘ release, no other key was pressed → trigger. If changed, a shortcut (⌘+A etc.) was in progress → abort.

Pre-existing ⌘ (from ⌘C copy) is detected via `NSEvent.modifierFlags` in `show()` → `cmdIsPreExisting = true` → button does NOT highlight and release does not trigger.

**Result mode**: When `viewModel.resultOverlay != nil` (after Calculate/Pinyin), ⌘ release triggers `CopyTextAction(text: overlay.copyText)` instead of `primaryAction`. The monitor guard checks `viewModel.primaryAction != nil || viewModel.resultOverlay != nil`.

Button visual feedback: `ToastViewModel.isCommandPressed` drives conditional SF Symbol (`"command"`), text (`"松开"`), background opacity (0.12→0.2), scale (1.0→0.92), with `.spring(response:0.2, dampingFraction:0.6)`. In result mode the icon is `"doc.on.doc"` and text is `"复制"`.

**Known dead-ends** (do not re-attempt):
- `addGlobalMonitorForEvents(.keyDown/.keyUp)` — macOS filters ⌘+key shortcut events
- `CGEvent.tapCreate` for ⌘ detection — ad-hoc signed app fails from `.build/`; works from `/Applications/` (used by `CopyGestureManager`)
- Timing-based heuristic — fast ⌘+A overlaps with slow intentional ⌘ tap

### Toast layout (current)

```
[色块/图标/缩略图 32/64] [12] [VStack: 预览(或结果覆盖) + 来源] [Spacer] [按钮: 图标+≤3字文案]
```

- **Color swatch**: 32×32 rounded rect (corner 8), replaces SF Symbol when `detectedColor != nil`. Has `.shadow` with the color itself.
- **Thumbnail**: 64×64 for images (unchanged from original).
- **Text area**: ZStack with opacity crossfade between preview text and result overlay. Preview uses `.lineLimit(2)` + `.lineSpacing(4)`. Result overlay splits `displayText` by `\n` into a `VStack` of `Text` views each with `.lineLimit(1)` — independent truncation prevents any line from overflowing into the next.
- **Action button**: `HStack(spacing:4)` with SF Symbol 12pt + text 12pt, `.white.opacity(0.12)` background, 8pt corner radius. Icon `.frame(height: 14)` for consistent sizing. Shows action's own SF Symbol (`arrow.up.forward`/`equal`/`magnifyingglass`/`keyboard`/`translate`). On **hover** or **⌘ press**, icon switches to `"command"` + text to "松开" (⌘ only). Hover exit debounced 100ms to prevent edge flickering. **Result mode**: when `resultOverlay != nil`, the button becomes "复制" (`doc.on.doc` icon, triggers `CopyTextAction`).
- **Context menu**: always shows 搜索 / 另存为…, plus content-specific items below a divider.

### Menu bar

`MenuBarExtra` with `doc.on.clipboard` SF Symbol. Pause/resume via `@AppStorage("isPaused")` → `ClipboardMonitor` reads `UserDefaults` directly (avoids binding propagation complexity). `LSUIElement = YES` in Info.plist hides Dock icon.

### Copy gesture (left-hold + right-click → ⌘C)

Toggle in Settings → 手势, off by default. Uses `CGEventTap` to intercept mouse events:

- `.leftMouseDown` → `isLeftPressed = true` (pass through)
- `.leftMouseUp` → `isLeftPressed = false` (pass through)
- `.rightMouseDown` → if `isLeftPressed`: consume event (return nil) + send ⌘C after 15ms

**Permission**: Requires Accessibility (CGEventTap). App MUST run from `/Applications/` or another standard location — `.build/` hidden dir causes TCC to reject even with permission granted. Settings tab shows live `isRunning` status + diagnostic text.

**Key files**: `CopyGestureManager.swift` (singleton, CGEventTap + ⌘C simulation), `CopiedApp.swift` (`@AppStorage("copyGestureEnabled")` + lifecycle), `SettingsView.swift` (gesture tab with toggle + permission UI).

### File/folder size calculation

`formatFileSize` in `ClipboardMonitor.swift` uses three-tier strategy:
1. `totalFileSizeKey` — fast recursive size (works for most packages/directories)
2. `fileSizeKey` — regular files
3. `calculateRecursiveSize()` — `FileManager.enumerator` fallback for dirs/packages when totalFileSize returns 0

Single folders now show size (was empty before 2026-06-29).

## GitHub 推送规则（硬性）

**涉及任何 git 操作时必须先调用 `git-push` skill。** 核心原则：只改/只传 `Copied-mac/`，根 `README.md` 不归你管。

## Known limitations

- **Edge highlight**: Liquid Glass edge highlight is suppressed by the WindowServer compositor on non-key floating windows. The SwiftUI `.stroke(.white.opacity(0.25))` overlay compensates visually.
- **Window position constraint**: macOS constrains window frames to screen bounds. The window extends above `visibleFrame.maxY` using `screen.frame.maxY`, but further upward push is clamped by the WindowServer.
- **Window animation clipping**: During `showResultOverlay` window expansion, the `NSHostingView` content is already at full target width while the window frame is still animating, causing brief right-edge clipping. Multiple approaches were tried (CALayer mask, `clipsToBounds`, hosting view offset, constraints) — none eliminated the AppKit ↔ SwiftUI timing mismatch. Current workaround: 0.25s fast animation + explicit 2-line result format (result always on line 2, visible) + ZStack crossfade masks the transition.
- **macOS 26+ only**: `.glassEffect()` requires macOS 26. Lower versions would need `NSVisualEffectView` fallback.
- **No Xcode project**: Built via `swiftc` in `build.sh`. To use Xcode, create a macOS App target and add all `.swift` files + `Info.plist`.
- **Frameworks**: SwiftUI, AppKit, QuickLookThumbnailing (file thumbnails), ServiceManagement (login item), CoreServices (DictionaryServices for word lookup). `build.sh` also ad-hoc codesigns for SMAppService.
- **Settings**: Settings page (⌘, or menu → 设置…) with launch-at-login toggle, search engine picker, type management. UserDefaults keys: `searchEngine`.
- **Dictionary lookup**: Implemented via `DCSCopyTextDefinition` from CoreServices/DictionaryServices. Returns results from macOS built-in Oxford Chinese-English dictionary. No download, no network. Single-word only (dictionary API limitation, not phrase-level). `showInlineResult()` pattern shared with Calculate/Pinyin actions.

