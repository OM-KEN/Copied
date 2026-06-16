using System.IO;
using System.Text;
using Copied.Models;
using Copied.Services;

namespace Copied.ContentParsers;

public sealed class FileDropContentParser : IContentParser
{
    public ContentType SupportedType => ContentType.Files;

    public ClipboardContentInfo Parse(ClipboardContentInfo raw)
    {
        string[]? files = ClipboardReader.ReadFileDrop();
        if (files == null || files.Length == 0)
            return raw with { Preview = "文件", Metadata = "?", PreviewLineCount = 0 };

        // 单图片文件 → 作为图片类型处理
        if (files.Length == 1 && ImageContentParser.IsImageFile(files[0]))
            return ParseSingleImage(raw, files[0]);

        var sb = new StringBuilder();
        int maxShow = Math.Min(files.Length, 3);
        for (int i = 0; i < maxShow; i++)
        {
            if (i > 0)
                sb.Append("，");
            sb.Append(Path.GetFileName(files[i]));
        }
        if (files.Length > 3)
            sb.Append("…");

        return raw with
        {
            Preview = sb.ToString(),
            Metadata = files.Length == 1
                ? GetSingleFileMeta(files[0])
                : $"{files.Length}个文件",
            FolderName = GetFolderName(files[0]),
            PreviewLineCount = 1
        };
    }

    private static ClipboardContentInfo ParseSingleImage(ClipboardContentInfo raw, string path)
    {
        string fileName = Path.GetFileName(path);
        long fileSize = GetFileSize(path);

        var (thumbnail, pw, ph) = ImageContentParser.GenerateThumbnailWithDims(path);
        string meta = pw > 0 && ph > 0
            ? $"{pw}×{ph}"
            : fileSize > 0 ? FormatFileSize(fileSize) : fileName;

        return raw with
        {
            Type = ContentType.Image,
            Preview = fileName,
            Metadata = meta,
            FolderName = GetFolderName(path),
            PreviewLineCount = 1,
            ThumbnailPng = thumbnail
        };
    }

    private static string? GetFolderName(string filePath)
    {
        try
        {
            string? dir = Path.GetDirectoryName(filePath);
            return !string.IsNullOrEmpty(dir) ? Path.GetFileName(dir) : null;
        }
        catch { return null; }
    }

    private static string GetSingleFileMeta(string path)
    {
        long size = GetFileSize(path);
        return size > 0 ? FormatFileSize(size) : Path.GetFileName(path);
    }

    private static long GetFileSize(string path)
    {
        try { return new FileInfo(path).Length; }
        catch { return -1; }
    }

    private static string FormatFileSize(long bytes)
    {
        return bytes switch
        {
            < 1024 => $"{bytes}B",
            < 1024 * 1024 => $"{bytes / 1024.0:F0}KB",
            < 1024 * 1024 * 1024 => $"{bytes / (1024.0 * 1024.0):F1}MB",
            _ => $"{bytes / (1024.0 * 1024.0 * 1024.0):F2}GB"
        };
    }
}
