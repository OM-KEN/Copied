using System.Text.Json.Serialization;

namespace Copied.Models;

public sealed class ToastConfiguration
{
    [JsonPropertyName("Animation")]
    public AnimationConfig Animation { get; set; } = new();

    [JsonPropertyName("PositionOffset")]
    public PositionOffsetConfig PositionOffset { get; set; } = new();

    [JsonPropertyName("Content")]
    public ContentConfig Content { get; set; } = new();

    [JsonPropertyName("DeduplicationWindowMs")]
    public int DeduplicationWindowMs { get; set; } = 500;

    [JsonPropertyName("MaxVisibleToasts")]
    public int MaxVisibleToasts { get; set; } = 3;

    [JsonPropertyName("AcrylicEnabled")]
    public bool AcrylicEnabled { get; set; } = true;

    [JsonPropertyName("DisplayMode")]
    public string DisplayMode { get; set; } = "TopCenter";

    [JsonPropertyName("Theme")]
    public string Theme { get; set; } = "System";
}

public sealed class AnimationConfig
{
    [JsonPropertyName("EnterMs")]
    public int EnterMs { get; set; } = 800;

    [JsonPropertyName("StayMs")]
    public int StayMs { get; set; } = 2000;

    [JsonPropertyName("ExitMs")]
    public int ExitMs { get; set; } = 200;
}

public sealed class PositionOffsetConfig
{
    [JsonPropertyName("X")]
    public int X { get; set; }

    [JsonPropertyName("Y")]
    public int Y { get; set; } = -40;
}

public sealed class ContentConfig
{
    [JsonPropertyName("MaxTextLines")]
    public int MaxTextLines { get; set; } = 3;

    [JsonPropertyName("MaxTextPreviewLength")]
    public int MaxTextPreviewLength { get; set; } = 120;

    [JsonPropertyName("ThumbnailSize")]
    public int ThumbnailSize { get; set; } = 80;

    [JsonPropertyName("EnabledContentTypes")]
    public List<string> EnabledContentTypes { get; set; } = new() { "Text", "Image", "Files", "Html" };
}
