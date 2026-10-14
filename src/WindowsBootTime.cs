using System;
using System.Runtime.InteropServices;

namespace Bitworks.FastLlm {
    // Read-only system time sources for the Resizable BAR detection cache (boot instant and sleep accounting).
    // No CIM, no WMI, no admin rights. Besides kernel32 it uses the realtime API set (api-ms-win-core-realtime-l1-1-1.dll) for
    // QueryInterruptTime, and LoadLibrary/GetProcAddress/FreeLibrary for the export diagnostic (a transient module handle, no other handles).
    public static class WindowsBootTime {
        [DllImport("kernel32.dll")]
        private static extern ulong GetTickCount64();

        // Interrupt time WITHOUT the time spent asleep or hibernated, in 100 ns units. Returns false on failure.
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryUnbiasedInterruptTime(out ulong unbiasedTime);

        // Interrupt time INCLUDING the time spent asleep or hibernated, in 100 ns units. The function returns void and kernel32.dll
        // does not export it: it lives in the API set api-ms-win-core-realtime-l1-1-1.dll (Windows 10 and later). A missing API set
        // or export surfaces as DllNotFoundException or EntryPointNotFoundException and selects the tick fallback.
        [DllImport("api-ms-win-core-realtime-l1-1-1.dll")]
        private static extern void QueryInterruptTime(out ulong interruptTime);

        // Which path the last SleepDeltaMilliseconds call used: "interrupt-time" or "tick-fallback" (null before the first call).
        private static string sleepDeltaSource;
        public static string SleepDeltaSource { get { return sleepDeltaSource; } }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryW(string fileName);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FreeLibrary(IntPtr module);

        // Diagnostic: true when the API set resolves and exports QueryInterruptTime (checked with GetProcAddress, no call made).
        public static bool QueryInterruptTimeExportPresent() {
            IntPtr module = LoadLibraryW("api-ms-win-core-realtime-l1-1-1.dll");
            if (module == IntPtr.Zero) { return false; }
            try { return GetProcAddress(module, "QueryInterruptTime") != IntPtr.Zero; }
            finally { FreeLibrary(module); }
        }

        public static long UptimeMilliseconds() {
            return unchecked((long)GetTickCount64());
        }

        // Unbiased interrupt time (excludes sleep and hibernation) in 100 ns units. Throws when the call fails.
        public static long QueryUnbiasedInterruptTime100ns() {
            ulong value;
            if (!QueryUnbiasedInterruptTime(out value)) {
                throw new InvalidOperationException("QueryUnbiasedInterruptTime failed (Win32 " + Marshal.GetLastWin32Error() + ").");
            }
            return unchecked((long)value);
        }

        // Sleep and hibernation time in milliseconds: QueryInterruptTime (counts sleep, including a Fast Startup shutdown) minus
        // QueryUnbiasedInterruptTime (does not), both in 100 ns units. It grows by the time the machine spent asleep or
        // hibernated and is otherwise constant, with no tick jitter. When the API set or the QueryInterruptTime export is missing
        // it falls back to GetTickCount64 minus the unbiased time. SleepDeltaSource records which path ran.
        public static long SleepDeltaMilliseconds() {
            // Reset first: a call that throws must never leave the previous call's path in SleepDeltaSource.
            sleepDeltaSource = null;
            long delta;
            try {
                ulong interrupt;
                ulong unbiased;
                QueryInterruptTime(out interrupt);
                if (!QueryUnbiasedInterruptTime(out unbiased)) {
                    throw new InvalidOperationException("QueryUnbiasedInterruptTime failed (Win32 " + Marshal.GetLastWin32Error() + ").");
                }
                delta = (unchecked((long)interrupt) - unchecked((long)unbiased)) / 10000L;
                sleepDeltaSource = "interrupt-time";
            } catch (DllNotFoundException) {
                delta = TickBasedSleepDeltaMilliseconds();
                sleepDeltaSource = "tick-fallback";
            } catch (EntryPointNotFoundException) {
                delta = TickBasedSleepDeltaMilliseconds();
                sleepDeltaSource = "tick-fallback";
            }
            return delta < 0L ? 0L : delta;
        }

        // Fallback: GetTickCount64 minus the unbiased interrupt time, in milliseconds (about 15.6 ms of tick jitter).
        private static long TickBasedSleepDeltaMilliseconds() {
            // Re-read until the tick counter did not move across the unbiased read, so a clock-interrupt update cannot
            // put the two sources one tick (about 15.6 ms) apart.
            long uptime = UptimeMilliseconds();
            long unbiasedMs = QueryUnbiasedInterruptTime100ns() / 10000L;
            for (int attempt = 0; attempt < 5; attempt++) {
                long after = UptimeMilliseconds();
                if (after == uptime) { break; }
                uptime = after;
                unbiasedMs = QueryUnbiasedInterruptTime100ns() / 10000L;
            }
            return uptime - unbiasedMs;
        }

        // Boot instant in UTC ticks, truncated to 10 seconds so repeated calls agree despite clock jitter.
        public static long BootUtcTicksTruncated() {
            long boot = DateTime.UtcNow.Ticks - UptimeMilliseconds() * 10000L;
            return boot - (boot % 100000000L);
        }
    }
}
