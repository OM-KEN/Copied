# Copied

### Copy Confirmation Toast & Smart Clipboard Actions for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift\&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)

**Know it was copied. See what you copied. Act on it instantly.**

Copied is a lightweight, open-source macOS utility that confirms every copy with an instant top-screen toast. It previews copied text, images, files, URLs, colors, calculations, and more, then suggests a relevant next action such as opening a link, revealing a file, searching, translating, or calculating.

Copied is not a traditional clipboard history manager. It focuses on the moment immediately after you copy, giving you visual confirmation, useful context, and a faster path to whatever comes next.

[Download the latest release](/OM-KEN/Copied/releases/latest)

![Copied preview](https://github.com/user-attachments/assets/c0a118a4-a140-468c-aa92-3043e8ba83f2)

## Why Copied?

Sometimes you press `⌘C`, but still wonder whether the copy actually worked, so you press it again just to be sure.

On Windows, I built a Quicker extension that showed a toast every time I copied something. It also supported a gesture I found especially useful: hold the left mouse button and click the right mouse button to copy. I wanted the same fast, visible feedback on macOS, so I built Copied.

As a UI designer, I also wanted it to feel at home on the Mac. The interface is native, lightweight, and designed to stay out of the way until it is useful.

With AI making software development more accessible, I took the idea one step further and added **smart next actions**.

Copy a sentence and trigger a search without opening a browser and pasting it manually. Copy an unfamiliar word or Chinese character and look it up immediately. Copy a color value and see the color directly in the toast. Copy a file or image and view its size, dimensions, and preview without opening Get Info.

Copied has one central goal: **make the moment after copying as fast as possible**.

The optional left-and-right mouse gesture is disabled by default, but I strongly recommend trying it. Select text, hold the left mouse button, click the right mouse button, and Copied immediately confirms the copy and prepares the next action.

## Highlights

* **Instant copy confirmation**
  Shows a top-screen toast whenever new content is copied.

* **Smart next actions**
  Displays a context-aware action such as opening a URL, revealing a file, calculating an expression, showing pronunciation or dictionary information, searching, or translating.

* **Rich content previews**
  Previews text, files, images, CSS colors, file sizes, image dimensions, and other useful metadata.

* **Fast keyboard trigger**
  Click the action button or double-tap the configured modifier key, `Control ⌃` by default, while the toast is visible.

* **Optional mouse copy gesture**
  Hold the left mouse button and click the right mouse button to copy selected content.

* **Native macOS design**
  Uses Liquid Glass on macOS 26 and a native material fallback on earlier supported versions, with dark mode support.

* **Local-first and lightweight**
  Built with Swift, AppKit, and SwiftUI. Content processing stays on your Mac, except for update checks.

* **No third-party dependencies**
  Uses native Apple frameworks and SF Symbols.

* **Low resource usage**
  Designed to remain responsive with minimal CPU overhead.

## Requirements

* macOS 14 or later

## Installation

1. Download the latest `.dmg` from [Releases](/OM-KEN/Copied/releases/latest).
2. Open the disk image.
3. Drag Copied into the Applications folder.
4. Launch Copied and copy anything to see the toast.

## Usage

Copy any supported content and Copied will show a preview at the top of the screen.

While the toast is visible, you can:

* Click the action button on the right.
* Double-tap the configured modifier key, `Control ⌃` by default.
* Open the context menu for additional actions.
* Expand longer content for a full preview.
* Use a configured mouse side button as a quick trigger.

Examples:

* Copy a URL to open it.
* Copy a file path to reveal the file in Finder.
* Copy a calculation to see the result.
* Copy a date or time to view contextual date information.
* Copy a Chinese character or English word to check its pronunciation or definition.
* Copy a CSS color to preview it instantly.
* Copy text to search or translate it.

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
* English words and phrases
* Source code
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

## Plugins

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
  MenuBarExtra, AppDelegate, and Settings

ClipboardMonitor.swift
  Polls NSPasteboard.changeCount every 0.15 seconds
  Includes the app blacklist filtering gate

CopyGestureManager.swift
  Shared CGEventTap for the left-button + right-button copy gesture
  Includes dual event paths and an R_UP fallback

DetectionRegistry.swift
  Global detector registry, priority pipeline, and throttling

ContentKind.swift
  Unified content-type identifiers using a struct and static constants

AppLanguage.swift
  Bundle language policy
  Filters English-word detection in English UI environments

Detectors/
  15 built-in content detectors

DictionaryLookupService.swift
  Dictionary lookup through DCSCopyTextDefinition

PluginLoader.swift
  Scans, validates, and loads .copiedplugin folders

PluginManifest.swift
  Plugin manifest, rule models, and compiled rules

PluginAction.swift
  Executes plugin actions such as openURL, search, and transform

PluginActionTemplate.swift
  Plugin action templates with menuOnly and multiline configuration

AppFilterSettings.swift
  App blacklist singleton, filtering logic, and persistence

AppFilterView.swift
  Settings interface for blacklist management and running-app selection

BlacklistSourceAppAction.swift
  Context-menu action for blocking the current source app

ClipboardAction.swift
  Action protocol, built-in actions, and ActionResolver

KeyboardShortcutSettings.swift
  Modifier-key trigger, single/double-tap mode, and side-button settings

QuickTriggerModifierKeyPolicy.swift
  Tracks left and right modifier-key states using their actual key codes

MouseButtonRecordingStateMachine.swift
  Handles side-button recording, cancellation, and binding decisions

AppUpdateService.swift
  GitHub Releases update checks, caching, throttling, and reminders

ToastWindowController.swift
  Floating NSWindow, NSHostingView, actions, and quick-trigger handling

ToastViewModel.swift
  @Observable model, including sourceBundleID

RelativeDateDescription.swift
  Localized relative date and calendar-day descriptions

ToastView.swift
  SwiftUI toast card
  Liquid Glass on macOS 26+, ultraThinMaterial fallback
  Expandable full-text preview and context menu

LightReminderController.swift
  Lightweight reminder indicator using NSWindow
  drawOff on macOS 26+, opacity fallback on earlier versions

TypeSettingsView.swift
  Smart Recognition settings and plugin management

SettingsView.swift
  Launch at login, search engine, quick trigger, recognition,
  gestures, blacklist, and lightweight reminder settings

FilePreviewGenerator.swift
  Asynchronous thumbnails through QLThumbnailGenerator

SourceAppDetector.swift
  Detects the frontmost app and its bundle identifier

Localizable.xcstrings
  String Catalog with Simplified Chinese as the source language,
  plus English and Traditional Chinese

build.sh
  swiftc, xcstringstool, actool, and codesign build pipeline
```

## Privacy

Copied processes copied content locally on your Mac. It does not send clipboard content to a remote service. Network access is only used to check GitHub Releases for updates.

## License

Copied is open source under the [MIT License](LICENSE).
