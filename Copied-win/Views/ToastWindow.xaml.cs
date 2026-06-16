using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Copied.Helpers;
using Copied.Native;
using Copied.ViewModels;

namespace Copied.Views;

public partial class ToastWindow : Window
{
    private readonly DispatcherTimer _stayTimer;
    private readonly int _enterMs;
    private readonly int _exitMs;
    private readonly string _displayMode;
    private bool _positioned;

    public ToastWindow(ToastViewModel viewModel,
        int enterMs = 800, int stayMs = 2000, int exitMs = 200,
        string displayMode = "Cursor")
    {
        InitializeComponent();

        _iconFill = (System.Windows.Application.Current.TryFindResource("IconFillBrush") as SolidColorBrush)
                    ?? new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x55, 0x55, 0x55));

        _displayMode = displayMode;
        _enterMs = enterMs;
        _exitMs = exitMs;

        FontFamily = new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI");
        PreviewText.FontFamily = FontFamily;
        SourceLabel.FontFamily = FontFamily;
        SourceNameText.FontFamily = FontFamily;
        DetailText.FontFamily = FontFamily;

        if (viewModel.HasThumbnail)
        {
            var thumbSource = LoadPng(viewModel.ThumbnailPng!);
            if (thumbSource != null)
            {
                IconViewbox.Visibility = Visibility.Collapsed;
                ThumbnailGrid.Visibility = Visibility.Visible;
                ThumbnailImage.Source = thumbSource;

                ThumbBorder.Clip = SmoothCornerHelper.CreateSquircleClip(64, 64, cornerRadius: 16);

                PreviewText.MaxWidth = 248;
            }
            else
            {
                // Thumbnail decode failed — fall back to vector icon
                DrawMaterialIcon(viewModel.ContentType);
            }
        }
        else
        {
            DrawMaterialIcon(viewModel.ContentType);
        }

        PreviewText.Text = viewModel.PreviewText;

        if (viewModel.HasThumbnail || viewModel.ContentType == Models.ContentType.Files)
        {
            PreviewText.TextWrapping = TextWrapping.NoWrap;
            PreviewText.MaxHeight = 22;
        }

        if (viewModel.HasDetail)
        {
            DetailText.Text = viewModel.DetailText;
            DetailText.Visibility = Visibility.Visible;
        }

        if (!string.IsNullOrEmpty(viewModel.SourceName))
        {
            // Source icon (optional)
            if (viewModel.HasSourceIcon)
            {
                var iconSource = LoadPng(viewModel.SourceIconPng!);
                if (iconSource != null)
                {
                    SourceIconImage.Source = iconSource;
                    SourceIconImage.Visibility = Visibility.Visible;
                }
                else
                {
                    SourceIconImage.Visibility = Visibility.Collapsed;
                }
            }
            else
            {
                SourceIconImage.Visibility = Visibility.Collapsed;
            }

            SourceNameText.Text = viewModel.SourceName;
            SourcePanel.Visibility = Visibility.Visible;
        }

        Opacity = 1.0;
        _stayTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(enterMs + stayMs) };
        _stayTimer.Tick += OnStayComplete;
    }

    private readonly SolidColorBrush _iconFill;

    private static BitmapImage? LoadPng(byte[] png)
    {
        try
        {
            using var ms = new MemoryStream(png);
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.StreamSource = ms;
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Copied] Failed to load PNG: {ex.Message}");
            return null;
        }
    }

    private void DrawMaterialIcon(Models.ContentType type)
    {
        var c = IconCanvas;
        c.Children.Clear();

        string d = type switch
        {
            Models.ContentType.Text =>
                "M2.5 4v3h5v12h3V7h5V4h-13zm19 5h-9v3h3v7h3v-7h3V9z",
            Models.ContentType.Image =>
                "M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z",
            Models.ContentType.Files =>
                "M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zM6 20V4h7v5h5v11H6zm2-6h8v1.5H8V14zm0-3h8v1.5H8V11zm0 6h5v1.5H8V17z",
            Models.ContentType.Html =>
                "M9.4 16.6L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4zm5.2 0l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4z",
            _ =>
                "M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"
        };

        c.Children.Add(new System.Windows.Shapes.Path
        {
            Fill = _iconFill,
            Data = Geometry.Parse(d),
            SnapsToDevicePixels = true
        });
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;

        int exStyle = NativeMethods.GetWindowLong(hwnd, Win32Constants.GWL_EXSTYLE);
        exStyle |= Win32Constants.WS_EX_TOOLWINDOW
                | Win32Constants.WS_EX_NOACTIVATE
                | Win32Constants.WS_EX_TRANSPARENT
                | Win32Constants.WS_EX_TOPMOST;
        NativeMethods.SetWindowLong(hwnd, Win32Constants.GWL_EXSTYLE, exStyle);

        NativeMethods.SetWindowPos(hwnd, Win32Constants.HWND_TOPMOST,
            0, 0, 0, 0,
            Win32Constants.SWP_SHOWWINDOW | Win32Constants.SWP_NOMOVE | Win32Constants.SWP_NOSIZE);
    }

    private double _targetTop;

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);
        if (!_positioned)
        {
            PositionToast();
            _positioned = true;

            // 保存目标位置，然后把 Window 推到屏幕外作为动画起点
            _targetTop = Top;
            bool isTopCenter = string.Equals(_displayMode, "TopCenter", StringComparison.OrdinalIgnoreCase);
            Top = isTopCenter ? _targetTop - 160 : _targetTop + 160;
        }

        StartEnterAnimation();
        _stayTimer.Start();
    }

    private void PositionToast()
    {
        if (string.Equals(_displayMode, "TopCenter", StringComparison.OrdinalIgnoreCase))
            PositionTopCenter();
        else
            PositionNearCursor();
    }

    private void PositionTopCenter()
    {
        double w = ActualWidth > 1 ? ActualWidth : 260;
        double h = ActualHeight > 1 ? ActualHeight : 72;

        NativeMethods.GetCursorPos(out POINT cursorPt);
        var screen = System.Windows.Forms.Screen.FromPoint(
            new System.Drawing.Point(cursorPt.X, cursorPt.Y));
        var area = screen.WorkingArea;

        double x = area.Left + (area.Width - w) / 2;
        double y = area.Top + 12;

        Left = x;
        Top = y;
    }

    private void PositionNearCursor()
    {
        NativeMethods.GetCursorPos(out POINT cursorPt);
        double w = ActualWidth > 1 ? ActualWidth : 260;
        double h = ActualHeight > 1 ? ActualHeight : 72;

        double x = cursorPt.X - (w / 2);
        double y = cursorPt.Y - h - 24;

        var screen = System.Windows.Forms.Screen.FromPoint(
            new System.Drawing.Point(cursorPt.X, cursorPt.Y));
        var area = screen.WorkingArea;

        x = Math.Clamp(x, area.Left + 8, area.Right - w - 8);
        y = Math.Clamp(y, area.Top + 8, area.Bottom - h - 8);
        if (y < area.Top + 8) y = cursorPt.Y + 24;

        Left = x;
        Top = y;
    }

    /// <summary>
    /// 入场动画：卡片外壳 + 内容层，两套完全一致的动画，内容层整体延迟 50ms
    /// </summary>
    private void StartEnterAnimation()
    {
        bool isTopCenter = string.Equals(_displayMode, "TopCenter", StringComparison.OrdinalIgnoreCase);

        var elastic = new ElasticEase { EasingMode = EasingMode.EaseOut, Oscillations = 1, Springiness = 5 };
        var duration = TimeSpan.FromMilliseconds(_enterMs);
        var delay = TimeSpan.FromMilliseconds(50);
        var contentDuration = TimeSpan.FromMilliseconds(_enterMs - 50);

        // ═══ 卡片外壳（立即开始） ═══
        CardScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.0, 1.0, duration) { EasingFunction = elastic });
        CardScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.0, 1.0, duration) { EasingFunction = elastic });

        // Blur: 24 → 0，配合缩放营造"聚焦清晰"感
        RootBlur.BeginAnimation(BlurEffect.RadiusProperty,
            new DoubleAnimation(24, 0, duration) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });

        // ═══ 内容层（延迟 50ms，弹簧更硬 = 更少夸张） ═══
        var contentElastic = new ElasticEase { EasingMode = EasingMode.EaseOut, Oscillations = 1, Springiness = 7 };
        ContentScale.BeginAnimation(ScaleTransform.ScaleXProperty,
            new DoubleAnimation(0.0, 1.0, contentDuration)
            { BeginTime = delay, EasingFunction = contentElastic });
        ContentScale.BeginAnimation(ScaleTransform.ScaleYProperty,
            new DoubleAnimation(0.0, 1.0, contentDuration)
            { BeginTime = delay, EasingFunction = contentElastic });

        // Slide: Window 整体从屏幕外滑回目标位置
        this.BeginAnimation(TopProperty,
            new DoubleAnimation(Top, _targetTop, duration) { EasingFunction = elastic });
    }

    private void OnStayComplete(object? sender, EventArgs e)
    {
        _stayTimer.Stop();
        StartExitAnimation();
    }

    private void StartExitAnimation()
    {
        var opacityAnim = new DoubleAnimation(1.0, 0.0, TimeSpan.FromMilliseconds(_exitMs))
        { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
        opacityAnim.Completed += (s, _) => Close();

        BeginAnimation(OpacityProperty, opacityAnim);
    }
}
