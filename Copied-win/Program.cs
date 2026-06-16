using System.Diagnostics;
using System.IO;
using System.Windows;
using Copied.Services;

namespace Copied;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        Trace.Listeners.Add(new TextWriterTraceListener(Console.Out));

        using var mutex = new Mutex(true, "Copied_SingleInstance_4F8B2A1C", out bool createdNew);
        if (!createdNew)
            return;

        AppDomain.CurrentDomain.UnhandledException += (s, e) =>
        {
            Debug.WriteLine($"Unhandled exception: {e.ExceptionObject}");
        };

        SourceDetector.LoadCache();

        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };

        string appDir = Path.GetDirectoryName(Environment.ProcessPath)!;
        string configPath = Path.Combine(appDir, "appsettings.json");
        var configService = new ConfigurationService(configPath);

        var dedup = new DeduplicationService(
            TimeSpan.FromMilliseconds(configService.Config.DeduplicationWindowMs));

        var clipboardMonitor = new ClipboardMonitor();
        var toastOrchestrator = new ToastOrchestrator(dedup, configService);

        clipboardMonitor.ClipboardChanged += toastOrchestrator.OnClipboardChanged;
        clipboardMonitor.Start();

        var trayIcon = new TrayIconService();
        trayIcon.ExitRequested += () =>
        {
            SourceDetector.SaveCache();
            clipboardMonitor.Dispose();
            toastOrchestrator.Dispose();
            dedup.Dispose();
            configService.Dispose();
            trayIcon.Dispose();
            app.Shutdown();
        };
        trayIcon.PauseToggled += (paused) => toastOrchestrator.IsPaused = paused;

        Console.WriteLine("Copied started. Press Ctrl+C in any app to test.");
        try { app.Run(); }
        finally
        {
            SourceDetector.SaveCache();
            clipboardMonitor.Dispose();
            toastOrchestrator.Dispose();
            dedup.Dispose();
            configService.Dispose();
            trayIcon.Dispose();
        }
    }
}
