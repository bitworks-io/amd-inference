using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Bitworks.FastLlm {
    // Diagnostic only. This uses the public b10698 GGML C ABI; no model or backend stream is initialized.
    public static class WindowsGgmlVulkanIdentity {
        public sealed class Device {
            public string Name { get; set; }
            public string Backend { get; set; }
            public string Description { get; set; }
            public long MemoryFreeBytes { get; set; }
            public long MemoryTotalBytes { get; set; }
            public string DeviceId { get; set; }
        }

        private const uint SearchDllLoadDir = 0x00000100;
        private const uint SearchUserDirs = 0x00000400;
        private const uint SearchSystem32 = 0x00000800;
        private const int PropsBytes = 128;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetDefaultDllDirectories(uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr AddDllDirectory(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate IntPtr BackendLoad(IntPtr path);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate IntPtr DeviceByName(IntPtr name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void DeviceProps(IntPtr device, IntPtr props);

        private static T Symbol<T>(IntPtr module, string name) where T : class {
            IntPtr address = GetProcAddress(module, name);
            if (address == IntPtr.Zero) throw new InvalidOperationException("Required GGML ABI symbol is absent: " + name);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
        }

        private static IntPtr AsciiZ(string value) {
            // std::filesystem::path's Windows conversion for char* is locale-dependent.
            // Fail closed for non-ASCII paths rather than load a different DLL.
            foreach (char c in value) if (c < 0x20 || c > 0x7e)
                throw new NotSupportedException("GGML diagnostic requires an ASCII-only engine path.");
            byte[] bytes = Encoding.ASCII.GetBytes(value + "\0");
            IntPtr ptr = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, ptr, bytes.Length);
            return ptr;
        }

        private static string ReadAnsiBounded(IntPtr ptr, int maxBytes) {
            if (ptr == IntPtr.Zero) return null;
            byte[] bytes = new byte[maxBytes];
            int count = 0;
            for (; count < maxBytes; count++) {
                byte b = Marshal.ReadByte(ptr, count);
                if (b == 0) break;
                bytes[count] = b;
            }
            if (count == maxBytes) throw new InvalidDataException("GGML device text exceeds its limit.");
            string value = Encoding.UTF8.GetString(bytes, 0, count);
            foreach (char c in value) if (char.IsControl(c))
                throw new InvalidDataException("GGML device text contains a control character.");
            return value;
        }

        public static Device[] Read(string engineDirectory) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("64-bit Windows is required.");
            string root = Path.GetFullPath(engineDirectory);
            if (!Directory.Exists(root)) throw new DirectoryNotFoundException("Verified engine directory is absent.");
            string basePath = Path.Combine(root, "ggml-base.dll");
            string corePath = Path.Combine(root, "ggml.dll");
            string vulkanPath = Path.Combine(root, "ggml-vulkan.dll");
            if (!File.Exists(basePath) || !File.Exists(corePath) || !File.Exists(vulkanPath))
                throw new FileNotFoundException("Required verified GGML DLL is absent.");

            // This is a short-lived, isolated worker. Exclude its PowerShell application
            // directory and inherited PATH from subsequent DLL dependency resolution.
            if (!SetDefaultDllDirectories(SearchUserDirs | SearchSystem32))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restrict DLL search.");
            if (AddDllDirectory(root) == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not add verified engine directory.");
            uint flags = SearchDllLoadDir | SearchUserDirs | SearchSystem32;
            IntPtr baseDll = LoadLibraryExW(basePath, IntPtr.Zero, flags);
            if (baseDll == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load verified GGML base.");
            IntPtr core = LoadLibraryExW(corePath, IntPtr.Zero, flags);
            if (core == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load verified GGML core.");

            BackendLoad load = Symbol<BackendLoad>(core, "ggml_backend_load");
            DeviceByName byName = Symbol<DeviceByName>(core, "ggml_backend_dev_by_name");
            // The pinned b10698 PE export table places get_props in ggml-base.dll.
            DeviceProps getProps = Symbol<DeviceProps>(baseDll, "ggml_backend_dev_get_props");
            IntPtr path = IntPtr.Zero;
            try {
                path = AsciiZ(vulkanPath);
                if (load(path) == IntPtr.Zero)
                    throw new InvalidOperationException("Verified GGML Vulkan backend did not register.");
            } finally {
                if (path != IntPtr.Zero) Marshal.FreeHGlobal(path);
            }

            var result = new List<Device>();
            for (int index = 0; index <= 8; index++) {
                string name = "Vulkan" + index.ToString(System.Globalization.CultureInfo.InvariantCulture);
                IntPtr namePtr = AsciiZ(name);
                IntPtr dev;
                try { dev = byName(namePtr); }
                finally { Marshal.FreeHGlobal(namePtr); }
                if (dev == IntPtr.Zero) break;
                if (index == 8) throw new InvalidDataException("More than eight GGML Vulkan devices were reported.");
                IntPtr props = Marshal.AllocHGlobal(PropsBytes);
                try {
                    for (int offset = 0; offset < PropsBytes; offset++) Marshal.WriteByte(props, offset, 0);
                    getProps(dev, props);
                    // b10698 ggml_backend_dev_props on x64: two char*, two size_t,
                    // four-byte enum plus padding, then device_id char*.
                    string reportedName = ReadAnsiBounded(Marshal.ReadIntPtr(props, 0), 64);
                    string description = ReadAnsiBounded(Marshal.ReadIntPtr(props, 8), 256);
                    long free = Marshal.ReadInt64(props, 16);
                    long total = Marshal.ReadInt64(props, 24);
                    int type = Marshal.ReadInt32(props, 32);
                    string pci = ReadAnsiBounded(Marshal.ReadIntPtr(props, 40), 32);
                    if (reportedName != name || String.IsNullOrWhiteSpace(description) ||
                        free < 0 || total <= 0 || free > total || (type != 1 && type != 2))
                        throw new InvalidDataException("GGML device properties are inconsistent.");
                    if (pci != null && !Regex.IsMatch(pci, "^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]$"))
                        throw new InvalidDataException("GGML PCI device ID has an unexpected format.");
                    result.Add(new Device { Name = name, Backend = "Vulkan", Description = description,
                        MemoryFreeBytes = free, MemoryTotalBytes = total, DeviceId = pci });
                } finally { Marshal.FreeHGlobal(props); }
            }
            return result.ToArray();
        }
    }
}
