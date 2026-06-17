# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Copied — Windows 智能复制反馈工具。按下 Ctrl+C 后在鼠标附近弹出 Apple 风格 Toast，显示复制内容。WPF (.NET 8) 单文件应用。

## Build & Run

```powershell
# 调试运行（控制台可见 Debug 输出）
dotnet run

# 构建
dotnet build

# 发布 Portable 单文件 (输出到 ../publish/)
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o ../publish
```

## 分发（Portable）

单文件便携版，解压即用，不在系统其他位置留文件：

- `Copied.exe` — 自包含（含 .NET 运行时，~68MB），双击启动
- `appsettings.json` — 首次启动自动生成，用户可编辑
- `iconcache.bin` — 图标缓存，首次复制后自动生成，可删除

文件路径均基于 `Environment.ProcessPath`（exe 实际位置），非 `AppContext.BaseDirectory`（单文件发布时指向临时解压目录）。

## Technical stack / constraints

- **WPF + .NET 8.0-windows**, 附带 `<UseWindowsForms>true</UseWindowsForms>`（用于 NotifyIcon 托盘图标和 Screen 多屏 API）
- **启动对象**: `Copied.Program`（非 App.xaml 自动生成的 Main；csproj 通过 `<StartupObject>` 指定）
- **DPI**: `PerMonitorV2`（csproj `ApplicationHighDpiMode`，不用 app.manifest 中的 DPI 声明）
- **单实例**: Mutex `"Copied_SingleInstance_4F8B2A1C"`
- `App.xaml` 仅作资源容器，`ShutdownMode="OnExplicitShutdown"` — 不自动退出

## 类型歧义警告

因为同时引用了 WPF 和 WinForms，`Color`、`FontFamily`、`Brushes`、`Application`、`Timer` 等类型在两个命名空间中共存。**在 `Views/` 下的文件中必须使用完全限定名**：
- `System.Windows.Media.Color`、`System.Windows.Media.FontFamily`、`System.Windows.Media.Brushes`
- `System.Windows.Application.Current`、`System.Windows.Threading.DispatcherTimer`
- `System.Threading.Timer`

## 核心架构

### 数据流
```
WM_CLIPBOARDUPDATE → ClipboardMonitor.WndProc → ToastOrchestrator.OnClipboardChanged()
  ├─ ContentDetector    — IsClipboardFormatAvailable (不打开剪贴板, <0.1ms)
  ├─ ClipboardReader    — Open→GetData→GlobalLock→copy→Unlock→Close (必须 STA 线程)
  ├─ DeduplicationService — HashCode.Combine(type, preview) 500ms 去重
  ├─ IContentParser     — 根据 ContentType 解析
  ├─ SourceDetector     — 前台应用友好名（含中文映射）+ 应用图标（ExtractAssociatedIcon→PNG）
  ├─ ThemeService       — 解析 Theme 配置 + 注册表检测系统主题 → 切换 App 资源字典
  └─ ToastWindow        — WPF Window, 定位→入场动画→停留→退场动画→Close
```

### 关键类

| 类 | 职责 |
|---|---|
| `ClipboardMonitor` | `HwndSource` 隐藏窗口 + `AddClipboardFormatListener`，收到 `WM_CLIPBOARDUPDATE` 触发 event |
| `ClipboardReader` | `OpenClipboard`/`CloseClipboard` 生命周期，`GlobalLock`/`Unlock` 配对，支持 try-finally 和 ERROR_ACCESS_DENIED 重试 |
| `ContentDetector` | 格式优先级: Text > Files > Image(CF_BITMAP\|CF_DIB\|CF_DIBV5) > Html |
| `ToastOrchestrator` | 中心协调器，持有 `DeduplicationService` + `ConfigurationService`，响应 `ConfigChanged` 热重载 |
| `ConfigurationService` | `FileSystemWatcher` 监听 `appsettings.json` 变更，`ToastConfiguration` 强类型 |
| `DeduplicationService` | `ConcurrentDictionary<long, DateTime>` + 后台 `Timer` 清理过期条目 |
| `TrayIconService` | `NotifyIcon` 托盘菜单（暂停/恢复/退出） |
| `ThemeService` | 静态工具类，读 `Theme` 配置 + `HKCU\...\AppsUseLightTheme` 注册表 → 切换 `App.Resources.MergedDictionaries`（LightTheme.xaml / DarkTheme.xaml） |
| `SmoothCornerHelper` | 生成 iOS 风格 Squircle（超椭圆）裁剪路径，卡片 r=32（动态尺寸）、缩略图 r=16（64×64） |
| `ToastWindow` | WPF `Window`，`AllowsTransparency=True`，`WS_EX_TOOLWINDOW\|NOACTIVATE\|TOPMOST`（`WS_EX_TRANSPARENT` 已于 2026-06-17 移除以支持鼠标交互） |

### 关键代码模式

**剪贴板访问必须严格配对**：所有 `OpenClipboard`/`CloseClipboard`、`GlobalLock`/`GlobalUnlock` 必须用 try-finally，否则会阻塞其他应用的剪贴板。

**图片缩略图生成** (`ImageContentParser`)：从 `CF_DIB` 读取→解析 `BITMAPINFOHEADER`→`BitmapSource.Create`→`TransformedBitmap` 缩放→`RenderTargetBitmap` 渲染（纯矩形，圆角由显示层 Squircle Clip 负责）→`PngBitmapEncoder` 编码为 `byte[]`。`ClipboardContentInfo.ThumbnailPng` 承载 PNG 字节。注意：Windows DIB 默认 bottom-up（`biHeight>0`），必须在 `BitmapSource.Create` 后做 `ScaleTransform(1,-1)` 翻转，否则图像上下颠倒。

**单图片文件** (`FileDropContentParser`)：复制图片文件时检测扩展名 → 生成缩略图 + 读取尺寸 → 作为 Image 类型展示，来源显示所在文件夹名。

**缩略图裁剪**：`ToastWindow.xaml` 中 `ThumbBorder` 用 Squircle Clip（`cornerRadius=16`）替代 `CornerRadius`+`ClipToBounds`，避免双重圆角导致的边缘模糊。无棋盘格，透明区域直接透出卡片背景。\

**动画**：嵌套结构 `CardBorder`→`ContentGrid`。`CardScale`（RootGrid）缩放卡片，`ContentScale`（ContentGrid）叠加缩放内容，双层 `ElasticEase` 差异化弹跳（卡片 `Springiness=5`，内容 `Springiness=7`，内容 `BeginTime=50ms` 滞后）。`RootBlur`（RootGrid BlurEffect）Radius 24→0 CubicEase 入场去模糊。入场滑动为 `Window.Top` 动画（-160px→目标位置，从上方落下）。入场 800ms，退场仅 200ms 透明度淡出。鼠标悬停暂停自动消失计时（入场动画期间不响应），点击立即退场。

## 配置 (appsettings.json)

```jsonc
{
  "Theme": "System",              // "System"=跟随 Windows | "Light"=亮色 | "Dark"=暗色
  "Animation": { "EnterMs": 800, "StayMs": 2000, "ExitMs": 200 },
  "DeduplicationWindowMs": 500,
  "MaxVisibleToasts": 3
}
```

Toast **固定使用 TopCenter 模式**：出现在光标所在屏幕顶部居中，入场从上方 160px 落下。滑动通过 `Window.Top` 动画实现。

> **注意**：Cursor（跟随鼠标）模式已于 2026-06-17 移除。`ToastWindow` 构造函数和 `ToastOrchestrator` 中不再接受 `displayMode` 参数，`ToastConfiguration` 中不再有 `DisplayMode` 属性。**不要再次添加 Cursor 模式切换逻辑。**

`Theme` 控制 Toast 卡片配色：`"System"` 通过注册表 `AppsUseLightTheme` 检测 Windows 主题；`"Light"` / `"Dark"` 强制指定。主题切换通过替换 `App.Resources.MergedDictionaries` 中的 `Themes/LightTheme.xaml` / `Themes/DarkTheme.xaml` 实现，XAML 中使用 `{DynamicResource}` 绑定颜色和阴影参数。修改后下一个 Toast 生效（热重载）。

## WPF 踩坑记录

1. **`Window.RenderTransform` 抛出 `InvalidOperationException`（"转换对于 Window 无效"）**：缩放用 `Border`/`Grid` 的 `RenderTransform`；入场滑动改用 `Window.Top` 动画（`this.BeginAnimation(TopProperty, ...)`）替代 `TranslateTransform`。
2. **`StartupObject` 自定义 Main 时**，`App.xaml` 仍然被编译为 partial class（含 `InitializeComponent`），但不会自动生成 `Main()`。
3. **`SetWindowCompositionAttribute` 丙烯酸模糊** 会让整个 `Window` 客户区（包括 Margin 透明区域）染上 tint 色，造成大白底。当前代码已禁用，卡片背景色由主题资源字典控制（亮色 `#F7F7FA` / 暗色 `#000000`），用 `DropShadowEffect` 模拟边框替代毛玻璃效果。
4. **窗口位置闪烁**：`Show()` 时窗口先在默认位置 (0,0) 出现一帧，然后 `OnContentRendered` 才重定位。解决方案：XAML 设置 `Left="-10000" Top="-10000" WindowStartupLocation="Manual"`，在 `OnContentRendered` 中定位后再渲染。
5. **`AllowsTransparency="True"` 时 `Background="Transparent"` 才是真正的透明窗口**；设置 `Background` 为其他颜色会导致整个窗口矩形渲染该颜色，即使在 Margin 区域。
6. **Squircle Clip 需在布局完成后生成**：卡片和缩略图均使用 `SmoothCornerHelper.CreateSquircleClip`（超椭圆 curvePower=2.3）。缩略图尺寸固定（64×64），在构造函数中直接设置；卡片尺寸由内容决定，在 `OnContentRendered` 中用 `ActualWidth/Height` 动态生成，需 `_cardClipGenerated` 标志位防止重复设置。

## UI 设计规范

所有颜色和阴影参数通过 `{DynamicResource}` 绑定到 `Themes/LightTheme.xaml` / `Themes/DarkTheme.xaml` 资源字典，由 `ThemeService` 根据配置切换。详细规范见 [DESIGN.md](DESIGN.md)。

- 圆角：卡片 Squircle `32px`（`OnContentRendered` 中用 `ActualWidth/Height` 动态生成），缩略图 Squircle `16px`（固定 64×64），均通过 `SmoothCornerHelper.CreateSquircleClip` + `curvePower=2.3` 实现
- 卡片无实体描边——用 `DropShadowEffect`(BlurRadius=3, ShadowDepth=0) 模拟边框，亮色模式黑色阴影，暗色模式白色阴影（纯黑背景 `#000000` 上看不见黑色阴影）
- 图标 Material 3 rounded 矢量 Path，32×32 Viewbox
  - Text→text_fields, Image→image, Files→description, HTML→code
- 字体 `Segoe UI, Microsoft YaHei UI`，SemiBold(600)，ClearType + ClearTypeHint
  - 文字色必须为**不透明**，半透明色会导致 ClearType 回退灰度抗锯齿
- 预览文字 14px LineHeight=20，Meta 文字 12px LineHeight=16
- 阴影：外层环境光 `BlurRadius=20 ShadowDepth=2`，内层模拟边框 `BlurRadius=3 ShadowDepth=0`，颜色和透明度由主题资源字典控制
- 预览行数：文本≤2行，图片/文件≤1行（NoWrap，超出省略）
- 短文本（≤100 字符且 ≤2 行）只显示内容，超长时才显示字符数
- 来源显示格式：`复制自 [16×16 应用图标] 应用友好名`（记事本/Chrome/VS Code 等）；文件类型显示所在文件夹名。图标从源进程 exe 提取（`ExtractAssociatedIcon`），提取失败时仅显示文字
- 卡片 + 缩略图均使用 Squircle 平滑圆角（`SmoothCornerHelper`，curvePower=2.3），卡片在 `OnContentRendered` 中动态生成，缩略图在构造函数中固定尺寸生成
