using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace FastLlmTests {
    public static class MockServer {
        // Windows PowerShell 5.1 and PowerShell 7 can format compressed JSON
        // with different whitespace. Match the JSON boolean, not one byte
        // layout, so the no-text canary tests the canary rather than spacing.
        public static bool IsSynchronousChatRequest(string json) {
            return Regex.IsMatch(json ?? "", "\"stream\"\\s*:\\s*false(?:\\s*[,}])", RegexOptions.CultureInvariant);
        }
        private static void Mark(string path, string stage) {
            if (!String.IsNullOrEmpty(path)) File.WriteAllText(path, stage);
        }
        public static void Run(int port, string mode, string model, int context, string diagnosticPath) {
            Run(port, mode, model, context, diagnosticPath, "enforce");
        }
        // API key behaviour, as llama-server has it: with LLAMA_API_KEY in the environment every path except /health needs
        // "Authorization: Bearer <key>" and is answered 401 without it. keyMode changes that for the proof tests:
        //   enforce      the behaviour above (the default)
        //   ignore       the variable is ignored: every request is answered as if no key were set
        //   reject       every request except /health is answered 401, also with the right key
        //   metrics-401  enforce, but /metrics is always answered 401
        // What each request carried (none, ok or wrong; never the key) is appended to <diagnosticPath>.auth.
        // A test may be reading the record while a request arrives (on Windows that is a sharing violation): the write is retried for
        // about a second and then given up, so recording can never fail a request.
        private static void Auth(string path, string line) {
            if (String.IsNullOrEmpty(path)) return;
            for (int attempt = 0; attempt < 100; attempt++) {
                try { File.AppendAllText(path + ".auth", line + "\n"); return; }
                catch (IOException) { System.Threading.Thread.Sleep(10); }
                catch (UnauthorizedAccessException) { System.Threading.Thread.Sleep(10); }
            }
        }
        public static void Run(int port, string mode, string model, int context, string diagnosticPath, string keyMode) {
            string apiKey = Environment.GetEnvironmentVariable("LLAMA_API_KEY");
            bool hasKey = !String.IsNullOrEmpty(apiKey);
            Auth(diagnosticPath, "env " + (hasKey ? "key-present" : "key-absent"));
            if (hasKey) {
                // The key reaches a server through its environment only: an argument that holds it ends the mock.
                foreach (string argument in Environment.GetCommandLineArgs())
                    if (argument != null && argument.IndexOf(apiKey, StringComparison.Ordinal) >= 0) { Mark(diagnosticPath, "api-key-in-arguments"); Environment.Exit(75); }
            }
            if (Environment.GetEnvironmentVariable("FASTLLM_TEST_EXPECT_ISOLATION") == "1") {
                foreach (string name in new string[] {"LLAMA_ARG_MODEL", "LLAMA_API_KEY", "GGML_TEST_OVERRIDE", "VK_TEST_OVERRIDE", "HIP_TEST_OVERRIDE", "SMITHY_TEST_OVERRIDE", "AIP_TEST_OVERRIDE"})
                    if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable(name))) { Mark(diagnosticPath, "isolation-variable-present: " + name); Environment.Exit(71); }
                foreach (string name in new string[] {"APPDATA", "PROGRAMDATA"}) {
                    string folder=Environment.GetEnvironmentVariable(name);
                    if (String.IsNullOrEmpty(folder) || !Directory.Exists(folder) || Directory.GetFileSystemEntries(folder).Length != 0) { Mark(diagnosticPath, "isolation-root-not-empty: " + name); Environment.Exit(72); }
                }
            }
            // Policy tests: the supervisor must set (or leave absent) the one mitigation variable AFTER clearing GGML_*.
            string expectVk = Environment.GetEnvironmentVariable("FASTLLM_TEST_EXPECT_VK_HOST_VISIBLE");
            if (!String.IsNullOrEmpty(expectVk)) {
                string actualVk = Environment.GetEnvironmentVariable("GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM");
                bool good = expectVk == "absent" ? String.IsNullOrEmpty(actualVk) : actualVk == expectVk;
                if (!good) { Mark(diagnosticPath, "vk-host-visible-variable-unexpected: expected " + expectVk + " got " + (actualVk ?? "absent")); Environment.Exit(73); }
                foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
                    string key = (string)entry.Key;
                    if (key.StartsWith("GGML_", StringComparison.OrdinalIgnoreCase) && !String.Equals(key, "GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM", StringComparison.OrdinalIgnoreCase)) { Mark(diagnosticPath, "extra-ggml-variable: " + key); Environment.Exit(74); }
                }
            }
            // Run-log privacy tests: "marker-<mode>" behaves as <mode>, but the server echoes every request and response body to stderr
            // (as a verbose llama-server would) and returns a completion marker, so a leak into any FastLLM file is detectable.
            bool echoMarkers = mode.StartsWith("marker-");
            if (echoMarkers) mode = mode.Substring(7);
            // Model switch tests: /metrics reports the four counters the supervisor reads. "busy-<mode>" behaves as <mode> with one request in
            // progress for the whole run, "busy2-<mode>" reports it for the first two reads only, and "nometrics-<mode>" answers /metrics with 404.
            int busyReads = 0;
            bool noMetrics = false;
            if (mode.StartsWith("busy-")) { busyReads = Int32.MaxValue; mode = mode.Substring(5); }
            else if (mode.StartsWith("busy2-")) { busyReads = 2; mode = mode.Substring(6); }
            else if (mode.StartsWith("nometrics-")) { noMetrics = true; mode = mode.Substring(10); }
            if (mode == "exit") Environment.Exit(7);
            Mark(diagnosticPath, "mock-entered");
            Console.Error.WriteLine("load_tensors: offloaded " + (mode == "partial" ? "39" : "41") + "/41 layers to GPU");
            Console.Error.WriteLine("load_tensors: Vulkan0 model buffer size = 1200.00 MiB");
            Console.Error.WriteLine("llama_kv_cache: Vulkan0 KV buffer size = 256.00 MiB");
            Console.Error.WriteLine("sched_reserve: Vulkan0 compute buffer size = 64.00 MiB");
            Console.Error.WriteLine("sched_reserve: Vulkan0 compute buffer size = 777.00 MiB /private/untrusted-text");
            Console.Error.WriteLine("llama_context: flash_attn = auto");
            Console.Error.WriteLine("resolve_fused_ops: Flash Attention enabled");
            // Real b10698 shapes: common_init() prefix (timestamp + level letter) and, for the device_info entry, the "cmn  %12.*s: " tag.
            // LOG_TRC logs at INFO level in b10698, so BOTH the device_info entry and the "using device" line carry level letter I (never D).
            // W03 enforce post-load modes (pl-*) change exactly one property of the default pair so each check of the post-load check fails alone.
            string gpuName = "Vulkan0", gpuDesc = "AMD Radeon RX 7900 XTX", usingName = "Vulkan0", usingId = "0000:03:00.0";
            int gpuTotal = 24560;
            if (mode == "pl-name") { gpuName = "Vulkan1"; usingName = "Vulkan1"; }
            if (mode == "pl-desc") gpuDesc = "AMD Radeon RX 7900 XT";
            if (mode == "pl-total") gpuTotal = 24561;
            if (mode == "pl-using-name") usingName = "Vulkan1";
            if (mode == "pl-ok-unknown") usingId = "unknown id";
            // llama-server prints the last four characters of a single key at startup.
            if (hasKey && keyMode != "ignore") Console.Error.WriteLine("0.00.402.100 I srv          main: api_keys: ****" + apiKey.Substring(Math.Max(apiKey.Length - 4, 0)));
            if (mode != "pl-no-gpu") Console.Error.WriteLine("0.00.402.123 I cmn  common_param:   - " + gpuName + " : " + gpuDesc + " (" + gpuTotal + " MiB, 20304 MiB free)");
            else Console.Error.WriteLine("0.00.402.123 I cmn  common_param:   - CPU : Synthetic CPU (65536 MiB, 32000 MiB free)");
            if (mode == "pl-two-gpu") Console.Error.WriteLine("0.00.402.124 I cmn  common_param:   - Vulkan1 : " + gpuDesc + " (" + gpuTotal + " MiB, 20304 MiB free)");
            if (mode == "pl-malformed") Console.Error.WriteLine("0.00.402.125 I cmn  common_param:   - Vulkan1 : broken (NaN MiB, 5 MiB free)");
            if (mode == "pl-overflow") for (int i = 1; i <= 16; i++) Console.Error.WriteLine("0.00.402.126 I cmn  common_param:   - Vulkan" + i + " : " + gpuDesc + " (" + gpuTotal + " MiB, 20304 MiB free)");
            if (mode != "diagflood" && mode != "pl-using-missing") Console.Error.WriteLine("0.01.234.567 I llama_prepare_model_devices: using device " + usingName + " (" + gpuDesc + ") (" + usingId + ") - 20000 MiB free");
            if (mode == "pl-using-double") Console.Error.WriteLine("0.01.234.568 I llama_prepare_model_devices: using device " + usingName + " (" + gpuDesc + ") (unknown id) - 20000 MiB free");
            if (mode == "diagduplicate") Console.Error.WriteLine("llama_prepare_model_devices: using device Vulkan0 (AMD Radeon) (unknown id) - 20000 MiB free");
            if (mode == "duplicate") Console.Error.WriteLine("load_tensors: offloaded 41/41 layers to GPU");
            if (mode == "diagduplicate") Console.Error.WriteLine("llama_kv_cache: Vulkan0 KV buffer size = 257.00 MiB");
            if (mode == "diagflood") {
                for (int i = 0; i < 50; i++) Console.Error.WriteLine("sched_reserve: CPU_" + i + " compute buffer size = 1.00 MiB");
            }
            if (mode == "flood") {
                for (int i = 0; i < 320; i++) Console.Error.WriteLine(new String('x', 1024));
                System.Threading.Thread.Sleep(500);
            }
            var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            Mark(diagnosticPath, "listener-started");
            int completion = 0;
            while (true) {
                using (var client = listener.AcceptTcpClient()) {
                    try {
                        client.ReceiveTimeout = 2000;
                        using (var stream = client.GetStream()) {
                        var reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true);
                        string first = reader.ReadLine();
                        if (first == null) continue;
                        string method = first.Split(' ')[0];
                        string path = first.Split(' ')[1];
                        int length=0;
                        string line;
                        string authorization=null;
                        while (!String.IsNullOrEmpty(line=reader.ReadLine())) {
                            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length=Int32.Parse(line.Substring(15).Trim());
                            if (line.StartsWith("Authorization:", StringComparison.OrdinalIgnoreCase)) authorization=line.Substring(14).Trim();
                        }
                        string authState = authorization == null ? "none" : (hasKey && authorization == "Bearer " + apiKey ? "ok" : "wrong");
                        Auth(diagnosticPath, method + " " + path + " " + authState);
                        // A verbose server could print request headers: in the marker modes the mock does, so a leak of the key into any FastLLM file is detectable.
                        if (echoMarkers && authorization != null) Console.Error.WriteLine("request header " + path + ": Authorization: " + authorization);
                        var requestBody = new StringBuilder();
                        for (int i=0;i<length;i++) requestBody.Append((char)reader.Read()); // test requests are ASCII
                        int status=200;
                        string body="{}";
                        if (path == "/health") { status=method!="GET" ? 405 : mode=="timeout" ? 503 : 200; body="{\"status\":\"ok\"}"; }
                        if (path == "/metrics") {
                            if (noMetrics) { status = 404; }
                            else {
                                int processing = 0;
                                if (busyReads > 0) { processing = 1; if (busyReads != Int32.MaxValue) busyReads--; }
                                body = "# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.\n# TYPE llamacpp:prompt_tokens_total counter\nllamacpp:prompt_tokens_total 0\n" +
                                    "llamacpp:tokens_predicted_total 0\nllamacpp:requests_processing " + processing + "\nllamacpp:requests_deferred 0\n";
                            }
                        }
                        if (path == "/v1/models") {
                            // This resembles an allowed startup log but occurs during
                            // a canary; the supervisor must already have frozen capture.
                            Console.Error.WriteLine("sched_reserve: Vulkan0 compute buffer size = 999.00 MiB");
                            Console.Error.WriteLine("llama_prepare_model_devices: using device Vulkan1 (canary-time text) (0000:04:00.0) - 20000 MiB free");
                            body="{\"data\":[{\"id\":\"" + model + "\"}]}";
                        }
                        // Slot modes: "slots2" serves two slots with the per-slot context (total / 2); "slots2-total" serves two slots but reports the total.
                        int propsSlots = (mode == "slots2" || mode == "slots2-total") ? 2 : 1;
                        int propsContext = (mode == "context" || mode == "slots2") ? context/2 : context;
                        if (path == "/props") body="{\"default_generation_settings\":{\"n_ctx\":"+propsContext+"},\"total_slots\":"+propsSlots+"}";
                        if (path == "/tokenize") {
                            var ids = new StringBuilder("{\"tokens\":[");
                            for (int i = 0; i < 600; i++) { if (i > 0) ids.Append(','); ids.Append(i + 1); }
                            body = ids.Append("]}").ToString();
                        }
                        bool streamingCompletion = path == "/completion" && Regex.IsMatch(requestBody.ToString(), "\"stream\"\\s*:\\s*true", RegexOptions.CultureInvariant);
                        if (streamingCompletion) {
                            // Throughput-canary workload: 512 prompt tokens, 16 generated; modes pick the prompt_ms timing.
                            if (mode == "canary-fail") { status = 500; body = "{}"; }
                            else {
                                string promptMs = mode == "canary-slow" ? "5000" : "100";
                                // selftest-ok honours the requested n_predict (the post-load self-test asks for 128); every other mode reports 16.
                                int predicted = 16;
                                if (mode == "selftest-ok") {
                                    Match requested = Regex.Match(requestBody.ToString(), "\"n_predict\"\\s*:\\s*(\\d+)", RegexOptions.CultureInvariant);
                                    if (requested.Success) predicted = Int32.Parse(requested.Groups[1].Value);
                                }
                                body = "data: {\"content\":\"x\",\"stop\":false}\n\n" +
                                    "data: {\"content\":\"\",\"stop\":true,\"timings\":{\"prompt_n\":512,\"prompt_ms\":" + promptMs + ",\"predicted_n\":" + predicted + ",\"predicted_ms\":" + (predicted * 10) + "}}\n\n" +
                                    "data: [DONE]\n\n";
                            }
                        }
                        else if (path == "/completion") { if (method!="POST") status=405; completion++; body="{\"tokens\":[" + (mode=="unstable"?completion:42) + "],\"content\":\"Paris\"}"; }
                        if (path == "/v1/chat/completions") {
                            if (IsSynchronousChatRequest(requestBody.ToString()))
                                body="{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\""+(mode=="chat"?"":"Hello")+"\"}}]}";
                            else {
                                body="data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n";
                                if (mode!="sse") body+="data: [DONE]\n\n";
                            }
                        }
                        if (path == "/oversize") body = new String('x', 1048577);
                        if (path == "/stall") System.Threading.Thread.Sleep(10000);
                        if (path == "/redirect") status = 302;
                        if (echoMarkers && path != "/health" && path != "/props" && path != "/tokenize") {
                            body = body.Replace("\"Paris\"", "\"Paris FLLM-MARKER-COMPLETION-7f3a\"").Replace("\"Hello\"", "\"Hello FLLM-MARKER-COMPLETION-7f3a\"").Replace("\"content\":\"x\"", "\"content\":\"FLLM-MARKER-COMPLETION-7f3a\"");
                            Console.Error.WriteLine("request " + path + ": " + requestBody.ToString());
                            Console.Error.WriteLine("response " + path + ": " + body.Replace("\n", " "));
                        }
                        if (hasKey && path != "/health" && keyMode != "ignore" &&
                            (keyMode == "reject" || authState != "ok" || (keyMode == "metrics-401" && path == "/metrics"))) {
                            status = 401;
                            body = "{\"error\":{\"message\":\"Invalid API Key\",\"type\":\"authentication_error\",\"code\":401}}";
                        }
                        var bytes=Encoding.UTF8.GetBytes(body);
                        var header=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" OK\r\n"+(status==302?"Location: https://example.com/\r\n":"")+"Content-Length: "+bytes.Length+"\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n");
                        stream.Write(header,0,header.Length); stream.Write(bytes,0,bytes.Length);
                        }
                    } catch (IOException) {
                        // A timed-out health probe may reset its own connection.
                        // One abandoned client must not terminate the mock server.
                    } catch (SocketException) {
                        // Same per-client disconnect boundary as IOException.
                    }
                }
            }
        }
    }
}
