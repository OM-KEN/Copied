using System;
using System.Collections.Concurrent;
using System.Windows.Media;

namespace Copied.Helpers;

public static class SmoothCornerHelper
{
    private static readonly ConcurrentDictionary<(double w, double h, double r), StreamGeometry> _cache = new();

    /// <summary>
    /// 生成 iOS 风格平滑圆角（超椭圆 / Squircle）的裁剪路径。
    /// curvePower: 越大约接近直角（iOS ≈ 5），2 就是标准圆弧。
    /// </summary>
    public static StreamGeometry CreateSquircleClip(double width, double height, double cornerRadius, double curvePower = 2.3)
    {
        // Toast 频繁复用相同尺寸，缓存避免重复三角函数计算
        var key = (Math.Round(width, 1), Math.Round(height, 1), Math.Round(cornerRadius, 1));
        return _cache.GetOrAdd(key, _ => BuildSquircle(width, height, cornerRadius, curvePower));
    }

    private static StreamGeometry BuildSquircle(double width, double height, double cornerRadius, double curvePower)
    {
        var geometry = new StreamGeometry();
        using var ctx = geometry.Open();

        double w = width, h = height, r = cornerRadius;

        ctx.BeginFigure(new System.Windows.Point(r, 0), true, true);

        // 上边
        ctx.LineTo(new System.Windows.Point(w - r, 0), true, false);
        // 右上角: 中心 (w-r, r), 从 π/2 到 0
        AppendCorner(ctx, w - r, r, r, curvePower, Math.PI / 2, 0);

        // 右边
        ctx.LineTo(new System.Windows.Point(w, h - r), true, false);
        // 右下角: 中心 (w-r, h-r), 从 0 到 -π/2
        AppendCorner(ctx, w - r, h - r, r, curvePower, 0, -Math.PI / 2);

        // 下边
        ctx.LineTo(new System.Windows.Point(r, h), true, false);
        // 左下角: 中心 (r, h-r), 从 -π/2 到 -π
        AppendCorner(ctx, r, h - r, r, curvePower, -Math.PI / 2, -Math.PI);

        // 左边
        ctx.LineTo(new System.Windows.Point(0, r), true, false);
        // 左上角: 中心 (r, r), 从 π 到 π/2
        AppendCorner(ctx, r, r, r, curvePower, Math.PI, Math.PI / 2);

        geometry.Freeze();
        return geometry;
    }

    private static void AppendCorner(StreamGeometryContext ctx, double cx, double cy,
        double r, double n, double startAngle, double endAngle)
    {
        const int segments = 20;
        for (int i = 1; i <= segments; i++)
        {
            double t = (double)i / segments;
            double angle = startAngle + t * (endAngle - startAngle);
            double x = cx + r * Math.Sign(Math.Cos(angle)) * Math.Pow(Math.Abs(Math.Cos(angle)), 2.0 / n);
            double y = cy - r * Math.Sign(Math.Sin(angle)) * Math.Pow(Math.Abs(Math.Sin(angle)), 2.0 / n);
            ctx.LineTo(new System.Windows.Point(x, y), true, false);
        }
    }
}
