using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
using Copied.Native;

namespace Copied.Services;

public sealed record SourceInfo(string Name, byte[]? IconPng = null);

public static class SourceDetector
{
    private static readonly ConcurrentDictionary<string, byte[]> IconCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentQueue<string> IconCacheOrder = new();
    private const int IconCacheMaxEntries = 50;

    private static string CacheFilePath =>
        Path.Combine(Path.GetDirectoryName(Environment.ProcessPath)!, "iconcache.bin");

    public static void LoadCache()
    {
        try
        {
            if (!File.Exists(CacheFilePath)) return;

            using var fs = new FileStream(CacheFilePath, FileMode.Open, FileAccess.Read);
            using var reader = new BinaryReader(fs, Encoding.UTF8);
            int count = reader.ReadInt32();
            for (int i = 0; i < count && IconCache.Count < IconCacheMaxEntries; i++)
            {
                string key = reader.ReadString();
                int len = reader.ReadInt32();
                byte[] value = reader.ReadBytes(len);
                if (!string.IsNullOrEmpty(key) && value.Length > 0
                    && IconCache.TryAdd(key, value))
                {
                    IconCacheOrder.Enqueue(key);
                }
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Copied] Failed to load icon cache: {ex.Message}");
        }
    }

    public static void SaveCache()
    {
        try
        {
            string? dir = Path.GetDirectoryName(CacheFilePath);
            if (!string.IsNullOrEmpty(dir))
                Directory.CreateDirectory(dir);

            using var fs = new FileStream(CacheFilePath, FileMode.Create, FileAccess.Write);
            using var writer = new BinaryWriter(fs, Encoding.UTF8);
            writer.Write(IconCache.Count);
            foreach (var kv in IconCache)
            {
                writer.Write(kv.Key);
                writer.Write(kv.Value.Length);
                writer.Write(kv.Value);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Copied] Failed to save icon cache: {ex.Message}");
        }
    }

    public static SourceInfo GetSource()
    {
        IntPtr hwnd = NativeMethods.GetForegroundWindow();
        if (hwnd == IntPtr.Zero || hwnd == NativeMethods.GetShellWindow())
            return new SourceInfo("");

        NativeMethods.GetWindowThreadProcessId(hwnd, out uint pid);
        try
        {
            using var proc = Process.GetProcessById((int)pid);
            string name = proc.ProcessName switch
            {
                "notepad" => "记事本",
                "mspaint" => "画图",
                "explorer" => "文件资源管理器",
                "msedge" => "Edge",
                "chrome" => "Chrome",
                "Code" => "VS Code",
                "devenv" => "Visual Studio",
                "WINWORD" => "Word",
                "EXCEL" => "Excel",
                "firefox" => "Firefox",
                "ApplicationFrameHost" => "截图工具",
                "SnippingTool" => "截图工具",
                "ScreenClippingHost" => "截图工具",
                var raw => raw
            };

            byte[]? iconPng = null;
            try
            {
                string? exePath = proc.MainModule?.FileName;
                if (!string.IsNullOrEmpty(exePath) && File.Exists(exePath))
                {
                    if (!IconCache.TryGetValue(exePath, out iconPng!))
                    {
                        using var icon = System.Drawing.Icon.ExtractAssociatedIcon(exePath);
                        if (icon != null)
                        {
                            using var bitmap = icon.ToBitmap();
                            using var ms = new MemoryStream();
                            bitmap.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                            iconPng = ms.ToArray();
                            if (IconCache.Count >= IconCacheMaxEntries
                                && IconCacheOrder.TryDequeue(out var oldest))
                            {
                                IconCache.TryRemove(oldest, out _);
                            }
                            IconCache[exePath] = iconPng;
                            IconCacheOrder.Enqueue(exePath);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Copied] SourceDetector icon extraction failed: {ex.Message}");
            }

            return new SourceInfo(name, iconPng);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Copied] SourceDetector process detection failed: {ex.Message}");
            return new SourceInfo("");
        }
    }
}
