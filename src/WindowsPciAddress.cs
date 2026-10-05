using System;
using System.Globalization;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm {
    // Advisory DXGI LUID -> address *without PCI segment*. Never construct a full BDF here.
    public sealed class WindowsPciAddressObservation {
        public string Luid { get; set; }
        public uint? Bus { get; set; }
        public uint? Device { get; set; }
        public uint? Function { get; set; }
        public string Error { get; set; }
    }

    public static class WindowsPciAddress {
        [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)] private struct OpenAdapter { public Luid AdapterLuid; public uint Handle; }
        [StructLayout(LayoutKind.Sequential)] private struct QueryAdapter {
            public uint Handle; public int Type; public IntPtr Data; public uint DataSize;
        }
        [StructLayout(LayoutKind.Sequential)] private struct AdapterAddress { public uint Bus, Device, Function; }
        [StructLayout(LayoutKind.Sequential)] private struct CloseAdapter { public uint Handle; }

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll", EntryPoint="D3DKMTOpenAdapterFromLuid", ExactSpelling=true)]
        private static extern int Open(ref OpenAdapter data);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll", EntryPoint="D3DKMTQueryAdapterInfo", ExactSpelling=true)]
        private static extern int Query(ref QueryAdapter data);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll", EntryPoint="D3DKMTCloseAdapter", ExactSpelling=true)]
        private static extern int Close(ref CloseAdapter data);

        public static bool LayoutIsExpected() {
            return IntPtr.Size == 8 && Marshal.SizeOf(typeof(Luid)) == 8 &&
                Marshal.SizeOf(typeof(OpenAdapter)) == 12 &&
                Marshal.SizeOf(typeof(QueryAdapter)) == 24 &&
                Marshal.SizeOf(typeof(AdapterAddress)) == 12 &&
                Marshal.SizeOf(typeof(CloseAdapter)) == 4;
        }

        public static WindowsPciAddressObservation Read(string luidHex) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("LUID PCI-address query requires 64-bit Windows.");
            if (!LayoutIsExpected()) throw new InvalidOperationException("D3DKMT structure layout differs from the expected Win64 ABI.");
            if (luidHex == null || luidHex.Length != 16) throw new ArgumentException("DXGI LUID must be 16 hexadecimal digits.", "luidHex");
            uint high, low;
            if (!UInt32.TryParse(luidHex.Substring(0,8), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out high) ||
                !UInt32.TryParse(luidHex.Substring(8,8), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out low))
                throw new ArgumentException("DXGI LUID must be 16 hexadecimal digits.", "luidHex");
            var result = new WindowsPciAddressObservation { Luid=luidHex.ToLowerInvariant() };
            var open = new OpenAdapter { AdapterLuid=new Luid { LowPart=low, HighPart=unchecked((int)high) } };
            int status = Open(ref open);
            if (status != 0 || open.Handle == 0) { result.Error="open-adapter-ntstatus-" + ((uint)status).ToString("x8"); return result; }
            IntPtr buffer = IntPtr.Zero;
            int queryStatus = 0, closeStatus = 0;
            AdapterAddress address = new AdapterAddress();
            try {
                buffer = Marshal.AllocHGlobal(12);
                for (int i=0;i<12;i++) Marshal.WriteByte(buffer,i,0);
                // KMTQAITYPE_ADAPTERADDRESS = 6 in d3dkmthk.h.
                var query = new QueryAdapter { Handle=open.Handle, Type=6, Data=buffer, DataSize=12 };
                queryStatus = Query(ref query);
                if (queryStatus == 0) address=(AdapterAddress)Marshal.PtrToStructure(buffer,typeof(AdapterAddress));
            } finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                var close = new CloseAdapter { Handle=open.Handle };
                closeStatus=Close(ref close);
            }
            if (queryStatus != 0) { result.Error="query-address-ntstatus-"+((uint)queryStatus).ToString("x8"); return result; }
            if (closeStatus != 0) { result.Error="close-adapter-ntstatus-"+((uint)closeStatus).ToString("x8"); return result; }
            if (address.Bus > 255 || address.Device > 31 || address.Function > 7) {
                result.Error="invalid-pci-address-range"; return result;
            }
            result.Bus=address.Bus; result.Device=address.Device; result.Function=address.Function;
            return result;
        }
    }
}
