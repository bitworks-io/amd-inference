using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace FastLlmTests {
    // In-process loopback mock for the W11 context-ladder tests. Separate from MockServer.cs on purpose.
    // The "tokenizer" counts alphanumeric words (JSON escapes count as whitespace), so token counts are deterministic.
    // Configuration is public static state, reset between test cases with Reset(). Compiles under C# 5.
    public static class ContextLadderMockServer {
        public static int NContext;
        public static int TotalSlots;
        public static int PropsStatus;
        public static int ApplyTemplateStatus;
        public static int TokenizeStatus;
        public static bool MetricsEnabled;
        public static long MetricsPromptTotal;
        public static long MetricsPredictedTotal;
        public static int CompletionStatus;
        public static int CompletionDelayMs;
        public static int PromptNDelta;
        public static int PredictedNOverride;
        public static string StopType;
        public static bool Truncated;
        public static bool ContextShift;
        public static int EarlyEosOrdinal;
        public static int ChatStatus;
        public static int ChatDelayMs;
        public static string ChatMode;
        public static int UsageDelta;
        public static string StatusPath;
        public static int IdentityChangeAfter;
        public static string IdentityFrom;
        public static string IdentityTo;

        private static readonly object Gate = new object();
        private static TcpListener listener;
        private static Thread loop;
        private static int completionCount;
        private static int workloadCount;
        private static int epoch;
        private static List<string> log = new List<string>();
        private static List<int> promptLengths = new List<int>();
        private static List<string> seenCodes = new List<string>();

        public static void Reset() {
            lock (Gate) {
                NContext = 4096; TotalSlots = 1; PropsStatus = 200; ApplyTemplateStatus = 200; TokenizeStatus = 200;
                MetricsEnabled = true; MetricsPromptTotal = 0; MetricsPredictedTotal = 0;
                CompletionStatus = 200; CompletionDelayMs = 0; PromptNDelta = 0; PredictedNOverride = -1;
                StopType = "limit"; Truncated = false; ContextShift = false; EarlyEosOrdinal = 0;
                ChatStatus = 200; ChatDelayMs = 0; ChatMode = "echo"; UsageDelta = 0;
                StatusPath = null; IdentityChangeAfter = 0; IdentityFrom = null; IdentityTo = null;
                completionCount = 0; workloadCount = 0; epoch++;
                log = new List<string>(); promptLengths = new List<int>(); seenCodes = new List<string>();
            }
        }

        public static int Start() {
            Reset();
            if (listener != null) return ((IPEndPoint)listener.LocalEndpoint).Port;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            loop = new Thread(AcceptLoop);
            loop.IsBackground = true;
            loop.Start();
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }

        public static string[] GetLog() { lock (Gate) { return log.ToArray(); } }
        public static int[] GetPromptLengths() { lock (Gate) { return promptLengths.ToArray(); } }
        public static string[] GetSeenCodes() { lock (Gate) { return seenCodes.ToArray(); } }
        public static int CountLog(string path) {
            int n = 0;
            lock (Gate) { foreach (string entry in log) { if (entry == path) n++; } }
            return n;
        }

        private static void AcceptLoop() {
            while (true) {
                TcpClient client = null;
                try { client = listener.AcceptTcpClient(); }
                catch (SocketException) { return; }
                catch (ObjectDisposedException) { return; }
                ThreadPool.QueueUserWorkItem(Handle, client);
            }
        }

        private static int IndexOfHeaderEnd(byte[] data, int length) {
            for (int i = 0; i + 3 < length; i++) {
                if (data[i] == 13 && data[i + 1] == 10 && data[i + 2] == 13 && data[i + 3] == 10) return i;
            }
            return -1;
        }

        private static void Handle(object state) {
            TcpClient client = (TcpClient)state;
            try {
                using (client) {
                    client.ReceiveTimeout = 5000;
                    NetworkStream stream = client.GetStream();
                    byte[] buffer = new byte[8192];
                    MemoryStream memory = new MemoryStream();
                    int headerEnd = -1;
                    while (headerEnd < 0) {
                        int n = stream.Read(buffer, 0, buffer.Length);
                        if (n <= 0) return;
                        memory.Write(buffer, 0, n);
                        headerEnd = IndexOfHeaderEnd(memory.GetBuffer(), (int)memory.Length);
                    }
                    string head = Encoding.ASCII.GetString(memory.GetBuffer(), 0, headerEnd);
                    string[] requestLine = head.Split('\n')[0].Trim().Split(' ');
                    string method = requestLine[0];
                    string path = requestLine[1];
                    int q = path.IndexOf('?');
                    if (q >= 0) path = path.Substring(0, q);
                    Match lengthMatch = Regex.Match(head, "(?im)^Content-Length:\\s*(\\d+)");
                    int length = lengthMatch.Success ? Int32.Parse(lengthMatch.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
                    int bodyStart = headerEnd + 4;
                    while (memory.Length - bodyStart < length) {
                        int n = stream.Read(buffer, 0, buffer.Length);
                        if (n <= 0) break;
                        memory.Write(buffer, 0, n);
                    }
                    string body = Encoding.UTF8.GetString(memory.GetBuffer(), bodyStart, (int)Math.Min(length, memory.Length - bodyStart));
                    Route(stream, method, path, body);
                }
            } catch (IOException) {
            } catch (SocketException) {
            } catch (ObjectDisposedException) {
            }
        }

        private static void Record(string entry) { lock (Gate) { log.Add(entry); } }

        private static void Send(NetworkStream stream, int status, string body, string contentType) {
            byte[] bytes = Encoding.UTF8.GetBytes(body);
            string header = "HTTP/1.1 " + status.ToString(CultureInfo.InvariantCulture) + " Mock\r\nContent-Length: " +
                bytes.Length.ToString(CultureInfo.InvariantCulture) + "\r\nContent-Type: " + contentType + "\r\nConnection: close\r\n\r\n";
            byte[] headerBytes = Encoding.ASCII.GetBytes(header);
            stream.Write(headerBytes, 0, headerBytes.Length);
            stream.Write(bytes, 0, bytes.Length);
        }

        private static string ExtractRawContent(string body) {
            Match m = Regex.Match(body ?? "", "\"content\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
            return m.Success ? m.Groups[1].Value : "";
        }

        // JSON escape sequences count as separators; a "token" is a run of ASCII letters or digits.
        private static int CountTokens(string rawJsonText) {
            string flattened = Regex.Replace(rawJsonText ?? "", "\\\\(u[0-9a-fA-F]{4}|.)", " ");
            return Regex.Matches(flattened, "[A-Za-z0-9]+").Count;
        }

        private static string Escape(string text) {
            return (text ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "\\r");
        }

        private static void MaybeChangeIdentity() {
            string path; string from; string to; int after; int count;
            lock (Gate) { path = StatusPath; from = IdentityFrom; to = IdentityTo; after = IdentityChangeAfter; count = workloadCount; }
            if (path == null || after <= 0 || count != after) return;
            string text = File.ReadAllText(path);
            string changed = text.Replace(from, to);
            string temporary = path + ".swap";
            File.WriteAllText(temporary, changed);
            File.Replace(temporary, path, null);
        }

        private static void Route(NetworkStream stream, string method, string path, string body) {
            if (path == "/props") {
                Record("/props");
                if (PropsStatus != 200) { Send(stream, PropsStatus, "{}", "application/json"); return; }
                Send(stream, 200, "{\"default_generation_settings\":{\"n_ctx\":" + NContext.ToString(CultureInfo.InvariantCulture) +
                    "},\"total_slots\":" + TotalSlots.ToString(CultureInfo.InvariantCulture) + "}", "application/json");
                return;
            }
            if (path == "/metrics") {
                Record("/metrics");
                if (!MetricsEnabled) { Send(stream, 404, "{}", "application/json"); return; }
                long prompt; long predicted;
                lock (Gate) { prompt = MetricsPromptTotal; predicted = MetricsPredictedTotal; }
                string text = "# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.\n" +
                    "# TYPE llamacpp:prompt_tokens_total counter\n" +
                    "llamacpp:prompt_tokens_total " + prompt.ToString(CultureInfo.InvariantCulture) + "\n" +
                    "# TYPE llamacpp:tokens_predicted_total counter\n" +
                    "llamacpp:tokens_predicted_total " + predicted.ToString(CultureInfo.InvariantCulture) + "\n" +
                    "# TYPE llamacpp:kv_cache_usage_ratio gauge\n" +
                    "llamacpp:kv_cache_usage_ratio 0.25\n" +
                    "llamacpp:kv_cache_tokens 512\n";
                Send(stream, 200, text, "text/plain; version=0.0.4");
                return;
            }
            if (path == "/tokenize") {
                Record("/tokenize");
                if (TokenizeStatus != 200) { Send(stream, TokenizeStatus, "{}", "application/json"); return; }
                int count = CountTokens(ExtractRawContent(body));
                StringBuilder ids = new StringBuilder("{\"tokens\":[");
                for (int i = 1; i <= count; i++) { if (i > 1) ids.Append(','); ids.Append(i.ToString(CultureInfo.InvariantCulture)); }
                ids.Append("]}");
                Send(stream, 200, ids.ToString(), "application/json");
                return;
            }
            if (path == "/apply-template") {
                Record("/apply-template");
                if (ApplyTemplateStatus != 200) { Send(stream, ApplyTemplateStatus, "{}", "application/json"); return; }
                Send(stream, 200, "{\"prompt\":\"TPLBEGIN " + ExtractRawContent(body) + " TPLEND\"}", "application/json");
                return;
            }
            if (path == "/completion") { Completion(stream, body); return; }
            if (path == "/v1/chat/completions") { Chat(stream, body); return; }
            Record(path);
            Send(stream, 404, "{}", "application/json");
        }

        private static void Completion(NetworkStream stream, string body) {
            int ordinal; int myEpoch;
            lock (Gate) { completionCount++; workloadCount++; ordinal = completionCount; log.Add("/completion"); myEpoch = epoch; }
            Match promptMatch = Regex.Match(body, "\"prompt\"\\s*:\\s*\\[([^\\]]*)\\]");
            int promptLength = 0;
            if (promptMatch.Success && promptMatch.Groups[1].Value.Trim().Length > 0) promptLength = promptMatch.Groups[1].Value.Split(',').Length;
            lock (Gate) { promptLengths.Add(promptLength); }
            Match predictMatch = Regex.Match(body, "\"n_predict\"\\s*:\\s*(\\d+)");
            int nPredict = predictMatch.Success ? Int32.Parse(predictMatch.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
            if (CompletionDelayMs > 0) Thread.Sleep(CompletionDelayMs);
            if (myEpoch != epoch) return;
            int status = CompletionStatus;
            int predicted = PredictedNOverride >= 0 ? PredictedNOverride : nPredict;
            string stopType = StopType;
            if (ordinal == EarlyEosOrdinal) { predicted = Math.Max(1, nPredict / 2); stopType = "eos"; }
            int promptN = promptLength + PromptNDelta;
            lock (Gate) { MetricsPromptTotal += promptN; MetricsPredictedTotal += predicted; }
            MaybeChangeIdentity();
            if (status != 200) { Send(stream, status, "{}", "application/json"); return; }
            CultureInfo ci = CultureInfo.InvariantCulture;
            string promptMs = (100.0 + promptN / 10.0).ToString("0.###", ci);
            string predictedMs = (predicted * 10.0).ToString("0.###", ci);
            string final = "{\"content\":\"\",\"stop\":true,\"stop_type\":\"" + stopType + "\",\"truncated\":" + (Truncated ? "true" : "false") +
                (ContextShift ? ",\"context_shift\":true" : "") +
                ",\"tokens_evaluated\":" + promptN.ToString(ci) + ",\"tokens_predicted\":" + predicted.ToString(ci) +
                ",\"timings\":{\"prompt_n\":" + promptN.ToString(ci) + ",\"prompt_ms\":" + promptMs +
                ",\"predicted_n\":" + predicted.ToString(ci) + ",\"predicted_ms\":" + predictedMs + "}}";
            string text = "data: {\"content\":\"x\",\"stop\":false}\n\ndata: " + final + "\n\ndata: [DONE]\n\n";
            Send(stream, 200, text, "text/event-stream");
        }

        private static void Chat(NetworkStream stream, string body) {
            int myEpoch;
            lock (Gate) { workloadCount++; log.Add("/v1/chat/completions"); myEpoch = epoch; }
            string raw = ExtractRawContent(body);
            foreach (Match m in Regex.Matches(raw, "[A-Z]{2}-[0-9]{4}")) {
                lock (Gate) { if (!seenCodes.Contains(m.Value)) seenCodes.Add(m.Value); }
            }
            if (ChatDelayMs > 0) Thread.Sleep(ChatDelayMs);
            if (myEpoch != epoch) return;
            int promptTokens = CountTokens(raw) + 2 + UsageDelta;
            string needle = "";
            Match needleMatch = Regex.Match(raw, "The vault access code is ([A-Z]{2}-[0-9]{4})");
            if (needleMatch.Success) needle = needleMatch.Groups[1].Value;
            string distractor = "";
            Match distractorMatch = Regex.Match(raw, "The (?!vault)[a-z]+ code is ([A-Z]{2}-[0-9]{4})");
            if (distractorMatch.Success) distractor = distractorMatch.Groups[1].Value;
            string content = needle;
            string extra = "";
            switch (ChatMode) {
                case "period": content = needle + "."; break;
                case "twoperiods": content = needle + ".."; break;
                case "lower": content = needle.ToLowerInvariant(); break;
                case "whitespace": content = "  " + needle + "\n"; break;
                case "distractor": content = distractor; break;
                case "wrong": content = "ZZ-0000"; break;
                case "empty": content = ""; break;
                case "reasoning": extra = ",\"reasoning_content\":\"private thinking\""; break;
                default: break;
            }
            MaybeChangeIdentity();
            if (ChatStatus != 200) { Send(stream, ChatStatus, "{}", "application/json"); return; }
            CultureInfo ci = CultureInfo.InvariantCulture;
            string json = "{\"id\":\"mock\",\"choices\":[{\"index\":0,\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"" +
                Escape(content) + "\"" + extra + "}}],\"usage\":{\"prompt_tokens\":" + promptTokens.ToString(ci) +
                ",\"completion_tokens\":6,\"total_tokens\":" + (promptTokens + 6).ToString(ci) + "}}";
            Send(stream, 200, json, "application/json");
        }
    }
}
