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
            if (Environment.GetEnvironmentVariable("FASTLLM_TEST_EXPECT_ISOLATION") == "1") {
                foreach (string name in new string[] {"LLAMA_ARG_MODEL", "GGML_TEST_OVERRIDE", "VK_TEST_OVERRIDE", "HIP_TEST_OVERRIDE", "SMITHY_TEST_OVERRIDE", "AIP_TEST_OVERRIDE"})
                    if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable(name))) { Mark(diagnosticPath, "isolation-variable-present: " + name); Environment.Exit(71); }
                foreach (string name in new string[] {"APPDATA", "PROGRAMDATA"}) {
                    string folder=Environment.GetEnvironmentVariable(name);
                    if (String.IsNullOrEmpty(folder) || !Directory.Exists(folder) || Directory.GetFileSystemEntries(folder).Length != 0) { Mark(diagnosticPath, "isolation-root-not-empty: " + name); Environment.Exit(72); }
                }
            }
            if (mode == "exit") Environment.Exit(7);
            Mark(diagnosticPath, "mock-entered");
            Console.Error.WriteLine("load_tensors: offloaded " + (mode == "partial" ? "39" : "41") + "/41 layers to GPU");
            Console.Error.WriteLine("load_tensors: Vulkan0 model buffer size = 1200.00 MiB");
            Console.Error.WriteLine("llama_kv_cache: Vulkan0 KV buffer size = 256.00 MiB");
            Console.Error.WriteLine("sched_reserve: Vulkan0 compute buffer size = 64.00 MiB");
            Console.Error.WriteLine("sched_reserve: Vulkan0 compute buffer size = 777.00 MiB /private/untrusted-text");
            Console.Error.WriteLine("llama_context: flash_attn = auto");
            Console.Error.WriteLine("resolve_fused_ops: Flash Attention enabled");
            if (mode != "diagflood") Console.Error.WriteLine("llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 20000 MiB free");
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
                    client.ReceiveTimeout = 2000;
                    using (var stream = client.GetStream()) {
                        var reader = new StreamReader(stream, Encoding.UTF8, false, 1024, true);
                        string first = reader.ReadLine();
                        if (first == null) continue;
                        string method = first.Split(' ')[0];
                        string path = first.Split(' ')[1];
                        int length=0;
                        string line;
                        while (!String.IsNullOrEmpty(line=reader.ReadLine())) {
                            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length=Int32.Parse(line.Substring(15).Trim());
                        }
                        var requestBody = new StringBuilder();
                        for (int i=0;i<length;i++) requestBody.Append((char)reader.Read()); // test requests are ASCII
                        int status=200;
                        string body="{}";
                        if (path == "/health") { status=method!="GET" ? 405 : mode=="timeout" ? 503 : 200; body="{\"status\":\"ok\"}"; }
                        if (path == "/v1/models") {
                            // This resembles an allowed startup log but occurs during
                            // a canary; the supervisor must already have frozen capture.
                            Console.Error.WriteLine("sched_reserve: Vulkan0 compute buffer size = 999.00 MiB");
                            Console.Error.WriteLine("llama_prepare_model_devices: using device Vulkan1 (canary-time text) (0000:04:00.0) - 20000 MiB free");
                            body="{\"data\":[{\"id\":\"" + model + "\"}]}";
                        }
                        if (path == "/props") body="{\"default_generation_settings\":{\"n_ctx\":"+(mode=="context"?context/2:context)+"},\"total_slots\":1}";
                        if (path == "/completion") { if (method!="POST") status=405; completion++; body="{\"tokens\":[" + (mode=="unstable"?completion:42) + "],\"content\":\"Paris\"}"; }
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
                        var bytes=Encoding.UTF8.GetBytes(body);
                        var header=Encoding.ASCII.GetBytes("HTTP/1.1 "+status+" OK\r\n"+(status==302?"Location: https://example.com/\r\n":"")+"Content-Length: "+bytes.Length+"\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n");
                        stream.Write(header,0,header.Length); stream.Write(bytes,0,bytes.Length);
                    }
                }
            }
        }
    }
}
