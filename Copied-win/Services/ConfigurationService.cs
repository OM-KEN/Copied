using System.Diagnostics;
using System.IO;
using System.Text.Json;
using Copied.Models;

namespace Copied.Services;

public sealed class ConfigurationService : IDisposable
{
    private readonly string _configPath;
    private FileSystemWatcher? _watcher;
    private ToastConfiguration _current;

    public ToastConfiguration Config
    {
        get
        {
            lock (this) { return _current; }
        }
    }

    public event Action? ConfigChanged;

    public ConfigurationService(string configPath)
    {
        _configPath = configPath;
        _current = LoadOrCreate(configPath);
        StartWatching();
    }

    private ToastConfiguration LoadOrCreate(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                string json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<ToastConfiguration>(json) ?? new ToastConfiguration();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Failed to load config: {ex.Message}");
        }

        var defaults = new ToastConfiguration();
        Save(path, defaults);
        return defaults;
    }

    private static void Save(string path, ToastConfiguration config)
    {
        try
        {
            string json = JsonSerializer.Serialize(config, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(path, json);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Failed to save config: {ex.Message}");
        }
    }

    private void StartWatching()
    {
        try
        {
            string? dir = Path.GetDirectoryName(_configPath);
            string file = Path.GetFileName(_configPath);
            if (dir == null) return;

            _watcher = new FileSystemWatcher(dir, file)
            {
                NotifyFilter = NotifyFilters.LastWrite
            };
            _watcher.Changed += (s, e) =>
            {
                Thread.Sleep(100);
                try
                {
                    lock (this)
                    {
                        _current = LoadOrCreate(_configPath);
                    }
                    ConfigChanged?.Invoke();
                }
                catch { }
            };
            _watcher.EnableRaisingEvents = true;
        }
        catch { }
    }

    public void Dispose()
    {
        _watcher?.Dispose();
    }
}
