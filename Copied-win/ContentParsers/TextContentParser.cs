using System.Text;
using Copied.Models;
using Copied.Services;

namespace Copied.ContentParsers;

public sealed class TextContentParser : IContentParser
{
    private readonly int _maxLines;
    private readonly int _maxLength;

    public ContentType SupportedType => ContentType.Text;

    public TextContentParser(int maxLines = 3, int maxLength = 200)
    {
        _maxLines = maxLines;
        _maxLength = maxLength;
    }

    public ClipboardContentInfo Parse(ClipboardContentInfo raw)
    {
        string? fullText = ClipboardReader.ReadUnicodeText();
        if (string.IsNullOrEmpty(fullText))
            return raw;

        int totalChars = fullText.Length;
        var lines = fullText.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        int totalLines = lines.Length;

        string preview;
        string? charCount = null;
        bool isLong = totalChars > 100 || totalLines > 2;

        if (totalLines <= _maxLines && totalChars <= _maxLength)
        {
            preview = fullText;
        }
        else
        {
            var sb = new StringBuilder();
            int charsAdded = 0;
            for (int i = 0; i < Math.Min(lines.Length, _maxLines); i++)
            {
                string line = lines[i];
                if (charsAdded + line.Length > _maxLength)
                {
                    sb.Append(line.AsSpan(0, _maxLength - charsAdded));
                    sb.Append('…');
                    break;
                }
                if (i > 0) sb.AppendLine();
                sb.Append(line);
                charsAdded += line.Length;
            }
            if (charsAdded < totalChars) sb.Append('…');
            preview = sb.ToString();
        }

        if (isLong)
            charCount = $"{totalChars}字符";

        return raw with
        {
            Preview = preview,
            Metadata = charCount ?? "",
            PreviewLineCount = Math.Min(totalLines, _maxLines)
        };
    }
}
