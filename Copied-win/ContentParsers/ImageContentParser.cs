using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Copied.Models;
using Copied.Native;
using Copied.Services;

namespace Copied.ContentParsers;

public sealed class ImageContentParser : IContentParser
{
    private readonly int _thumbSize;

    public ContentType SupportedType => ContentType.Image;

    public ImageContentParser(int thumbnailSize = 80)
    {
        _thumbSize = thumbnailSize;
    }

    public ClipboardContentInfo Parse(ClipboardContentInfo raw)
    {
        // Read CF_DIB (preferred — includes BITMAPINFOHEADER + pixel data, no file header)
        byte[]? dibData = ClipboardReader.ReadClipboardData(Win32Constants.CF_DIB);
        if (dibData == null || dibData.Length < 40)
            return BasicInfo(raw, "?", "?");

        try
        {
            int headerSize = BitConverter.ToInt32(dibData, 0);
            if (headerSize != 40) // BITMAPINFOHEADER
                return BasicInfo(raw, "?", "?");

            int width = BitConverter.ToInt32(dibData, 4);
            int height = Math.Abs(BitConverter.ToInt32(dibData, 8));
            short bpp = BitConverter.ToInt16(dibData, 14);
            uint compression = BitConverter.ToUInt32(dibData, 16);

            if (width <= 0 || height <= 0 || bpp <= 0)
                return BasicInfo(raw, "?", "?");

            // Calculate pixel data offset
            int paletteEntries = bpp <= 8 ? 1 << bpp : (compression == 3 ? 3 : 0); // BI_BITFIELDS
            int pixelOffset = headerSize + paletteEntries * 4;
            if (pixelOffset >= dibData.Length)
                return BasicInfo(raw, $"{width}×{height}", $"{width}×{height}");

            // Pick pixel format
            PixelFormat format;
            if (bpp == 32) format = PixelFormats.Bgra32;
            else if (bpp == 24) format = PixelFormats.Bgr24;
            else if (bpp == 16) format = PixelFormats.Bgr555;
            else if (bpp == 8) format = PixelFormats.Indexed8;
            else
                return BasicInfo(raw, $"{width}×{height}", $"{width}×{height}");

            int stride = ((width * bpp + 31) / 32) * 4;
            int expectedSize = stride * height;
            int available = dibData.Length - pixelOffset;
            if (available < expectedSize)
                expectedSize = available;

            int absHeight = BitConverter.ToInt32(dibData, 8);
            bool isBottomUp = absHeight > 0;

            // Create BitmapSource
            var bitmap = BitmapSource.Create(
                width, height, 96, 96, format, null,
                dibData.AsSpan(pixelOffset, expectedSize).ToArray(), stride);

            if (isBottomUp)
            {
                // Bottom-up DIB: first scanline = bottom row → flip for WPF top-down expectation
                bitmap = new TransformedBitmap(bitmap, new ScaleTransform(1, -1));
            }

            // Scale to thumbnail
            double scale = Math.Min((double)_thumbSize / width, (double)_thumbSize / height);
            int thumbW = Math.Max(1, (int)(width * scale));
            int thumbH = Math.Max(1, (int)(height * scale));

            var scaled = new TransformedBitmap(bitmap, new ScaleTransform(scale, scale));

            byte[] pngBytes = RenderToPng(scaled, thumbW, thumbH);

            return raw with
            {
                Preview = "图片",
                Metadata = $"{width}×{height}",
                PreviewLineCount = 0,
                ThumbnailPng = pngBytes
            };
        }
        catch
        {
            return BasicInfo(raw, "?", "?");
        }
    }

    private static ClipboardContentInfo BasicInfo(ClipboardContentInfo raw, string preview, string meta)
    {
        return raw with { Preview = preview, Metadata = meta, PreviewLineCount = 0 };
    }

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".webp", ".tiff", ".tif", ".ico", ".svg"
    };

    public static bool IsImageFile(string filePath)
    {
        return ImageExtensions.Contains(Path.GetExtension(filePath));
    }

    public static (byte[]? thumbnail, int width, int height) GenerateThumbnailWithDims(string filePath, int thumbSize = 80)
    {
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.UriSource = new Uri(filePath);
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.DecodePixelWidth = thumbSize;
            bmp.EndInit();

            int pw = bmp.PixelWidth;
            int ph = bmp.PixelHeight;
            if (pw < 1 || ph < 1)
                return (null, 0, 0);

            double scale = Math.Min((double)thumbSize / pw, (double)thumbSize / ph);
            int tw = Math.Max(1, (int)(pw * scale));
            int th = Math.Max(1, (int)(ph * scale));

            var scaled = new TransformedBitmap(bmp, new ScaleTransform(scale, scale));
            var png = RenderToPng(scaled, tw, th);
            return (png, pw, ph);
        }
        catch
        {
            return (null, 0, 0);
        }
    }

    public static byte[]? GenerateThumbnailFromFile(string filePath, int thumbSize = 80)
    {
        var (thumbnail, _, _) = GenerateThumbnailWithDims(filePath, thumbSize);
        return thumbnail;
    }

    private static byte[] RenderToPng(ImageSource source, int w, int h)
    {
        var visual = new DrawingVisual();
        using (var ctx = visual.RenderOpen())
        {
            ctx.DrawRectangle(new ImageBrush(source), null,
                new System.Windows.Rect(0, 0, w, h));
        }

        var rt = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        rt.Render(visual);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(rt));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        return ms.ToArray();
    }
}
