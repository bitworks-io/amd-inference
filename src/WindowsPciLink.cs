using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace Bitworks.FastLlm {
    // Read-only PCIe link-state collector for present display devices and their
    // ancestors. Pure Configuration Manager / SetupAPI device properties: no CIM,
    // no WMI, no handles to the devices, no driver IOCTLs, no admin rights.
    //
    // Property keys (all in pciprop.h; GUID {3AB22E31-8264-4b4e-9AF5-A8D2D8E33E62}):
    //   DEVPKEY_PciDevice_DeviceType        pid 1   (UINT32; DevProp_PciDevice_DeviceType_* / _BridgeType_*)
    //   DEVPKEY_PciDevice_CurrentLinkSpeed  pid 9   (UINT32)
    //   DEVPKEY_PciDevice_CurrentLinkWidth  pid 10  (UINT32)
    //   DEVPKEY_PciDevice_MaxLinkSpeed      pid 11  (UINT32)
    //   DEVPKEY_PciDevice_MaxLinkWidth      pid 12  (UINT32)
    //   Header: https://github.com/tpn/winsdk-10/blob/master/Include/10.0.10240.0/shared/pciprop.h
    //   (Windows SDK shared/pciprop.h). Docs: https://learn.microsoft.com/en-us/windows-hardware/drivers/install/devpkey-pcidevice-currentlinkspeed
    //   (the learn.microsoft.com per-key pages were not reachable when authored; the SDK header is the primary source.)
    // devpkey.h, GUID {a45c254e-df1c-4efd-8020-67d146a850e0}:
    //   DEVPKEY_Device_HardwareIds   pid 3   (string list)
    //   DEVPKEY_Device_Class         pid 9   (string)
    //   DEVPKEY_Device_LocationInfo  pid 15  (string)
    //   DEVPKEY_Device_LocationPaths pid 37  (string list)
    // devpkey.h, GUID {4340a6c5-93fa-4706-972c-7b648008a5a7}:
    //   DEVPKEY_Device_Parent        pid 8   (string, parent instance ID)
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/install/devpkey-device-hardwareids
    // pciprop.h defines link-speed codes 1 (2.5 GT/s) and 2 (5 GT/s) only; 3..6 follow the PCIe
    // generation ordinal and must be validated natively. Raw values are always preserved.

    public sealed class PciLinkProperty {
        public uint? Raw { get; set; }
        public string Text { get; set; }
        public string[] List { get; set; }
        public string Decoded { get; set; }
        public int? Generation { get; set; }
        public string DecodeNote { get; set; }
        public string Error { get; set; }
        public int? ErrorCode { get; set; }
        public static PciLinkProperty Fail(string error, int? code) {
            return new PciLinkProperty { Error=error, ErrorCode=code };
        }
    }

    public sealed class PciLinkNode {
        public int Level { get; set; }
        public string InstanceId { get; set; }
        public string VendorId { get; set; }
        public PciLinkProperty Class { get; set; }
        public PciLinkProperty DeviceType { get; set; }
        public PciLinkProperty LocationInfo { get; set; }
        public PciLinkProperty LocationPaths { get; set; }
        public PciLinkProperty Parent { get; set; }
        public PciLinkProperty HardwareIds { get; set; }
        public PciLinkProperty CurrentLinkSpeed { get; set; }
        public PciLinkProperty CurrentLinkWidth { get; set; }
        public PciLinkProperty MaxLinkSpeed { get; set; }
        public PciLinkProperty MaxLinkWidth { get; set; }
    }

    public sealed class PciLinkDevice {
        public PciLinkNode Device { get; set; }
        public bool IsAmd { get; set; }
        public string VendorClassification { get; set; }   // amd | non-amd | unknown
        public string RootPortInstanceId { get; set; }     // raw: first ancestor typed as PCIe root port, else null
        public string RootPortLocationPath { get; set; }   // raw first location path of that ancestor, else null
        public List<PciLinkNode> Ancestors { get; set; }
        public bool AncestorsTruncated { get; set; }
        public string AncestorStopReason { get; set; }     // no-parent | max-depth | cycle | read-error
        public string Error { get; set; }
    }

    // Raw-read seam. The Windows implementation is WindowsPciLinkNative; tests supply a mock.
    public interface IPciLinkSource {
        string[] EnumerateDisplayInstanceIds();
        // Returns raw properties only; decoding is done by WindowsPciLink.
        PciLinkNode ReadNode(string instanceId);
    }

    public static class WindowsPciLink {
        public const int MaxDevices = 128;
        public const int MaxAncestors = 6;

        public static string DecodeSpeed(uint raw, out int? generation) {
            generation = null;
            switch (raw) {
                case 1: generation=1; return "Gen1 2.5GT/s";
                case 2: generation=2; return "Gen2 5GT/s";
                case 3: generation=3; return "Gen3 8GT/s";
                case 4: generation=4; return "Gen4 16GT/s";
                case 5: generation=5; return "Gen5 32GT/s";
                case 6: generation=6; return "Gen6 64GT/s";
                default: return null;
            }
        }

        public static string DecodeWidth(uint raw) {
            switch (raw) {
                case 1: case 2: case 4: case 8: case 12: case 16: case 32:
                    return "x" + raw.ToString(CultureInfo.InvariantCulture);
                default: return null;
            }
        }

        // DevProp_PciDevice_DeviceType_* (0..5) and DevProp_PciDevice_BridgeType_* (6..14) from pciprop.h.
        public static string DecodeDeviceType(uint raw) {
            switch (raw) {
                case 0: return "PciConventional";
                case 1: return "PciX";
                case 2: return "PciExpressEndpoint";
                case 3: return "PciExpressLegacyEndpoint";
                case 4: return "PciExpressRootComplexIntegratedEndpoint";
                case 5: return "PciExpressTreatedAsPci";
                case 6: return "BridgePciConventional";
                case 7: return "BridgePciX";
                case 8: return "BridgePciExpressRootPort";
                case 9: return "BridgePciExpressUpstreamSwitchPort";
                case 10: return "BridgePciExpressDownstreamSwitchPort";
                case 11: return "BridgePciExpressToPciXBridge";
                case 12: return "BridgePciXToExpressBridge";
                case 13: return "BridgePciExpressTreatedAsPci";
                case 14: return "BridgePciExpressEventCollector";
                default: return null;
            }
        }

        public const uint RootPortCode = 8;

        // Raw VEN_xxxx token from a PCI/DISPLAY instance ID or hardware ID; null when absent.
        public static string ParseVendorId(string text) {
            if (text == null) return null;
            int i = text.IndexOf("VEN_", StringComparison.OrdinalIgnoreCase);
            if (i < 0 || i + 8 > text.Length) return null;
            string hex = text.Substring(i + 4, 4);
            foreach (char c in hex) if (!Uri.IsHexDigit(c)) return null;
            return hex.ToLowerInvariant();
        }

        private static string FindVendor(PciLinkNode node) {
            string v = ParseVendorId(node.InstanceId);
            if (v != null) return v;
            if (node.HardwareIds != null && node.HardwareIds.List != null)
                foreach (string id in node.HardwareIds.List) { v = ParseVendorId(id); if (v != null) return v; }
            return null;
        }

        private static PciLinkProperty Missing() { return PciLinkProperty.Fail("not-read", null); }

        // Decodes raw codes in place. A missing value stays null with its error; zero is never invented.
        private static void Normalize(PciLinkNode node, int level) {
            node.Level = level;
            if (node.Class == null) node.Class = Missing();
            if (node.DeviceType == null) node.DeviceType = Missing();
            if (node.LocationInfo == null) node.LocationInfo = Missing();
            if (node.LocationPaths == null) node.LocationPaths = Missing();
            if (node.Parent == null) node.Parent = Missing();
            if (node.HardwareIds == null) node.HardwareIds = Missing();
            if (node.CurrentLinkSpeed == null) node.CurrentLinkSpeed = Missing();
            if (node.CurrentLinkWidth == null) node.CurrentLinkWidth = Missing();
            if (node.MaxLinkSpeed == null) node.MaxLinkSpeed = Missing();
            if (node.MaxLinkWidth == null) node.MaxLinkWidth = Missing();
            DecodeSpeedProperty(node.CurrentLinkSpeed);
            DecodeSpeedProperty(node.MaxLinkSpeed);
            DecodeWidthProperty(node.CurrentLinkWidth);
            DecodeWidthProperty(node.MaxLinkWidth);
            if (node.DeviceType.Raw.HasValue) {
                node.DeviceType.Decoded = DecodeDeviceType(node.DeviceType.Raw.Value);
                if (node.DeviceType.Decoded == null) node.DeviceType.DecodeNote = "unknown-device-type-code";
            }
            node.VendorId = FindVendor(node);
        }

        private static void DecodeSpeedProperty(PciLinkProperty p) {
            if (!p.Raw.HasValue) return;
            int? gen;
            p.Decoded = DecodeSpeed(p.Raw.Value, out gen);
            p.Generation = gen;
            if (p.Decoded == null) p.DecodeNote = "unknown-speed-code";
        }

        private static void DecodeWidthProperty(PciLinkProperty p) {
            if (!p.Raw.HasValue) return;
            p.Decoded = DecodeWidth(p.Raw.Value);
            if (p.Decoded == null) p.DecodeNote = "unknown-width-code";
        }

        public static PciLinkDevice[] Collect() {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("PCI link collection requires Windows.");
            if (IntPtr.Size != 8)
                throw new PlatformNotSupportedException("PCI link collection requires 64-bit Windows.");
            return Collect(new WindowsPciLinkNative());
        }

        public static PciLinkDevice[] Collect(IPciLinkSource source) {
            if (source == null) throw new ArgumentNullException("source");
            string[] ids = source.EnumerateDisplayInstanceIds();
            if (ids == null) ids = new string[0];
            if (ids.Length > MaxDevices) throw new InvalidOperationException("Display-class enumeration exceeded safety limit.");
            var result = new List<PciLinkDevice>();
            foreach (string id in ids) {
                var entry = new PciLinkDevice { Ancestors=new List<PciLinkNode>() };
                result.Add(entry);
                PciLinkNode node = null;
                try { node = source.ReadNode(id); } catch (Exception ex) { entry.Error = "read-failed:" + ex.GetType().Name; }
                if (node == null) {
                    node = new PciLinkNode { InstanceId = id };
                    if (entry.Error == null) entry.Error = "read-returned-null";
                }
                if (node.InstanceId == null) node.InstanceId = id;
                Normalize(node, 0);
                entry.Device = node;
                if (node.VendorId == null) { entry.IsAmd = false; entry.VendorClassification = "unknown"; }
                else if (node.VendorId == "1002") { entry.IsAmd = true; entry.VendorClassification = "amd"; }
                else { entry.IsAmd = false; entry.VendorClassification = "non-amd"; }
                WalkAncestors(source, entry);
            }
            return result.ToArray();
        }

        private static void WalkAncestors(IPciLinkSource source, PciLinkDevice entry) {
            var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            visited.Add(entry.Device.InstanceId);
            PciLinkNode current = entry.Device;
            while (true) {
                string parentId = current.Parent == null ? null : current.Parent.Text;
                if (String.IsNullOrEmpty(parentId)) { entry.AncestorStopReason = "no-parent"; return; }
                if (entry.Ancestors.Count >= MaxAncestors) {
                    entry.AncestorStopReason = "max-depth"; entry.AncestorsTruncated = true; return;
                }
                if (!visited.Add(parentId)) { entry.AncestorStopReason = "cycle"; return; }
                PciLinkNode parent = null;
                try { parent = source.ReadNode(parentId); } catch (Exception ex) {
                    entry.Error = "ancestor-read-failed:" + ex.GetType().Name;
                }
                if (parent == null) {
                    parent = new PciLinkNode { InstanceId = parentId };
                    if (entry.Error == null) entry.Error = "ancestor-read-returned-null";
                    Normalize(parent, entry.Ancestors.Count + 1);
                    entry.Ancestors.Add(parent);
                    entry.AncestorStopReason = "read-error";
                    return;
                }
                if (parent.InstanceId == null) parent.InstanceId = parentId;
                Normalize(parent, entry.Ancestors.Count + 1);
                entry.Ancestors.Add(parent);
                if (entry.RootPortInstanceId == null && parent.DeviceType.Raw.HasValue &&
                    parent.DeviceType.Raw.Value == RootPortCode) {
                    entry.RootPortInstanceId = parent.InstanceId;
                    if (parent.LocationPaths.List != null && parent.LocationPaths.List.Length > 0)
                        entry.RootPortLocationPath = parent.LocationPaths.List[0];
                }
                current = parent;
            }
        }
    }

    // Windows implementation: SetupAPI enumerates present Display-class instance IDs; cfgmgr32
    // CM_Get_DevNode_PropertyW reads every property (the same DEVPROPKEY store SetupAPI uses).
    public sealed class WindowsPciLinkNative : IPciLinkSource {
        private const uint DIGCF_PRESENT = 0x2;
        private const int ERROR_NO_MORE_ITEMS = 259;
        private const uint CR_SUCCESS = 0;
        private const uint CR_BUFFER_SMALL = 0x1A;
        private const uint CR_NO_SUCH_VALUE = 0x25;
        private const uint DEVPROP_TYPE_UINT32 = 0x7;
        private const uint DEVPROP_TYPE_STRING = 0x12;
        private const uint DEVPROP_TYPE_STRING_LIST = 0x2012; // DEVPROP_TYPEMOD_LIST | DEVPROP_TYPE_STRING
        private const int MAX_PROPERTY_BYTES = 16384;
        private const int MAX_LIST_ITEMS = 64;
        private static readonly Guid DisplayClass = new Guid("4d36e968-e325-11ce-bfc1-08002be10318");

        [StructLayout(LayoutKind.Sequential)] private struct DeviceInfoData {
            public uint Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] private struct PropertyKey {
            public Guid FormatId; public uint PropertyId;
            public PropertyKey(string formatId, uint propertyId) { FormatId=new Guid(formatId); PropertyId=propertyId; }
        }
        private const string PciGuid = "3ab22e31-8264-4b4e-9af5-a8d2d8e33e62";
        private const string DevGuid = "a45c254e-df1c-4efd-8020-67d146a850e0";
        private static readonly PropertyKey KeyDeviceType = new PropertyKey(PciGuid, 1);
        private static readonly PropertyKey KeyCurrentLinkSpeed = new PropertyKey(PciGuid, 9);
        private static readonly PropertyKey KeyCurrentLinkWidth = new PropertyKey(PciGuid, 10);
        private static readonly PropertyKey KeyMaxLinkSpeed = new PropertyKey(PciGuid, 11);
        private static readonly PropertyKey KeyMaxLinkWidth = new PropertyKey(PciGuid, 12);
        private static readonly PropertyKey KeyHardwareIds = new PropertyKey(DevGuid, 3);
        private static readonly PropertyKey KeyClass = new PropertyKey(DevGuid, 9);
        private static readonly PropertyKey KeyLocationInfo = new PropertyKey(DevGuid, 15);
        private static readonly PropertyKey KeyLocationPaths = new PropertyKey(DevGuid, 37);
        private static readonly PropertyKey KeyParent = new PropertyKey("4340a6c5-93fa-4706-972c-7b648008a5a7", 8);

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
        [DllImport("setupapi.dll", EntryPoint="SetupDiDestroyDeviceInfoList", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyDeviceInfoList(IntPtr set);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("cfgmgr32.dll", EntryPoint="CM_Locate_DevNodeW", CharSet=CharSet.Unicode, ExactSpelling=true)]
        private static extern uint LocateDevNode(out uint devInst, string deviceId, uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("cfgmgr32.dll", EntryPoint="CM_Get_DevNode_PropertyW", ExactSpelling=true)]
        private static extern uint GetDevNodeProperty(uint devInst, ref PropertyKey key, out uint propertyType,
            [Out] byte[] buffer, ref uint bufferSize, uint flags);

        public string[] EnumerateDisplayInstanceIds() {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("SetupAPI PCI link enumeration requires Windows.");
            Guid display = DisplayClass;
            IntPtr set = GetClassDevs(ref display, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT);
            if (set == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Display-class enumeration failed.");
            var ids = new List<string>();
            try {
                for (uint index = 0; index < WindowsPciLink.MaxDevices; index++) {
                    var data = new DeviceInfoData { Size=(uint)Marshal.SizeOf(typeof(DeviceInfoData)) };
                    if (!EnumDeviceInfo(set, index, ref data)) {
                        int code = Marshal.GetLastWin32Error();
                        if (code == ERROR_NO_MORE_ITEMS) return ids.ToArray();
                        throw new Win32Exception(code, "Display-class enumeration failed.");
                    }
                    var id = new StringBuilder(4096); uint needed;
                    if (!GetDeviceInstanceId(set, ref data, id, (uint)id.Capacity, out needed))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "Display device instance ID unavailable.");
                    ids.Add(id.ToString());
                }
                throw new InvalidOperationException("Display-class enumeration exceeded safety limit.");
            } finally { DestroyDeviceInfoList(set); }
        }

        public PciLinkNode ReadNode(string instanceId) {
            var node = new PciLinkNode { InstanceId = instanceId };
            uint devInst;
            uint cr = LocateDevNode(out devInst, instanceId, 0);
            if (cr != CR_SUCCESS) {
                PciLinkProperty fail = PciLinkProperty.Fail("cr-locate-0x" + cr.ToString("x2"), (int)cr);
                node.Class = fail; node.DeviceType = fail; node.LocationInfo = fail; node.LocationPaths = fail;
                node.Parent = fail; node.HardwareIds = fail; node.CurrentLinkSpeed = fail; node.CurrentLinkWidth = fail;
                node.MaxLinkSpeed = fail; node.MaxLinkWidth = fail;
                return node;
            }
            node.Class = ReadText(devInst, KeyClass);
            node.DeviceType = ReadUInt(devInst, KeyDeviceType);
            node.LocationInfo = ReadText(devInst, KeyLocationInfo);
            node.LocationPaths = ReadList(devInst, KeyLocationPaths);
            node.Parent = ReadText(devInst, KeyParent);
            node.HardwareIds = ReadList(devInst, KeyHardwareIds);
            node.CurrentLinkSpeed = ReadUInt(devInst, KeyCurrentLinkSpeed);
            node.CurrentLinkWidth = ReadUInt(devInst, KeyCurrentLinkWidth);
            node.MaxLinkSpeed = ReadUInt(devInst, KeyMaxLinkSpeed);
            node.MaxLinkWidth = ReadUInt(devInst, KeyMaxLinkWidth);
            return node;
        }

        private static byte[] Fetch(uint devInst, PropertyKey key, uint expectedType, out uint length, out PciLinkProperty failure) {
            failure = null; length = 0;
            uint type; uint size = (uint)MAX_PROPERTY_BYTES;
            byte[] bytes = new byte[MAX_PROPERTY_BYTES];
            uint cr = GetDevNodeProperty(devInst, ref key, out type, bytes, ref size, 0);
            if (cr == CR_NO_SUCH_VALUE) { failure = PciLinkProperty.Fail("cr-0x25-property-unavailable", (int)cr); return null; }
            if (cr == CR_BUFFER_SMALL) { failure = PciLinkProperty.Fail("cr-0x1a-property-over-limit", (int)cr); return null; }
            if (cr != CR_SUCCESS) { failure = PciLinkProperty.Fail("cr-0x" + cr.ToString("x2"), (int)cr); return null; }
            if (type != expectedType || size > bytes.Length) {
                failure = PciLinkProperty.Fail("unexpected-property-type-or-length", null); return null;
            }
            length = size;
            return bytes;
        }

        private static PciLinkProperty ReadUInt(uint devInst, PropertyKey key) {
            uint length; PciLinkProperty failure;
            byte[] bytes = Fetch(devInst, key, DEVPROP_TYPE_UINT32, out length, out failure);
            if (bytes == null) return failure;
            if (length != 4) return PciLinkProperty.Fail("unexpected-property-type-or-length", null);
            return new PciLinkProperty { Raw = BitConverter.ToUInt32(bytes, 0) };
        }

        private static PciLinkProperty ReadText(uint devInst, PropertyKey key) {
            uint length; PciLinkProperty failure;
            byte[] bytes = Fetch(devInst, key, DEVPROP_TYPE_STRING, out length, out failure);
            if (bytes == null) return failure;
            if (length < 2 || (length & 1) != 0) return PciLinkProperty.Fail("unexpected-property-type-or-length", null);
            return new PciLinkProperty { Text = Encoding.Unicode.GetString(bytes, 0, (int)length).TrimEnd('\0') };
        }

        private static PciLinkProperty ReadList(uint devInst, PropertyKey key) {
            uint length; PciLinkProperty failure;
            byte[] bytes = Fetch(devInst, key, DEVPROP_TYPE_STRING_LIST, out length, out failure);
            if (bytes == null) return failure;
            if ((length & 1) != 0) return PciLinkProperty.Fail("unexpected-property-type-or-length", null);
            string all = Encoding.Unicode.GetString(bytes, 0, (int)length);
            var items = new List<string>();
            foreach (string part in all.Split('\0')) {
                if (part.Length == 0) continue;
                if (items.Count >= MAX_LIST_ITEMS) return PciLinkProperty.Fail("property-over-limit", null);
                items.Add(part);
            }
            return new PciLinkProperty { List = items.ToArray() };
        }
    }
}
