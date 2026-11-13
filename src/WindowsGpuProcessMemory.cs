using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm {
    // Per-process committed GPU memory on one adapter, as Task Manager splits it: aperture segments are shared, the rest dedicated.
    // Advisory only. D3DKMT_QUERYSTATISTICS is marshalled as one zeroed byte buffer; every offset below is an x64 value taken from
    // the public D3DKMT headers (System Informer plugins/ExtendedTools/d3dkmt/d3dkmthk.h and Wine include/ddk/d3dkmthk.h agree on them).
    public sealed class GpuProcessMemoryObservation {
        public string Luid { get; set; }
        public int ProcessId { get; set; }
        public int SegmentCount { get; set; }
        public int ApertureSegmentCount { get; set; }
        public ulong? DedicatedBytes { get; set; }
        public ulong? SharedBytes { get; set; }
        public string Error { get; set; }
    }

    public static class WindowsGpuProcessMemory {
        // sizeof(D3DKMT_QUERYSTATISTICS) on AMD64 (C_ASSERT == 0x328 in the System Informer header).
        public const int StatisticsSize = 0x328;
        // D3DKMT_QUERYSTATISTICS.Type (D3DKMT_QUERYSTATISTICS_TYPE, a 4-byte enum).
        public const int OffsetType = 0;
        // D3DKMT_QUERYSTATISTICS.AdapterLuid (LUID: ULONG LowPart, LONG HighPart), 4-byte aligned right after Type.
        public const int OffsetAdapterLuid = 4;
        // D3DKMT_QUERYSTATISTICS.hProcess (HANDLE, 8-byte aligned on x64).
        public const int OffsetProcessHandle = 16;
        // D3DKMT_QUERYSTATISTICS.QueryResult (D3DKMT_QUERYSTATISTICS_RESULT union, 8-byte aligned).
        public const int OffsetQueryResult = 24;
        // sizeof(D3DKMT_QUERYSTATISTICS_RESULT): derived from the 0x328 total and confirmed by compiling both headers on x64.
        public const int QueryResultSize = 776;
        // D3DKMT_QUERYSTATISTICS anonymous trailing union (QuerySegment / QueryProcessSegment .SegmentId, ULONG) follows QueryResult.
        public const int OffsetSegmentId = OffsetQueryResult + QueryResultSize;
        // D3DKMT_QUERYSTATISTICS_ADAPTER_INFORMATION.NbSegments (first field), relative to QueryResult.
        public const int ResultOffsetNbSegments = 0;
        // D3DKMT_QUERYSTATISTICS_SEGMENT_INFORMATION (Win8+ layout): CommitLimit 0, BytesCommitted 8, BytesResident 16, Memory 24..40, Aperture 40.
        public const int ResultOffsetSegmentBytesCommitted = 8;
        public const int ResultOffsetAperture = 40;
        // D3DKMT_QUERYSTATISTICS_PROCESS_SEGMENT_INFORMATION.BytesCommitted (first field), relative to QueryResult.
        public const int ResultOffsetProcessSegmentBytesCommitted = 0;
        // D3DKMT_QUERYSTATISTICS_TYPE members used here.
        public const int QueryTypeAdapter = 0;
        public const int QueryTypeSegment = 3;
        public const int QueryTypeProcessSegment = 4;
        // D3DKMT_MAX_SEGMENT_COUNT in d3dkmthk.h; a larger NbSegments is treated as an unexpected answer.
        public const int MaxSegments = 32;

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll", EntryPoint="D3DKMTQueryStatistics", ExactSpelling=true)]
        private static extern int QueryStatistics(IntPtr data);

        public static bool LayoutIsExpected() {
            return IntPtr.Size == 8 &&
                StatisticsSize == 0x328 && StatisticsSize % 8 == 0 &&
                OffsetType == 0 && OffsetAdapterLuid == OffsetType + 4 && OffsetProcessHandle == OffsetAdapterLuid + 8 + 4 &&
                OffsetQueryResult == OffsetProcessHandle + 8 && OffsetQueryResult % 8 == 0 &&
                QueryResultSize % 8 == 0 && OffsetSegmentId == OffsetQueryResult + QueryResultSize &&
                OffsetSegmentId + 4 <= StatisticsSize && StatisticsSize - (OffsetSegmentId + 4) < 8 &&
                ResultOffsetNbSegments + 4 <= QueryResultSize &&
                ResultOffsetSegmentBytesCommitted + 8 <= ResultOffsetAperture && ResultOffsetAperture + 4 <= QueryResultSize &&
                ResultOffsetProcessSegmentBytesCommitted + 8 <= QueryResultSize;
        }

        // Aperture segments count as shared, every other segment as dedicated. False on mismatched input or when a sum would overflow.
        public static bool TrySplit(IList<bool> aperture, IList<ulong> bytes, out ulong dedicated, out ulong shared) {
            dedicated = 0; shared = 0;
            if (aperture == null || bytes == null || aperture.Count != bytes.Count) return false;
            ulong d = 0, s = 0;
            try {
                checked {
                    for (int i=0;i<bytes.Count;i++) { if (aperture[i]) s += bytes[i]; else d += bytes[i]; }
                }
            } catch (OverflowException) { return false; }
            dedicated = d; shared = s;
            return true;
        }

        // The same read, bounded in time: it runs on a background thread and the caller waits at most timeoutMs. A read that has not
        // finished by then is reported as read-timeout (the thread is left to finish on its own and never keeps the process alive).
        // Never throws: every failure becomes a short error code on the observation.
        public static GpuProcessMemoryObservation ReadWithin(string luidHex, Process process, int timeoutMs) {
            GpuProcessMemoryObservation observation = null;
            string failure = null;
            var worker = new System.Threading.Thread(delegate() {
                try { observation = Read(luidHex, process); }
                catch (PlatformNotSupportedException) { failure = "not-windows"; }
                catch (Exception) { failure = "read-failed"; }
            });
            worker.IsBackground = true;
            worker.Start();
            if (timeoutMs < 1) timeoutMs = 1;
            if (!worker.Join(timeoutMs)) return new GpuProcessMemoryObservation { Luid = luidHex, Error = "read-timeout" };
            if (observation != null) return observation;
            return new GpuProcessMemoryObservation { Luid = luidHex, Error = failure ?? "read-failed" };
        }

        private static string Status(string step, int status) { return step + "-ntstatus-" + ((uint)status).ToString("x8"); }

        private static void Prepare(IntPtr buffer, int type, uint low, int high, IntPtr process, int segmentId) {
            for (int i=0;i<StatisticsSize;i+=8) Marshal.WriteInt64(buffer,i,0);
            Marshal.WriteInt32(buffer,OffsetType,type);
            Marshal.WriteInt32(buffer,OffsetAdapterLuid,unchecked((int)low));
            Marshal.WriteInt32(buffer,OffsetAdapterLuid+4,high);
            Marshal.WriteInt64(buffer,OffsetProcessHandle,process.ToInt64());
            Marshal.WriteInt32(buffer,OffsetSegmentId,segmentId);
        }

        public static GpuProcessMemoryObservation Read(string luidHex, Process process) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT || IntPtr.Size != 8)
                throw new PlatformNotSupportedException("GPU process-memory query requires 64-bit Windows.");
            if (luidHex == null || luidHex.Length != 16) throw new ArgumentException("DXGI LUID must be 16 hexadecimal digits.", "luidHex");
            if (process == null) throw new ArgumentNullException("process");
            uint high, low;
            if (!UInt32.TryParse(luidHex.Substring(0,8), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out high) ||
                !UInt32.TryParse(luidHex.Substring(8,8), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out low))
                throw new ArgumentException("DXGI LUID must be 16 hexadecimal digits.", "luidHex");
            var result = new GpuProcessMemoryObservation { Luid=luidHex.ToLowerInvariant() };
            if (!LayoutIsExpected()) { result.Error="layout-unexpected"; return result; }
            IntPtr handle;
            try { result.ProcessId = process.Id; handle = process.Handle; }
            catch (Exception) { result.Error="process-handle-unavailable"; return result; }
            int highSigned = unchecked((int)high);
            IntPtr buffer = IntPtr.Zero;
            try {
                buffer = Marshal.AllocHGlobal(StatisticsSize);
                Prepare(buffer, QueryTypeAdapter, low, highSigned, IntPtr.Zero, 0);
                int status = QueryStatistics(buffer);
                if (status != 0) { result.Error=Status("query-adapter", status); return result; }
                int count = Marshal.ReadInt32(buffer, OffsetQueryResult + ResultOffsetNbSegments);
                if (count < 0 || count > MaxSegments) { result.Error="segment-count-unexpected"; return result; }
                result.SegmentCount = count;
                var aperture = new List<bool>(count);
                var committed = new List<ulong>(count);
                for (int id=0; id<count; id++) {
                    Prepare(buffer, QueryTypeSegment, low, highSigned, IntPtr.Zero, id);
                    status = QueryStatistics(buffer);
                    if (status != 0) { result.Error=Status("query-segment", status); return result; }
                    bool isAperture = Marshal.ReadInt32(buffer, OffsetQueryResult + ResultOffsetAperture) != 0;
                    Prepare(buffer, QueryTypeProcessSegment, low, highSigned, handle, id);
                    status = QueryStatistics(buffer);
                    if (status != 0) { result.Error=Status("query-process-segment", status); return result; }
                    aperture.Add(isAperture);
                    committed.Add(unchecked((ulong)Marshal.ReadInt64(buffer, OffsetQueryResult + ResultOffsetProcessSegmentBytesCommitted)));
                    if (isAperture) result.ApertureSegmentCount++;
                }
                ulong dedicated, shared;
                if (!TrySplit(aperture, committed, out dedicated, out shared)) { result.Error="sum-overflow"; return result; }
                result.DedicatedBytes = dedicated; result.SharedBytes = shared;
                return result;
            } finally {
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
