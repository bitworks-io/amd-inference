using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm
{
    // Read-only SMBIOS Type 17 diagnostic. Never expose firmware strings or raw bytes.
    // Sources: https://learn.microsoft.com/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemfirmwaretable
    // and https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.7.1.pdf section 7.18.
    public static class WindowsSmbiosMemory
    {
        public const int MaximumTableBytes = 1024 * 1024;
        private const uint RawSmbiosProvider = 0x52534D42; // 'RSMB'

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        private static extern uint GetSystemFirmwareTable(uint provider, uint tableId, IntPtr buffer, uint bufferSize);

        public sealed class Device
        {
            public int Ordinal { get; set; }
            public string CapacityStatus { get; set; }
            public long? InstalledCapacityBytes { get; set; }
            public string RatedSpeedStatus { get; set; }
            public uint? RatedSpeedMTps { get; set; }
            public string ConfiguredSpeedStatus { get; set; }
            public uint? ConfiguredSpeedMTps { get; set; }
        }

        public sealed class Report
        {
            public int SchemaVersion { get { return 1; } }
            public string Kind { get { return "windows-smbios-type17-memory"; } }
            public bool Qualified { get { return false; } }
            public string Source { get { return "GetSystemFirmwareTable.RSMB.Type17"; } }
            public int SmbiosMajor { get; set; }
            public int SmbiosMinor { get; set; }
            public int Type17Structures { get; set; }
            public int PopulatedCount { get; set; }
            public int EmptyCount { get; set; }
            public int LogicalDeviceCountExcluded { get; set; }
            public bool InstalledCapacityComplete { get; set; }
            public long? KnownInstalledCapacityBytes { get; set; }
            public Device[] Devices { get; set; }
            public string CapacityMeaning { get { return "SMBIOS reported installed capacity, not OS usable physical memory"; } }
            public string TopologyMeaning { get { return "No memory channel, PCIe link, or GPU routing inference"; } }
        }

        private static byte[] ReadRawTable()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("SMBIOS firmware reading requires Windows.");
            uint size = GetSystemFirmwareTable(RawSmbiosProvider, 0, IntPtr.Zero, 0);
            if (size < 8 || size > MaximumTableBytes)
                throw new InvalidOperationException("SMBIOS table size unavailable or outside the fixed bound.");
            IntPtr buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                uint written = GetSystemFirmwareTable(RawSmbiosProvider, 0, buffer, size);
                if (written != size)
                    throw new InvalidOperationException("SMBIOS table changed or could not be read completely.");
                byte[] bytes = new byte[(int)size];
                Marshal.Copy(buffer, bytes, 0, bytes.Length);
                return bytes;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static ushort U16(byte[] data, int offset)
        {
            return (ushort)(data[offset] | (data[offset + 1] << 8));
        }

        private static uint U32(byte[] data, int offset)
        {
            return (uint)(data[offset] | (data[offset + 1] << 8) |
                (data[offset + 2] << 16) | (data[offset + 3] << 24));
        }

        private static bool AtLeast(int major, int minor, int requiredMajor, int requiredMinor)
        {
            return major > requiredMajor || (major == requiredMajor && minor >= requiredMinor);
        }

        private static void Speed(byte[] data, int start, int length, int major, int minor,
            int fieldOffset, int extendedOffset, int requiredMajor, int requiredMinor,
            out string status, out uint? value)
        {
            value = null;
            if (!AtLeast(major, minor, requiredMajor, requiredMinor) || length < fieldOffset + 2)
            {
                status = "not-reported";
                return;
            }
            ushort raw = U16(data, start + fieldOffset);
            if (raw == 0) { status = "unknown"; return; }
            // DSP0134 revisions through 3.0 named this value MHz, although some DDR
            // implementations already reported transfer rate. Do not relabel it MT/s.
            if (!AtLeast(major, minor, 3, 1))
            {
                status = "legacy-unit-ambiguous";
                return;
            }
            if (raw != 0xffff) { status = "reported"; value = raw; return; }
            if (!AtLeast(major, minor, 3, 3) || length < extendedOffset + 4)
            {
                status = "extended-unavailable";
                return;
            }
            uint extended = U32(data, start + extendedOffset);
            if (extended < 65535u || (extended & 0x80000000u) != 0)
            {
                status = "extended-invalid";
                return;
            }
            status = "reported-extended";
            value = extended;
        }

        public static Report Parse(byte[] raw)
        {
            if (raw == null || raw.Length < 8 || raw.Length > MaximumTableBytes)
                throw new ArgumentException("SMBIOS buffer is outside the fixed bound.");
            int major = raw[1], minor = raw[2];
            if (!AtLeast(major, minor, 2, 1))
                throw new ArgumentException("SMBIOS version cannot describe Type 17 memory devices.");
            uint tableLength = U32(raw, 4);
            if (tableLength < 6 || tableLength != (uint)(raw.Length - 8))
                throw new ArgumentException("SMBIOS header length differs from the bounded table.");
            int end = raw.Length, position = 8, structures = 0;
            var devices = new List<Device>();
            var report = new Report { SmbiosMajor = major, SmbiosMinor = minor };
            long capacity = 0;
            bool complete = true, endSeen = false;
            while (position < end)
            {
                if (++structures > 4096 || end - position < 6)
                    throw new ArgumentException("SMBIOS structure count or boundary is invalid.");
                int type = raw[position], length = raw[position + 1];
                if (length < 4 || length > end - position - 2)
                    throw new ArgumentException("SMBIOS formatted structure exceeds the table.");
                int stringsStart = position + length;
                int after = -1;
                for (int cursor = stringsStart; cursor + 1 < end; cursor++)
                {
                    if (raw[cursor] == 0 && raw[cursor + 1] == 0) { after = cursor + 2; break; }
                }
                if (after < 0) throw new ArgumentException("SMBIOS string area is unterminated.");
                if (type == 17)
                {
                    if (++report.Type17Structures > 32 || length < 0x15)
                        throw new ArgumentException("SMBIOS Type 17 count or minimum length is invalid.");
                    if (raw[position + 0x12] == 0x1f)
                    {
                        report.LogicalDeviceCountExcluded++;
                    }
                    else
                    {
                        ushort size = U16(raw, position + 0x0c);
                        if (size == 0) report.EmptyCount++;
                        else
                        {
                            var device = new Device { Ordinal = report.PopulatedCount++ };
                            if (size == 0xffff)
                            {
                                device.CapacityStatus = "unknown";
                                complete = false;
                            }
                            else if (size == 0x7fff)
                            {
                                if (!AtLeast(major, minor, 2, 7) || length < 0x20)
                                {
                                    device.CapacityStatus = "extended-unavailable";
                                    complete = false;
                                }
                                else
                                {
                                    uint extended = U32(raw, position + 0x1c);
                                    if (extended == 0 || (extended & 0x80000000u) != 0)
                                    {
                                        device.CapacityStatus = "extended-invalid";
                                        complete = false;
                                    }
                                    else
                                    {
                                        device.CapacityStatus = "reported-extended";
                                        device.InstalledCapacityBytes = checked((long)extended * 1048576L);
                                    }
                                }
                            }
                            else
                            {
                                long units = size & 0x7fff;
                                if (units == 0)
                                {
                                    device.CapacityStatus = "invalid";
                                    complete = false;
                                }
                                else
                                {
                                    device.CapacityStatus = "reported";
                                    device.InstalledCapacityBytes = checked(units * ((size & 0x8000) == 0 ? 1048576L : 1024L));
                                }
                            }
                            if (device.InstalledCapacityBytes.HasValue)
                                capacity = checked(capacity + device.InstalledCapacityBytes.Value);
                            string ratedStatus, configuredStatus;
                            uint? ratedValue, configuredValue;
                            Speed(raw, position, length, major, minor, 0x15, 0x54, 2, 3,
                                out ratedStatus, out ratedValue);
                            Speed(raw, position, length, major, minor, 0x20, 0x58, 2, 7,
                                out configuredStatus, out configuredValue);
                            device.RatedSpeedStatus = ratedStatus;
                            device.RatedSpeedMTps = ratedValue;
                            device.ConfiguredSpeedStatus = configuredStatus;
                            device.ConfiguredSpeedMTps = configuredValue;
                            devices.Add(device);
                        }
                    }
                }
                position = after;
                if (type == 127)
                {
                    if (position != end) throw new ArgumentException("SMBIOS end marker has trailing table data.");
                    endSeen = true;
                }
                if (endSeen) break;
            }
            if (!endSeen || report.Type17Structures == 0)
                throw new ArgumentException("SMBIOS end marker or Type 17 structures are missing.");
            report.Devices = devices.ToArray();
            report.InstalledCapacityComplete = complete && report.PopulatedCount > 0;
            report.KnownInstalledCapacityBytes = report.PopulatedCount > 0 ? (long?)capacity : null;
            return report;
        }

        public static Report Read()
        {
            byte[] raw = ReadRawTable();
            try { return Parse(raw); }
            finally { Array.Clear(raw, 0, raw.Length); }
        }
    }
}
