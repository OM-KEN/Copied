using System.Diagnostics;
using Copied.ContentParsers;
using Copied.Models;
using Copied.ViewModels;
using Copied.Views;

namespace Copied.Services;

public sealed class ToastOrchestrator : IDisposable
{
    private readonly List<IContentParser> _parsers;
    private readonly List<ToastWindow> _activeToasts = new();
    private readonly DeduplicationService _dedup;
    private readonly ConfigurationService _configService;
    private int _enterMs = 150;
    private int _stayMs = 2000;
    private int _exitMs = 200;
    private int _maxVisibleToasts = 3;
    public bool IsPaused { get; set; }

    public ToastOrchestrator(DeduplicationService dedup, ConfigurationService configService)
    {
        _dedup = dedup;
        _configService = configService;
        _parsers = new List<IContentParser>
        {
            new TextContentParser(),
            new ImageContentParser(),
            new FileDropContentParser(),
            new HtmlContentParser()
        };
        ApplyConfig(configService.Config);
        configService.ConfigChanged += OnConfigChanged;
    }

    private void OnConfigChanged()
    {
        ApplyConfig(_configService.Config);
    }

    private void ApplyConfig(ToastConfiguration cfg)
    {
        _enterMs = cfg.Animation.EnterMs;
        _stayMs = cfg.Animation.StayMs;
        _exitMs = cfg.Animation.ExitMs;
        _maxVisibleToasts = cfg.MaxVisibleToasts;

        ThemeService.ApplyTheme(cfg.Theme);
    }

    public void OnClipboardChanged()
    {
        if (IsPaused) return;

        try
        {
            ContentType? primaryType = ContentDetector.DetectPrimaryFormat();
            if (primaryType == null) return;
            IContentParser? parser = _parsers.FirstOrDefault(p => p.SupportedType == primaryType.Value);
            if (parser == null) return;

            var rawInfo = new ClipboardContentInfo { Type = primaryType.Value, RawData = ReadOnlyMemory<byte>.Empty };
            ClipboardContentInfo parsed = parser.Parse(rawInfo);
            if (string.IsNullOrEmpty(parsed.Preview)) return;

            if (!_dedup.ShouldShow(parsed.Preview, (int)primaryType.Value)) return;

            string sourceName;
            byte[]? sourceIconPng = null;

            // Always get source icon from foreground app
            var sourceInfo = SourceDetector.GetSource();
            sourceIconPng = sourceInfo.IconPng;

            // Folder path overrides app name for display, but icon still comes from the app
            if (!string.IsNullOrEmpty(parsed.FolderName))
            {
                sourceName = parsed.FolderName;
            }
            else
            {
                sourceName = sourceInfo.Name;
            }

            var app = System.Windows.Application.Current;
            if (app == null) return;

            app.Dispatcher.BeginInvoke(() => ShowToast(parsed, sourceName, sourceIconPng));
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Copied] Error: {ex.Message}");
        }
    }

    private void ShowToast(ClipboardContentInfo info, string sourceName, byte[]? sourceIconPng = null)
    {
        while (_activeToasts.Count >= _maxVisibleToasts)
        {
            var oldest = _activeToasts[0];
            _activeToasts.RemoveAt(0);
            try { oldest.Close(); } catch { }
        }

        var vm = ToastViewModel.FromContent(info, sourceName, sourceIconPng);
        var window = new ToastWindow(vm, _enterMs, _stayMs, _exitMs);
        window.Closed += (s, e) => _activeToasts.Remove(window);
        _activeToasts.Add(window);
        window.Show();
    }

    public void Dispose()
    {
        _configService.ConfigChanged -= OnConfigChanged;
        foreach (var toast in _activeToasts.ToList())
            try { toast.Close(); } catch { }
        _activeToasts.Clear();
    }
}
