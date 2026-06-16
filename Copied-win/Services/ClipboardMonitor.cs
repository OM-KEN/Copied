using System.Runtime.InteropServices;
using System.Windows.Interop;
using Copied.Native;

namespace Copied.Services;

public sealed class ClipboardMonitor : IDisposable
{
    private HwndSource? _hwndSource;

    public event Action? ClipboardChanged;

    public void Start()
    {
        var parameters = new HwndSourceParameters("Copied_ClipboardMonitor")
        {
            Width = 0, Height = 0,
            WindowStyle = 0, ExtendedWindowStyle = 0
        };
        _hwndSource = new HwndSource(parameters);
        _hwndSource.AddHook(WndProc);
        NativeMethods.AddClipboardFormatListener(_hwndSource.Handle);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Win32Constants.WM_CLIPBOARDUPDATE)
            ClipboardChanged?.Invoke();
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_hwndSource != null)
        {
            NativeMethods.RemoveClipboardFormatListener(_hwndSource.Handle);
            _hwndSource.RemoveHook(WndProc);
            _hwndSource.Dispose();
            _hwndSource = null;
        }
    }
}
