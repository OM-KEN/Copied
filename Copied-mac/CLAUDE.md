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
ContentDetector.swift          Detects URL/path/color/math/Chinese/English in text
ClipboardAction.swift          Action protocol + 6 concrete actions + resolver
FilePreviewGenerator.swift     QLThumbnailGenerator wrapper — async content thumbnails
ToastWindowController.swift Manages the floating NSWindow + NSHostingView + actions
ToastViewModel.swift           @Observable model, icon/type-label/action/async-thumbnail logic
ToastView.swift                SwiftUI card layout + glassEffect + button + swatch + menu
SourceAppDetector.swift     NSWorkspace.frontmostApplication → name + icon
SettingsView.swift              Settings page (launch-at-login + search engine picker)
```

**Data flow:** `ClipboardMonitor` → `ClipboardContent` (+ detections from `ContentDetector`) → `ToastWindowController.show()` → `ToastViewModel` resolves actions + triggers async thumbnail → `NSHostingView` → `ToastView` (`.glassEffect()` + thumbnail + button + swatch + contextMenu)

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

Exit animation: 200ms AppKit `easeIn` fade-out. Triggered by 3s timer expiry or user click.

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

### Text kind detection (detectTextKind)

Regex-based heuristics, checked in order:
- HTML: `</?[a-zA-Z]+\b` tags → `.html`
- Swift: `func|var|let|struct|class|import SwiftUI…` → `.swift`
- Python: `def|import|elif|yield…` → `.python`
- JavaScript: `function|const |=>|export |console.…` → `.javascript`
- CSS: braces + colons + semicolons + `px|em|rem|#…|rgb(` → `.css`
- Generic code: any braces or semicolons+newlines → `.code`
- Otherwise: `.plain`

### Icon mapping (ToastViewModel.iconSymbolName)

Icon selection priority: **color swatch → detection type → content type / textKind**.

When `detectedColor != nil`, returns `""` — the color swatch replaces the icon entirely.

| Condition | Icon |
|-----------|------|
| Color detected | (color swatch, no SF Symbol) |
| URL detected | `safari` |
| File path detected | `folder` |
| Math expression detected | `function` |
| Chinese character detected | `waveform` |
| Single folder (Finder copy) | `folder` |
| `.image` (screenshot, clipboard image) | `photo` |
| `.file` (generic) | `doc.on.doc` |
| `.html` | `chevron.left.forwardslash.chevron.right` |
| `.swift` / `.css` / `.python` / `.javascript` / `.code` | `curlybraces` |
| `.plain` (short text, <50 chars) | `text.alignleft` |
| `.plain` (long text) | `text.quote` |

`.englishPhrase` and color detections are **skipped** in `primaryDetection` — they don't affect the left icon.

### Detail line format

Driven by `ToastViewModel.typeLabel` (priority: image format → file type/folder → detection type → textKind).

| Content | Detail line |
|---------|------------|
| Clipboard image (PNG screenshot) | `PNG 图片 · 1920×1080` |
| Single image file (JPG) | `JPG 图片 · 800×600` |
| Single folder (Finder copy) | `文件夹` |
| Single non-image file (PDF) | `PDF 文件 · 2.5 MB` |
| URL detected text | `链接 · 120字符` |
| File path detected text | `路径 · 80字符` |
| Math expression text | `公式 · 45字符` |
| Chinese character text | `汉字` |
| Code text (Swift) | `Swift · 120字符` |
| Plain short text (<50 chars) | (empty — not shown) |
| Plain long text | `N字符` |
| Multiple files | `N个文件` |

### Deduplication

500ms dedup window via `HashCode.Combine(type, preview)`. Same content within 500ms is silently dropped.

### Source app display

`SourceAppDetector.detect(for:)` reads `NSWorkspace.shared.frontmostApplication`. When it's Finder + `content.fileURLs` are present, the parent folder name replaces "访达". Multiple folders → `N个文件夹`.

### Content detection (`ContentDetector`)

After text is parsed, `ContentDetector.detect(in:)` scans for these types (ordered by priority):

| Priority | Type | Detection method |
|----------|------|-----------------|
| 1 | Color (hex #RGB/#RRGGBB/#RRGGBBAA) | Regex + manual NSColor parse |
| 1b | Color (bare 6-digit hex, no #) | Try prepending # → parse; skip if invalid |
| 2 | Color (rgb/rgba/hsl) | Regex + manual NSColor parse |
| 3 | URL | `NSDataDetector` with `.link` |
| 4 | File path | `^(~\|/).+` → `expandingTildeInPath` → `FileManager.fileExists` |
| 5 | Math expression | Digits + operators, no letters, balanced parens; char whitelist + multi-line/implied-mult/comma/% rejection → `isValidMathStructure` → NSExpression (ObjC exceptions uncatchable in Swift — all safety checks MUST live in detection layer) |
| 6 | Chinese character | Exactly 1 char, U+4E00–U+9FFF |
| 7 | English phrase | 2-10 ASCII words, no code delimiters |

Detection results stored in `ClipboardContent.detections`. Raw text stored in `ClipboardContent.rawText` (untruncated).

**Display exclusion**: `.englishPhrase` and color detections are excluded from `primaryDetection` — they don't affect the left icon or detail label. Color uses the swatch instead; English phrase display is deferred until translation is implemented.

### Action system (`ClipboardAction` protocol)

```swift
protocol ClipboardAction: Identifiable {
    var id: String { get }
    var title: String { get }       // ≤3 Chinese chars for button
    var systemImage: String { get } // SF Symbol
    var menuTitle: String { get }   // context menu label
    func perform(content:, controller:)
}
```

**6 concrete actions** (resolved by `ActionResolver.resolve(for:)`):

| Action | Trigger | Button text | Behavior |
|--------|---------|:---:|------|
| `OpenURLAction` | `.url` | 打开 | `NSWorkspace.shared.open` |
| `RevealFileAction` | `.filePath` | 打开 | `NSWorkspace.shared.activateFileViewerSelecting` |
| `CalculateAction` | `.mathExpression` | 计算 | NSExpression eval → `showResultOverlay` (NO clipboard write) |
| `ShowPinyinAction` | `.chineseCharacter` | 拼音 | `CFStringTransform` to Latin (keep tones) → `showResultOverlay` |
| `SearchTextAction` | `.englishPhrase` / plain text | 搜索 | `NSWorkspace.open` search engine URL (configurable via `UserDefaults("searchEngine")`) |
| `SaveFileAction` | context menu | — | `NSSavePanel` → write to file |

**Priority**: highest-priority detection → right-side button (max 1). Others → context menu. If no detection but text exists → button defaults to 搜索.

### Click handling (NSEvent monitor + SwiftUI Button coexistence)

Click handling uses TWO layers working together:

1. **NSEvent local monitor** (`leftMouseDown`): fires first. If click inside window → calls `handleTap()` (starts dismiss). **Returns the event** (does NOT consume it) so SwiftUI still processes it.
2. **SwiftUI Button**: receives the same click. For result actions (Calculate/Pinyin) → calls `cancelDismiss()` to undo the monitor's dismiss, then shows result overlay + restarts timer. For other actions → performs action + lets dismiss proceed.

Background click: only layer 1 fires → toast dismisses. Button click: both fire → dismiss + action execute together.

`cancelDismiss()` resets `isDismissing=false`, increments `dismissGeneration` (invalidates stale animation), restores `alphaValue=1.0`.

### ⌘ key quick-action

When the toast has a primary action button, pressing and releasing ⌘ triggers it. Uses two mechanisms that work **without Accessibility permission**:

1. **`NSEvent.addGlobalMonitorForEvents(.flagsChanged)`** — detects ⌘ press/release.
2. **`CGEventSource.counterForEventType(.hidSystemState, .keyDown)`** — HID-level key-down counter. Snapshot at ⌘ press; if unchanged at ⌘ release, no other key was pressed → trigger. If changed, a shortcut (⌘+A etc.) was in progress → abort.

Pre-existing ⌘ (from ⌘C copy) is detected via `NSEvent.modifierFlags` in `show()` → `cmdIsPreExisting = true` → button does NOT highlight and release does not trigger.

Button visual feedback: `ToastViewModel.isCommandPressed` drives conditional SF Symbol (`"command"`), text (`"松开"`), background opacity (0.12→0.2), scale (1.0→0.92), with `.spring(response:0.2, dampingFraction:0.6)`.

**Known dead-ends** (do not re-attempt):
- `addGlobalMonitorForEvents(.keyDown/.keyUp)` — macOS filters ⌘+key shortcut events
- `CGEvent.tapCreate` — ad-hoc signed LSUIElement app returns nil even with Accessibility
- Timing-based heuristic — fast ⌘+A overlaps with slow intentional ⌘ tap

### Toast layout (current)

```
[色块/图标/缩略图 32/64] [12] [VStack: 预览(或结果覆盖) + 来源] [Spacer] [按钮: 图标+≤3字文案]
```

- **Color swatch**: 32×32 rounded rect (corner 8), replaces SF Symbol when `detectedColor != nil`. Has `.shadow` with the color itself.
- **Thumbnail**: 64×64 for images (unchanged from original).
- **Action button**: `HStack(spacing:4)` with SF Symbol 12pt + text 12pt, `.white.opacity(0.12)` background, 8pt corner radius. When a special type is detected (URL/file path/math/Chinese), the button icon defaults to `"command"` (⌘) instead of the action's own icon — avoids duplicating the left-side type icon. `showCommandIcon` drives this.
- **Context menu**: always shows 搜索 / 翻译(disabled) / 另存为…, plus content-specific items below a divider.

### Menu bar

`MenuBarExtra` with `doc.on.clipboard` SF Symbol. Pause/resume via `@AppStorage("isPaused")` → `ClipboardMonitor` reads `UserDefaults` directly (avoids binding propagation complexity). `LSUIElement = YES` in Info.plist hides Dock icon.

## GitHub 推送规则（硬性）

项目已配置 **sparse-checkout**，工作树只包含 `Copied-mac/`，`Copied-win/` 不可见不可改。

**日常提交：**
```
git pull --rebase && git push
```
mac 和 win 改不同文件夹，永不冲突，rebase 秒过。

**发布 release：** 构建 DMG 后用 `gh release create vX.Y.Z --title … --notes … <dmg>`。（详见 `docs/RELEASE.md`）

**只改 Copied-mac，只传 Copied-mac。根 README.md 不归你管。**

## Known limitations

- **Edge highlight**: Liquid Glass edge highlight is suppressed by the WindowServer compositor on non-key floating windows. The SwiftUI `.stroke(.white.opacity(0.25))` overlay compensates visually.
- **Window position constraint**: macOS constrains window frames to screen bounds. The window extends above `visibleFrame.maxY` using `screen.frame.maxY`, but further upward push is clamped by the WindowServer.
- **macOS 26+ only**: `.glassEffect()` requires macOS 26. Lower versions would need `NSVisualEffectView` fallback.
- **No Xcode project**: Built via `swiftc` in `build.sh`. To use Xcode, create a macOS App target and add all `.swift` files + `Info.plist`.
- **Frameworks**: SwiftUI, AppKit, QuickLookThumbnailing (file thumbnails), ServiceManagement (login item). `build.sh` also ad-hoc codesigns for SMAppService.
- **Settings**: Settings page (⌘, or menu → 设置…) with launch-at-login toggle (SMAppService, requires app in /Applications) and search engine picker (Google/Baidu/Bing/DuckDuckGo). Saved to UserDefaults `searchEngine`, read by `SearchTextAction`.
- **Translation not yet implemented**: macOS lacks a clean public translation API. Menu item is grayed-out placeholder.

