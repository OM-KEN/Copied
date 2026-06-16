namespace Copied.Models;

public sealed record ClipboardContentInfo
{
    public ContentType Type { get; init; }
    public ReadOnlyMemory<byte> RawData { get; init; }
    public string Preview { get; init; } = string.Empty;
    public string Metadata { get; init; } = string.Empty;
    public int PreviewLineCount { get; init; }
    public byte[]? ThumbnailPng { get; init; }
    public string? FolderName { get; init; }
}
