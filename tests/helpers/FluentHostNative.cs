using System;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm.Tests {
    // Test-only Win32 helpers for the Fluent window host mechanics suite. No method throws on a missing window.
    public static class FluentHostNative {
        private const uint WM_CLOSE = 0x0010;
        private const uint GW_OWNER = 4;
        private const uint WM_COMMAND = 0x0111;
        private const uint BM_CLICK = 0x00F5;
        private const uint GR_GDIOBJECTS = 0;

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

        [DllImport("user32.dll", EntryPoint = "GetDlgItem")]
        private static extern IntPtr GetDlgItemRaw(IntPtr hDlg, int nIDDlgItem);

        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr SendMessageRaw(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", EntryPoint = "GetGuiResources")]
        private static extern uint GetGuiResourcesRaw(IntPtr hProcess, uint uiFlags);

        [DllImport("kernel32.dll", EntryPoint = "GetCurrentProcess")]
        private static extern IntPtr GetCurrentProcessRaw();

        [DllImport("user32.dll", EntryPoint = "GetThreadDpiAwarenessContext")]
        private static extern IntPtr GetThreadDpiAwarenessContextRaw();

        [DllImport("user32.dll", EntryPoint = "GetAwarenessFromDpiAwarenessContext")]
        private static extern int GetAwarenessFromDpiAwarenessContextRaw(IntPtr context);

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

        // Added for the shell suite. GetDlgItem finds a dialog button (a message box: 1 OK, 6 Yes, 7 No).
        public static IntPtr GetDlgItem(IntPtr dialog, int id) {
            if (dialog == IntPtr.Zero) { return IntPtr.Zero; }
            try { return GetDlgItemRaw(dialog, id); } catch (Exception) { return IntPtr.Zero; }
        }

        // Posts BM_CLICK to a dialog button; false when the button is not found.
        public static bool PostButtonClick(IntPtr dialog, int id) {
            IntPtr button = GetDlgItem(dialog, id);
            if (button == IntPtr.Zero) { return false; }
            try { return PostMessageRaw(button, BM_CLICK, IntPtr.Zero, IntPtr.Zero); } catch (Exception) { return false; }
        }

        // Posts WM_COMMAND with the button id (IDYES 6, IDNO 7) to the dialog itself.
        public static bool PostCommand(IntPtr dialog, int id) {
            if (dialog == IntPtr.Zero) { return false; }
            try { return PostMessageRaw(dialog, WM_COMMAND, new IntPtr(id), IntPtr.Zero); } catch (Exception) { return false; }
        }

        // Synchronous SendMessage to a window of this process only; the caller passes its own hwnd.
        public static IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
            return SendMessageRaw(hwnd, msg, wParam, lParam);
        }

        // GDI objects held by this process (GetGuiResources GR_GDIOBJECTS); -1 when the call fails.
        public static int GetGdiObjectCount() {
            try { return (int)GetGuiResourcesRaw(GetCurrentProcessRaw(), GR_GDIOBJECTS); } catch (Exception) { return -1; }
        }

        // Thread DPI awareness: 0 unaware, 1 system, 2 per-monitor, -1 invalid, -2 the call is not available. Evidence only.
        public static int GetDpiAwareness() {
            try { return GetAwarenessFromDpiAwarenessContextRaw(GetThreadDpiAwarenessContextRaw()); } catch (Exception) { return -2; }
        }
    }
}
