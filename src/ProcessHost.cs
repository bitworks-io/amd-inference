using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;

namespace Bitworks.FastLlm {
    // No shell, bounded in-memory output, and no PowerShell callbacks on native threads.
    public sealed class ProcessHost : IDisposable {
        public readonly Process Process = new Process();
        private readonly StringBuilder output = new StringBuilder();
        private readonly StringBuilder placementOutput = new StringBuilder();
        private readonly StringBuilder startupOutput = new StringBuilder();
        private readonly StringBuilder selectedDeviceOutput = new StringBuilder();
        private readonly object sync = new object();
        private static readonly Regex OffloadLine = new Regex(@"load_tensors:\s+offloaded\s+([0-9]+)/([0-9]+)\s+layers to GPU\s*$", RegexOptions.CultureInvariant);
        private static readonly Regex BufferLine = new Regex(@"load_tensors:\s+(Vulkan[0-9]+|ROCm[0-9]+)\s+model buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?)\s+MiB\s*$", RegexOptions.CultureInvariant);
        // The pinned b10698 loader prints the backend buffer name and a numeric MiB size.
        // Keep CPU evidence separate from the normal all-GPU placement allowlist.
        private static readonly Regex CpuBufferLine = new Regex(@"load_tensors:\s+(CPU|CPU_Mapped)\s+model buffer size\s*=\s*([0-9]{1,32}(?:\.[0-9]{1,32})?)\s+MiB\s*$", RegexOptions.CultureInvariant);
        private static readonly Regex CpuBufferLikeLine = new Regex(@"load_tensors:\s+CPU(?:_Mapped)?\s+model buffer size\b", RegexOptions.CultureInvariant);
        // Exact b10698 INFO formats in llama-kv-cache.cpp and llama-context.cpp.
        // Normalize only device names and numeric/enum values, never paths or text.
        private static readonly Regex KvLine = new Regex(@"llama_[A-Za-z0-9_]+:\s+(Vulkan[0-9]+|ROCm[0-9]+|CPU(?:_[A-Za-z0-9]+)?)\s+KV buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?)\s+MiB\s*$", RegexOptions.CultureInvariant);
        private static readonly Regex ComputeLine = new Regex(@"sched_reserve:\s+(Vulkan[0-9]+|ROCm[0-9]+|CPU(?:_[A-Za-z0-9]+)?)\s+compute buffer size\s*=\s*([0-9]+(?:\.[0-9]+)?)\s+MiB\s*$", RegexOptions.CultureInvariant);
        private static readonly Regex FlashModeLine = new Regex(@"llama_context:\s+flash_attn\s*=\s*(auto|enabled|disabled)\s*$", RegexOptions.CultureInvariant);
        private static readonly Regex FlashResolvedLine = new Regex(@"resolve_fused_ops:\s+Flash Attention (enabled|not supported, set to disabled)\s*$", RegexOptions.CultureInvariant);
        // b10698 src/llama.cpp llama_prepare_model_devices logs the devices selected by
        // this model load. Vulkan's device_id is a full BDF when VK_EXT_pci_bus_info
        // is available. Retain only the backend name and BDF, never the description.
        private static readonly Regex SelectedDeviceLine = new Regex(@"llama_prepare_model_devices:\s+using device\s+(Vulkan[0-9]{1,2})\s+\(.{1,512}\)\s+\(([0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7])\)\s+-\s+[0-9]{1,12}\s+MiB free\s*$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
        private static readonly Regex SelectedDeviceUnknownIdLine = new Regex(@"llama_prepare_model_devices:\s+using device\s+Vulkan[0-9]{1,2}\s+\(.{1,512}\)\s+\(unknown id\)\s+-\s+[0-9]{1,12}\s+MiB free\s*$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
        private int placementLines, placementDropped, tensorLines, offloadLikeLines, bufferLikeLines, cpuBufferLikeLines;
        private int startupLines, startupDropped;
        private int selectedDeviceLikeLines, selectedDeviceLines, selectedDeviceDropped, selectedDeviceMalformed, selectedDeviceUnknownId, selectedDeviceBadFormat;
        private bool startupFrozen;
        private bool selectedDeviceFrozen;
        private bool outputTruncated;
        private bool stdoutCompleted, stderrCompleted;
        private bool discard;
        private IntPtr job;
        public void Start(ProcessStartInfo info) {
            info.UseShellExecute = false;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.CreateNoWindow = true;
            Process.StartInfo = info;
            Process.OutputDataReceived += CaptureOutput;
            Process.ErrorDataReceived += CaptureError;
            if (!Process.Start()) throw new InvalidOperationException("Child process did not start.");
            try {
                if (Environment.OSVersion.Platform == PlatformID.Win32NT) {
                    job = CreateJobObject(IntPtr.Zero, null);
                    if (job == IntPtr.Zero) throw new InvalidOperationException("Cannot create process job.");
                    JobLimits limits = new JobLimits();
                    limits.Basic.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
                    if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JobLimits))) ||
                        !AssignProcessToJobObject(job, Process.Handle))
                        throw new InvalidOperationException("Cannot contain child process in a Windows job.");
                }
                Process.BeginOutputReadLine();
                Process.BeginErrorReadLine();
            } catch { Dispose(); throw; }
        }
        private void CaptureOutput(object sender, DataReceivedEventArgs args) {
            if (args.Data == null) { lock (sync) { stdoutCompleted = true; } return; }
            Capture(sender, args);
        }
        private void CaptureError(object sender, DataReceivedEventArgs args) {
            if (args.Data == null) { lock (sync) { stderrCompleted = true; } return; }
            Capture(sender, args);
        }
        private void Capture(object sender, DataReceivedEventArgs args) {
            lock (sync) {
                if (discard) return;
                string line = args.Data.Length > 8192 ? args.Data.Substring(0, 8192) : args.Data;
                if (args.Data.IndexOf("load_tensors:", StringComparison.Ordinal) >= 0) {
                    tensorLines++;
                    if (args.Data.IndexOf("offloaded", StringComparison.Ordinal) >= 0) offloadLikeLines++;
                    if (args.Data.IndexOf("model buffer size", StringComparison.Ordinal) >= 0) bufferLikeLines++;
                    if (CpuBufferLikeLine.IsMatch(line)) cpuBufferLikeLines++;
                }
                Match offload = OffloadLine.Match(line);
                Match buffer = BufferLine.Match(line);
                Match cpuBuffer = CpuBufferLine.Match(line);
                if (!selectedDeviceFrozen && args.Data.IndexOf("llama_prepare_model_devices:", StringComparison.Ordinal) >= 0 &&
                    args.Data.IndexOf("using device", StringComparison.Ordinal) >= 0) {
                    selectedDeviceLikeLines++;
                    try {
                        Match selected = args.Data.Length <= 8192 ? SelectedDeviceLine.Match(line) : null;
                        if (selected == null || !selected.Success) {
                            bool unknownId = args.Data.Length <= 8192 && SelectedDeviceUnknownIdLine.IsMatch(line);
                            selectedDeviceMalformed++;
                            if (unknownId) selectedDeviceUnknownId++;
                            else selectedDeviceBadFormat++;
                        }
                        else if (selectedDeviceLines < 16) {
                            selectedDeviceOutput.Append("selected-device ").Append(selected.Groups[1].Value).Append(' ')
                                .AppendLine(selected.Groups[2].Value.ToLowerInvariant());
                            selectedDeviceLines++;
                        } else selectedDeviceDropped++;
                    } catch (RegexMatchTimeoutException) { selectedDeviceMalformed++; selectedDeviceBadFormat++; }
                }
                if (offload.Success || buffer.Success || cpuBuffer.Success) {
                    if (placementLines < 64) {
                        if (offload.Success)
                            placementOutput.Append("load_tensors: offloaded ").Append(offload.Groups[1].Value).Append('/').Append(offload.Groups[2].Value).AppendLine(" layers to GPU");
                        else if (buffer.Success)
                            placementOutput.Append("load_tensors: ").Append(buffer.Groups[1].Value).Append(" model buffer size = ").Append(buffer.Groups[2].Value).AppendLine(" MiB");
                        else
                            placementOutput.Append("load_tensors: ").Append(cpuBuffer.Groups[1].Value).Append(" model buffer size = ").Append(cpuBuffer.Groups[2].Value).AppendLine(" MiB");
                        placementLines++;
                    } else placementDropped++;
                }
                if (!startupFrozen) {
                    Match kv = KvLine.Match(line), compute = ComputeLine.Match(line);
                    Match flashMode = FlashModeLine.Match(line), flashResolved = FlashResolvedLine.Match(line);
                    string normalized = null;
                    if (kv.Success) normalized = "kv " + kv.Groups[1].Value + " " + kv.Groups[2].Value;
                    else if (compute.Success) normalized = "compute " + compute.Groups[1].Value + " " + compute.Groups[2].Value;
                    else if (flashMode.Success) normalized = "flash-mode " + flashMode.Groups[1].Value;
                    else if (flashResolved.Success) normalized = "flash-resolved " + (flashResolved.Groups[1].Value == "enabled" ? "enabled" : "disabled");
                    if (normalized != null) {
                        if (startupLines < 32 && startupOutput.Length + normalized.Length + 1 <= 4096) {
                            startupOutput.AppendLine(normalized);
                            startupLines++;
                        } else startupDropped++;
                    }
                }
                output.AppendLine(line);
                if (output.Length > 262144) { output.Remove(0, output.Length - 262144); outputTruncated = true; }
            }
        }
        public string Snapshot() { lock (sync) { return output.ToString(); } }
        public bool OutputCompleted { get { lock (sync) { return stdoutCompleted && stderrCompleted; } } }
        public bool OutputTruncated { get { lock (sync) { return outputTruncated; } } }
        public string PlacementSnapshot() { lock (sync) { return placementOutput.ToString(); } }
        public string FreezeStartupDiagnostics() { lock (sync) { startupFrozen = true; return startupOutput.ToString(); } }
        public string FreezeSelectedDeviceIdentity() { lock (sync) { selectedDeviceFrozen = true; return selectedDeviceOutput.ToString(); } }
        public int SelectedDeviceLikeLines { get { lock (sync) { return selectedDeviceLikeLines; } } }
        public int SelectedDeviceMalformedLines { get { lock (sync) { return selectedDeviceMalformed; } } }
        public int SelectedDeviceUnknownIdLines { get { lock (sync) { return selectedDeviceUnknownId; } } }
        public int SelectedDeviceBadFormatLines { get { lock (sync) { return selectedDeviceBadFormat; } } }
        public bool SelectedDeviceIdentityOverflow { get { lock (sync) { return selectedDeviceDropped != 0; } } }
        public string SelectedDeviceIdentityDiagnostics() {
            lock (sync) {
                return String.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "like={0}, captured={1}, malformed={2}, unknownId={3}, badFormat={4}, dropped={5}",
                    selectedDeviceLikeLines, selectedDeviceLines, selectedDeviceMalformed,
                    selectedDeviceUnknownId, selectedDeviceBadFormat, selectedDeviceDropped);
            }
        }
        public bool StartupDiagnosticsOverflow { get { lock (sync) { return startupDropped != 0; } } }
        public bool PlacementOverflow { get { lock (sync) { return placementDropped != 0; } } }
        public int CpuBufferLikeLines { get { lock (sync) { return cpuBufferLikeLines; } } }
        public string PlacementDiagnostics() {
            lock (sync) {
                return String.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "tensorLines={0}, offloadLike={1}, bufferLike={2}, captured={3}, dropped={4}, generalOutputTruncated={5}",
                    tensorLines, offloadLikeLines, bufferLikeLines, placementLines, placementDropped, outputTruncated);
            }
        }
        public void DiscardOutput() { lock (sync) { discard = true; output.Clear(); } }
        public void Dispose() {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            try {
                if (!Process.HasExited) {
                    var killTree = typeof(Process).GetMethod("Kill", new Type[] { typeof(bool) });
                    if (killTree != null) killTree.Invoke(Process, new object[] { true });
                    else Process.Kill();
                    Process.WaitForExit(5000);
                }
            } catch (InvalidOperationException) { }
            finally { Process.Dispose(); }
        }
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
            public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
        }
        [StructLayout(LayoutKind.Sequential)] private struct JobLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll")] private static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits info, uint length);
        [DllImport("kernel32.dll")] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    }

    public sealed class HttpResult {
        public string Body;
        public int Status;
        public double ElapsedMs;
        public string[] Events;
        public double[] EventTimesMs;
    }
    public static class LoopbackHttp {
        public static HttpResult Request(string url, string body, int timeoutMs, int maxBytes) {
            Uri uri = new Uri(url);
            if (uri.Scheme != "http" || uri.Host != "127.0.0.1" || !String.IsNullOrEmpty(uri.UserInfo))
                throw new ArgumentException("Only literal IPv4 loopback HTTP is permitted.");
            var timer = Stopwatch.StartNew();
            // A scoped unnumbered pragma also works with the .NET Framework C# compiler.
#pragma warning disable
            var request = (HttpWebRequest)WebRequest.Create(uri);
#pragma warning restore
            request.Proxy = null;
            request.AllowAutoRedirect = false;
            request.Timeout = timeoutMs;
            request.ReadWriteTimeout = timeoutMs;
            request.KeepAlive = false;
            using (var deadline = new System.Threading.Timer(delegate { request.Abort(); }, null, timeoutMs, System.Threading.Timeout.Infinite)) {
            // Windows PowerShell 5.1 can marshal a PowerShell $null argument
            // to an empty C# string. Treat both as a bodyless GET.
            if (!String.IsNullOrEmpty(body)) {
                byte[] bytes = Encoding.UTF8.GetBytes(body);
                request.Method = "POST";
                request.ContentType = "application/json";
                request.ContentLength = bytes.Length;
                using (var stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
            }
            HttpWebResponse response;
            try { response = (HttpWebResponse)request.GetResponse(); }
            catch (WebException error) {
                if (error.Response == null) throw;
                response = (HttpWebResponse)error.Response;
            }
            using (response)
            using (var stream = response.GetResponseStream())
            using (var memory = new MemoryStream()) {
                var events = new List<string>();
                var eventTimes = new List<double>();
                var pending = new StringBuilder();
                var decoder = Encoding.UTF8.GetDecoder();
                char[] chars = new char[4096];
                byte[] buffer = new byte[4096];
                while (true) {
                    if (timer.ElapsedMilliseconds > timeoutMs) { request.Abort(); throw new TimeoutException("HTTP deadline exceeded."); }
                    int count = stream.Read(buffer, 0, buffer.Length);
                    if (count == 0) break;
                    if (memory.Length + count > maxBytes) { request.Abort(); throw new InvalidDataException("HTTP response exceeds limit."); }
                    memory.Write(buffer, 0, count);
                    int decoded = decoder.GetChars(buffer, 0, count, chars, 0);
                    for (int i=0; i<decoded; i++) {
                        if (chars[i] == '\n') {
                            string line = pending.ToString().TrimEnd('\r'); pending.Clear();
                            if (line.StartsWith("data: ", StringComparison.Ordinal)) {
                                events.Add(line.Substring(6)); eventTimes.Add(timer.Elapsed.TotalMilliseconds);
                            }
                        } else pending.Append(chars[i]);
                    }
                }
                return new HttpResult { Status = (int)response.StatusCode, Body = Encoding.UTF8.GetString(memory.ToArray()), ElapsedMs = timer.Elapsed.TotalMilliseconds, Events=events.ToArray(), EventTimesMs=eventTimes.ToArray() };
            }
            }
        }
    }
}
