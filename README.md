https://github.com/user-attachments/assets/658eb81e-d57e-4ef9-93c6-4ed20cb5f88c

# Copied

### Copy Confirmation Toast & Smart Clipboard Actions for macOS

English | [简体中文](README.zh-CN.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift\&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

**Know it was copied. See what you copied. Act on it instantly.**

Copied is a lightweight, open-source macOS utility that confirms every copy with an instant top-screen toast. It previews all copied content, then suggests a relevant **next action** such as opening a link, revealing a file, searching, translating, or calculating.

Copied is not a traditional clipboard history manager. It focuses on the moment immediately after you copy, giving you visual confirmation, useful context, and a faster path to whatever comes next.

[Download the latest release](https://github.com/OM-KEN/Copied/releases/latest)

## Why Copied?

Sometimes you press `⌘C`, but still wonder whether the copy actually worked, so you press it again just to be sure.

On Windows, I built a Quicker extension that showed a toast every time I copied something. It also supported a gesture I found especially useful: hold the left mouse button and click the right mouse button to copy. I wanted the same fast, visible feedback on macOS, so I built Copied.

As a UI designer, I also wanted it to feel at home on the Mac. The interface is native, lightweight, and designed to stay out of the way until it is useful.

With AI making software development more accessible, I took the idea one step further and added **smart next actions**.

Copy a sentence and trigger a search without opening a browser and pasting it manually. Copy a color value and see the color directly in the toast. Copy a file or image and view its size, dimensions, and preview without opening Get Info.

Copied has one central goal: **make the moment after copying as fast as possible**.

The optional left-and-right mouse gesture is disabled by default, but I strongly recommend trying it. Select text, hold the left mouse button, click the right mouse button, and Copied immediately confirms the copy and prepares the next action.

## Highlights

* **Instant copy confirmation**
  Shows a top-screen toast whenever new content is copied.

* **Smart next actions**
  Displays a context-aware action such as opening a URL, revealing a file, calculating an expression, or searching.

* **Rich content previews**
  Previews text, word count, files, images, **CSS colors**, file sizes, image dimensions, and other useful metadata.

* **Fast keyboard trigger**
  Click the action button or double-tap the configured modifier key, `Control ⌃` by default, while the toast is visible.

* **Optional mouse copy gesture**
  Hold the left mouse button and click the right mouse button to copy selected content.

* **Native macOS design**
  Uses Liquid Glass on macOS 26+ and a native material fallback on earlier supported versions, with dark mode support.

* **Local-first and lightweight**
  Built with Swift, AppKit, and SwiftUI. Content processing stays on your Mac, except for update checks.

* **No third-party dependencies**
  Uses native Apple frameworks and SF Symbols.

* **Low resource usage**
  Designed to remain responsive with minimal CPU overhead.

## Requirements

* macOS 14 or later

## Installation

1. Download the latest `.dmg` from [Releases](https://github.com/OM-KEN/Copied/releases).
2. Open it.
3. Drag Copied into the Applications folder.
4. Launch Copied and try copying anything.

## Usage

Copy any content and Copied will show a preview at the top of the screen.

While the toast is visible, you can:

* Click the action button on the right.
* Double-tap the configured modifier key, `Control ⌃` by default.
* Open the context menu for additional actions.
* Expand longer content for a full preview.
* Use a configured mouse side button as a quick trigger.

Examples:

* Copy a URL to open it. Try → `www.google.com`
* Copy a file path to reveal the file in Finder. Try → `/System/Applications/System Settings.app`
* Copy a calculation to see the result. Try → `111111111*111111111`
* Copy a date or time to view contextual date information. Try → `Jan 1, 2077`
* Copy a CSS color to preview it instantly. Try → `rgb(1, 102, 239)` or `#0166ef`
* Copy text to search or copy text over 50 characters to save it separately. Try → `a​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​​b` (There are a lot of Zero-Width Space hidden in here)

## Supported Content

Copied can recognize and preview:

* Plain text
* Files and folders
* Images
* URLs
* File paths
* Email addresses
* Phone numbers
* Mathematical expressions
* Dates and times
* Chinese characters
* Code
* Hex, RGB, HSL, and other CSS color values

Recognition for individual content types can be enabled or disabled in Settings.

## Customization

Copied includes settings for:

* Launch at login
* Search engine
* Quick-trigger modifier key
* Single-tap or double-tap trigger mode
* Mouse side-button shortcuts
* Smart recognition types
* Copy gesture
* App blacklist
* Lightweight reminder mode
* Plugins

## Plugins (Experimental)

Copied supports `.copiedplugin` folders for custom detection rules and actions.

Plugins can define:

* Pattern-based content detection
* Search actions
* URL actions
* Text transformations
* Menu-only actions
* Multiline behavior

Plugin folders are scanned, validated, compiled, and loaded locally.

## Build from Source

Copied is compiled directly with Swift.

```bash
git clone https://github.com/OM-KEN/Copied.git
cd Copied/Copied-mac
./build.sh
```

On macOS 26 or later, the project can be built without an Xcode project file. Earlier supported macOS versions may require Xcode Command Line Tools.

## Architecture

```text
CopiedApp.swift
ClipboardMonitor.swift
CopyGestureManager.swift
DetectionRegistry.swift
ContentKind.swift
AppLanguage.swift
Detectors/
DictionaryLookupService.swift
PluginLoader.swift
PluginManifest.swift
PluginAction.swift
PluginActionTemplate.swift
AppFilterSettings.swift
AppFilterView.swift
BlacklistSourceAppAction.swift
ClipboardAction.swift
KeyboardShortcutSettings.swift
QuickTriggerModifierKeyPolicy.swift
MouseButtonRecordingStateMachine.swift
AppUpdateService.swift
ToastWindowController.swift
ToastViewModel.swift
RelativeDateDescription.swift
ToastView.swift
LightReminderController.swift
TypeSettingsView.swift
SettingsView.swift
FilePreviewGenerator.swift
SourceAppDetector.swift
Localizable.xcstrings
build.sh
```

## Privacy

Copied processes copied content locally on your Mac. It does not send clipboard content to a remote service. Network access is only used to check GitHub Releases for updates.

## License

Copied is open source under the [MIT License](LICENSE).
