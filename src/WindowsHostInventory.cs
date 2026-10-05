using System;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm
{
    // Read-only, standard-user host facts. GPU/PnP identity is deliberately not inferred here.
    public static class WindowsHostInventory
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatusEx
        {
            public uint Length;
            public uint MemoryLoad;
            public ulong TotalPhys;
            public ulong AvailPhys;
            public ulong TotalPageFile;
            public ulong AvailPageFile;
            public ulong TotalVirtual;
            public ulong AvailVirtual;
            public ulong AvailExtendedVirtual;
        }

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx status);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint GetActiveProcessorCount(ushort groupNumber);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("ntdll.dll", ExactSpelling = true)]
        private static extern int RtlGetVersion(IntPtr versionInfo);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern void GetNativeSystemInfo(IntPtr systemInfo);

        public sealed class OsVersion
        {
            public uint Major { get; set; }
            public uint Minor { get; set; }
            public uint Build { get; set; }
        }

        public static long ReadPhysicalMemoryBytes()
        {
            MemoryStatusEx status = new MemoryStatusEx();
            status.Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
            if (!GlobalMemoryStatusEx(ref status) || status.TotalPhys == 0 || status.TotalPhys > long.MaxValue)
                throw new InvalidOperationException("Physical memory unavailable.");
            return checked((long)status.TotalPhys);
        }

        public static int ReadActiveLogicalProcessors()
        {
            // ALL_PROCESSOR_GROUPS == 0xffff. This is system active count, not process affinity.
            uint count = GetActiveProcessorCount(0xffff);
            if (count == 0 || count > 65536)
                throw new InvalidOperationException("Active processor count unavailable.");
            return checked((int)count);
        }

        public static OsVersion ReadOsVersion()
        {
            // OSVERSIONINFOEXW is 284 bytes; the first four DWORDs are size/major/minor/build.
            const int bytes = 284;
            IntPtr info = Marshal.AllocHGlobal(bytes);
            try
            {
                for (int offset = 0; offset < bytes; offset += 4) Marshal.WriteInt32(info, offset, 0);
                Marshal.WriteInt32(info, 0, bytes);
                if (RtlGetVersion(info) != 0) throw new InvalidOperationException("OS version unavailable.");
                uint major = unchecked((uint)Marshal.ReadInt32(info, 4));
                uint minor = unchecked((uint)Marshal.ReadInt32(info, 8));
                uint build = unchecked((uint)Marshal.ReadInt32(info, 12));
                if (major == 0 || build == 0) throw new InvalidOperationException("OS version unavailable.");
                return new OsVersion { Major = major, Minor = minor, Build = build };
            }
            finally { Marshal.FreeHGlobal(info); }
        }

        public static string ReadNativeArchitecture()
        {
            // Only SYSTEM_INFO's first WORD (wProcessorArchitecture) is read.
            IntPtr info = Marshal.AllocHGlobal(64);
            try
            {
                for (int offset = 0; offset < 64; offset += 4) Marshal.WriteInt32(info, offset, 0);
                GetNativeSystemInfo(info);
                ushort architecture = unchecked((ushort)Marshal.ReadInt16(info, 0));
                if (architecture == 9) return "x64";
                if (architecture == 12) return "arm64";
                if (architecture == 0) return "x86";
                throw new InvalidOperationException("Native architecture unavailable.");
            }
            finally { Marshal.FreeHGlobal(info); }
        }
    }
}
