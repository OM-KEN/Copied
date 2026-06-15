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
CopiedApp.swift          Entry point: MenuBarExtra + AppDelegate
ClipboardMonitor.swift      Timer polls NSPasteboard.changeCount every 0.15s
ToastWindowController.swift Manages the floating NSWindow + NSHostingView
ToastViewModel.swift        @Observable model, icon logic
ToastView.swift             SwiftUI card layout + glassEffect + entry animation
SourceAppDetector.swift     NSWorkspace.frontmostApplication → name + icon
```

**Data flow:** `ClipboardMonitor` → `ClipboardContent` → `ToastWindowController.show()` → `NSHostingView` → `ToastView` (with `.glassEffect()`)

## Key design decisions

### Window: SwiftUI `.glassEffect()` (macOS 26+)

The toast uses SwiftUI's native `.glassEffect(in: .rect(cornerRadius: 32))` modifier (Liquid Glass), applied directly to the card inside `ToastView`. The window uses a plain `NSView` as content view — no `NSGlassEffectView` needed. The pseudo edge highlight is drawn as a SwiftUI `.stroke(.white.opacity(0.25))` overlay because the real edge highlight is suppressed by the WindowServer compositor on non-key floating windows.

Window config: `.borderless`, `.floating` level, `ignoresMouseEvents = true`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`.

### Entry animation: SwiftUI spring

All entry animation lives in `ToastView` via `@State + .onAppear + withAnimation(.interpolatingSpring)`:

| Property | Start | End |
|----------|-------|-----|
| `scaleEffect` | 0.2 | 1 |
| `offset(y:)` | -56 | 0 |
| `blur(radius:)` | 12 | 0 |
| `opacity` | 0 | 1 |

Spring: `mass: 1.2, stiffness: 120, damping: 14, initialVelocity: 3` (~550ms perceptual). Asymmetric padding (top:20, bottom:12, horizontal:18) outside the animation absorbs spring overshoot. Window positioned via `screen.frame.maxY` for tight-to-top placement.

Exit animation: 200ms AppKit `easeIn` fade-out (unchanged).

### Clipboard detection: pasteboard types, not readObjects

`readClipboardContent` checks `pasteboard.types` directly to determine the content category. Detection priority:

1. `.fileURL` → file (stores `fileURLs: [URL]`, used by `SourceAppDetector` for folder names)
2. `.tiff` / `.png` → image (generates 64×64 square thumbnail)
3. `.string` → text (with language detection)

Single image files from Finder get a thumbnail by reading the file via `NSImage(contentsOf:)`.

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

| Kind | Short text | Long text (≥50) |
|---|---|---|
| `.plain` | `text.alignleft` | `text.quote` |
| `.html` | `chevron.left.forwardslash.chevron.right` | same |
| `.code` / `.swift` / `.css` / `.python` / `.javascript` | `curlybraces` | same |

### Detail line format

- Plain short text: empty (not shown)
- Plain long text: `N字符`
- Code: `Swift · 120字符` (language label + character count if ≥50)
- Single non-image file: file size via `ByteCountFormatter` (e.g., "25 KB")
- Single image file: dimensions W×H (e.g., "84×84")
- Multiple files: `N个文件`
- Clipboard image (screenshot etc.): dimensions W×H

### Deduplication

500ms dedup window via `HashCode.Combine(type, preview)`. Same content within 500ms is silently dropped.

### Source app display

`SourceAppDetector.detect(for:)` reads `NSWorkspace.shared.frontmostApplication`. When it's Finder + `content.fileURLs` are present, the parent folder name replaces "访达". Multiple folders → `N个文件夹`.

### Menu bar

`MenuBarExtra` with `doc.on.clipboard` SF Symbol. Pause/resume via `@AppStorage("isPaused")` → `ClipboardMonitor` reads `UserDefaults` directly (avoids binding propagation complexity). `LSUIElement = YES` in Info.plist hides Dock icon.

## Known limitations

- **Edge highlight**: Liquid Glass edge highlight is suppressed by the WindowServer compositor on non-key floating windows. The SwiftUI `.stroke(.white.opacity(0.25))` overlay compensates visually.
- **Window position constraint**: macOS constrains window frames to screen bounds. The window extends above `visibleFrame.maxY` using `screen.frame.maxY`, but further upward push is clamped by the WindowServer.
- **macOS 26+ only**: `.glassEffect()` requires macOS 26. Lower versions would need `NSVisualEffectView` fallback.
- **No Xcode project**: Built via `swiftc` in `build.sh`. To use Xcode, create a macOS App target and add all `.swift` files + `Info.plist`.
