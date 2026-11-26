using System;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm.Tests {
    // Test-only Win32 helpers for the Fluent window host mechanics suite. No method throws on a missing window.
    public static class FluentHostNative {
        private const uint WM_CLOSE = 0x0010;
        private const uint GW_OWNER = 4;
        private const uint WM_COMMAND = 0x0111;
        private const uint BM_CLICK = 0x00F5;
        private const uint WM_GETTEXT = 0x000D;
        private const uint WM_KEYDOWN = 0x0100;
        private const uint WM_KEYUP = 0x0101;
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

        // Reads a message box's static text (the control with the id 0xFFFF) with WM_GETTEXT; empty when the box or the control is not found.
        public static string GetText(IntPtr dialog) {
            IntPtr item = GetDlgItem(dialog, 0xFFFF);
            if (item == IntPtr.Zero) { return string.Empty; }
            try {
                IntPtr buffer = Marshal.AllocHGlobal(8192 * 2);
                try {
                    IntPtr n = SendMessageRaw(item, WM_GETTEXT, new IntPtr(8192), buffer);
                    int len = n.ToInt32();
                    if (len <= 0) { return string.Empty; }
                    return Marshal.PtrToStringUni(buffer, Math.Min(len, 8191));
                } finally { Marshal.FreeHGlobal(buffer); }
            } catch (Exception) { return string.Empty; }
        }

        // Posts WM_KEYDOWN then WM_KEYUP with a virtual key to a window of this process (the queue, so key filters see it).
        public static bool PostKey(IntPtr hwnd, int vk) {
            if (hwnd == IntPtr.Zero) { return false; }
            try {
                bool down = PostMessageRaw(hwnd, WM_KEYDOWN, new IntPtr(vk), IntPtr.Zero);
                bool up = PostMessageRaw(hwnd, WM_KEYUP, new IntPtr(vk), new IntPtr(unchecked((int)0xC0000001)));
                return down && up;
            } catch (Exception) { return false; }
        }

        // Posts a message to a window of this process (the queue, so the message loop and its key filters see it).
        public static bool PostMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam) {
            if (hwnd == IntPtr.Zero) { return false; }
            try { return PostMessageRaw(hwnd, msg, wParam, lParam); } catch (Exception) { return false; }
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
