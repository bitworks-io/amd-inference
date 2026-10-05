// Private, unqualified Windows lab diagnostic. Do not use for selection or
// compatibility approval. ABI sources:
// https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceIDProperties.html
// https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDevicePCIBusInfoPropertiesEXT.html
// https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_adapter_name
// https://learn.microsoft.com/en-us/windows/win32/api/setupapi/nf-setupapi-setupdigetdeviceinterfacedetailw
// https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/shared/devpkey.h
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Bitworks.FastLlm {
    public static class WindowsVulkanPnPBridge {
        public sealed class Result {
            public string Bdf { get; set; }
            public string Luid { get; set; }
            public uint NodeMask { get; set; }
            public string InstanceId { get; set; }
            public string DriverVersion { get; set; }
            public string DriverProvider { get; set; }
            public string DriverInfPath { get; set; }
            public string Failure { get; set; }
        }
        [StructLayout(LayoutKind.Sequential)] private struct AppInfo {
            public int sType; public IntPtr pNext; public IntPtr pApplicationName;
            public uint applicationVersion; public IntPtr pEngineName; public uint engineVersion; public uint apiVersion;
        }
        [StructLayout(LayoutKind.Sequential)] private struct InstanceInfo {
            public int sType; public IntPtr pNext; public uint flags; public IntPtr pApplicationInfo;
            public uint enabledLayerCount; public IntPtr ppEnabledLayerNames;
            public uint enabledExtensionCount; public IntPtr ppEnabledExtensionNames;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)] private struct DisplayHeader {
            public uint type, size; public Luid adapterId; public uint id;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct AdapterName {
            public DisplayHeader header;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string adapterDevicePath;
        }
        [StructLayout(LayoutKind.Sequential)] private struct InterfaceData {
            public uint cbSize; public Guid InterfaceClassGuid; public uint Flags; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] private struct DevInfoData {
            public uint cbSize; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] private struct DevPropKey { public Guid fmtid; public uint pid; }
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr GetInstanceProcAddr(IntPtr instance, [MarshalAs(UnmanagedType.LPStr)] string name);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int CreateInstance(ref InstanceInfo info, IntPtr allocator, out IntPtr instance);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void DestroyInstance(IntPtr instance, IntPtr allocator);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int EnumeratePhysicalDevices(IntPtr instance, ref uint count, IntPtr devices);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int EnumerateDeviceExtensions(IntPtr physicalDevice, IntPtr layerName, ref uint count, IntPtr properties);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void GetPhysicalDeviceProperties2(IntPtr physicalDevice, IntPtr properties);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetSystemDirectoryW(StringBuilder buffer, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetModuleFileNameW(IntPtr module, StringBuilder buffer, uint size);
        [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
        [DllImport("user32.dll", SetLastError=true)] private static extern int DisplayConfigGetDeviceInfo(ref AdapterName packet);
        [DllImport("setupapi.dll", SetLastError=true)] private static extern IntPtr SetupDiCreateDeviceInfoList(IntPtr classGuid, IntPtr hwndParent);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, EntryPoint="SetupDiOpenDeviceInterfaceW", SetLastError=true)] private static extern bool SetupDiOpenDeviceInterface(IntPtr list, string path, uint flags, ref InterfaceData data);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, EntryPoint="SetupDiGetDeviceInterfaceDetailW", SetLastError=true)] private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr list, ref InterfaceData interfaceData, IntPtr detail, uint detailSize, out uint required, ref DevInfoData deviceData);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, EntryPoint="SetupDiGetDeviceInstanceIdW", SetLastError=true)] private static extern bool SetupDiGetDeviceInstanceId(IntPtr list, ref DevInfoData device, StringBuilder id, uint size, out uint required);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, EntryPoint="SetupDiGetDevicePropertyW", SetLastError=true)] private static extern bool SetupDiGetDeviceProperty(IntPtr list, ref DevInfoData device, ref DevPropKey key, out uint type, byte[] buffer, uint size, out uint required, uint flags);
        [DllImport("setupapi.dll")] private static extern bool SetupDiDestroyDeviceInfoList(IntPtr list);

        public static string AbiSizes() {
            return String.Join(",", new string[] {
                Marshal.SizeOf(typeof(AppInfo)).ToString(), Marshal.SizeOf(typeof(InstanceInfo)).ToString(),
                Marshal.SizeOf(typeof(Luid)).ToString(), Marshal.SizeOf(typeof(DisplayHeader)).ToString(),
                Marshal.SizeOf(typeof(AdapterName)).ToString(), Marshal.SizeOf(typeof(InterfaceData)).ToString(),
                Marshal.SizeOf(typeof(DevInfoData)).ToString(), Marshal.SizeOf(typeof(DevPropKey)).ToString()
            });
        }
        public static string FormatLuid(byte[] bytes) {
            if (bytes == null || bytes.Length != 8) throw new ArgumentException("LUID must have exactly eight bytes.", "bytes");
            return BitConverter.ToUInt32(bytes, 4).ToString("x8", System.Globalization.CultureInfo.InvariantCulture) +
                   BitConverter.ToUInt32(bytes, 0).ToString("x8", System.Globalization.CultureInfo.InvariantCulture);
        }

        private static T Function<T>(GetInstanceProcAddr get, IntPtr instance, string name) where T : class {
            IntPtr pointer = get(instance, name);
            if (pointer == IntPtr.Zero) throw new InvalidOperationException("vulkan-function-unavailable:" + name);
            return Marshal.GetDelegateForFunctionPointer(pointer, typeof(T)) as T;
        }
        private static string BoundedProperty(IntPtr list, ref DevInfoData dev, uint pid) {
            var key = new DevPropKey { fmtid = new Guid("a8b865dd-2e3d-4094-ad97-e593a70c75d6"), pid = pid };
            uint type, needed;
            byte[] bytes = new byte[1024];
            if (!SetupDiGetDeviceProperty(list, ref dev, ref key, out type, bytes, (uint)bytes.Length, out needed, 0)) return null;
            if (type != 0x12 || needed < 2 || needed > bytes.Length || (needed & 1) != 0) return null; // DEVPROP_TYPE_STRING
            string value = Encoding.Unicode.GetString(bytes, 0, (int)needed).TrimEnd('\0');
            return value.Length > 0 && value.Length <= 512 && value.IndexOf('\0') < 0 ? value : null;
        }
        private static void BindDevice(ref Result result, byte[] luidBytes) {
            var packet = new AdapterName {
                header = new DisplayHeader { type = 4, size = (uint)Marshal.SizeOf(typeof(AdapterName)),
                    adapterId = new Luid { LowPart = BitConverter.ToUInt32(luidBytes, 0), HighPart = BitConverter.ToInt32(luidBytes, 4) } },
                adapterDevicePath = ""
            };
            int status = DisplayConfigGetDeviceInfo(ref packet);
            if (status != 0) { result.Failure = "displayconfig-unavailable:" + status; return; }
            string path = packet.adapterDevicePath;
            if (String.IsNullOrEmpty(path) || path.Length >= 128) { result.Failure = "adapter-path-unavailable"; return; }
            IntPtr list = SetupDiCreateDeviceInfoList(IntPtr.Zero, IntPtr.Zero);
            if (list == new IntPtr(-1)) { result.Failure = "setupapi-list-unavailable"; return; }
            try {
                var iface = new InterfaceData { cbSize = (uint)Marshal.SizeOf(typeof(InterfaceData)) };
                if (!SetupDiOpenDeviceInterface(list, path, 0, ref iface)) { result.Failure = "setupapi-interface-unavailable"; return; }
                var dev = new DevInfoData { cbSize = (uint)Marshal.SizeOf(typeof(DevInfoData)) };
                uint needed;
                bool ok = SetupDiGetDeviceInterfaceDetail(list, ref iface, IntPtr.Zero, 0, out needed, ref dev);
                if (ok || Marshal.GetLastWin32Error() != 122 || needed == 0 || needed > 4096) { result.Failure = "setupapi-detail-unavailable"; return; }
                var id = new StringBuilder(512);
                if (!SetupDiGetDeviceInstanceId(list, ref dev, id, (uint)id.Capacity, out needed) || id.Length == 0 || id.Length > 511) {
                    result.Failure = "instance-id-unavailable"; return;
                }
                result.InstanceId = id.ToString();
                if (!result.InstanceId.StartsWith("PCI\\VEN_1002&", StringComparison.OrdinalIgnoreCase)) {
                    result.Failure = "pnp-instance-not-amd-pci"; return;
                }
                result.DriverVersion = BoundedProperty(list, ref dev, 3);
                result.DriverInfPath = BoundedProperty(list, ref dev, 5);
                result.DriverProvider = BoundedProperty(list, ref dev, 9);
                if (result.DriverVersion == null || result.DriverInfPath == null || result.DriverProvider == null)
                    result.Failure = "driver-properties-unavailable";
            } finally { SetupDiDestroyDeviceInfoList(list); }
        }
        public static Result Probe(string expectedBdf) {
            if (IntPtr.Size != 8 || Environment.OSVersion.Platform != PlatformID.Win32NT) throw new InvalidOperationException("windows-x64-required");
            if (!System.Text.RegularExpressions.Regex.IsMatch(expectedBdf ?? "", @"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$")) throw new InvalidOperationException("invalid-bdf");
            var result = new Result { Bdf = expectedBdf, Failure = "no-unique-vulkan-bdf" };
            var system = new StringBuilder(32768);
            uint systemLength = GetSystemDirectoryW(system, (uint)system.Capacity);
            if (systemLength == 0 || systemLength >= system.Capacity) throw new InvalidOperationException("system32-unavailable");
            string loaderPath = Path.Combine(system.ToString(), "vulkan-1.dll");
            if (!File.Exists(loaderPath)) throw new InvalidOperationException("system32-vulkan-loader-missing");
            IntPtr loader = LoadLibraryExW(loaderPath, IntPtr.Zero, 0x800); // LOAD_LIBRARY_SEARCH_SYSTEM32
            if (loader == IntPtr.Zero) throw new InvalidOperationException("system32-vulkan-loader-unavailable");
            try {
                var loaded = new StringBuilder(32768);
                uint loadedLength = GetModuleFileNameW(loader, loaded, (uint)loaded.Capacity);
                if (loadedLength == 0 || loadedLength >= loaded.Capacity ||
                    !String.Equals(Path.GetFullPath(loaded.ToString()), Path.GetFullPath(loaderPath), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("vulkan-loader-provenance-mismatch");
                IntPtr addr = GetProcAddress(loader, "vkGetInstanceProcAddr");
                if (addr == IntPtr.Zero) throw new InvalidOperationException("vulkan-entrypoint-missing");
                var get = (GetInstanceProcAddr)Marshal.GetDelegateForFunctionPointer(addr, typeof(GetInstanceProcAddr));
                var create = Function<CreateInstance>(get, IntPtr.Zero, "vkCreateInstance");
                var app = new AppInfo { sType = 0, apiVersion = 0x00401000 }; // Vulkan 1.1
                IntPtr appMem = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AppInfo)));
                IntPtr instance = IntPtr.Zero;
                try {
                    Marshal.StructureToPtr(app, appMem, false);
                    var info = new InstanceInfo { sType = 1, pApplicationInfo = appMem };
                    if (create(ref info, IntPtr.Zero, out instance) != 0 || instance == IntPtr.Zero)
                        throw new InvalidOperationException("vulkan-1.1-instance-unavailable");
                    var destroy = Function<DestroyInstance>(get, instance, "vkDestroyInstance");
                    try {
                        var enumerate = Function<EnumeratePhysicalDevices>(get, instance, "vkEnumeratePhysicalDevices");
                        var extensions = Function<EnumerateDeviceExtensions>(get, instance, "vkEnumerateDeviceExtensionProperties");
                        var properties2 = Function<GetPhysicalDeviceProperties2>(get, instance, "vkGetPhysicalDeviceProperties2");
                        uint count = 0;
                        if (enumerate(instance, ref count, IntPtr.Zero) != 0 || count == 0 || count > 16)
                            throw new InvalidOperationException("vulkan-device-count-unavailable");
                        IntPtr devices = Marshal.AllocHGlobal((int)count * IntPtr.Size);
                        try {
                            uint actual = count;
                            if (enumerate(instance, ref actual, devices) != 0 || actual != count)
                                throw new InvalidOperationException("vulkan-device-list-changed");
                            int matches = 0;
                            byte[] matchLuid = null;
                            uint matchNode = 0;
                            var allValidLuids = new List<string>();
                            for (int i = 0; i < count; i++) {
                                IntPtr dev = Marshal.ReadIntPtr(devices, i * IntPtr.Size);
                                bool hasPci = HasPciExtension(extensions, dev);
                                IntPtr props = Marshal.AllocHGlobal(4096); // opaque VkPhysicalDeviceProperties2; larger than fixed Vulkan 1.1 struct
                                IntPtr id = Marshal.AllocHGlobal(64);
                                IntPtr pci = hasPci ? Marshal.AllocHGlobal(32) : IntPtr.Zero;
                                try {
                                    for (int k = 0; k < 4096; k += 4) Marshal.WriteInt32(props, k, 0);
                                    for (int k = 0; k < 64; k += 4) Marshal.WriteInt32(id, k, 0);
                                    if (hasPci) for (int k = 0; k < 32; k += 4) Marshal.WriteInt32(pci, k, 0);
                                    Marshal.WriteInt32(props, 0, 1000059001); // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
                                    Marshal.WriteIntPtr(props, 8, id);
                                    Marshal.WriteInt32(id, 0, 1000071004); // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES
                                    Marshal.WriteIntPtr(id, 8, pci);
                                    if (hasPci) Marshal.WriteInt32(pci, 0, 1000212000); // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PCI_BUS_INFO_PROPERTIES_EXT
                                    properties2(dev, props);
                                    bool luidValid = Marshal.ReadInt32(id, 60) != 0;
                                    byte[] observedLuid = new byte[8]; Marshal.Copy(IntPtr.Add(id, 48), observedLuid, 0, 8);
                                    if (luidValid) allValidLuids.Add(FormatLuid(observedLuid));
                                    if (!hasPci) continue;
                                    uint domain = (uint)Marshal.ReadInt32(pci, 16), bus = (uint)Marshal.ReadInt32(pci, 20);
                                    uint slot = (uint)Marshal.ReadInt32(pci, 24), function = (uint)Marshal.ReadInt32(pci, 28);
                                    if (domain > 65535 || bus > 255 || slot > 31 || function > 7) continue;
                                    string bdf = String.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:x4}:{1:x2}:{2:x2}.{3:x1}", domain, bus, slot, function);
                                    if (bdf != expectedBdf) continue;
                                    matches++;
                                    if (!luidValid) { result.Failure = "vulkan-luid-invalid"; continue; }
                                    uint nodeMask = (uint)Marshal.ReadInt32(id, 56);
                                    if (nodeMask == 0 || (nodeMask & (nodeMask - 1)) != 0) { result.Failure = "vulkan-node-mask-invalid"; continue; }
                                    matchLuid = observedLuid;
                                    matchNode = nodeMask;
                                } finally { if (pci != IntPtr.Zero) Marshal.FreeHGlobal(pci); Marshal.FreeHGlobal(id); Marshal.FreeHGlobal(props); }
                            }
                            if (matches != 1) { result.Failure = matches == 0 ? "no-unique-vulkan-bdf" : "ambiguous-vulkan-bdf"; return result; }
                            if (matchLuid == null) return result;
                            if (matchNode != 1 || allValidLuids.FindAll(x => x == FormatLuid(matchLuid)).Count != 1) {
                                result.Failure = "linked-adapter-luid-unresolved"; return result;
                            }
                            result.Luid = FormatLuid(matchLuid);
                            result.NodeMask = matchNode;
                            result.Failure = null;
                            BindDevice(ref result, matchLuid);
                            return result;
                        } finally { Marshal.FreeHGlobal(devices); }
                    } finally { destroy(instance, IntPtr.Zero); }
                } finally { Marshal.FreeHGlobal(appMem); }
            } finally { FreeLibrary(loader); }
        }
        private static bool HasPciExtension(EnumerateDeviceExtensions enumerate, IntPtr device) {
            uint count = 0;
            if (enumerate(device, IntPtr.Zero, ref count, IntPtr.Zero) != 0 || count == 0 || count > 1024) return false;
            IntPtr data = Marshal.AllocHGlobal((int)count * 260); // VkExtensionProperties: char[256] + uint32
            try {
                uint actual = count;
                if (enumerate(device, IntPtr.Zero, ref actual, data) != 0 || actual != count) return false;
                for (int i = 0; i < count; i++) {
                    byte[] name = new byte[256];
                    Marshal.Copy(IntPtr.Add(data, i * 260), name, 0, name.Length);
                    int end = Array.IndexOf(name, (byte)0);
                    if (end >= 0 && Encoding.ASCII.GetString(name, 0, end) == "VK_EXT_pci_bus_info") return true;
                }
                return false;
            } finally { Marshal.FreeHGlobal(data); }
        }
    }
}
