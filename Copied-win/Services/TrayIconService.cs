using System.Diagnostics;

namespace Copied.Services;

public sealed class TrayIconService : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _notifyIcon;
    private bool _isPaused;

    public event Action? ExitRequested;
    public event Action<bool>? PauseToggled;

    public TrayIconService()
    {
        _notifyIcon = new System.Windows.Forms.NotifyIcon
        {
            Visible = true,
            Text = "Copied — 智能复制反馈",
            Icon = System.Drawing.SystemIcons.Information
        };

        var contextMenu = new System.Windows.Forms.ContextMenuStrip();
        var pauseItem = new System.Windows.Forms.ToolStripMenuItem("暂停复制反馈");
        pauseItem.Click += (s, e) =>
        {
            _isPaused = !_isPaused;
            pauseItem.Text = _isPaused ? "恢复复制反馈" : "暂停复制反馈";
            PauseToggled?.Invoke(_isPaused);
        };
        contextMenu.Items.Add(pauseItem);
        contextMenu.Items.Add(new System.Windows.Forms.ToolStripSeparator());

        var exitItem = new System.Windows.Forms.ToolStripMenuItem("退出");
        exitItem.Click += (s, e) =>
        {
            ExitRequested?.Invoke();
        };
        contextMenu.Items.Add(exitItem);

        _notifyIcon.ContextMenuStrip = contextMenu;

        _notifyIcon.MouseClick += (s, e) =>
        {
            if (e.Button == System.Windows.Forms.MouseButtons.Left)
            {
                Debug.WriteLine("Copied running...");
            }
        };
    }

    public void SetPaused(bool paused)
    {
        _isPaused = paused;
    }

    public void Dispose()
    {
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }
}
