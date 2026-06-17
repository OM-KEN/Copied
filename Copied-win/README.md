# Copied

Windows 智能复制反馈工具——每次按下 Ctrl+C，鼠标附近弹出精美的 Toast 通知，清晰展示复制内容，无需再担心"到底复制成功了吗"。

## 特性

- 监听所有复制操作（Ctrl+C、右键复制、菜单复制、应用内复制），无需键盘 Hook
- 支持四种内容类型：文本、图片（含缩略图）、文件、网页内容
- Apple 风格浮动卡片 UI，Material 3 矢量图标
- 入场/退场流畅动画
- 相同内容 500ms 内自动去重，避免重复弹窗
- 显示来源应用名称及图标
- 屏幕顶部居中显示，入场从上方滑入
- 支持亮色/暗色模式，可跟随 Windows 系统主题或手动指定
- 配置热重载，无需重启
- 系统托盘图标，支持暂停/恢复
- 事件驱动，CPU 占用接近 0%，内存 20–40MB

## 系统要求

- Windows 10 1803+ 或 Windows 11
- .NET 8 Desktop Runtime（非自包含部署时需要）

## 安装

### 下载运行（推荐）

从 Release 页面下载 `Copied.exe`，双击运行即可。自包含部署，无需安装 .NET。

### 从源码构建

```powershell
git clone <repo-url>
cd Copied
dotnet build
dotnet run
```

发布单文件 exe：
```powershell
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

## 使用

启动后，应用进入系统托盘。按下 Ctrl+C 复制任意内容，Toast 即出现在屏幕顶部居中。

托盘菜单：
- **暂停复制反馈** — 临时关闭通知
- **退出** — 关闭应用

## 配置

编辑 `appsettings.json`（与 exe 同目录），保存后即时生效：

```jsonc
{
  "Theme": "System",               // "System" 跟随 Windows | "Light" 亮色 | "Dark" 暗色
  "Animation": {
    "EnterMs": 800,                // 入场动画时长
    "StayMs": 2000,               // 停留时长
    "ExitMs": 200                 // 退场动画时长
  },
  "DeduplicationWindowMs": 500,   // 去重窗口
  "MaxVisibleToasts": 3           // 同时最多显示几个 Toast
}
```
