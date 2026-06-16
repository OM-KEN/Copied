using Copied.Models;

namespace Copied.ContentParsers;

public interface IContentParser
{
    ContentType SupportedType { get; }
    ClipboardContentInfo Parse(ClipboardContentInfo raw);
}
