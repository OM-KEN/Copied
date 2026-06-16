using System.Text;
using System.Text.RegularExpressions;
using System.Web;
using Copied.Models;
using Copied.Services;

namespace Copied.ContentParsers;

public sealed partial class HtmlContentParser : IContentParser
{
    public ContentType SupportedType => ContentType.Html;

    [GeneratedRegex("<[^>]*>")]
    private static partial Regex TagRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();

    public ClipboardContentInfo Parse(ClipboardContentInfo raw)
    {
        byte[]? htmlData = ClipboardReader.ReadClipboardData(ContentDetector.CfHtmlFormat);
        if (htmlData == null)
            return raw;

        string html = Encoding.UTF8.GetString(htmlData).TrimEnd('\0');

        string plain = TagRegex().Replace(html, " ");
        plain = WhitespaceRegex().Replace(plain, " ").Trim();
        plain = HttpUtility.HtmlDecode(plain);

        if (string.IsNullOrWhiteSpace(plain))
        {
            plain = "[网页内容]";
        }
        else if (plain.Length > 150)
        {
            plain = plain[..150] + "...";
        }

        return raw with
        {
            Preview = plain,
            Metadata = $"{html.Length}字符 (HTML)",
            PreviewLineCount = 1
        };
    }
}
