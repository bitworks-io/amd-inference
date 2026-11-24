using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm {
    // Window chrome helpers for the Fluent window. No method throws: a missing DLL or entry point, or a Win32 failure,
    // becomes a failure value (an HRESULT, false or 0) so the caller can fall back to the solid look.
    public static class FluentWindowNative {
        private const int DwmwaUseImmersiveDarkModeBefore20H1 = 19;
        private const int DwmwaUseImmersiveDarkMode = 20;
        private const int DwmwaSystemBackdropType = 38;
        private static readonly int EFail = unchecked((int)0x80004005);

        [StructLayout(LayoutKind.Sequential)]
        private struct MARGINS {
            public int cxLeftWidth;
            public int cxRightWidth;
            public int cyTopHeight;
            public int cyBottomHeight;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct OSVERSIONINFOEX {
            public int dwOSVersionInfoSize;
            public int dwMajorVersion;
            public int dwMinorVersion;
            public int dwBuildNumber;
            public int dwPlatformId;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            public string szCSDVersion;
            public ushort wServicePackMajor;
            public ushort wServicePackMinor;
            public ushort wSuiteMask;
            public byte wProductType;
            public byte wReserved;
        }

        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);

        [DllImport("ntdll.dll", PreserveSig = true)]
        private static extern int RtlGetVersion(ref OSVERSIONINFOEX info);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyIcon(IntPtr icon);

        [DllImport("user32.dll")]
        private static extern uint GetGuiResources(IntPtr process, uint flags);

        [DllImport("kernel32.dll")]
        private static extern IntPtr GetCurrentProcess();

        private static int SetAttribute(IntPtr hwnd, int attribute, int value) {
            try {
                int v = value;
                return DwmSetWindowAttribute(hwnd, attribute, ref v, sizeof(int));
            } catch (DllNotFoundException) {
                return EFail;
            } catch (EntryPointNotFoundException) {
                return EFail;
            } catch (Win32Exception) {
                return EFail;
            }
        }

        // Attribute 20 (Windows 10 2004 and later), then attribute 19 (older builds). Returns the HRESULT of the last attempt.
        public static int SetDarkTitleBar(IntPtr hwnd, bool dark) {
            int value = dark ? 1 : 0;
            int hr = SetAttribute(hwnd, DwmwaUseImmersiveDarkMode, value);
            if (hr != 0) {
                hr = SetAttribute(hwnd, DwmwaUseImmersiveDarkModeBefore20H1, value);
            }
            return hr;
        }

        // Type 1 is none and 2 is Mica.
        public static int SetSystemBackdrop(IntPtr hwnd, int type) {
            return SetAttribute(hwnd, DwmwaSystemBackdropType, type);
        }

        public static int ExtendFrameIntoClientArea(IntPtr hwnd) {
            try {
                MARGINS margins = new MARGINS();
                margins.cxLeftWidth = -1;
                margins.cxRightWidth = -1;
                margins.cyTopHeight = -1;
                margins.cyBottomHeight = -1;
                return DwmExtendFrameIntoClientArea(hwnd, ref margins);
            } catch (DllNotFoundException) {
                return EFail;
            } catch (EntryPointNotFoundException) {
                return EFail;
            } catch (Win32Exception) {
                return EFail;
            }
        }

        // The real build number (not subject to manifest version lies); 0 when it cannot be read.
        public static int GetOsBuild() {
            try {
                OSVERSIONINFOEX info = new OSVERSIONINFOEX();
                info.dwOSVersionInfoSize = Marshal.SizeOf(typeof(OSVERSIONINFOEX));
                if (RtlGetVersion(ref info) != 0) {
                    return 0;
                }
                return info.dwBuildNumber;
            } catch (DllNotFoundException) {
                return 0;
            } catch (EntryPointNotFoundException) {
                return 0;
            } catch (Win32Exception) {
                return 0;
            }
        }

        public static bool DestroyIconHandle(IntPtr icon) {
            if (icon == IntPtr.Zero) {
                return false;
            }
            try {
                return DestroyIcon(icon);
            } catch (DllNotFoundException) {
                return false;
            } catch (EntryPointNotFoundException) {
                return false;
            } catch (Win32Exception) {
                return false;
            }
        }

        public static int GetGdiObjectCount() {
            try {
                return (int)GetGuiResources(GetCurrentProcess(), 0);
            } catch (DllNotFoundException) {
                return 0;
            } catch (EntryPointNotFoundException) {
                return 0;
            } catch (Win32Exception) {
                return 0;
            }
        }
    }

    // The window-message hook body. PowerShell cannot write back a ref bool from a scriptblock delegate, so the
    // hook itself is C#; PowerShell runs only for session-end queries and theme messages.
    public sealed class FluentWindowHook {
        private readonly Func<bool> refuseSessionEnd;
        private readonly Action themeChanged;

        // The last exception a callback threw (the hook swallows it so the message loop is never broken); null when none.
        public Exception LastError { get; private set; }

        public FluentWindowHook(Func<bool> refuseSessionEnd, Action themeChanged) {
            this.refuseSessionEnd = refuseSessionEnd;
            this.themeChanged = themeChanged;
        }

        public IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
            if (msg == 0x0011) {
                bool refuse;
                try { refuse = refuseSessionEnd(); } catch (Exception ex) { LastError = ex; refuse = true; }
                if (refuse) { handled = true; }
                return IntPtr.Zero;
            }
            if (msg == 0x001A || msg == 0x0015 || msg == 0x0320) {
                try { themeChanged(); } catch (Exception ex) { LastError = ex; }
            }
            return IntPtr.Zero;
        }

        public Delegate CreateHook(Type hookType) {
            return Delegate.CreateDelegate(hookType, this, "WndProc");
        }
    }
}
