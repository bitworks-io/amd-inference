using System;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm.Tests {
    // Test-only Win32 helpers for the Fluent window host mechanics suite. No method throws on a missing window.
    public static class FluentHostNative {
        private const uint WM_CLOSE = 0x0010;
        private const uint GW_OWNER = 4;

        [DllImport("user32.dll", EntryPoint = "IsWindowEnabled")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowEnabledRaw(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", EntryPoint = "GetWindow")]
        private static extern IntPtr GetWindowRaw(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PostMessageRaw(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        public static bool IsWindowEnabled(IntPtr hwnd) {
            try { return IsWindowEnabledRaw(hwnd); } catch (Exception) { return false; }
        }

        public static IntPtr FindWindowByTitle(string title) {
            try { return FindWindowW(null, title); } catch (Exception) { return IntPtr.Zero; }
        }

        public static IntPtr GetOwner(IntPtr hwnd) {
            if (hwnd == IntPtr.Zero) { return IntPtr.Zero; }
            try { return GetWindowRaw(hwnd, GW_OWNER); } catch (Exception) { return IntPtr.Zero; }
        }

        public static bool PostClose(IntPtr hwnd) {
            if (hwnd == IntPtr.Zero) { return false; }
            try { return PostMessageRaw(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero); } catch (Exception) { return false; }
        }
    }
}
