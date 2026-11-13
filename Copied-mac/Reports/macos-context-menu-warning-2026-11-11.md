# macOS 菜单焦点警告排查

日期：2026-11-11。验证系统：macOS 27.2（26B123），Apple Silicon。
用户报告系统：macOS 27.2.1（26B131）；本机未运行该精确构建。

## 结论

本机复现的 `AppKit._NSGlassEffectWindow` / `canBecomeKeyWindow == NO` 警告来自 AppKit 原生右键菜单的内部窗口排序与焦点处理。它不是 Copied 独有的问题，也不需要 Copied 代码、应用侧 SwiftUI 界面、窗口捕获或诊断拦截才能触发。

Copied 通过标准原生菜单触发这条系统路径；没有观察到 Copied 对该私有玻璃辅助窗口直接调用 `makeKey()`。对照菜单正常打开和关闭，因此这条警告本身不是设置窗口无法前置的证据。设置入口单独通过统一激活流程修复；本警告没有引入生产窗口变更或日志屏蔽。

## 证据

1. 使用 Copied 的生产 `ToastWindowController`，仅提供合成文本，且不启动剪贴板监听。右键打开卡片菜单时，2026-11-11 17:52:02.285 捕获了与 [issue #23](https://github.com/OM-KEN/Copied/issues/23) 同签名的警告，并取得触发调用栈。
2. 仅使用 AppKit 的普通 `NSWindow`、`NSButton` 和 `NSMenu`，不包含 SwiftUI 或 Copied 代码。右键打开按钮菜单，17:53:59.831 产生同样警告；关键 AppKit 调用栈与生产卡片一致。
3. 最终控制去掉所有方法拦截，也不进行窗口捕获。独立程序调用公开的 `NSMenu.popUp(positioning:at:in:)`，17:56:46.224 再次产生同样警告。程序输出 `MENU_WILL_OPEN`、`MENU_DID_CLOSE`、`MENU_POPUP_RETURNED false` 并正常退出（exit 0）；false 对应测试主动取消菜单。

关键调用路径（省略诊断拦截器与普通事件循环）：

```text
NSView rightMouseDown:
  NSView _showMenuForEvent:
    NSMenu _popUpContextMenu:...
      NSContextMenuImpl / NSPopupMenuWindow
        NSPopupMenuWindow updateWindowFrameTo:offset:animated:completion:
          NSWindow _synchronizeOrderingGroupVisibility
            NSWindow _makeKeyRegardlessOfVisibility
              NSWindow makeKeyWindow
                AppKit._NSGlassEffectWindow.canBecomeKeyWindow == NO
```

窗口快照还确认：真实菜单窗口 `NSPopupMenuWindow` 允许成为 key window；警告指向的是它的 `_NSGlassEffectWindow` 子窗口，该子窗口不允许成为 key window。

AppKit 在同步弹出菜单窗口组时，尝试让系统玻璃辅助窗口成为 key window，但该辅助窗口不允许成为 key window，于是输出警告。该次系统调用路径没有 Copied 的菜单业务处理或窗口命中代码。

## 最小复现

将下面的源码保存为 `AppKitMenuReproducer.swift`。它仅使用 AppKit，没有窗口方法替换、私有 API、应用侧 SwiftUI、剪贴板访问或窗口捕获代码；自动弹出原生菜单，再用事件跟踪 RunLoop 中的计时器正常取消。

```swift
import AppKit

final class MenuProbeDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow?
    let menu = NSMenu()
    let button = NSButton(title: "Synthetic menu anchor", target: nil, action: nil)
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("NO_HOOK_NO_CAPTURE pid=\(ProcessInfo.processInfo.processIdentifier)")
        let window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 400,height: 200),styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        button.frame = NSRect(x: 30,y: 60,width: 300,height: 60)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Synthetic option A",action: nil,keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Synthetic option B",action: nil,keyEquivalent: ""))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let closeTimer = Timer(timeInterval: 0.7, repeats: false) { _ in self.menu.cancelTracking() }
            RunLoop.main.add(closeTimer, forMode: .eventTracking)
            RunLoop.main.add(closeTimer, forMode: .common)
            let result = self.menu.popUp(positioning: nil, at: NSPoint(x: 20,y: 20), in: self.button)
            print("MENU_POPUP_RETURNED \(result)")
            NSApp.terminate(nil)
        }
    }
    func menuWillOpen(_ menu: NSMenu) { print("MENU_WILL_OPEN") }
    func menuDidClose(_ menu: NSMenu) { print("MENU_DID_CLOSE") }
}
@main struct ProbeMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuProbeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
```

```sh
swiftc -parse-as-library -target arm64-apple-macosx14.0 AppKitMenuReproducer.swift -o AppKitMenuReproducer
./AppKitMenuReproducer
```

随后检查该进程的系统日志，筛选 `makeKeyWindow`。此复现不参与 Copied 的构建。

## 边界

这是本机运行证据，不代表 Apple 已公开确认该问题，也未在其他 macOS 构建上验证。原报告的 19 条日志没有逐条操作时序和调用栈，无法逐条证明它们全部由同一种菜单操作触发；但相同警告及其系统内部触发路径已经在不含 Copied 的程序中得到验证。

临时应用、原始日志、诊断方法拦截和测试偏好已清理；这里只保留复现源码及脱敏结论。
