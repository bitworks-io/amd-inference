using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Bitworks.FastLlm {
    // Private, short-lived b10698 GGML C-ABI diagnostic. No model/backend stream is created.
    public static class WindowsGgmlVulkanCapabilities {
        public sealed class Device {
            public string DeviceName { get; set; }
            public string Description { get; set; }
            public string DeviceId { get; set; }
            public string DeviceIdStatus { get; set; }
            public long TotalMiB { get; set; }
            public long FreeMiB { get; set; }
            public string DriverName { get; set; }
            public bool Uma { get; set; }
            public string Fp16 { get; set; }
            public bool Bf16 { get; set; }
            public bool Fp4 { get; set; }
            public int WarpSize { get; set; }
            public int SharedMemoryBytes { get; set; }
            public bool IntegerDotProduct { get; set; }
            public string MatrixCores { get; set; }
        }
        public sealed class Snapshot {
            public int ReportedDeviceCount { get; set; }
            public Device[] Devices { get; set; }
        }

        private const uint SearchDllLoadDir = 0x00000100;
        private const uint SearchUserDirs = 0x00000400;
        private const uint SearchSystem32 = 0x00000800;
        private const int PropsBytes = 128;
        private const long MiB = 1024 * 1024;
        private static readonly Regex FoundPattern = new Regex(@"^ggml_vulkan: Found ([1-8]) Vulkan devices:\s*$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
        private static readonly Regex CapabilityPattern = new Regex(@"^ggml_vulkan: ([0-7]) = ([A-Za-z0-9 ._()+-]{1,96}) \(([A-Za-z0-9 ._()+-]{1,96})\) \| uma: ([01]) \| fp16: (0|1|dot2) \| bf16: ([01]) \| fp4: ([01]) \| warp size: ([0-9]{1,3}) \| shared memory: ([0-9]{1,8}) \| int dot: ([01]) \| matrix cores: (none|KHR_coopmat|NV_coopmat2v|NV_coopmat2)\s*$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetDefaultDllDirectories(uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr AddDllDirectory(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr GetModuleHandleW(string name);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void LogCallback(int level, IntPtr text, IntPtr userData);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void LogGet(out IntPtr callback, out IntPtr userData);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate void LogSet(IntPtr callback, IntPtr userData);
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
            foreach (char c in value) if (c < 0x20 || c > 0x7e)
                throw new NotSupportedException("GGML diagnostic requires an ASCII-only engine path.");
            byte[] bytes = Encoding.ASCII.GetBytes(value + "\0");
            IntPtr ptr = Marshal.AllocHGlobal(bytes.Length);
            Marshal.Copy(bytes, 0, ptr, bytes.Length);
            return ptr;
        }
        private static string ReadUtf8Bounded(IntPtr ptr, int maxBytes) {
            if (ptr == IntPtr.Zero) return null;
            byte[] bytes = new byte[maxBytes];
            int count = 0;
            for (; count < maxBytes; count++) {
                byte b = Marshal.ReadByte(ptr, count);
                if (b == 0) break;
                bytes[count] = b;
            }
            if (count == maxBytes) throw new InvalidDataException("GGML diagnostic text exceeds its limit.");
            return Encoding.UTF8.GetString(bytes, 0, count);
        }
        private static long CheckedMiB(long bytes) {
            if (bytes < 0 || bytes > 1024L * 1024L * 1024L * 1024L)
                throw new InvalidDataException("GGML device memory is invalid.");
            return bytes / MiB;
        }

        public static Snapshot Read(string engineDirectory) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("64-bit Windows is required.");
            string root = Path.GetFullPath(engineDirectory);
            if (!Directory.Exists(root)) throw new DirectoryNotFoundException("Verified engine directory is absent.");
            foreach (string name in new string[] { "ggml-base.dll", "ggml.dll", "ggml-vulkan.dll" }) {
                if (!File.Exists(Path.Combine(root, name))) throw new FileNotFoundException("Required verified GGML DLL is absent.");
                if (GetModuleHandleW(name) != IntPtr.Zero)
                    throw new InvalidOperationException("A GGML DLL was preloaded before the restricted diagnostic loader.");
            }
            if (!SetDefaultDllDirectories(SearchUserDirs | SearchSystem32))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restrict DLL search.");
            if (AddDllDirectory(root) == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not add verified engine directory.");
            uint flags = SearchDllLoadDir | SearchUserDirs | SearchSystem32;
            IntPtr baseDll = LoadLibraryExW(Path.Combine(root, "ggml-base.dll"), IntPtr.Zero, flags);
            if (baseDll == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load verified GGML base.");
            LogGet logGet = Symbol<LogGet>(baseDll, "ggml_log_get");
            LogSet logSet = Symbol<LogSet>(baseDll, "ggml_log_set");
            IntPtr previousCallback, previousUserData;
            logGet(out previousCallback, out previousUserData);
            var messages = new List<string>();
            var gate = new object();
            bool callbackFailed = false;
            LogCallback collector = delegate(int level, IntPtr text, IntPtr ignored) {
                try {
                    // ggml.h: GGML_LOG_LEVEL_DEBUG = 1. Other logs are not retained.
                    if (level != 1) return;
                    string line = ReadUtf8Bounded(text, 1024);
                    if (line == null || !line.StartsWith("ggml_vulkan: ", StringComparison.Ordinal)) return;
                    if (!line.StartsWith("ggml_vulkan: Found ", StringComparison.Ordinal) &&
                        !Regex.IsMatch(line, @"^ggml_vulkan: [0-9]+ = ", RegexOptions.CultureInvariant)) return;
                    lock (gate) {
                        if (messages.Count >= 10) { callbackFailed = true; return; }
                        messages.Add(line.TrimEnd('\r', '\n'));
                    }
                } catch { lock (gate) { callbackFailed = true; } }
            };
            IntPtr callbackPointer = Marshal.GetFunctionPointerForDelegate(collector);
            logSet(callbackPointer, IntPtr.Zero);
            try {
                IntPtr core = LoadLibraryExW(Path.Combine(root, "ggml.dll"), IntPtr.Zero, flags);
                if (core == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not load verified GGML core.");
                BackendLoad load = Symbol<BackendLoad>(core, "ggml_backend_load");
                DeviceByName byName = Symbol<DeviceByName>(core, "ggml_backend_dev_by_name");
                // b10698 PE export audit: device props lives in ggml-base.dll,
                // while backend_load and dev_by_name live in ggml.dll.
                DeviceProps getProps = Symbol<DeviceProps>(baseDll, "ggml_backend_dev_get_props");
                IntPtr path = AsciiZ(Path.Combine(root, "ggml-vulkan.dll"));
                try {
                    if (load(path) == IntPtr.Zero)
                        throw new InvalidOperationException("Verified GGML Vulkan backend did not register.");
                } finally { Marshal.FreeHGlobal(path); }

                int foundCount = -1;
                var capabilityRows = new Dictionary<int, Match>();
                lock (gate) {
                    if (callbackFailed) throw new InvalidDataException("GGML callback data was excessive or malformed.");
                    foreach (string line in messages) {
                        Match found = FoundPattern.Match(line);
                        if (found.Success) {
                            if (foundCount != -1) throw new InvalidDataException("Duplicate GGML Vulkan device-count row.");
                            foundCount = int.Parse(found.Groups[1].Value, CultureInfo.InvariantCulture);
                            continue;
                        }
                        Match row = CapabilityPattern.Match(line);
                        if (!row.Success) throw new InvalidDataException("Malformed GGML Vulkan capability row.");
                        int index = int.Parse(row.Groups[1].Value, CultureInfo.InvariantCulture);
                        if (capabilityRows.ContainsKey(index)) throw new InvalidDataException("Duplicate GGML Vulkan capability row.");
                        capabilityRows.Add(index, row);
                    }
                }
                if (foundCount < 1 || foundCount > 8 || capabilityRows.Count != foundCount)
                    throw new InvalidDataException("GGML Vulkan callback did not provide a complete device set.");
                var devices = new List<Device>();
                for (int index = 0; index < foundCount; index++) {
                    Match row;
                    if (!capabilityRows.TryGetValue(index, out row)) throw new InvalidDataException("GGML Vulkan device indices are not contiguous.");
                    string deviceName = "Vulkan" + index.ToString(CultureInfo.InvariantCulture);
                    IntPtr namePtr = AsciiZ(deviceName);
                    IntPtr dev;
                    try { dev = byName(namePtr); }
                    finally { Marshal.FreeHGlobal(namePtr); }
                    if (dev == IntPtr.Zero) throw new InvalidDataException("GGML Vulkan capability device is absent from registry.");
                    IntPtr props = Marshal.AllocHGlobal(PropsBytes);
                    try {
                        for (int offset = 0; offset < PropsBytes; offset++) Marshal.WriteByte(props, offset, 0);
                        getProps(dev, props);
                        string reportedName = ReadUtf8Bounded(Marshal.ReadIntPtr(props, 0), 64);
                        string description = ReadUtf8Bounded(Marshal.ReadIntPtr(props, 8), 256);
                        long freeBytes = Marshal.ReadInt64(props, 16);
                        long totalBytes = Marshal.ReadInt64(props, 24);
                        int type = Marshal.ReadInt32(props, 32);
                        string pci = ReadUtf8Bounded(Marshal.ReadIntPtr(props, 40), 32);
                        if (reportedName != deviceName || description != row.Groups[2].Value ||
                            (type != 1 && type != 2) || freeBytes < 0 || totalBytes <= 0 || freeBytes > totalBytes)
                            throw new InvalidDataException("GGML Vulkan device properties disagree with callback.");
                        // The Vulkan backend may expose no PCI BDF on Windows. Its
                        // capability row remains useful, but no identity join follows.
                        string pciStatus = "unavailable";
                        if (!string.IsNullOrEmpty(pci)) {
                            if (Regex.IsMatch(pci, @"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$", RegexOptions.CultureInvariant))
                                pciStatus = "bdf-reported";
                            else { pciStatus = "invalid-format"; pci = null; }
                        } else pci = null;
                        int warp = int.Parse(row.Groups[8].Value, CultureInfo.InvariantCulture);
                        int shared = int.Parse(row.Groups[9].Value, CultureInfo.InvariantCulture);
                        if (warp < 1 || warp > 128 || shared < 1 || shared > 1048576)
                            throw new InvalidDataException("GGML Vulkan capability value is impossible.");
                        devices.Add(new Device {
                            DeviceName = deviceName, Description = description, DeviceId = pci, DeviceIdStatus = pciStatus,
                            TotalMiB = CheckedMiB(totalBytes), FreeMiB = CheckedMiB(freeBytes),
                            DriverName = row.Groups[3].Value, Uma = row.Groups[4].Value == "1",
                            Fp16 = row.Groups[5].Value, Bf16 = row.Groups[6].Value == "1",
                            Fp4 = row.Groups[7].Value == "1", WarpSize = warp,
                            SharedMemoryBytes = shared, IntegerDotProduct = row.Groups[10].Value == "1",
                            MatrixCores = row.Groups[11].Value
                        });
                    } finally { Marshal.FreeHGlobal(props); }
                }
                // Fail closed if GGML exposes an additional ninth Vulkan device.
                IntPtr ninthName = AsciiZ("Vulkan" + foundCount.ToString(CultureInfo.InvariantCulture));
                try { if (byName(ninthName) != IntPtr.Zero) throw new InvalidDataException("GGML Vulkan registry has more devices than callback."); }
                finally { Marshal.FreeHGlobal(ninthName); }
                return new Snapshot { ReportedDeviceCount = foundCount, Devices = devices.ToArray() };
            } finally {
                logSet(previousCallback, previousUserData);
                GC.KeepAlive(collector);
            }
        }
    }
}
