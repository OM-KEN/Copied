using System.Collections.Concurrent;

namespace Copied.Services;

public sealed class DeduplicationService : IDisposable
{
    private readonly ConcurrentDictionary<long, DateTime> _recentHashes = new();
    private readonly TimeSpan _window;
    private readonly System.Threading.Timer _cleanupTimer;

    public DeduplicationService(TimeSpan dedupWindow)
    {
        _window = dedupWindow;
        _cleanupTimer = new System.Threading.Timer(Cleanup, null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    }

    public bool ShouldShow(string preview, int typeFlag)
    {
        long hash = HashCode.Combine(typeFlag, preview);
        var now = DateTime.UtcNow;

        if (_recentHashes.TryGetValue(hash, out var lastSeen))
        {
            if (now - lastSeen < _window)
                return false;
        }

        _recentHashes[hash] = now;
        return true;
    }

    private void Cleanup(object? state)
    {
        var cutoff = DateTime.UtcNow.Subtract(TimeSpan.FromSeconds(2));
        foreach (var kv in _recentHashes)
        {
            if (kv.Value < cutoff)
                _recentHashes.TryRemove(kv.Key, out _);
        }
    }

    public void Dispose()
    {
        _cleanupTimer.Dispose();
    }
}
