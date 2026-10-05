using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Bitworks.FastLlm {
    // A PnP record is not a DXGI adapter. In particular, InstanceId is persistent
    // across boots while a DXGI LUID is not. Never join these records by display name.
    public sealed class WindowsGpuPnpRecord {
        public string InstanceId, Description, LocationInfo, DriverVersion, DriverProvider;
        public string DriverVersionError, LocationError;
        public string DriverVersionSource="SetupDiGetDevicePropertyW:DEVPKEY_Device_DriverVersion:{a8b865dd-2e3d-4094-ad97-e593a70c75d6}:3";
        public string DxgiCorrelation="unmatched";
    }

    public static class WindowsGpuIdentity {
        private const uint DIGCF_PRESENT=0x2;
        private const int ERROR_NO_MORE_ITEMS=259;
        private const int ERROR_NOT_FOUND=1168;
        private const int ERROR_INSUFFICIENT_BUFFER=122;
        private const uint DEVPROP_TYPE_STRING=0x12;
        private const int MAX_DEVICES=128;
        private const int MAX_PROPERTY_BYTES=16384;
        private static readonly Guid DisplayClass=new Guid("4d36e968-e325-11ce-bfc1-08002be10318");

        [StructLayout(LayoutKind.Sequential)] private struct DeviceInfoData {
            public uint Size; public Guid ClassGuid; public uint DevInst; public IntPtr Reserved;
        }
        [StructLayout(LayoutKind.Sequential)] private struct PropertyKey {
            public Guid FormatId; public uint PropertyId;
            public PropertyKey(string formatId,uint propertyId) { FormatId=new Guid(formatId); PropertyId=propertyId; }
        }
        private static readonly PropertyKey DeviceDescription=new PropertyKey("a45c254e-df1c-4efd-8020-67d146a850e0",2);
        private static readonly PropertyKey DeviceLocationInfo=new PropertyKey("a45c254e-df1c-4efd-8020-67d146a850e0",15);
        private static readonly PropertyKey DeviceDriverVersion=new PropertyKey("a8b865dd-2e3d-4094-ad97-e593a70c75d6",3);
        private static readonly PropertyKey DeviceDriverProvider=new PropertyKey("a8b865dd-2e3d-4094-ad97-e593a70c75d6",9);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll",EntryPoint="SetupDiGetClassDevsW",SetLastError=true)]
        private static extern IntPtr GetClassDevs(ref Guid classGuid,IntPtr enumerator,IntPtr parent,uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll",EntryPoint="SetupDiEnumDeviceInfo",SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDeviceInfo(IntPtr set,uint index,ref DeviceInfoData data);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll",EntryPoint="SetupDiGetDeviceInstanceIdW",SetLastError=true,CharSet=CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetDeviceInstanceId(IntPtr set,ref DeviceInfoData data,StringBuilder output,uint size,out uint needed);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll",EntryPoint="SetupDiGetDevicePropertyW",SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetDeviceProperty(IntPtr set,ref DeviceInfoData data,ref PropertyKey key,out uint propertyType,
            [Out] byte[] output,uint size,out uint needed,uint flags);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("setupapi.dll",EntryPoint="SetupDiDestroyDeviceInfoList",SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyDeviceInfoList(IntPtr set);

        private static string ReadString(IntPtr set,ref DeviceInfoData data,PropertyKey key,out string error) {
            error=null;
            uint type, needed;
            byte[] bytes=new byte[MAX_PROPERTY_BYTES];
            if (!GetDeviceProperty(set,ref data,ref key,out type,bytes,(uint)bytes.Length,out needed,0)) {
                int code=Marshal.GetLastWin32Error();
                if (code==ERROR_NOT_FOUND) { error="property-unavailable"; return null; }
                if (code==ERROR_INSUFFICIENT_BUFFER) { error="property-over-limit"; return null; }
                error="win32-"+code; return null;
            }
            if (type!=DEVPROP_TYPE_STRING || needed<2 || needed>bytes.Length || (needed&1)!=0) {
                error="unexpected-property-type-or-length"; return null;
            }
            return Encoding.Unicode.GetString(bytes,0,(int)needed).TrimEnd('\0');
        }

        public static WindowsGpuPnpRecord[] ReadPnP() {
            if (Environment.OSVersion.Platform!=PlatformID.Win32NT)
                throw new PlatformNotSupportedException("SetupAPI GPU identity requires Windows.");
            Guid display=DisplayClass;
            IntPtr set=GetClassDevs(ref display,IntPtr.Zero,IntPtr.Zero,DIGCF_PRESENT);
            if (set==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Display-class enumeration failed.");
            var records=new List<WindowsGpuPnpRecord>();
            try {
                for (uint index=0;index<MAX_DEVICES;index++) {
                    var data=new DeviceInfoData { Size=(uint)Marshal.SizeOf(typeof(DeviceInfoData)) };
                    if (!EnumDeviceInfo(set,index,ref data)) {
                        int code=Marshal.GetLastWin32Error();
                        if (code==ERROR_NO_MORE_ITEMS) return records.ToArray();
                        throw new Win32Exception(code,"Display-class enumeration failed.");
                    }
                    var id=new StringBuilder(4096); uint needed;
                    if (!GetDeviceInstanceId(set,ref data,id,(uint)id.Capacity,out needed))
                        throw new Win32Exception(Marshal.GetLastWin32Error(),"Display device instance ID unavailable.");
                    var record=new WindowsGpuPnpRecord { InstanceId=id.ToString() };
                    string ignored;
                    record.Description=ReadString(set,ref data,DeviceDescription,out ignored);
                    record.LocationInfo=ReadString(set,ref data,DeviceLocationInfo,out record.LocationError);
                    record.DriverVersion=ReadString(set,ref data,DeviceDriverVersion,out record.DriverVersionError);
                    record.DriverProvider=ReadString(set,ref data,DeviceDriverProvider,out ignored);
                    records.Add(record);
                }
                throw new InvalidOperationException("Display-class enumeration exceeded safety limit.");
            } finally { DestroyDeviceInfoList(set); }
        }
    }
}
