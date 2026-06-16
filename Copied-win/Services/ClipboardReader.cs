using System.Diagnostics;
using System.Runtime.InteropServices;
using Copied.Native;

namespace Copied.Services;

public static class ClipboardReader
{
    public static byte[]? ReadClipboardData(uint format)
    {
        if (!NativeMethods.OpenClipboard(IntPtr.Zero))
        {
            int err = Marshal.GetLastWin32Error();
            if (err == 5) // ERROR_ACCESS_DENIED — clipboard busy
            {
                Thread.Sleep(10);
                if (!NativeMethods.OpenClipboard(IntPtr.Zero))
                    return null;
            }
            else
            {
                return null;
            }
        }

        try
        {
            IntPtr hData = NativeMethods.GetClipboardData(format);
            if (hData == IntPtr.Zero)
                return null;

            IntPtr pData = NativeMethods.GlobalLock(hData);
            if (pData == IntPtr.Zero)
                return null;

            try
            {
                uint size = NativeMethods.GlobalSize(hData);
                if (size == 0)
                    return null;

                byte[] buffer = new byte[size];
                Marshal.Copy(pData, buffer, 0, (int)size);
                return buffer;
            }
            finally
            {
                NativeMethods.GlobalUnlock(hData);
            }
        }
        finally
        {
            NativeMethods.CloseClipboard();
        }
    }

    public static string? ReadUnicodeText()
    {
        byte[]? data = ReadClipboardData(Win32Constants.CF_UNICODETEXT);
        if (data == null || data.Length < 2)
            return null;

        return System.Text.Encoding.Unicode.GetString(data).TrimEnd('\0');
    }

    public static IntPtr ReadBitmapHandle()
    {
        if (!NativeMethods.OpenClipboard(IntPtr.Zero))
            return IntPtr.Zero;

        try
        {
            return NativeMethods.GetClipboardData(Win32Constants.CF_BITMAP);
        }
        finally
        {
            NativeMethods.CloseClipboard();
        }
    }

    public static string[]? ReadFileDrop()
    {
        byte[]? data = ReadClipboardData(Win32Constants.CF_HDROP);
        if (data == null)
            return null;

        IntPtr hDrop = Marshal.AllocHGlobal(data.Length);
        try
        {
            Marshal.Copy(data, 0, hDrop, data.Length);

            uint fileCount = NativeMethods.DragQueryFile(hDrop, 0xFFFFFFFF, null, 0);
            if (fileCount == 0)
                return Array.Empty<string>();

            var files = new string[fileCount];
            var sb = new System.Text.StringBuilder(260);

            for (uint i = 0; i < fileCount; i++)
            {
                sb.Clear();
                uint result = NativeMethods.DragQueryFile(hDrop, i, sb, (uint)sb.Capacity);
                if (result > 0)
                    files[i] = sb.ToString();
            }

            return files;
        }
        finally
        {
            Marshal.FreeHGlobal(hDrop);
        }
    }
}
