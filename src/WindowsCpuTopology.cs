using System;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm
{
    // Read-only physical core and package counts from GetLogicalProcessorInformationEx.
    // No CIM or WMI. 64-bit layout only (KAFFINITY is 8 bytes). Parse is pure so a
    // synthesized buffer can be tested without Windows.
    public static class WindowsCpuTopology
    {
        public const int MaximumBufferBytes = 1024 * 1024;
        private const int RelationProcessorCore = 0;
        private const int RelationProcessorPackage = 3;
        private const int ErrorInsufficientBuffer = 122;

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetLogicalProcessorInformationEx(int relationship, IntPtr buffer, ref uint length);

        public sealed class Topology
        {
            public int PhysicalCores { get; set; }
            public int Packages { get; set; }
            public int LogicalProcessors { get; set; }
            public string Source { get { return "GetLogicalProcessorInformationEx.RelationAll"; } }
        }

        private static int PopCount(ulong mask)
        {
            int count = 0;
            while (mask != 0) { count++; mask &= mask - 1; }
            return count;
        }

        // Record layout: int Relationship, int Size, then PROCESSOR_RELATIONSHIP for core/package:
        // byte Flags, byte EfficiencyClass, byte Reserved[20], ushort GroupCount at offset 30,
        // GROUP_AFFINITY GroupMask[GroupCount] at offset 32 (8-byte mask, ushort group, ushort[3]).
        public static Topology Parse(byte[] buffer, int length)
        {
            if (buffer == null || length < 8 || length > buffer.Length || length > MaximumBufferBytes)
                throw new ArgumentException("Processor topology buffer is outside the fixed bound.");
            int position = 0;
            int records = 0;
            Topology result = new Topology();
            while (position < length)
            {
                if (++records > 4096 || length - position < 8)
                    throw new ArgumentException("Processor topology record count or boundary is invalid.");
                int relationship = BitConverter.ToInt32(buffer, position);
                int size = BitConverter.ToInt32(buffer, position + 4);
                if (size < 8 || size > length - position)
                    throw new ArgumentException("Processor topology record exceeds the buffer.");
                if (relationship == RelationProcessorCore || relationship == RelationProcessorPackage)
                {
                    if (size < 32 + 16)
                        throw new ArgumentException("Processor relationship record is too short.");
                    int groups = BitConverter.ToUInt16(buffer, position + 30);
                    if (groups < 1 || groups > 64 || size < 32 + 16 * groups)
                        throw new ArgumentException("Processor relationship group count is invalid.");
                    if (relationship == RelationProcessorCore)
                    {
                        result.PhysicalCores++;
                        for (int g = 0; g < groups; g++)
                            result.LogicalProcessors += PopCount(BitConverter.ToUInt64(buffer, position + 32 + 16 * g));
                    }
                    else
                    {
                        result.Packages++;
                    }
                }
                position += size;
            }
            if (result.PhysicalCores < 1 || result.Packages < 1 || result.LogicalProcessors < result.PhysicalCores)
                throw new ArgumentException("Processor topology contains no usable core or package data.");
            return result;
        }

        public static Topology Read()
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("Processor topology requires Windows.");
            if (IntPtr.Size != 8)
                throw new PlatformNotSupportedException("Processor topology requires 64-bit Windows.");
            uint length = 0;
            GetLogicalProcessorInformationEx(0xffff, IntPtr.Zero, ref length);
            if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer || length < 8 || length > MaximumBufferBytes)
                throw new InvalidOperationException("Processor topology size unavailable or outside the fixed bound.");
            IntPtr memory = Marshal.AllocHGlobal((int)length);
            try
            {
                if (!GetLogicalProcessorInformationEx(0xffff, memory, ref length))
                    throw new InvalidOperationException("Processor topology could not be read.");
                if (length < 8 || length > MaximumBufferBytes)
                    throw new InvalidOperationException("Processor topology size is outside the fixed bound.");
                byte[] bytes = new byte[(int)length];
                Marshal.Copy(memory, bytes, 0, bytes.Length);
                return Parse(bytes, bytes.Length);
            }
            finally { Marshal.FreeHGlobal(memory); }
        }
    }
}
