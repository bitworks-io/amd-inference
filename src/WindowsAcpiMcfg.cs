using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm
{
    // Read-only ACPI MCFG (PCI Express memory-mapped configuration) segment groups via
    // GetSystemFirmwareTable('ACPI','MCFG'). Standard user. Parse is pure and testable.
    public static class WindowsAcpiMcfg
    {
        public const int MaximumTableBytes = 64 * 1024;
        private const uint AcpiProvider = 0x41435049; // 'ACPI'
        private const uint McfgTable = 0x4746434D;    // 'MCFG' as a little-endian DWORD

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        private static extern uint GetSystemFirmwareTable(uint provider, uint tableId, IntPtr buffer, uint bufferSize);

        // ACPI header is 36 bytes, then 8 reserved bytes, then 16-byte allocation entries:
        // UInt64 base, UInt16 segment group, byte start bus, byte end bus, UInt32 reserved.
        public static int[] ParseSegments(byte[] raw)
        {
            if (raw == null || raw.Length < 44 || raw.Length > MaximumTableBytes)
                throw new ArgumentException("MCFG buffer is outside the fixed bound.");
            if (raw[0] != (byte)'M' || raw[1] != (byte)'C' || raw[2] != (byte)'F' || raw[3] != (byte)'G')
                throw new ArgumentException("MCFG signature is missing.");
            uint length = BitConverter.ToUInt32(raw, 4);
            if (length != (uint)raw.Length)
                throw new ArgumentException("MCFG header length differs from the buffer.");
            int body = raw.Length - 44;
            if (body < 16 || body % 16 != 0)
                throw new ArgumentException("MCFG allocation area is empty or misaligned.");
            byte sum = 0;
            for (int i = 0; i < raw.Length; i++) sum = unchecked((byte)(sum + raw[i]));
            if (sum != 0) throw new ArgumentException("MCFG checksum is invalid.");
            var segments = new List<int>();
            for (int offset = 44; offset < raw.Length; offset += 16)
            {
                int segment = BitConverter.ToUInt16(raw, offset + 8);
                int startBus = raw[offset + 10], endBus = raw[offset + 11];
                if (endBus < startBus) throw new ArgumentException("MCFG bus range is invalid.");
                if (!segments.Contains(segment)) segments.Add(segment);
            }
            segments.Sort();
            return segments.ToArray();
        }

        public static int[] Read()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("ACPI MCFG reading requires Windows.");
            uint size = GetSystemFirmwareTable(AcpiProvider, McfgTable, IntPtr.Zero, 0);
            if (size < 44 || size > MaximumTableBytes)
                throw new InvalidOperationException("MCFG size unavailable or outside the fixed bound.");
            IntPtr buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                uint written = GetSystemFirmwareTable(AcpiProvider, McfgTable, buffer, size);
                if (written != size) throw new InvalidOperationException("MCFG changed or could not be read completely.");
                byte[] bytes = new byte[(int)size];
                Marshal.Copy(buffer, bytes, 0, bytes.Length);
                return ParseSegments(bytes);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}
