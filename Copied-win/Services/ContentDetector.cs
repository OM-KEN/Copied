using Copied.Models;
using Copied.Native;

namespace Copied.Services;

public static class ContentDetector
{
    private static uint? _cfHtml;

    public static uint CfHtmlFormat
    {
        get
        {
            _cfHtml ??= NativeMethods.RegisterClipboardFormat("HTML Format");
            return _cfHtml.Value;
        }
    }

    public static IReadOnlyList<ContentType> DetectAvailableFormats()
    {
        if (NativeMethods.CountClipboardFormats() == 0)
            return Array.Empty<ContentType>();

        var result = new List<ContentType>(4);

        if (NativeMethods.IsClipboardFormatAvailable(Win32Constants.CF_UNICODETEXT))
            result.Add(ContentType.Text);

        if (NativeMethods.IsClipboardFormatAvailable(Win32Constants.CF_HDROP))
            result.Add(ContentType.Files);

        if (NativeMethods.IsClipboardFormatAvailable(Win32Constants.CF_BITMAP)
            || NativeMethods.IsClipboardFormatAvailable(Win32Constants.CF_DIB)
            || NativeMethods.IsClipboardFormatAvailable(Win32Constants.CF_DIBV5))
            result.Add(ContentType.Image);

        if (NativeMethods.IsClipboardFormatAvailable(CfHtmlFormat))
            result.Add(ContentType.Html);

        return result;
    }

    public static ContentType? DetectPrimaryFormat()
    {
        var formats = DetectAvailableFormats();
        return formats.Count > 0 ? formats[0] : null;
    }
}
