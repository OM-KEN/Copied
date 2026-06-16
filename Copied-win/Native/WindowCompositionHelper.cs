using System.Runtime.InteropServices;
using System.Windows.Media;

namespace Copied.Native;

public static class WindowCompositionHelper
{
    private const uint WCA_ACCENT_POLICY = 19;

    private static bool s_acrylicAvailable = true;
    private static bool s_blurAvailable = true;

    public static bool TryEnableAcrylic(IntPtr hwnd, System.Windows.Media.Color tintColor)
    {
        uint abgr = (uint)((tintColor.A << 24) | (tintColor.B << 16) | (tintColor.G << 8) | tintColor.R);

        if (s_acrylicAvailable)
        {
            if (TrySetAccent(hwnd, AccentState.ACCENT_ENABLE_ACRYLICBLURBEHIND, abgr))
                return true;
            s_acrylicAvailable = false;
        }

        if (s_blurAvailable)
        {
            if (TrySetAccent(hwnd, AccentState.ACCENT_ENABLE_BLURBEHIND, abgr))
                return true;
            s_blurAvailable = false;
        }

        return false;
    }

    private static bool TrySetAccent(IntPtr hwnd, AccentState state, uint gradientColor)
    {
        var accent = new AccentPolicy
        {
            AccentState = state,
            AccentFlags = 2,
            GradientColor = gradientColor
        };

        int structSize = Marshal.SizeOf(accent);
        IntPtr ptr = Marshal.AllocHGlobal(structSize);
        try
        {
            Marshal.StructureToPtr(accent, ptr, false);
            var data = new WindowCompositionAttributeData
            {
                Attribute = WCA_ACCENT_POLICY,
                SizeOfData = structSize,
                Data = ptr
            };
            return NativeMethods.SetWindowCompositionAttribute(hwnd, ref data) != 0;
        }
        catch
        {
            return false;
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }
}
