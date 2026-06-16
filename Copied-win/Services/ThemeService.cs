using Microsoft.Win32;

namespace Copied.Services;

/// <summary>
/// 解析 Theme 配置 + 检测 Windows 系统主题 → 确定是否使用暗色模式。
/// </summary>
public static class ThemeService
{
    private const string LightThemePath = "Themes/LightTheme.xaml";
    private const string DarkThemePath = "Themes/DarkTheme.xaml";

    /// <summary>
    /// 根据配置值判断是否应使用暗色模式。
    /// </summary>
    /// <param name="themeConfig">"System" | "Light" | "Dark"（大小写不敏感）</param>
    /// <returns>true = 暗色模式, false = 亮色模式</returns>
    public static bool IsDark(string themeConfig)
    {
        return string.Equals(themeConfig, "Dark", StringComparison.OrdinalIgnoreCase)
            || (string.Equals(themeConfig, "System", StringComparison.OrdinalIgnoreCase) && IsSystemDark());
    }

    /// <summary>
    /// 根据配置切换 App 级别的主题资源字典。
    /// 应在 Toast 窗口创建前调用。
    /// </summary>
    public static void ApplyTheme(string themeConfig)
    {
        bool isDark = IsDark(themeConfig);
        string sourcePath = isDark ? DarkThemePath : LightThemePath;

        var app = System.Windows.Application.Current;
        if (app == null) return;

        var dict = new System.Windows.ResourceDictionary { Source = new Uri(sourcePath, UriKind.Relative) };
        app.Resources.MergedDictionaries.Clear();
        app.Resources.MergedDictionaries.Add(dict);
    }

    /// <summary>
    /// 通过注册表检测 Windows 系统是否使用暗色模式。
    /// AppsUseLightTheme=0 表示系统使用暗色模式，1 表示亮色。
    /// </summary>
    private static bool IsSystemDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("AppsUseLightTheme") is int value)
                return value == 0;
        }
        catch
        {
            // 读取失败时默认亮色
        }
        return false;
    }
}
