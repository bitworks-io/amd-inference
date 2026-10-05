using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Bitworks.FastLlm {
    // Read-only PDH diagnostics. These counters are NOT residency evidence.
    public sealed class WindowsGpuMemoryRow {
        public string Luid { get; set; }
        public int? PhysicalAdapterIndex { get; set; }
        public long? DedicatedBytes { get; set; }
        public long? SharedBytes { get; set; }
        public long? CommittedBytes { get; set; }
    }

    public static class WindowsGpuTelemetry {
        private const uint PdhMoreData = 0x800007D2;
        private const uint PdhNoInstance = 0x800007D1;
        private const uint PdhNoData = 0x800007D5;
        private const uint PdhNoCounter = 0xC0000BB9;
        private const uint FormatLargeNoScale = 0x00000400 | 0x00001000;
        private const int MaxArrayBytes = 4 * 1024 * 1024;
        private const int MaxItems = 4096;
        private const int MaxTcpTableBytes = 1024 * 1024;
        private const int MaxTcpRows = 8192;
        private const uint ErrorInsufficientBuffer = 122;
        private static readonly Regex Instance = new Regex(
            @"^pid_([0-9]+)_luid_(0x[0-9a-fA-F]{1,8})_(0x[0-9a-fA-F]{1,8})(?:_phys_([0-9]+))?$",
            RegexOptions.CultureInvariant | RegexOptions.Compiled);

        [StructLayout(LayoutKind.Sequential)]
        private struct CounterItem64 {
            public IntPtr Name;
            public uint Status;
            public uint Padding;
            public long Value;
        }

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("pdh.dll", EntryPoint="PdhOpenQueryW", CharSet=CharSet.Unicode)]
        private static extern uint OpenQuery(string source, IntPtr userData, out IntPtr query);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("pdh.dll", EntryPoint="PdhAddEnglishCounterW", CharSet=CharSet.Unicode)]
        private static extern uint AddEnglishCounter(IntPtr query, string path, IntPtr userData, out IntPtr counter);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("pdh.dll", EntryPoint="PdhCollectQueryData")]
        private static extern uint Collect(IntPtr query);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("pdh.dll", EntryPoint="PdhGetFormattedCounterArrayW", CharSet=CharSet.Unicode)]
        private static extern uint GetCounterArray(IntPtr counter, uint format, ref uint bytes, ref uint count, IntPtr buffer);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("pdh.dll", EntryPoint="PdhCloseQuery")]
        private static extern uint CloseQuery(IntPtr query);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("iphlpapi.dll", EntryPoint="GetExtendedTcpTable")]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref uint size, bool order, uint addressFamily, int tableClass, uint reserved);

        // MIB_TCPTABLE_OWNER_PID: DWORD count followed by 24-byte MIB_TCPROW_OWNER_PID
        // rows. Local address is an in_addr and port occupies the first two network-
        // ordered bytes of its DWORD. Parse only IPv4 127.0.0.1 LISTEN rows.
        public static int[] ParseLoopbackListenerOwners(byte[] table, int port) {
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            if (table == null || table.Length < 4 || table.Length > MaxTcpTableBytes) throw new InvalidOperationException("Invalid TCP owner table size.");
            uint count = BitConverter.ToUInt32(table, 0);
            if (count > MaxTcpRows || 4UL + (ulong)count * 24UL > (ulong)table.Length) throw new InvalidOperationException("Invalid TCP owner table row count.");
            var owners = new SortedSet<int>();
            for (int i = 0; i < (int)count; i++) {
                int offset = 4 + i * 24;
                if (BitConverter.ToUInt32(table, offset) != 2 || // MIB_TCP_STATE_LISTEN
                    table[offset + 4] != 127 || table[offset + 5] != 0 ||
                    table[offset + 6] != 0 || table[offset + 7] != 1) continue;
                int rowPort = (table[offset + 8] << 8) | table[offset + 9];
                if (rowPort != port) continue;
                if (table[offset + 10] != 0 || table[offset + 11] != 0) throw new InvalidOperationException("Malformed TCP listener port.");
                uint pid = BitConverter.ToUInt32(table, offset + 20);
                if (pid == 0 || pid > int.MaxValue) throw new InvalidOperationException("Invalid TCP listener PID.");
                owners.Add((int)pid);
            }
            var result = new int[owners.Count];
            owners.CopyTo(result);
            return result;
        }

        public static int[] GetLoopbackListenerOwners(int port) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8) throw new PlatformNotSupportedException("TCP owner lookup needs 64-bit Windows.");
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            uint size = 0;
            // AF_INET=2; TCP_TABLE_OWNER_PID_LISTENER=3.
            uint status = GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 3, 0);
            if (status != ErrorInsufficientBuffer || size < 4 || size > MaxTcpTableBytes) throw new InvalidOperationException("TCP listener table unavailable or oversized.");
            uint capacity = size;
            IntPtr buffer = Marshal.AllocHGlobal((int)capacity);
            try {
                status = GetExtendedTcpTable(buffer, ref size, false, 2, 3, 0);
                if (status != 0 || size < 4 || size > capacity) throw new InvalidOperationException("TCP listener table read failed or changed size.");
                var bytes = new byte[size];
                Marshal.Copy(buffer, bytes, 0, (int)size);
                return ParseLoopbackListenerOwners(bytes, port);
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        // Only these documented statuses mean an optional counter is absent;
        // invalid paths, buffers, and resource failures remain hard errors.
        public static bool IsUnavailableOptionalCounterStatus(uint status) {
            return status == PdhNoInstance || status == PdhNoData || status == PdhNoCounter;
        }

        public static bool MatchesSupervisedProcessIdentity(int actualPid, long actualStartUtcTicks, int recordedPid, long recordedStartUtcTicks) {
            return actualPid > 0 && actualStartUtcTicks > 0 &&
                actualPid == recordedPid && actualStartUtcTicks == recordedStartUtcTicks;
        }

        public static bool TryParseInstance(string name, int expectedPid, out string luid, out int? physicalAdapterIndex) {
            luid = null;
            physicalAdapterIndex = null;
            if (name == null || name.Length > 160) return false;
            Match match = Instance.Match(name);
            int pid;
            if (!match.Success || !int.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out pid) || pid != expectedPid)
                return false;
            uint high, low;
            if (!uint.TryParse(match.Groups[2].Value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out high) ||
                !uint.TryParse(match.Groups[3].Value.Substring(2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out low))
                return false;
            if (match.Groups[4].Success) {
                int physical;
                if (!int.TryParse(match.Groups[4].Value, NumberStyles.None, CultureInfo.InvariantCulture, out physical)) return false;
                physicalAdapterIndex = physical;
            }
            luid = "0x" + high.ToString("X8", CultureInfo.InvariantCulture) + low.ToString("X8", CultureInfo.InvariantCulture);
            return true;
        }

        private static Dictionary<string, long> ReadArray(IntPtr counter, int pid, bool optional) {
            var result = new Dictionary<string, long>(StringComparer.Ordinal);
            if (counter == IntPtr.Zero) return result;
            uint bytes = 0, count = 0;
            uint status = GetCounterArray(counter, FormatLargeNoScale, ref bytes, ref count, IntPtr.Zero);
            if (optional && (status == PdhNoInstance || status == PdhNoData)) return result;
            if (status != PdhMoreData || bytes == 0 || bytes > MaxArrayBytes) throw new InvalidOperationException("GPU PDH counter array unavailable or oversized.");
            IntPtr buffer = Marshal.AllocHGlobal((int)bytes);
            try {
                status = GetCounterArray(counter, FormatLargeNoScale, ref bytes, ref count, buffer);
                if (optional && (status == PdhNoInstance || status == PdhNoData)) return result;
                if (status != 0 || bytes > MaxArrayBytes || count > MaxItems) throw new InvalidOperationException("GPU PDH counter read failed or exceeded its bound.");
                int itemSize = Marshal.SizeOf(typeof(CounterItem64));
                if ((ulong)count * (ulong)itemSize > bytes) throw new InvalidOperationException("GPU PDH counter array is malformed.");
                for (uint i = 0; i < count; i++) {
                    var item = (CounterItem64)Marshal.PtrToStructure(IntPtr.Add(buffer, checked((int)i * itemSize)), typeof(CounterItem64));
                    if (item.Name == IntPtr.Zero) throw new InvalidOperationException("GPU PDH counter array contains a null instance name.");
                    string name = Marshal.PtrToStringUni(item.Name);
                    string luid; int? physical;
                    if (!TryParseInstance(name, pid, out luid, out physical)) continue;
                    if (optional && (item.Status == PdhNoInstance || item.Status == PdhNoData)) continue;
                    if ((item.Status != 0 && item.Status != 1) || item.Value < 0) throw new InvalidOperationException("GPU PDH target counter value is invalid.");
                    string key = luid + "|" + (physical.HasValue ? physical.Value.ToString(CultureInfo.InvariantCulture) : "");
                    if (result.ContainsKey(key)) throw new InvalidOperationException("Duplicate GPU PDH adapter instance for target process.");
                    result.Add(key, item.Value);
                }
            } finally { Marshal.FreeHGlobal(buffer); }
            return result;
        }

        public static WindowsGpuMemoryRow[] ReadProcessMemory(int pid) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8) throw new PlatformNotSupportedException("GPU PDH telemetry needs 64-bit Windows.");
            if (pid <= 0) throw new ArgumentOutOfRangeException("pid");
            IntPtr query = IntPtr.Zero, dedicated = IntPtr.Zero, shared = IntPtr.Zero, committed = IntPtr.Zero;
            uint status = OpenQuery(null, IntPtr.Zero, out query);
            if (status != 0 || query == IntPtr.Zero) throw new InvalidOperationException("Cannot open GPU PDH query.");
            try {
                status = AddEnglishCounter(query, @"\GPU Process Memory(*)\Dedicated Usage", IntPtr.Zero, out dedicated);
                if (status != 0) throw new InvalidOperationException("GPU Process Memory dedicated counter unavailable.");
                status = AddEnglishCounter(query, @"\GPU Process Memory(*)\Shared Usage", IntPtr.Zero, out shared);
                if (status != 0) {
                    if (!IsUnavailableOptionalCounterStatus(status)) throw new InvalidOperationException("GPU PDH shared counter failed to initialize.");
                    shared = IntPtr.Zero;
                }
                status = AddEnglishCounter(query, @"\GPU Process Memory(*)\Total Committed", IntPtr.Zero, out committed);
                if (status != 0) {
                    if (!IsUnavailableOptionalCounterStatus(status)) throw new InvalidOperationException("GPU PDH committed counter failed to initialize.");
                    committed = IntPtr.Zero;
                }
                status = Collect(query);
                if (status != 0) throw new InvalidOperationException("GPU PDH collection failed.");
                var values = new Dictionary<string, WindowsGpuMemoryRow>(StringComparer.Ordinal);
                Action<Dictionary<string, long>, Action<WindowsGpuMemoryRow, long>> add = (readings, assign) => {
                    foreach (var pair in readings) {
                        WindowsGpuMemoryRow row;
                        if (!values.TryGetValue(pair.Key, out row)) {
                            string[] fields = pair.Key.Split('|');
                            int physical;
                            row = new WindowsGpuMemoryRow { Luid = fields[0], PhysicalAdapterIndex = int.TryParse(fields[1], out physical) ? (int?)physical : null };
                            values.Add(pair.Key, row);
                        }
                        assign(row, pair.Value);
                    }
                };
                add(ReadArray(dedicated, pid, false), (row, value) => row.DedicatedBytes = value);
                add(ReadArray(shared, pid, true), (row, value) => row.SharedBytes = value);
                add(ReadArray(committed, pid, true), (row, value) => row.CommittedBytes = value);
                var rows = new List<WindowsGpuMemoryRow>(values.Values);
                rows.Sort((a, b) => string.CompareOrdinal(a.Luid + "|" + a.PhysicalAdapterIndex, b.Luid + "|" + b.PhysicalAdapterIndex));
                return rows.ToArray();
            } finally { CloseQuery(query); }
        }
    }
}
