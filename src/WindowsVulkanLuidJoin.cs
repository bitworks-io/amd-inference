// Read-only Windows probe: raw Vulkan physical-device observations (in vkEnumeratePhysicalDevices order),
// DXGI adapters (IDXGIFactory1::EnumAdapters1) and SetupAPI display-class devices. It performs NO joining
// and NO guessing; tools/collect-vulkan-luid-join.ps1 joins the three observation sets by exact keys.
// It only observes: no logical device is ever created, no process is started, no environment variable is set.
// ABI sources:
// https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceIDProperties.html
// https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceDriverProperties.html
// https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDevicePCIBusInfoPropertiesEXT.html
// https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceProperties.html
// https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/shared/dxgi.h
//   dxgi.h: IDXGIObject l.321, IDXGIAdapter l.1353, IDXGIFactory l.2159, CreateDXGIFactory1 l.2360,
//   DXGI_ADAPTER_DESC1 l.2590, DXGI_ADAPTER_FLAG_* l.2585, IDXGIFactory1 l.2627, IDXGIAdapter1 l.2830.
//   dxgi1_4.h: DXGI_MEMORY_SEGMENT_GROUP l.1321-1325, DXGI_QUERY_VIDEO_MEMORY_INFO l.1327-1333, IDXGIAdapter3 l.1351
//   (QueryVideoMemoryInfo l.1365); dxgi1_2.h: IDXGIAdapter2 l.2176.
// https://raw.githubusercontent.com/KhronosGroup/Vulkan-Headers/main/include/vulkan/vulkan_core.h
//   vulkan_core.h: VK_MAX_MEMORY_TYPES l.122, VK_MAX_MEMORY_HEAPS l.127, VkMemoryHeap l.3504, VkMemoryType l.3509,
//   VkPhysicalDeviceMemoryProperties l.3681, VkPhysicalDeviceMemoryProperties2 l.5700,
//   VkPhysicalDeviceMemoryBudgetPropertiesEXT l.19129, VK_MEMORY_HEAP_DEVICE_LOCAL_BIT l.2838.
// https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/shared/devpkey.h
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Bitworks.FastLlm {
    public sealed class VulkanLuidDeviceRecord {
        public int Index { get; set; }                       // raw vkEnumeratePhysicalDevices index
        public string DeviceUuid { get; set; }
        public string DriverUuid { get; set; }
        public string DeviceLuid { get; set; }               // 16 hex digits (high then low), null when not valid
        public bool DeviceLuidValid { get; set; }
        public uint DeviceNodeMask { get; set; }
        public uint VendorId { get; set; }
        public uint DeviceId { get; set; }
        public string DeviceName { get; set; }
        public uint DriverVersionRaw { get; set; }           // vendor-specific encoding; never decoded here
        public uint ApiVersionRaw { get; set; }
        public string ApiVersion { get; set; }
        public int DeviceType { get; set; }
        public string DeviceTypeName { get; set; }
        public bool DriverPropertiesAdvertised { get; set; } // VK_KHR_driver_properties
        public int? DriverId { get; set; }
        public string DriverName { get; set; }
        public string DriverInfo { get; set; }
        public bool PciBusInfoAdvertised { get; set; }       // VK_EXT_pci_bus_info
        public uint? PciDomain { get; set; }
        public uint? PciBus { get; set; }
        public uint? PciDevice { get; set; }
        public uint? PciFunction { get; set; }
        public string ExtensionError { get; set; }
        // VkPhysicalDevice16BitStorageFeatures.storageBuffer16BitAccess (ggml's device support check), read with
        // vkGetPhysicalDeviceFeatures2. Null when it could not be read; StorageBuffer16BitAccessReason then holds a fixed token.
        public bool? StorageBuffer16BitAccess { get; set; }
        public string StorageBuffer16BitAccessReason { get; set; }
    }

    public sealed class DxgiAdapterRecord {
        public int Index { get; set; }
        public string Description { get; set; }
        public uint VendorId { get; set; }
        public uint DeviceId { get; set; }
        public uint SubSysId { get; set; }
        public uint Revision { get; set; }
        public ulong DedicatedVideoMemory { get; set; }
        public string AdapterLuid { get; set; }              // 16 hex digits (high then low)
        public uint Flags { get; set; }
    }

    public sealed class SetupApiDisplayRecord {
        public string InstanceId { get; set; }
        public string Description { get; set; }
        public string LocationInfo { get; set; }
        public string LocationError { get; set; }
        public string[] HardwareIds { get; set; }
        public string HardwareIdsError { get; set; }
        public string DriverVersion { get; set; }
        public string DriverVersionError { get; set; }
        public string DriverProvider { get; set; }
    }

    public sealed class VulkanLuidJoinSnapshot {
        public List<VulkanLuidDeviceRecord> Vulkan = new List<VulkanLuidDeviceRecord>();
        public List<DxgiAdapterRecord> Dxgi = new List<DxgiAdapterRecord>();
        public List<SetupApiDisplayRecord> SetupApi = new List<SetupApiDisplayRecord>();
        public string VulkanError, DxgiError, SetupApiError;
        public string VulkanLoaderPath;
        public int DefaultSelectionDedicatedGpuCount;        // deviceType discrete or integrated; informational
    }


    public sealed class DxgiMemorySegmentRecord {
        public string Group { get; set; }                    // LOCAL (0) or NON_LOCAL (1), node 0
        public string Status { get; set; }                   // ok | query-failed
        public string Hresult { get; set; }
        public ulong Budget { get; set; }
        public ulong CurrentUsage { get; set; }
        public ulong AvailableForReservation { get; set; }
        public ulong CurrentReservation { get; set; }
    }

    public sealed class DxgiBudgetRecord {
        public int AdapterIndex { get; set; }
        public string AdapterLuid { get; set; }
        public string TimestampUtc { get; set; }
        public string Adapter3Status { get; set; }           // ok | adapter3-unavailable | desc-unavailable
        public string Adapter3Hresult { get; set; }
        public DxgiMemorySegmentRecord Local { get; set; }
        public DxgiMemorySegmentRecord NonLocal { get; set; }
    }

    public sealed class VulkanHeapBudgetRecord {
        public int HeapIndex { get; set; }
        public ulong Size { get; set; }
        public uint Flags { get; set; }
        public bool DeviceLocal { get; set; }
        public ulong HeapBudget { get; set; }
        public ulong HeapUsage { get; set; }
    }

    public sealed class VulkanBudgetRecord {
        public int Index { get; set; }
        public string DeviceUuid { get; set; }
        public string DeviceLuid { get; set; }
        public string TimestampUtc { get; set; }
        public bool MemoryBudgetAdvertised { get; set; }     // VK_EXT_memory_budget
        public string Status { get; set; }                   // ok | memory-budget-not-advertised | extension-enumeration-failed
        public List<VulkanHeapBudgetRecord> Heaps = new List<VulkanHeapBudgetRecord>();
    }

    public sealed class VulkanBudgetSample {
        public string TimestampUtc { get; set; }
        public List<DxgiBudgetRecord> Dxgi = new List<DxgiBudgetRecord>();
        public List<VulkanBudgetRecord> Vulkan = new List<VulkanBudgetRecord>();
        public string DxgiError, VulkanError;
    }

    public static class WindowsVulkanLuidJoin {
        private const int MAX_VULKAN_DEVICES = 64;
        private const int MAX_DXGI_ADAPTERS = 64;
        private const int MAX_SETUPAPI_DEVICES = 128;
        private const int MAX_PROPERTY_BYTES = 16384;
        private const uint LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x800;
        private const int DXGI_ERROR_NOT_FOUND = unchecked((int)0x887A0002);

        [StructLayout(LayoutKind.Sequential)] private struct AppInfo {
            public int sType; public IntPtr pNext; public IntPtr pApplicationName;
            public uint applicationVersion; public IntPtr pEngineName; public uint engineVersion; public uint apiVersion;
        }
        [StructLayout(LayoutKind.Sequential)] private struct InstanceInfo {
            public int sType; public IntPtr pNext; public uint flags; public IntPtr pApplicationInfo;
            public uint enabledLayerCount; public IntPtr ppEnabledLayerNames;
            public uint enabledExtensionCount; public IntPtr ppEnabledExtensionNames;
        }
        [StructLayout(LayoutKind.Sequential)] private struct DeviceInfoData {
            public uint Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] private struct PropertyKey {
            public Guid FormatId; public uint PropertyId;
            public PropertyKey(string formatId, uint propertyId) { FormatId = new Guid(formatId); PropertyId = propertyId; }
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate IntPtr GetInstanceProcAddr(IntPtr instance, [MarshalAs(UnmanagedType.LPStr)] string name);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int CreateInstance(ref InstanceInfo info, IntPtr allocator, out IntPtr instance);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void DestroyInstance(IntPtr instance, IntPtr allocator);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int EnumeratePhysicalDevices(IntPtr instance, ref uint count, IntPtr devices);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate int EnumerateDeviceExtensions(IntPtr physicalDevice, IntPtr layerName, ref uint count, IntPtr properties);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void GetPhysicalDeviceProperties2(IntPtr physicalDevice, IntPtr properties);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void GetPhysicalDeviceFeatures2(IntPtr physicalDevice, IntPtr features);
        // COM vtable calls: CallingConvention.StdCall == WINAPI on x64.
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate uint ComRelease(IntPtr self);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ComEnumAdapters1(IntPtr self, uint index, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ComGetDesc1(IntPtr self, IntPtr desc);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ComQueryInterface(IntPtr self, ref Guid iid, out IntPtr obj);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int ComQueryVideoMemoryInfo(IntPtr self, uint node, int group, IntPtr info);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] private delegate void GetPhysicalDeviceMemoryProperties2(IntPtr physicalDevice, IntPtr properties);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetSystemDirectoryW(StringBuilder buffer, uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr LoadLibraryExW(string name, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)] private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern uint GetModuleFileNameW(IntPtr module, StringBuilder buffer, uint size);
        [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("dxgi.dll", EntryPoint="CreateDXGIFactory1", ExactSpelling=true)]
        private static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);

        private const uint DIGCF_PRESENT = 0x2;
        private const int ERROR_NO_MORE_ITEMS = 259;
        private const int ERROR_NOT_FOUND = 1168;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const uint DEVPROP_TYPE_STRING = 0x12;
        private const uint DEVPROP_TYPE_STRING_LIST = 0x2012;
        private static readonly Guid DisplayClass = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");
        private static readonly PropertyKey DeviceDescription = new PropertyKey("a45c254e-df1c-4efd-8020-67d146a850e0", 2);
        private static readonly PropertyKey DeviceHardwareIds = new PropertyKey("a45c254e-df1c-4efd-8020-67d146a850e0", 3);
        private static readonly PropertyKey DeviceLocationInfo = new PropertyKey("a45c254e-df1c-4efd-8020-67d146a850e0", 15);
        private static readonly PropertyKey DeviceDriverVersion = new PropertyKey("a8b865dd-2e3d-4094-ad97-e593a70c75d6", 3);
        private static readonly PropertyKey DeviceDriverProvider = new PropertyKey("a8b865dd-2e3d-4094-ad97-e593a70c75d6", 9);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiGetClassDevsW", SetLastError=true)]
        private static extern IntPtr GetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr parent, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiEnumDeviceInfo", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDeviceInfo(IntPtr set, uint index, ref DeviceInfoData data);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiGetDeviceInstanceIdW", SetLastError=true, CharSet=CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetDeviceInstanceId(IntPtr set, ref DeviceInfoData data, StringBuilder output, uint size, out uint needed);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiGetDevicePropertyW", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetDeviceProperty(IntPtr set, ref DeviceInfoData data, ref PropertyKey key, out uint propertyType,
            [Out] byte[] output, uint size, out uint needed, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll", EntryPoint="SetupDiDestroyDeviceInfoList", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyDeviceInfoList(IntPtr set);

        public static string FormatLuid(byte[] bytes) {
            if (bytes == null || bytes.Length != 8) throw new ArgumentException("LUID must have exactly eight bytes.", "bytes");
            // LUID memory layout is LowPart (little-endian) then HighPart; WindowsPciAddress expects high then low.
            return BitConverter.ToUInt32(bytes, 4).ToString("x8", CultureInfo.InvariantCulture) +
                   BitConverter.ToUInt32(bytes, 0).ToString("x8", CultureInfo.InvariantCulture);
        }

        public static string FormatUuid(byte[] bytes) {
            if (bytes == null || bytes.Length != 16) throw new ArgumentException("UUID must have exactly sixteen bytes.", "bytes");
            var sb = new StringBuilder(36);
            for (int i = 0; i < 16; i++) {
                if (i == 4 || i == 6 || i == 8 || i == 10) sb.Append('-');
                sb.Append(bytes[i].ToString("x2", CultureInfo.InvariantCulture));
            }
            return sb.ToString();
        }

        public static string DeviceTypeName(int type) {
            switch (type) {
                case 0: return "other";
                case 1: return "integrated";
                case 2: return "discrete";
                case 3: return "virtual";
                case 4: return "cpu";
                default: return "unknown";
            }
        }

        public static string FormatApiVersion(uint v) {
            return String.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}", (v >> 22) & 0x7f, (v >> 12) & 0x3ff, v & 0xfff);
        }

        public static VulkanLuidJoinSnapshot Collect() {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("Vulkan/DXGI/SetupAPI identity probe requires 64-bit Windows.");
            var snapshot = new VulkanLuidJoinSnapshot();
            try { CollectVulkan(snapshot); } catch (Exception e) { snapshot.VulkanError = Describe(e); }
            try { CollectDxgi(snapshot); } catch (Exception e) { snapshot.DxgiError = Describe(e); }
            try { CollectSetupApi(snapshot); } catch (Exception e) { snapshot.SetupApiError = Describe(e); }
            return snapshot;
        }

        private static string Describe(Exception e) {
            // Reasons only; no stack traces or paths beyond the message text.
            string message = e.Message ?? "";
            if (message.Length > 200) message = message.Substring(0, 200);
            return e.GetType().Name + ":" + message;
        }

        private static T Function<T>(GetInstanceProcAddr get, IntPtr instance, string name) where T : class {
            IntPtr p = get(instance, name);
            if (p == IntPtr.Zero) throw new InvalidOperationException("vulkan-entrypoint-missing:" + name);
            return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
        }

        // Like Function<T> but returns null instead of throwing, so an optional entry point can never fail the enumeration.
        private static T TryFunction<T>(GetInstanceProcAddr get, IntPtr instance, string name) where T : class {
            IntPtr p = get(instance, name);
            if (p == IntPtr.Zero) return null;
            return (T)(object)Marshal.GetDelegateForFunctionPointer(p, typeof(T));
        }

        // Why storageBuffer16BitAccess cannot be read, or null when the query may run. The instance is created for Vulkan 1.1 with no
        // extensions, so the core vkGetPhysicalDeviceFeatures2 (device apiVersion 1.1 or later) is the only route; the
        // VK_KHR_get_physical_device_properties2 alias is not available here.
        public static string StorageBuffer16BitUnavailableReason(bool entryPointResolved, uint deviceApiVersionRaw) {
            if (deviceApiVersionRaw < 0x00401000u) return "vulkan-1.1-unavailable";
            if (!entryPointResolved) return "features2-entrypoint-unavailable";
            return null;
        }

        private static void ReadStorageBuffer16BitAccess(GetPhysicalDeviceFeatures2 features2, IntPtr dev, VulkanLuidDeviceRecord record) {
            record.StorageBuffer16BitAccess = null;
            record.StorageBuffer16BitAccessReason = StorageBuffer16BitUnavailableReason(features2 != null, record.ApiVersionRaw);
            if (record.StorageBuffer16BitAccessReason != null) return;
            // Nothing in here may escape: a failure must not turn into a Vulkan enumeration error for the whole snapshot.
            IntPtr features = IntPtr.Zero, storage16 = IntPtr.Zero;
            try {
                features = Marshal.AllocHGlobal(512);  // VkPhysicalDeviceFeatures2: sType, pNext, 55 VkBool32 (236 bytes) with headroom
                storage16 = Marshal.AllocHGlobal(32);  // VkPhysicalDevice16BitStorageFeatures: sType, pNext, four VkBool32 (32 bytes)
                Zero(features, 512); Zero(storage16, 32);
                Marshal.WriteInt32(features, 0, 1000059000);   // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2
                Marshal.WriteInt32(storage16, 0, 1000083000);  // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES
                Marshal.WriteIntPtr(features, 8, storage16);
                features2(dev, features);
                record.StorageBuffer16BitAccess = Marshal.ReadInt32(storage16, 16) != 0;   // storageBuffer16BitAccess
            } catch (Exception) {
                record.StorageBuffer16BitAccess = null;
                record.StorageBuffer16BitAccessReason = "features-query-failed";
            } finally {
                if (storage16 != IntPtr.Zero) Marshal.FreeHGlobal(storage16);
                if (features != IntPtr.Zero) Marshal.FreeHGlobal(features);
            }
        }

        private static void Zero(IntPtr p, int bytes) { for (int k = 0; k < bytes; k += 4) Marshal.WriteInt32(p, k, 0); }

        private static string AsciiZ(IntPtr p, int offset, int max) {
            byte[] raw = new byte[max];
            Marshal.Copy(IntPtr.Add(p, offset), raw, 0, max);
            int end = Array.IndexOf(raw, (byte)0);
            if (end < 0) end = max;
            return Encoding.UTF8.GetString(raw, 0, end);
        }

        private delegate void VulkanBody(GetInstanceProcAddr get, IntPtr instance, IntPtr devices, int count);

        // Loads the System32 loader, creates a Vulkan 1.1 instance (no layers, no extensions), runs the body over the
        // enumerated physical devices and always destroys the instance and frees the loader before returning.
        private static void RunVulkan(string[] loaderPathOut, VulkanBody body) {
            var system = new StringBuilder(32768);
            uint systemLength = GetSystemDirectoryW(system, (uint)system.Capacity);
            if (systemLength == 0 || systemLength >= system.Capacity) throw new InvalidOperationException("system32-unavailable");
            string loaderPath = Path.Combine(system.ToString(), "vulkan-1.dll");
            if (!File.Exists(loaderPath)) throw new InvalidOperationException("system32-vulkan-loader-missing");
            // Only the System32 copy of the loader is ever loaded.
            IntPtr loader = LoadLibraryExW(loaderPath, IntPtr.Zero, LOAD_LIBRARY_SEARCH_SYSTEM32);
            if (loader == IntPtr.Zero) throw new InvalidOperationException("system32-vulkan-loader-unavailable");
            try {
                var loaded = new StringBuilder(32768);
                uint loadedLength = GetModuleFileNameW(loader, loaded, (uint)loaded.Capacity);
                if (loadedLength == 0 || loadedLength >= loaded.Capacity ||
                    !String.Equals(Path.GetFullPath(loaded.ToString()), Path.GetFullPath(loaderPath), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("vulkan-loader-provenance-mismatch");
                loaderPathOut[0] = loaded.ToString();
                IntPtr addr = GetProcAddress(loader, "vkGetInstanceProcAddr");
                if (addr == IntPtr.Zero) throw new InvalidOperationException("vulkan-entrypoint-missing:vkGetInstanceProcAddr");
                var get = (GetInstanceProcAddr)Marshal.GetDelegateForFunctionPointer(addr, typeof(GetInstanceProcAddr));
                var create = Function<CreateInstance>(get, IntPtr.Zero, "vkCreateInstance");
                var app = new AppInfo { sType = 0, apiVersion = 0x00401000 }; // Vulkan 1.1; no layers, no extensions
                IntPtr appMem = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AppInfo)));
                IntPtr instance = IntPtr.Zero;
                try {
                    Marshal.StructureToPtr(app, appMem, false);
                    var info = new InstanceInfo { sType = 1, pApplicationInfo = appMem };
                    int created = create(ref info, IntPtr.Zero, out instance);
                    if (created != 0 || instance == IntPtr.Zero)
                        throw new InvalidOperationException("vulkan-1.1-instance-unavailable-vkresult-" + created.ToString(CultureInfo.InvariantCulture));
                    var destroy = Function<DestroyInstance>(get, instance, "vkDestroyInstance");
                    try {
                        var enumerate = Function<EnumeratePhysicalDevices>(get, instance, "vkEnumeratePhysicalDevices");
                        uint count = 0;
                        int rc = enumerate(instance, ref count, IntPtr.Zero);
                        if (rc != 0) throw new InvalidOperationException("vulkan-device-count-unavailable-vkresult-" + rc.ToString(CultureInfo.InvariantCulture));
                        if (count == 0) return;
                        if (count > MAX_VULKAN_DEVICES) throw new InvalidOperationException("vulkan-device-count-over-limit");
                        IntPtr devices = Marshal.AllocHGlobal((int)count * IntPtr.Size);
                        try {
                            uint actual = count;
                            if (enumerate(instance, ref actual, devices) != 0 || actual != count)
                                throw new InvalidOperationException("vulkan-device-list-changed");
                            body(get, instance, devices, (int)count);
                        } finally { Marshal.FreeHGlobal(devices); }
                    } finally { destroy(instance, IntPtr.Zero); }
                } finally { Marshal.FreeHGlobal(appMem); }
            } finally { FreeLibrary(loader); }
        }

        private static void CollectVulkan(VulkanLuidJoinSnapshot snapshot) {
            string[] loaderOut = new string[1];
            try {
                RunVulkan(loaderOut, delegate(GetInstanceProcAddr get, IntPtr instance, IntPtr devices, int count) {
                    var extensions = Function<EnumerateDeviceExtensions>(get, instance, "vkEnumerateDeviceExtensionProperties");
                    var properties2 = Function<GetPhysicalDeviceProperties2>(get, instance, "vkGetPhysicalDeviceProperties2");
                    GetPhysicalDeviceFeatures2 features2 = null;
                    try { features2 = TryFunction<GetPhysicalDeviceFeatures2>(get, instance, "vkGetPhysicalDeviceFeatures2"); } catch (Exception) { features2 = null; }
                    for (int i = 0; i < count; i++) {
                        IntPtr dev = Marshal.ReadIntPtr(devices, i * IntPtr.Size);
                        snapshot.Vulkan.Add(ReadDevice(i, dev, extensions, properties2, features2));
                    }
                });
            } finally { snapshot.VulkanLoaderPath = loaderOut[0]; }
            int dedicated = 0;
            foreach (var d in snapshot.Vulkan) if (d.DeviceType == 1 || d.DeviceType == 2) dedicated++;
            snapshot.DefaultSelectionDedicatedGpuCount = dedicated;
        }

        private static VulkanLuidDeviceRecord ReadDevice(int index, IntPtr dev, EnumerateDeviceExtensions enumerate, GetPhysicalDeviceProperties2 properties2, GetPhysicalDeviceFeatures2 features2) {
            var record = new VulkanLuidDeviceRecord { Index = index };
            bool hasPci = false, hasDriver = false;
            ReadExtensions(enumerate, dev, record, out hasPci, out hasDriver);
            record.PciBusInfoAdvertised = hasPci;
            record.DriverPropertiesAdvertised = hasDriver;
            IntPtr props = Marshal.AllocHGlobal(4096); // VkPhysicalDeviceProperties2 (840 bytes) with headroom
            IntPtr id = Marshal.AllocHGlobal(64);      // VkPhysicalDeviceIDProperties (64 bytes)
            IntPtr drv = hasDriver ? Marshal.AllocHGlobal(560) : IntPtr.Zero; // VkPhysicalDeviceDriverProperties (536 bytes)
            IntPtr pci = hasPci ? Marshal.AllocHGlobal(32) : IntPtr.Zero;     // VkPhysicalDevicePCIBusInfoPropertiesEXT (32 bytes)
            try {
                Zero(props, 4096); Zero(id, 64);
                if (hasDriver) Zero(drv, 560);
                if (hasPci) Zero(pci, 32);
                Marshal.WriteInt32(props, 0, 1000059001);  // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
                Marshal.WriteInt32(id, 0, 1000071004);     // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES
                // pNext chain: props2 -> id -> [driver] -> [pci]. Only advertised structures are chained.
                IntPtr tail = id;
                Marshal.WriteIntPtr(props, 8, id);
                if (hasDriver) {
                    Marshal.WriteInt32(drv, 0, 1000196000); // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES
                    Marshal.WriteIntPtr(tail, 8, drv); tail = drv;
                }
                if (hasPci) {
                    Marshal.WriteInt32(pci, 0, 1000212000); // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PCI_BUS_INFO_PROPERTIES_EXT
                    Marshal.WriteIntPtr(tail, 8, pci); tail = pci;
                }
                properties2(dev, props);
                // VkPhysicalDeviceProperties begins at offset 16 of VkPhysicalDeviceProperties2.
                record.ApiVersionRaw = (uint)Marshal.ReadInt32(props, 16);
                record.ApiVersion = FormatApiVersion(record.ApiVersionRaw);
                record.DriverVersionRaw = (uint)Marshal.ReadInt32(props, 20);
                record.VendorId = (uint)Marshal.ReadInt32(props, 24);
                record.DeviceId = (uint)Marshal.ReadInt32(props, 28);
                record.DeviceType = Marshal.ReadInt32(props, 32);
                record.DeviceTypeName = DeviceTypeName(record.DeviceType);
                record.DeviceName = AsciiZ(props, 36, 256);
                byte[] uuid = new byte[16]; Marshal.Copy(IntPtr.Add(id, 16), uuid, 0, 16); record.DeviceUuid = FormatUuid(uuid);
                byte[] drvUuid = new byte[16]; Marshal.Copy(IntPtr.Add(id, 32), drvUuid, 0, 16); record.DriverUuid = FormatUuid(drvUuid);
                byte[] luid = new byte[8]; Marshal.Copy(IntPtr.Add(id, 48), luid, 0, 8);
                record.DeviceNodeMask = (uint)Marshal.ReadInt32(id, 56);
                record.DeviceLuidValid = Marshal.ReadInt32(id, 60) != 0;
                record.DeviceLuid = record.DeviceLuidValid ? FormatLuid(luid) : null;
                if (hasDriver) {
                    record.DriverId = Marshal.ReadInt32(drv, 16);
                    record.DriverName = AsciiZ(drv, 20, 256);
                    record.DriverInfo = AsciiZ(drv, 276, 256);
                }
                if (hasPci) {
                    // Reported only because the device advertised VK_EXT_pci_bus_info.
                    record.PciDomain = (uint)Marshal.ReadInt32(pci, 16);
                    record.PciBus = (uint)Marshal.ReadInt32(pci, 20);
                    record.PciDevice = (uint)Marshal.ReadInt32(pci, 24);
                    record.PciFunction = (uint)Marshal.ReadInt32(pci, 28);
                }
            } finally {
                if (pci != IntPtr.Zero) Marshal.FreeHGlobal(pci);
                if (drv != IntPtr.Zero) Marshal.FreeHGlobal(drv);
                Marshal.FreeHGlobal(id); Marshal.FreeHGlobal(props);
            }
            ReadStorageBuffer16BitAccess(features2, dev, record);
            return record;
        }

        private static void ReadExtensions(EnumerateDeviceExtensions enumerate, IntPtr device, VulkanLuidDeviceRecord record, out bool hasPci, out bool hasDriver) {
            hasPci = false; hasDriver = false;
            uint count = 0;
            int rc = enumerate(device, IntPtr.Zero, ref count, IntPtr.Zero);
            if (rc != 0) { record.ExtensionError = "extension-count-vkresult-" + rc.ToString(CultureInfo.InvariantCulture); return; }
            if (count == 0) return;
            if (count > 1024) { record.ExtensionError = "extension-count-over-limit"; return; }
            IntPtr data = Marshal.AllocHGlobal((int)count * 260); // VkExtensionProperties: char[256] + uint32
            try {
                uint actual = count;
                rc = enumerate(device, IntPtr.Zero, ref actual, data);
                if (rc != 0 || actual != count) { record.ExtensionError = "extension-list-vkresult-" + rc.ToString(CultureInfo.InvariantCulture); return; }
                for (int i = 0; i < count; i++) {
                    string name = AsciiZ(data, i * 260, 256);
                    if (name == "VK_EXT_pci_bus_info") hasPci = true;
                    else if (name == "VK_KHR_driver_properties") hasDriver = true;
                }
            } finally { Marshal.FreeHGlobal(data); }
        }

        private static IntPtr VtableSlot(IntPtr com, int slot) {
            IntPtr vtbl = Marshal.ReadIntPtr(com);
            return Marshal.ReadIntPtr(vtbl, slot * IntPtr.Size);
        }

        private static void ReleaseCom(IntPtr com) {
            if (com == IntPtr.Zero) return;
            // IUnknown::Release is vtable slot 2.
            var release = (ComRelease)Marshal.GetDelegateForFunctionPointer(VtableSlot(com, 2), typeof(ComRelease));
            release(com);
        }

        private static void CollectDxgi(VulkanLuidJoinSnapshot snapshot) {
            // IID_IDXGIFactory1 = 770aae78-f26f-4dba-a829-253c83d1b387 (dxgi.h l.2627).
            Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            IntPtr factory;
            int hr = CreateDXGIFactory1(ref iid, out factory);
            if (hr != 0 || factory == IntPtr.Zero) throw new InvalidOperationException("create-dxgi-factory1-hresult-" + ((uint)hr).ToString("x8", CultureInfo.InvariantCulture));
            try {
                // Vtable: IUnknown 0-2, IDXGIObject 3-6, IDXGIFactory 7-11, IDXGIFactory1::EnumAdapters1 = 12.
                var enumAdapters1 = (ComEnumAdapters1)Marshal.GetDelegateForFunctionPointer(VtableSlot(factory, 12), typeof(ComEnumAdapters1));
                for (int index = 0; index < MAX_DXGI_ADAPTERS + 1; index++) {
                    IntPtr adapter;
                    hr = enumAdapters1(factory, (uint)index, out adapter);
                    if (hr == DXGI_ERROR_NOT_FOUND) return;
                    if (hr != 0 || adapter == IntPtr.Zero) throw new InvalidOperationException("enum-adapters1-hresult-" + ((uint)hr).ToString("x8", CultureInfo.InvariantCulture));
                    if (index >= MAX_DXGI_ADAPTERS) { ReleaseCom(adapter); throw new InvalidOperationException("dxgi-adapter-count-over-limit"); }
                    try {
                        // Vtable: IUnknown 0-2, IDXGIObject 3-6, IDXGIAdapter 7-9 (EnumOutputs, GetDesc, CheckInterfaceSupport), GetDesc1 = 10.
                        var getDesc1 = (ComGetDesc1)Marshal.GetDelegateForFunctionPointer(VtableSlot(adapter, 10), typeof(ComGetDesc1));
                        IntPtr desc = Marshal.AllocHGlobal(512);
                        try {
                            Zero(desc, 512);
                            hr = getDesc1(adapter, desc);
                            if (hr != 0) throw new InvalidOperationException("get-desc1-hresult-" + ((uint)hr).ToString("x8", CultureInfo.InvariantCulture));
                            // DXGI_ADAPTER_DESC1 x64 layout (dxgi.h l.2590): WCHAR[128]@0, VendorId@256, DeviceId@260,
                            // SubSysId@264, Revision@268, DedicatedVideoMemory@272, DedicatedSystemMemory@280,
                            // SharedSystemMemory@288, AdapterLuid{LowPart@296,HighPart@300}, Flags@304.
                            byte[] luid = new byte[8]; Marshal.Copy(IntPtr.Add(desc, 296), luid, 0, 8);
                            snapshot.Dxgi.Add(new DxgiAdapterRecord {
                                Index = index,
                                Description = Marshal.PtrToStringUni(desc, 128).Split('\0')[0],
                                VendorId = (uint)Marshal.ReadInt32(desc, 256),
                                DeviceId = (uint)Marshal.ReadInt32(desc, 260),
                                SubSysId = (uint)Marshal.ReadInt32(desc, 264),
                                Revision = (uint)Marshal.ReadInt32(desc, 268),
                                DedicatedVideoMemory = (ulong)Marshal.ReadInt64(desc, 272),
                                AdapterLuid = FormatLuid(luid),
                                Flags = (uint)Marshal.ReadInt32(desc, 304)
                            });
                        } finally { Marshal.FreeHGlobal(desc); }
                    } finally { ReleaseCom(adapter); }
                }
            } finally { ReleaseCom(factory); }
        }

        private static string ReadString(IntPtr set, ref DeviceInfoData data, PropertyKey key, out string error) {
            error = null;
            uint type, needed;
            byte[] bytes = new byte[MAX_PROPERTY_BYTES];
            if (!GetDeviceProperty(set, ref data, ref key, out type, bytes, (uint)bytes.Length, out needed, 0)) {
                int code = Marshal.GetLastWin32Error();
                if (code == ERROR_NOT_FOUND) { error = "property-unavailable"; return null; }
                if (code == ERROR_INSUFFICIENT_BUFFER) { error = "property-over-limit"; return null; }
                error = "win32-" + code; return null;
            }
            if (type != DEVPROP_TYPE_STRING || needed < 2 || needed > bytes.Length || (needed & 1) != 0) {
                error = "unexpected-property-type-or-length"; return null;
            }
            return Encoding.Unicode.GetString(bytes, 0, (int)needed).TrimEnd('\0');
        }

        private static string[] ReadStringList(IntPtr set, ref DeviceInfoData data, PropertyKey key, out string error) {
            error = null;
            uint type, needed;
            byte[] bytes = new byte[MAX_PROPERTY_BYTES];
            if (!GetDeviceProperty(set, ref data, ref key, out type, bytes, (uint)bytes.Length, out needed, 0)) {
                int code = Marshal.GetLastWin32Error();
                if (code == ERROR_NOT_FOUND) { error = "property-unavailable"; return null; }
                if (code == ERROR_INSUFFICIENT_BUFFER) { error = "property-over-limit"; return null; }
                error = "win32-" + code; return null;
            }
            if (type != DEVPROP_TYPE_STRING_LIST || needed < 2 || needed > bytes.Length || (needed & 1) != 0) {
                error = "unexpected-property-type-or-length"; return null;
            }
            string all = Encoding.Unicode.GetString(bytes, 0, (int)needed);
            var list = new List<string>();
            foreach (string part in all.Split('\0')) if (part.Length > 0) list.Add(part);
            return list.ToArray();
        }

        private static void CollectSetupApi(VulkanLuidJoinSnapshot snapshot) {
            Guid display = DisplayClass;
            IntPtr set = GetClassDevs(ref display, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Display-class enumeration failed.");
            try {
                for (uint index = 0; index < MAX_SETUPAPI_DEVICES; index++) {
                    var data = new DeviceInfoData { Size = (uint)Marshal.SizeOf(typeof(DeviceInfoData)) };
                    if (!EnumDeviceInfo(set, index, ref data)) {
                        int code = Marshal.GetLastWin32Error();
                        if (code == ERROR_NO_MORE_ITEMS) return;
                        throw new Win32Exception(code, "Display-class enumeration failed.");
                    }
                    var id = new StringBuilder(4096); uint needed;
                    if (!GetDeviceInstanceId(set, ref data, id, (uint)id.Capacity, out needed))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Display device instance ID unavailable.");
                    var record = new SetupApiDisplayRecord { InstanceId = id.ToString() };
                    string ignored, error;
                    record.Description = ReadString(set, ref data, DeviceDescription, out ignored);
                    record.LocationInfo = ReadString(set, ref data, DeviceLocationInfo, out error); record.LocationError = error;
                    record.HardwareIds = ReadStringList(set, ref data, DeviceHardwareIds, out error); record.HardwareIdsError = error;
                    record.DriverVersion = ReadString(set, ref data, DeviceDriverVersion, out error); record.DriverVersionError = error;
                    record.DriverProvider = ReadString(set, ref data, DeviceDriverProvider, out ignored);
                    snapshot.SetupApi.Add(record);
                }
                throw new InvalidOperationException("Display-class enumeration exceeded safety limit.");
            } finally { DestroyDeviceInfoList(set); }
        }

        private static string Now() { return DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture); }
        private static string HrText(int hr) { return ((uint)hr).ToString("x8", CultureInfo.InvariantCulture); }

        // Re-reads only memory budget numbers (no identity). Never creates a Vulkan logical device.
        // The values describe THIS probe process's usage and the OS budget available to it; they are not
        // per-process attribution of any other process and not proof of which allocations are resident.
        public static VulkanBudgetSample CollectBudgetSample() {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("Memory budget probe requires 64-bit Windows.");
            var sample = new VulkanBudgetSample { TimestampUtc = Now() };
            try { CollectVulkanBudgets(sample); } catch (Exception e) { sample.VulkanError = Describe(e); }
            try { CollectDxgiBudgets(sample); } catch (Exception e) { sample.DxgiError = Describe(e); }
            return sample;
        }

        private static bool HasExtension(EnumerateDeviceExtensions enumerate, IntPtr device, string wanted, out string error) {
            error = null;
            uint count = 0;
            int rc = enumerate(device, IntPtr.Zero, ref count, IntPtr.Zero);
            if (rc != 0) { error = "extension-count-vkresult-" + rc.ToString(CultureInfo.InvariantCulture); return false; }
            if (count == 0) return false;
            if (count > 1024) { error = "extension-count-over-limit"; return false; }
            IntPtr data = Marshal.AllocHGlobal((int)count * 260);
            try {
                uint actual = count;
                rc = enumerate(device, IntPtr.Zero, ref actual, data);
                if (rc != 0 || actual != count) { error = "extension-list-vkresult-" + rc.ToString(CultureInfo.InvariantCulture); return false; }
                for (int i = 0; i < count; i++) if (AsciiZ(data, i * 260, 256) == wanted) return true;
                return false;
            } finally { Marshal.FreeHGlobal(data); }
        }

        private static void CollectVulkanBudgets(VulkanBudgetSample sample) {
            string[] loaderOut = new string[1];
            RunVulkan(loaderOut, delegate(GetInstanceProcAddr get, IntPtr instance, IntPtr devices, int count) {
                var extensions = Function<EnumerateDeviceExtensions>(get, instance, "vkEnumerateDeviceExtensionProperties");
                var properties2 = Function<GetPhysicalDeviceProperties2>(get, instance, "vkGetPhysicalDeviceProperties2");
                var memory2 = Function<GetPhysicalDeviceMemoryProperties2>(get, instance, "vkGetPhysicalDeviceMemoryProperties2");
                for (int i = 0; i < count; i++) {
                    IntPtr dev = Marshal.ReadIntPtr(devices, i * IntPtr.Size);
                    var record = new VulkanBudgetRecord { Index = i, TimestampUtc = Now() };
                    sample.Vulkan.Add(record);
                    // Identity keys so the caller can confirm the enumeration order matches the identity snapshot.
                    IntPtr props = Marshal.AllocHGlobal(4096);
                    IntPtr id = Marshal.AllocHGlobal(64);
                    try {
                        Zero(props, 4096); Zero(id, 64);
                        Marshal.WriteInt32(props, 0, 1000059001);
                        Marshal.WriteInt32(id, 0, 1000071004);
                        Marshal.WriteIntPtr(props, 8, id);
                        properties2(dev, props);
                        byte[] uuid = new byte[16]; Marshal.Copy(IntPtr.Add(id, 16), uuid, 0, 16); record.DeviceUuid = FormatUuid(uuid);
                        byte[] luid = new byte[8]; Marshal.Copy(IntPtr.Add(id, 48), luid, 0, 8);
                        if (Marshal.ReadInt32(id, 60) != 0) record.DeviceLuid = FormatLuid(luid);
                    } finally { Marshal.FreeHGlobal(id); Marshal.FreeHGlobal(props); }
                    string error;
                    bool hasBudget = HasExtension(extensions, dev, "VK_EXT_memory_budget", out error);
                    record.MemoryBudgetAdvertised = hasBudget;
                    if (error != null) { record.Status = "extension-enumeration-failed"; continue; }
                    if (!hasBudget) { record.Status = "memory-budget-not-advertised"; continue; }
                    // VkPhysicalDeviceMemoryProperties2: sType@0 pNext@8 memoryProperties@16 (520 bytes):
                    //   memoryTypeCount@16, memoryTypes[32]{propertyFlags,heapIndex}@20, memoryHeapCount@276,
                    //   memoryHeaps[16]{VkDeviceSize size@+0, flags@+8, pad}@280 (16 bytes each).
                    // VkPhysicalDeviceMemoryBudgetPropertiesEXT: sType@0 pNext@8 heapBudget[16]@16 heapUsage[16]@144.
                    IntPtr mem = Marshal.AllocHGlobal(1024);
                    IntPtr budget = Marshal.AllocHGlobal(272);
                    try {
                        Zero(mem, 1024); Zero(budget, 272);
                        Marshal.WriteInt32(mem, 0, 1000059006);     // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_PROPERTIES_2
                        Marshal.WriteInt32(budget, 0, 1000237000);  // VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MEMORY_BUDGET_PROPERTIES_EXT
                        Marshal.WriteIntPtr(mem, 8, budget);
                        memory2(dev, mem);
                        uint heapCount = (uint)Marshal.ReadInt32(mem, 276);
                        if (heapCount > 16) { record.Status = "heap-count-over-limit"; continue; }
                        for (int h = 0; h < heapCount; h++) {
                            uint flags = (uint)Marshal.ReadInt32(mem, 280 + h * 16 + 8);
                            record.Heaps.Add(new VulkanHeapBudgetRecord {
                                HeapIndex = h,
                                Size = (ulong)Marshal.ReadInt64(mem, 280 + h * 16),
                                Flags = flags,
                                DeviceLocal = (flags & 1) != 0,
                                HeapBudget = (ulong)Marshal.ReadInt64(budget, 16 + h * 8),
                                HeapUsage = (ulong)Marshal.ReadInt64(budget, 144 + h * 8)
                            });
                        }
                        record.Status = "ok";
                    } finally { Marshal.FreeHGlobal(budget); Marshal.FreeHGlobal(mem); }
                }
            });
        }

        private static DxgiMemorySegmentRecord QuerySegment(IntPtr adapter3, int group, string name) {
            var query = (ComQueryVideoMemoryInfo)Marshal.GetDelegateForFunctionPointer(VtableSlot(adapter3, 14), typeof(ComQueryVideoMemoryInfo));
            IntPtr info = Marshal.AllocHGlobal(32); // DXGI_QUERY_VIDEO_MEMORY_INFO: four UINT64 (dxgi1_4.h l.1327)
            try {
                for (int k = 0; k < 32; k += 4) Marshal.WriteInt32(info, k, 0);
                int hr = query(adapter3, 0, group, info);
                if (hr != 0) return new DxgiMemorySegmentRecord { Group = name, Status = "query-failed", Hresult = HrText(hr) };
                return new DxgiMemorySegmentRecord {
                    Group = name, Status = "ok", Hresult = HrText(hr),
                    Budget = (ulong)Marshal.ReadInt64(info, 0), CurrentUsage = (ulong)Marshal.ReadInt64(info, 8),
                    AvailableForReservation = (ulong)Marshal.ReadInt64(info, 16), CurrentReservation = (ulong)Marshal.ReadInt64(info, 24)
                };
            } finally { Marshal.FreeHGlobal(info); }
        }

        private static void CollectDxgiBudgets(VulkanBudgetSample sample) {
            Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            IntPtr factory;
            int hr = CreateDXGIFactory1(ref iid, out factory);
            if (hr != 0 || factory == IntPtr.Zero) throw new InvalidOperationException("create-dxgi-factory1-hresult-" + HrText(hr));
            try {
                var enumAdapters1 = (ComEnumAdapters1)Marshal.GetDelegateForFunctionPointer(VtableSlot(factory, 12), typeof(ComEnumAdapters1));
                for (int index = 0; index < MAX_DXGI_ADAPTERS + 1; index++) {
                    IntPtr adapter;
                    hr = enumAdapters1(factory, (uint)index, out adapter);
                    if (hr == DXGI_ERROR_NOT_FOUND) return;
                    if (hr != 0 || adapter == IntPtr.Zero) throw new InvalidOperationException("enum-adapters1-hresult-" + HrText(hr));
                    if (index >= MAX_DXGI_ADAPTERS) { ReleaseCom(adapter); throw new InvalidOperationException("dxgi-adapter-count-over-limit"); }
                    var record = new DxgiBudgetRecord { AdapterIndex = index, TimestampUtc = Now() };
                    sample.Dxgi.Add(record);
                    IntPtr adapter3 = IntPtr.Zero;
                    try {
                        var getDesc1 = (ComGetDesc1)Marshal.GetDelegateForFunctionPointer(VtableSlot(adapter, 10), typeof(ComGetDesc1));
                        IntPtr desc = Marshal.AllocHGlobal(512);
                        try {
                            for (int k = 0; k < 512; k += 4) Marshal.WriteInt32(desc, k, 0);
                            int dhr = getDesc1(adapter, desc);
                            if (dhr != 0) { record.Adapter3Status = "desc-unavailable"; record.Adapter3Hresult = HrText(dhr); continue; }
                            byte[] luid = new byte[8]; Marshal.Copy(IntPtr.Add(desc, 296), luid, 0, 8);
                            record.AdapterLuid = FormatLuid(luid);
                        } finally { Marshal.FreeHGlobal(desc); }
                        // IID_IDXGIAdapter3 = 645967A4-1392-4310-A798-8053CE3E93FD (dxgi1_4.h l.1351).
                        // Vtable: IDXGIAdapter1 GetDesc1 = 10, IDXGIAdapter2 GetDesc2 = 11,
                        // IDXGIAdapter3: Register...TeardownStatusEvent 12, Unregister... 13, QueryVideoMemoryInfo 14.
                        Guid iid3 = new Guid("645967a4-1392-4310-a798-8053ce3e93fd");
                        var qi = (ComQueryInterface)Marshal.GetDelegateForFunctionPointer(VtableSlot(adapter, 0), typeof(ComQueryInterface));
                        int qhr = qi(adapter, ref iid3, out adapter3);
                        if (qhr != 0 || adapter3 == IntPtr.Zero) {
                            adapter3 = IntPtr.Zero;
                            record.Adapter3Status = "adapter3-unavailable"; record.Adapter3Hresult = HrText(qhr);
                            continue;
                        }
                        record.Adapter3Status = "ok"; record.Adapter3Hresult = HrText(qhr);
                        record.Local = QuerySegment(adapter3, 0, "LOCAL");
                        record.NonLocal = QuerySegment(adapter3, 1, "NON_LOCAL");
                    } finally { ReleaseCom(adapter3); ReleaseCom(adapter); }
                }
            } finally { ReleaseCom(factory); }
        }
    }
}
