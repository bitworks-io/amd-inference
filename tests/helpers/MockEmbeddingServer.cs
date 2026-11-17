using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace FastLlmTests {
    // A stand-in for llama-server started as an embedding server (tests/sidecar-tests.ps1). It takes llama-server's own arguments
    // (--model, --alias, --host, --port, --embedding, --pooling, -c, ...), binds the host and port they name, and answers /health,
    // /v1/models, /v1/embeddings and /metrics. Nothing here is an inference engine: a "vector" is numbers derived from the request text.
    //
    // The control folder (environment variable FASTLLM_TEST_SIDECAR_CONTROL) holds what a test sets and what the mock records:
    //   mode        the mode of THIS start is its first line; with more than one line the first is consumed (the next start gets the next)
    //   metrics     read at every /metrics request: idle (default), busy, activity, 404 or garbage
    //   keymode     enforce (default), ignore or reject, as in MockServer.cs
    //   dimension   the vector length (default 1024)
    //   starts.log  one line per start (the mode)                        argv.txt   the arguments of the latest start, one per line
    //   env.txt     what the child environment held (names only)         auth.log   one line per request: METHOD PATH none|ok|wrong
    //   pid         the process id of the latest start
    // Like upstream llama-server, /health, /v1/health, /v1/models and /models are answered WITHOUT the API key; every other path needs it.
    // /props is a path that needs the key (the supervisor's 401/200 proof uses it, as the text server's does).
    // Modes: ok, exit, nohealth, models-wrong, dimension-wrong, unstable, embed-500, zero-vector, gpu-layers,
    //   silent    loads without printing any load_tensors line at all,
    //   gpu-odd   prints a CPU placement the supervisor can parse, plus GPU lines in shapes it does not parse (they still count as like-lines),
    //   slow      answers every request but /health only after a delay of 3 s (see "delaying" below),
    //   hang      reads every request but /health and never answers it.
    // For slow and hang the file "delaying" is written when the first delayed request arrives (and its time is kept as a line in delaying.log).
    // "marker-<mode>" behaves as <mode> and also prints every request header and body and every response body to stderr, as a verbose server would.
    public static class MockEmbeddingServer {
        private static string control;
        private static string ReadControl(string name, string fallback) {
            if (String.IsNullOrEmpty(control)) return fallback;
            for (int attempt = 0; attempt < 50; attempt++) {
                try {
                    string path = Path.Combine(control, name);
                    if (!File.Exists(path)) return fallback;
                    string text = File.ReadAllText(path).Trim();
                    return text.Length == 0 ? fallback : text;
                }
                catch (IOException) { System.Threading.Thread.Sleep(10); }
                catch (UnauthorizedAccessException) { System.Threading.Thread.Sleep(10); }
            }
            return fallback;
        }
        private static void Record(string name, string text, bool append) {
            if (String.IsNullOrEmpty(control)) return;
            for (int attempt = 0; attempt < 100; attempt++) {
                try {
                    string path = Path.Combine(control, name);
                    if (append) File.AppendAllText(path, text); else File.WriteAllText(path, text);
                    return;
                }
                catch (IOException) { System.Threading.Thread.Sleep(10); }
                catch (UnauthorizedAccessException) { System.Threading.Thread.Sleep(10); }
            }
        }
        private static string TakeMode() {
            if (String.IsNullOrEmpty(control)) return "ok";
            string path = Path.Combine(control, "mode");
            if (!File.Exists(path)) return "ok";
            var lines = new List<string>();
            foreach (string line in File.ReadAllLines(path)) if (!String.IsNullOrEmpty(line.Trim())) lines.Add(line.Trim());
            if (lines.Count == 0) return "ok";
            if (lines.Count > 1) File.WriteAllLines(path, lines.GetRange(1, lines.Count - 1).ToArray());
            return lines[0];
        }
        private static string Argument(string[] args, string name, string fallback) {
            for (int i = 0; i + 1 < args.Length; i++) if (args[i] == name) return args[i + 1];
            return fallback;
        }
        // Numbers derived from the text: the same text gives the same vector. Never a real embedding.
        private static string Vector(string text, int dimension, int salt, bool zero) {
            uint seed = 2166136261;
            foreach (char c in text) { seed ^= c; seed *= 16777619; }
            seed += (uint)salt * 977u;
            var builder = new StringBuilder("[");
            for (int i = 0; i < dimension; i++) {
                if (i > 0) builder.Append(',');
                if (zero) { builder.Append('0'); continue; }
                seed = seed * 1664525u + 1013904223u;
                // Six digits after the point, with a recognisable first component so a leak of a vector into any file is detectable.
                double value = i == 0 ? 0.123457 : ((seed >> 8) % 2000000) / 1000000.0 - 1.0;
                builder.Append(value.ToString("0.000000", System.Globalization.CultureInfo.InvariantCulture));
            }
            return builder.Append(']').ToString();
        }
        public static void Run(string[] args, string controlFolder) {
            control = controlFolder;
            string mode = TakeMode();
            Record("starts.log", mode + "\n", true);
            Record("argv.txt", String.Join("\n", args) + "\n", false);
            Record("pid", System.Diagnostics.Process.GetCurrentProcess().Id.ToString(), false);
            string apiKey = Environment.GetEnvironmentVariable("LLAMA_API_KEY");
            bool hasKey = !String.IsNullOrEmpty(apiKey);
            // What the child environment held: the names an engine reads its settings from. Never a value.
            var seen = new StringBuilder(hasKey ? "key-present\n" : "key-absent\n");
            foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
                string name = (string)entry.Key;
                foreach (string prefix in new string[] { "LLAMA_", "GGML_", "VK_", "HIP_", "ROCM_", "HSA_", "HF_TOKEN" })
                    if (name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { seen.Append("name " + name + "\n"); break; }
            }
            foreach (string name in new string[] { "APPDATA", "PROGRAMDATA" }) {
                string folder = Environment.GetEnvironmentVariable(name);
                bool empty = !String.IsNullOrEmpty(folder) && Directory.Exists(folder) && Directory.GetFileSystemEntries(folder).Length == 0;
                seen.Append("sandbox " + name + " " + (empty ? "empty" : "not-empty") + "\n");
            }
            Record("env.txt", seen.ToString(), false);
            if (hasKey) {
                // The key reaches a server through its environment only: an argument that holds it ends the mock.
                foreach (string argument in Environment.GetCommandLineArgs())
                    if (argument != null && argument.IndexOf(apiKey, StringComparison.Ordinal) >= 0) { Record("fault", "api-key-in-arguments", false); Environment.Exit(75); }
            }
            bool echo = mode.StartsWith("marker-");
            if (echo) mode = mode.Substring(7);
            if (mode == "exit") Environment.Exit(7);
            string keyMode = ReadControl("keymode", "enforce");
            string alias = Argument(args, "--alias", "unnamed");
            // As llama-server does, the environment can name the host and the port; a supervisor that did not clear it would be exposed here.
            string host = Environment.GetEnvironmentVariable("LLAMA_ARG_HOST");
            if (String.IsNullOrEmpty(host)) host = Argument(args, "--host", "127.0.0.1");
            string portText = Environment.GetEnvironmentVariable("LLAMA_ARG_PORT");
            if (String.IsNullOrEmpty(portText)) portText = Argument(args, "--port", "8080");
            int port = Int32.Parse(portText);
            int dimension = Int32.Parse(ReadControl("dimension", "1024"));
            // A CPU load, as the engine reports it; gpu-layers is a load that went to a GPU although none was asked for.
            if (mode == "gpu-layers") {
                Console.Error.WriteLine("load_tensors: offloaded 13/13 layers to GPU");
                Console.Error.WriteLine("load_tensors: Vulkan0 model buffer size = 600.00 MiB");
            } else if (mode == "silent") {
                // No placement line at all: nothing proves where the model went.
            } else {
                Console.Error.WriteLine("load_tensors: offloaded 0/13 layers to GPU");
                Console.Error.WriteLine("load_tensors: CPU_Mapped model buffer size = 600.00 MiB");
                if (mode == "gpu-odd") {
                    // GPU placement in shapes the strict parse does not accept: the supervisor's like-line counters see them.
                    Console.Error.WriteLine("load_tensors: offloaded 13/13 layers to Vulkan0");
                    Console.Error.WriteLine("load_tensors: Vulkan0 model buffer size: 600.00 MiB");
                }
            }
            if (hasKey && keyMode != "ignore") Console.Error.WriteLine("0.00.402.100 I srv          main: api_keys: ****" + apiKey.Substring(Math.Max(apiKey.Length - 4, 0)));
            TcpListener listener;
            try { listener = new TcpListener(IPAddress.Parse(host), port); listener.Start(); }
            catch (SocketException) {
                Console.Error.WriteLine("couldn't bind HTTP server socket, hostname: " + host + ", port: " + port);
                Environment.Exit(1);
                return;
            }
            Record("listening", host + ":" + port, false);
            int calls = 0;
            long promptTokens = 0;
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
                            int length = 0;
                            string line;
                            string authorization = null;
                            while (!String.IsNullOrEmpty(line = reader.ReadLine())) {
                                if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = Int32.Parse(line.Substring(15).Trim());
                                if (line.StartsWith("Authorization:", StringComparison.OrdinalIgnoreCase)) authorization = line.Substring(14).Trim();
                            }
                            string authState = authorization == null ? "none" : (hasKey && authorization == "Bearer " + apiKey ? "ok" : "wrong");
                            Record("auth.log", method + " " + path + " " + authState + "\n", true);
                            if (echo && authorization != null) Console.Error.WriteLine("request header " + path + ": Authorization: " + authorization);
                            var requestBody = new StringBuilder();
                            for (int i = 0; i < length; i++) requestBody.Append((char)reader.Read()); // test requests are ASCII
                            if ((mode == "slow" || mode == "hang") && path != "/health") {
                                if (!String.IsNullOrEmpty(control) && !File.Exists(Path.Combine(control, "delaying"))) Record("delaying", "1", false);
                                Record("delaying.log", path + "\n", true);
                                if (mode == "hang") System.Threading.Thread.Sleep(120000); else System.Threading.Thread.Sleep(3000);
                            }
                            int status = 200;
                            string body = "{}";
                            if (path == "/health") { status = mode == "nohealth" ? 503 : 200; body = mode == "nohealth" ? "{\"error\":{\"message\":\"Loading model\"}}" : "{\"status\":\"ok\"}"; }
                            else if (path == "/props") { body = "{\"model_alias\":\"" + alias + "\"}"; }
                            else if (path == "/v1/models" || path == "/models") { body = "{\"object\":\"list\",\"data\":[{\"id\":\"" + (mode == "models-wrong" ? "another-model" : alias) + "\",\"object\":\"model\"}]}"; }
                            else if (path == "/v1/embeddings") {
                                if (method != "POST") status = 405;
                                else if (mode == "embed-500") { status = 500; body = "{\"error\":{\"message\":\"embedding failed\"}}"; }
                                else {
                                    calls++;
                                    promptTokens += 12;
                                    int size = mode == "dimension-wrong" ? dimension + 1 : dimension;
                                    body = "{\"object\":\"list\",\"data\":[{\"object\":\"embedding\",\"index\":0,\"embedding\":" +
                                        Vector(requestBody.ToString(), size, mode == "unstable" ? calls : 0, mode == "zero-vector") +
                                        "}],\"model\":\"" + alias + "\",\"usage\":{\"prompt_tokens\":12,\"total_tokens\":12}}";
                                }
                            }
                            else if (path == "/metrics") {
                                string metrics = ReadControl("metrics", "idle");
                                Record("metrics.log", metrics + "\n", true);
                                if (metrics == "404") { status = 404; }
                                else if (metrics == "garbage") { body = "not a metrics document\n"; }
                                else {
                                    if (metrics == "activity") promptTokens += 5;
                                    body = "# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.\n# TYPE llamacpp:prompt_tokens_total counter\n" +
                                        "llamacpp:prompt_tokens_total " + promptTokens + "\nllamacpp:tokens_predicted_total 0\n" +
                                        "llamacpp:requests_processing " + (metrics == "busy" ? "1" : "0") + "\nllamacpp:requests_deferred 0\n";
                                }
                            }
                            else { status = 404; }
                            if (echo && path != "/health") {
                                Console.Error.WriteLine("request " + path + ": " + requestBody.ToString());
                                Console.Error.WriteLine("response " + path + ": " + body.Replace("\n", " "));
                            }
                            if (hasKey && path != "/health" && path != "/v1/health" && path != "/v1/models" && path != "/models" && keyMode != "ignore" && (keyMode == "reject" || authState != "ok")) {
                                status = 401;
                                body = "{\"error\":{\"message\":\"Invalid API Key\",\"type\":\"authentication_error\",\"code\":401}}";
                            }
                            var bytes = Encoding.UTF8.GetBytes(body);
                            var header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " OK\r\nContent-Length: " + bytes.Length + "\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n");
                            stream.Write(header, 0, header.Length); stream.Write(bytes, 0, bytes.Length);
                        }
                    }
                    catch (IOException) { }
                    catch (SocketException) { }
                }
            }
        }
    }
}
