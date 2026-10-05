using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm {
    public sealed class AdapterInventory {
        public string Name, Luid;
        public uint VendorId, DeviceId, SubsystemId, Revision, Flags;
        public ulong DedicatedVideoBytes, DedicatedSystemBytes, SharedSystemBytes;
        public bool BudgetAvailable;
        public ulong LocalBudgetBytes, ProbeProcessLocalUsageBytes, AvailableForReservationBytes;
    }
    // Windows SDK DXGI interfaces. LUID is boot-scoped, not a persistent PCI identity.
    public static class WindowsInventory {
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct Description {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Name;
            public uint VendorId, DeviceId, SubsystemId, Revision;
            public UIntPtr DedicatedVideo, DedicatedSystem, SharedSystem;
            public uint LuidLow; public int LuidHigh; public uint Flags;
        }
        [StructLayout(LayoutKind.Sequential)] private struct MemoryInfo { public ulong Budget, CurrentUsage, AvailableForReservation, CurrentReservation; }
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int EnumAdapter(IntPtr self, uint index, out IntPtr adapter);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetDescription(IntPtr self, out Description description);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int GetMemory(IntPtr self, uint node, int segment, out MemoryInfo info);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("dxgi.dll", ExactSpelling=true)] private static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr factory);
        private static Delegate Method(IntPtr instance, int slot, Type type) {
            IntPtr table=Marshal.ReadIntPtr(instance);
            return Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(table, slot*IntPtr.Size), type);
        }
        public static AdapterInventory[] Read() {
            if(Environment.OSVersion.Platform!=PlatformID.Win32NT) throw new PlatformNotSupportedException("DXGI inventory requires Windows.");
            Guid factoryId=new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            IntPtr factory;
            Marshal.ThrowExceptionForHR(CreateDXGIFactory1(ref factoryId,out factory));
            var result=new List<AdapterInventory>();
            try {
                var enumerate=(EnumAdapter)Method(factory,12,typeof(EnumAdapter));
                for(uint index=0;index<64;index++) {
                    IntPtr adapter;
                    int hr=enumerate(factory,index,out adapter);
                    if(hr==unchecked((int)0x887A0002)) return result.ToArray();
                    Marshal.ThrowExceptionForHR(hr);
                    try {
                        Description d;
                        Marshal.ThrowExceptionForHR(((GetDescription)Method(adapter,10,typeof(GetDescription)))(adapter,out d));
                        var item=new AdapterInventory {Name=d.Name,VendorId=d.VendorId,DeviceId=d.DeviceId,SubsystemId=d.SubsystemId,Revision=d.Revision,Flags=d.Flags,DedicatedVideoBytes=d.DedicatedVideo.ToUInt64(),DedicatedSystemBytes=d.DedicatedSystem.ToUInt64(),SharedSystemBytes=d.SharedSystem.ToUInt64(),Luid=((uint)d.LuidHigh).ToString("x8")+d.LuidLow.ToString("x8")};
                        Guid adapter3Id=new Guid("645967a4-1392-4310-a798-8053ce3e93fd");
                        IntPtr adapter3;
                        // ref is needed by .NET Framework; .NET 10 annotates this argument in.
#pragma warning disable
                        if(Marshal.QueryInterface(adapter,ref adapter3Id,out adapter3)==0) {
#pragma warning restore
                            try {
                                MemoryInfo memory;
                                if(((GetMemory)Method(adapter3,14,typeof(GetMemory)))(adapter3,0,0,out memory)==0) {
                                    item.BudgetAvailable=true;item.LocalBudgetBytes=memory.Budget;item.ProbeProcessLocalUsageBytes=memory.CurrentUsage;item.AvailableForReservationBytes=memory.AvailableForReservation;
                                }
                            } finally {Marshal.Release(adapter3);}
                        }
                        result.Add(item);
                    } finally {Marshal.Release(adapter);}
                }
                throw new InvalidOperationException("DXGI adapter enumeration exceeded safety limit.");
            } finally {Marshal.Release(factory);}
        }
    }
}
