# Copied 设计规范

## 设计理念

Apple 风格的浮动通知卡片——轻盈、克制、不打扰。支持亮色（微蓝灰底 `#F7F7FA`）和暗色（纯黑底 `#000000`）双主题，Squircle 超椭圆平滑圆角，微妙的双层阴影层次，干净的 SemiBold 字体排版。不抢键盘焦点，不打断工作流。

## 视觉系统

### 色彩

主题通过 `Themes/LightTheme.xaml` / `Themes/DarkTheme.xaml` 资源字典管理，由 `ThemeService` 根据 `appsettings.json` 中 `Theme` 配置（`"System"` / `"Light"` / `"Dark"`）切换。

**亮色模式：**

| 用途 | 色值 | 说明 |
|------|------|------|
| 卡片背景 | `#F7F7FA` | 微蓝灰 |
| 卡片边框 | 无实体描边 | 用 DropShadowEffect(BlurRadius=3,ShadowDepth=0,黑色,Opacity=0.18) 模拟，避免 AllowsTransparency 窗口锯齿 |
| 预览文字 | `#3E3E3E` | 预合成不透明色（Figma rgba(0,0,0,0.75) 等效），确保 ClearType 工作 |
| Meta 文字 | `#949496` | 预合成不透明色（Figma rgba(0,0,0,0.4) 等效） |
| 图标填充 | `#555555` | Material 3 风格 |

**暗色模式：**

| 用途 | 色值 | 说明 |
|------|------|------|
| 卡片背景 | `#000000` | 纯黑 |
| 卡片边框 | 无实体描边 | 用 DropShadowEffect(BlurRadius=3,ShadowDepth=0,白色,Opacity=0.125) 模拟——纯黑背景看不见黑色阴影 |
| 预览文字 | `#E8E8E8` | 浅灰白 |
| Meta 文字 | `#8E8E93` | Apple 暗色模式辅助色 |
| 图标填充 | `#CCCCCC` | 浅灰 |

### 字体

| 层级 | 字号 | 字重 | 颜色资源 | 行高 |
|------|------|------|----------|------|
| 预览文字 | 14px | SemiBold (600) | `PreviewTextBrush` | 20px |
| 来源应用 | 12px | SemiBold (600) | `MetaTextBrush` | 16px |
| 详情信息 | 12px | SemiBold (600) | `MetaTextBrush` | 16px |

字体系列：`Segoe UI, Microsoft YaHei UI`（英文用 Segoe UI 静态版，中文回退微软雅黑 UI；不用 Variable 版——在小字号+透明窗口下 opsz 光学校正轴导致渲染异常）。

渲染模式：`ClearType` + `Display` 对齐 + `RenderOptions.ClearTypeHint="Enabled"`。文字色必须为**不透明**——Layered Window 上半透明色强制灰度抗锯齿，导致模糊。

### 来源图标

来源行格式：`复制自 [16×16 应用图标] 应用名称`。应用图标通过 `System.Drawing.Icon.ExtractAssociatedIcon` 从源进程的 exe 中提取，转为 PNG 后在 WPF Image 控件中渲染。提取失败时（系统进程、跨位数等）图标区域自动隐藏，仅显示文字。

| 元素 | 尺寸 | 间距 |
|------|------|------|
| 来源图标 | 16×16 | 左右各 4px |
| "复制自" 标签 | 12px SemiBold `MetaTextBrush` | — |
| 来源名称 | 12px SemiBold `MetaTextBrush` | — |

### 阴影

双层结构，模拟物理卡片浮空感。颜色和透明度由主题资源字典控制（`{DynamicResource}` 绑定），亮色模式黑色阴影，暗色模式白色阴影。

| 层 | BlurRadius | ShadowDepth | 方向 | 亮色不透明度 | 暗色不透明度 | 用途 |
|----|-----------|-------------|------|------------|------------|------|
| 环境阴影 | 20px | 2px | 270° (向下) | 0.12 | 0.15 | 卡片浮空感 |
| 边框阴影 | 3px | 0 | 270° | 0.18 | 0.125 | 模拟 1px 描边，无锯齿 |

### 圆角

卡片和缩略图均使用 **Squircle 平滑圆角**（超椭圆，curvePower=2.3），通过 `SmoothCornerHelper.CreateSquircleClip` 生成 Clip 路径：

| 元素 | 圆角半径 | 尺寸 | 生成时机 |
|------|---------|------|---------|
| 卡片 (`CardBorder`) | 32px | `ActualWidth × ActualHeight` | `OnContentRendered`（布局完成后动态生成） |
| 缩略图 (`ThumbBorder`) | 16px | 64 × 64 | 构造函数（尺寸固定） |

`curvePower=2.3` 接近正圆弧，视觉上平滑但不夸张。`curvePower` 不宜超过 3~4，否则视觉圆角远小于几何值。

### 间距

```
┌── 卡片 32px 圆角 ──────────┐
│ 内边距 16                      │
│                                │
│ [图标 32×32]  12px  文字区     │
│                 ↑ 上方对齐     │
│                                │
│ 预览文字                       │
│ ↕ 8px                         │
│ 复制自 [16×16 来源图标] 来源应用│
│ ↕ 4px                         │
│ 详情（字符数/尺寸/大小）        │
│                                │
│ 内边距 16                      │
└────────────────────────────────┘
```

外容器与卡片间有 `Margin="32,32"` 为入场动画的模糊延伸 + 弹性 overshoot 预留空间。

## 图标系统

使用 Material Design 3 rounded 风格图标，24×24 网格内自绘 WPF Path 矢量。

| 内容类型 | 图标 | 形状描述 |
|----------|------|---------|
| 文本 | text_fields | 大写 T + 小写文字线条 |
| 图片 | image | 圆角矩形 + 山景/太阳 |
| 文件 | description | 圆角文档 + 文字线条 |
| HTML | code | 尖角括号 `<>` |

图标颜色由主题资源 `IconFillBrush` 控制：亮色 `#555555`，暗色 `#CCCCCC`。深灰/浅灰而非纯黑/纯白，不喧宾夺主。

## 动画

### 架构：双动画层

卡片外壳 (`CardBorder`) 和内容层 (`ContentGrid`) 独立动画——`CardScale` + `RootBlur` 立即开始，`ContentScale` 滞后 50ms（`BeginTime=50ms`），营造"卡片先到、内容追上"的层次感。

### 入场（800ms）

| 属性 | 起始值 | 结束值 | 缓动 |
|------|--------|--------|------|
| CardScale (RootGrid) ScaleX/Y | 0.0 | 1.0 | ElasticEase EaseOut (Oscillations=1, Springiness=5) |
| ContentScale (ContentGrid) ScaleX/Y | 0.0 | 1.0 | 同上，延迟 50ms |
| RootBlur (RootGrid) Radius | 24 | 0 | CubicEase EaseOut |
| Window.Top | 目标位置 -160px | 目标位置 | ElasticEase EaseOut |

`RenderTransformOrigin="0.5,0.5"` 确保缩放以卡片中心为原点。Window.Top 动画替代内部 TranslateTransform，避免 Window 边界裁剪。

### 退场（200ms）

| 属性 | 起始值 | 结束值 | 缓动 |
|------|--------|--------|------|
| Opacity | 1.0 | 0.0 | CubicEase EaseOut |

纯透明度淡出。

## 显示模式

Toast 固定使用 **TopCenter 模式**：出现在光标所在屏幕顶部居中，距顶部 12px。入场从上方 160px 滑入（`Window.Top` 动画：`_targetTop - 160` → `_targetTop`）。

> Cursor（跟随鼠标）模式已于 2026-06-17 移除，相关代码已清理。

## 内容展示规则

- **短文本**（≤100 字符、≤2 行）：仅显示文本内容，来源行
- **长文本**：截断到 2 行，尾部添加 "…"，下方显示来源+字符数（如 "202字符"）
- **图片**：显示 64×64 Squircle 缩略图 + 尺寸信息。透明区域直接透出卡片背景色（无棋盘格）。单图片文件自动识别并生成缩略图
- **文件**：文件名逗号分隔单行显示，超 3 个尾部加 "…"。多文件显示文件数，单文件非图片显示文件大小。来源显示所在文件夹名（非"文件资源管理器"）
- **HTML**：去除标签后显示纯文本
- **来源**：显示 `复制自 [16×16 来源图标] 应用友好名`（记事本、Chrome、VS Code 等），图标从应用 exe 提取。若图标提取失败则仅显示文字。文件类型显示所在文件夹名

## 设计决策

1. **不使用毛玻璃**：`SetWindowCompositionAttribute` / DWM Backdrop API 均要求 `AllowsTransparency=False`，与自定义形状+Squircle 圆角+阴影冲突。唯一的可行方案（屏幕捕获+高斯模糊）复杂度高收益低——2 秒 Toast 上静态模糊和实时 Acrylic 肉眼无法区分。

2. **Squircle 平滑圆角**：标准 `CornerRadius` 是圆弧，iOS 风格用超椭圆（Squircle）曲率连续变化。卡片和缩略图均通过 `SmoothCornerHelper.CreateSquircleClip` 生成 Clip 路径，卡片 r=32（`OnContentRendered` 中动态获取 `ActualWidth/Height`），缩略图 r=16（固定 64×64），curvePower=2.3（接近正圆弧，避免高 curvePower 导致视觉半径严重偏离几何值）。

3. **字体选择**：弃用 `Segoe UI Variable`（可变字体，opsz 光学校正轴在 WPF 透明窗口下导致渲染异常），改用 `Segoe UI`（经典静态版）+ `Microsoft YaHei UI`（中文回退）。

4. **文字色必须不透明**：WPF `AllowsTransparency=True` 创建 Layered Window，半透明色强制 ClearType 回退灰度抗锯齿→文字模糊。解决方案是用预合成不透明色（等效 rgba 色值叠加到卡片背景 `#F7F7FA` 上的结果）。

5. **缩略图单次裁剪**：生成端 `DrawRectangle`（纯矩形），显示端 Squircle Clip 统一处理圆角，避免 `DrawRoundedRectangle` + `CornerRadius` + `ClipToBounds` 三重叠加导致的边缘模糊。

6. **不跟随选中文字位置**：实现成本高（需跨进程获取选区坐标），且 TopCenter 模式已在光标所在屏幕顶部居中，覆盖所有操作的视觉反馈需求。

7. **不使用键盘 Hook**：`AddClipboardFormatListener` 是 Windows 官方推荐 API，覆盖所有复制路径，无需全局键盘 Hook。

8. **纯矢量图标**：不用 emoji（跨系统渲染不一致）、不用字体图标（依赖特定字体安装）、不用 PNG（缩放模糊）。自绘 Material 3 风格 WPF Path 矢量，任意 DPI 下清晰。
