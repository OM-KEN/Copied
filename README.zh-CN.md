https://github.com/user-attachments/assets/658eb81e-d57e-4ef9-93c6-4ed20cb5f88c

# Copied

### 适用于 macOS 的复制确认提示与智能剪贴板操作

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift\&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

**确认已经复制。查看复制内容。智能推荐下一步操作。**

Copied 是一款轻量、开源的 macOS 工具。每当你复制内容时，它都会立即在屏幕顶部显示一条提示，确认复制操作已经完成。它可以预览复制的所有内容，并根据内容推荐合适的下一步操作，例如打开链接、显示文件位置、搜索、翻译或计算。

Copied 不是一款传统意义上的剪贴板历史管理工具。它只给你复制后的视觉反馈、有用的内容预览，以及更快捷的下一步操作。

## 为什么做 Copied？
有时候明明复制了，却总会怀疑到底成功了没，然后下意识再多按几次。在 Windows 上，我用 Quicker 写过插件，让我的每次复制都会有 Toast 提醒，还有一个特别好用的功能：按住左键点右键就能复制。于是，我也在 Mac 上实现了复制提醒和左右键复制。作为 UI 设计师，我也尽量做到既原生又美观，先满足自己——**能让自己每天都能用得舒服的 app 才是好 app**。

现在 AI 写代码更容易了，于是我也更进一步，增加了复制后的“**下一步操作**”。比如复制一句话，不用打开网页再粘贴搜索，只要再双击一下快捷键（默认是control ⌃）就能**直接搜**。遇到不会读的单词、生僻字，或者忘记单词意思，也是一样。作为设计师，我复制了某个色值，也不用打开设计软件粘贴再看了，现在复制后弹窗**直接显示颜色**。文件大小、图片尺寸等信息，也不用反复切视图或者右键“显示简介”，复制一下就能看到。

做这个 App 的唯一目标就是快。所以我尽量使用**原生功能**，让它保持**轻量、简洁**。左右键复制默认关闭，但我非常推荐打开，因为鼠标已经选中文本后，再去按 ⌘+C 已经慢了。选中内容，按住左键点一下右键，**马上复制、马上预览、马上进行下一步操作，唯快不破**。

## 功能特征

- **复制弹窗**：监听所有复制操作，弹窗预览已复制的内容
- **快捷操作按钮**：根据内容类型在弹窗右侧显示对应操作按钮（打开链接、定位文件、计算、显示拼音、搜索、翻译）
- **文件、图片、颜色等预览**：复制文件、图片，显示预览小图；复制 #FF6B6B 或CSS颜色，显示预览颜色
- 原生液态玻璃 UI和动效、深色模式适配
- 纯 Swift + AppKit + SwiftUI，纯本地（检查更新除外），零第三方依赖
- 使用 Apple SF Symbols 作为图标系统
- CPU 占用极低

## 系统要求

目前支持 macOS 14+

## 使用

[下载 `dmg`](https://github.com/OM-KEN/Copied/releases/latest)，拖动 app 到 Applications。复制任意内容，显示弹窗。

弹窗显示期间，**点击右侧按钮或双击 ⌃ 键**可触发右侧操作按钮（如计算、打开链接、搜索）。

菜单栏中的“重现上一个弹窗”可以恢复最后一次显示的卡片，保留原来的操作和结果；不重新复制，也不播放复制音效。只在内存保存一张快照，从首次显示起保留最多 10 分钟，重现不续期；缓存内容预算为 8 MiB。到期、暂停或超出预算会清空记录；仅提醒模式和被屏蔽来源禁用重现。

## 支持的类型

普通文本、文件、URL、文件路径、邮箱、电话、算式、日期、汉字、英文、代码

## 构建

源码构建需要 Xcode 26，用于编译字符串目录和 App 图标；脚本使用 Apple Development 身份签名，无需 Xcode 工程文件。

```bash
git clone https://github.com/OM-KEN/Copied.git
cd Copied/Copied-mac
./build.sh
open .build/Copied.app
```

在同一目录运行 `./run-tests.sh` 可执行测试。

## 架构

[ClipboardMonitor](Copied-mac/ClipboardMonitor.swift) 用[自适应轮询](Copied-mac/ClipboardPollingPolicy.swift)发现剪贴板变化。通过筛选与隐私检查的复制可以先显示确认，再由 [ClipboardPipeline](Copied-mac/ClipboardPipeline.swift) 在后台读取和处理，过期结果不会覆盖新反馈。[CopySoundFeedback](Copied-mac/CopySoundFeedback.swift) 在后台处理音效。

交互细节见[设计规范](Copied-mac/DESIGN.md)和 [UI 规范](Copied-mac/UI_GUIDELINES.md)。

## 许可证

本项目基于 [MIT License](LICENSE) 开源。
