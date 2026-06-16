using System.ComponentModel;
using System.Runtime.CompilerServices;
using Copied.Models;

namespace Copied.ViewModels;

public sealed class ToastViewModel : INotifyPropertyChanged
{
    private string _previewText = string.Empty;
    private string _detailText = string.Empty;
    private string _sourceName = string.Empty;
    private byte[]? _thumbnailPng;
    private byte[]? _sourceIconPng;

    public ContentType ContentType { get; set; }

    public string PreviewText
    {
        get => _previewText;
        set { _previewText = value; OnPropertyChanged(); }
    }

    public string DetailText
    {
        get => _detailText;
        set { _detailText = value; OnPropertyChanged(); }
    }

    public string SourceName
    {
        get => _sourceName;
        set { _sourceName = value; OnPropertyChanged(); }
    }

    public byte[]? ThumbnailPng
    {
        get => _thumbnailPng;
        set { _thumbnailPng = value; OnPropertyChanged(); }
    }

    public byte[]? SourceIconPng
    {
        get => _sourceIconPng;
        set { _sourceIconPng = value; OnPropertyChanged(); }
    }

    public bool HasThumbnail => _thumbnailPng != null && _thumbnailPng.Length > 0;

    public bool HasDetail => !string.IsNullOrEmpty(_detailText);

    public bool HasSourceIcon => _sourceIconPng != null && _sourceIconPng.Length > 0;

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public static ToastViewModel FromContent(ClipboardContentInfo info, string sourceName, byte[]? sourceIconPng = null)
    {
        return new ToastViewModel
        {
            ContentType = info.Type,
            PreviewText = info.Preview,
            DetailText = info.Metadata,
            SourceName = sourceName,
            SourceIconPng = sourceIconPng,
            ThumbnailPng = info.ThumbnailPng
        };
    }
}
