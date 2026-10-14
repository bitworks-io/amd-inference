"""Synthetic tests for the private Linux benchmark producer.

A fake sysfs/procfs tree and a fake loopback llama-server stand in for real
hardware. No native engine, GPU or driver is touched and nothing here is a
performance or compatibility result.
"""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_linux_benchmark", ROOT / "linux" / "benchmark.py")
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)

SUP_PID, CHILD_PID = 4001, 4002
RUN_ID = "ab" * 16
HASHES = {key: hashlib.sha256(key.encode()).hexdigest() for key in benchmark.IDENTITY_HASHES}
BDF_CHAIN = ("0000:00:01.1", "0000:01:00.0", "0000:02:00.0", "0000:03:00.0")
LEVEL_LINKS = {  # per-level (current speed, max speed, current width, max width), all distinct
    "0000:00:01.1": ("16.0 GT/s PCIe", "16.0 GT/s PCIe", "16", "16"),
    "0000:01:00.0": ("16.0 GT/s PCIe", "32.0 GT/s PCIe", "16", "16"),
    "0000:02:00.0": ("8.0 GT/s PCIe", "16.0 GT/s PCIe", "8", "16"),
    "0000:03:00.0": ("2.5 GT/s PCIe", "16.0 GT/s PCIe", "4", "16"),
}


def write(path, text, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mode is not None:
        path.chmod(mode)


def stat_line(pid, ticks):
    fields = ["S"] + ["0"] * 18 + [str(ticks)] + ["0"] * 5
    return "%d (llama server) %s\n" % (pid, " ".join(fields))


class FakeSystem(object):
    """Temp directory holding fake sys/proc/etc roots and a private run root."""

    def __init__(self, hwmon=True, dmi_denied=False, chain=BDF_CHAIN):
        self.base = Path(tempfile.mkdtemp(prefix="fastllm-bench-test-")).resolve()
        self.sys, self.proc, self.etc = self.base / "sys", self.base / "proc", self.base / "etc"
        self.run_root = self.base / "run"
        self.run_root.mkdir(mode=0o700)
        self.run_root.chmod(0o700)
        self.out_dir = self.base / "out"
        self.out_dir.mkdir()
        self.chain = chain
        self._build_pci(hwmon)
        self._build_host(dmi_denied)
        self.set_ticks(SUP_PID, 111)
        self.set_ticks(CHILD_PID, 222)

    def cleanup(self):
        for path in self.sys.rglob("*"):
            try:
                path.chmod(0o700 if path.is_dir() and not path.is_symlink() else 0o600)
            except OSError:
                pass
        shutil.rmtree(self.base, ignore_errors=True)

    def _build_pci(self, hwmon):
        device = self.sys / "devices" / "pci0000:00"
        for bdf in self.chain:
            device = device / bdf
            speed, max_speed, width, max_width = LEVEL_LINKS[bdf]
            write(device / "current_link_speed", speed + "\n")
            write(device / "max_link_speed", max_speed + "\n")
            write(device / "current_link_width", width + "\n")
            write(device / "max_link_width", max_width + "\n")
        self.gpu = device
        for name, value in (("vendor", "0x1002"), ("device", "0x744c"), ("revision", "0xcc"),
                            ("class", "0x030000"), ("subsystem_vendor", "0x1002"),
                            ("subsystem_device", "0x0e3a"), ("mem_info_vram_total", "21458059264"),
                            ("mem_info_vram_used", "1000000"), ("mem_info_gtt_total", "33554432000"),
                            ("mem_info_gtt_used", "2000000"), ("gpu_busy_percent", "7")):
            write(self.gpu / name, value + "\n")
        if hwmon:
            mon = self.gpu / "hwmon" / "hwmon3"
            for name, value in (("power1_cap", "300000000"), ("power1_cap_max", "327000000"),
                                ("power1_cap_default", "300000000"), ("power1_average", "45000000"),
                                ("temp1_label", "edge"), ("temp1_input", "41000"),
                                ("temp2_label", "junction"), ("temp2_input", "47000")):
                write(mon / name, value + "\n")
        card = self.sys / "class" / "drm" / "card0"
        card.mkdir(parents=True)
        os.symlink(self.gpu, card / "device")
        (self.sys / "class" / "drm" / "card0-DP-1").mkdir()
        (self.sys / "class" / "drm" / "renderD128").mkdir()

    def _build_host(self, dmi_denied):
        dmi = self.sys / "class" / "dmi" / "id"
        for name in benchmark.DMI_FIELDS:
            write(dmi / name, name + "-value\n")
        if dmi_denied:
            (dmi / "bios_version").chmod(0)
        cpu = self.sys / "devices" / "system" / "cpu"
        for index, (package, core) in enumerate(((0, 0), (0, 0), (0, 1), (0, 1))):
            write(cpu / ("cpu%d" % index) / "topology" / "physical_package_id", "%d\n" % package)
            write(cpu / ("cpu%d" % index) / "topology" / "core_id", "%d\n" % core)
            if index:
                write(cpu / ("cpu%d" % index) / "online", "1\n")
        write(self.sys / "module" / "amdgpu" / "version", "6.8.5\n")
        write(self.proc / "cpuinfo", "processor\t: 0\nmodel name\t: Fake Ryzen 7 9999X\n")
        write(self.proc / "meminfo", "MemTotal:       65536000 kB\nMemFree: 1 kB\nMemAvailable:   60000000 kB\n")
        write(self.etc / "os-release", 'PRETTY_NAME="Ubuntu 24.04.2 LTS"\nID=ubuntu\nVERSION_ID="24.04"\n')

    def roots(self):
        uname = os.uname_result(("Linux", "host", "6.8.0-fake", "#1 SMP", "x86_64"))
        return benchmark.Roots(self.sys, self.proc, self.etc, uname=lambda: uname)

    def set_ticks(self, pid, ticks):
        write(self.proc / str(pid) / "stat", stat_line(pid, ticks))

    def write_state(self, port, **extra):
        state = {"schemaVersion": 1, "phase": "ready", "runId": RUN_ID, "supervisorPid": SUP_PID,
                 "supervisorStartTicks": 111, "childPid": CHILD_PID, "childStartTicks": 222,
                 "modelId": "fixture-model", "contextSize": 4096,
                 "endpoint": "http://127.0.0.1:%d/v1" % port, "identity": dict(HASHES),
                 "apiCanaries": {"modelIdentity": True}, "reportedPlacement": {"offloadedLayers": 1}}
        state.update(extra)
        path = self.run_root / "status.json"
        path.write_text(json.dumps(state))
        path.chmod(0o600)
        return state


class FakeServer(object):
    def __init__(self, tokens=None, prompt_extra=0, on_completion=None, events=None):
        self.requests = []
        self.completions = 0
        self.on_completion = on_completion
        self.token_count = tokens
        self.prompt_extra = prompt_extra
        self.custom_events = events
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def _send(self, payload):
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                outer.requests.append(("GET", self.path, None))
                if self.path == "/health":
                    self._send({"status": "ok"})
                elif self.path == "/props":
                    self._send({"total_slots": 1, "default_generation_settings": {"n_ctx": 4096}})
                else:
                    self.send_error(404)

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append(("POST", self.path, body))
                if self.path == "/tokenize":
                    words = body["content"].split()
                    if outer.token_count is not None:
                        words = words[:outer.token_count]
                    self._send({"tokens": list(range(100, 100 + len(words)))})
                elif self.path == "/completion":
                    outer.completions += 1
                    if outer.on_completion:
                        outer.on_completion(outer.completions)
                    self._stream(body)
                else:
                    self.send_error(404)

            def _stream(self, body):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                if outer.custom_events is not None:
                    frames = outer.custom_events
                else:
                    count = body["n_predict"]
                    frames = [{"content": "SECRET-COMPLETION-TEXT ", "stop": False}]
                    frames += [{"content": "x", "stop": False} for _ in range(min(count - 1, 3))]
                    frames.append({"content": "", "stop": True, "timings": {
                        "prompt_n": len(body["prompt"]) + outer.prompt_extra, "prompt_ms": 50.0,
                        "predicted_n": count, "predicted_ms": 400.0}})
                for frame in frames:
                    self.wfile.write(b"data: " + json.dumps(frame).encode() + b"\n\n")
                    self.wfile.flush()
                    time.sleep(0.005)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class Base(unittest.TestCase):
    def setUp(self):
        self.system = FakeSystem()
        self.addCleanup(self.system.cleanup)
        self.servers = []

    def server(self, **kwargs):
        server = FakeServer(**kwargs)
        self.servers.append(server)
        self.addCleanup(server.close)
        self.system.write_state(server.port)
        return server

    def run_bench(self, **kwargs):
        options = dict(prompt_tokens=(32, 64), output_tokens=8, warmup=1, repetitions=5, sample_hz=5,
                       order_seed=7, roots=self.system.roots())
        options.update(kwargs)
        self.output = self.system.out_dir / "report.json"
        return benchmark.run_benchmark(self.system.run_root, options.pop("output", self.output), **options)

    def assertRefused(self, code, call, *args, **kwargs):
        with self.assertRaises(benchmark.Refusal) as caught:
            call(*args, **kwargs)
        self.assertEqual(caught.exception.code, code)
        return caught.exception


class WorkloadTests(Base):
    def test_artifact_digest_matches_independent_computation(self):
        ids = [5, 0, 2147483647]
        expected = hashlib.sha256(b"fastllm-prompt-tokens-v1\n3\n5\n0\n2147483647\n").hexdigest()
        self.assertEqual(benchmark.prompt_artifact_sha256(ids), expected)
        for bad in ([], [-1], [2147483648], [True], ["1"]):
            self.assertRefused("artifact-invalid", benchmark.prompt_artifact_sha256, bad)

    def test_exact_token_artifacts_prompts_and_methodology(self):
        server = self.server()
        report = self.run_bench()
        sent = [body for method, path, body in server.requests if path == "/completion"]
        self.assertEqual(len(sent), (1 + 5) * 2)
        self.assertEqual({len(body["prompt"]) for body in sent}, {32, 64})
        for body in sent:
            self.assertIs(body["cache_prompt"], False)
            self.assertEqual(body["temperature"], 0)
            self.assertIs(body["stream"], True)
            self.assertEqual(body["n_predict"], 8)
        artifacts = {item["requestedPromptTokens"]: item for item in report["methodology"]["promptArtifacts"]}
        for length in (32, 64):
            tokens = list(range(100, 100 + length))
            self.assertEqual(artifacts[length]["tokenCount"], length)
            self.assertEqual(artifacts[length]["sha256"], benchmark.prompt_artifact_sha256(tokens))
            self.assertEqual(artifacts[length]["format"], "fastllm-prompt-tokens-v1")
        method = report["methodology"]
        self.assertIs(method["prefixCache"], False)
        self.assertEqual((method["warmupPerPrompt"], method["repetitions"], method["concurrency"]), (1, 5, 1))

    def test_warmup_is_discarded_and_samples_mirror_windows_semantics(self):
        self.server()
        report = self.run_bench()
        self.assertEqual(len(report["samples"]), 10)
        for length in (32, 64):
            group = [s for s in report["samples"] if s["requestedPromptTokens"] == length]
            self.assertEqual(sorted(s["repetition"] for s in group), [1, 2, 3, 4, 5])
        sample = report["samples"][0]
        self.assertEqual(list(sample), ["promptTokens", "outputTokens", "promptTokensPerSecond",
                                        "generationTokensPerSecond", "timeToFirstTextMs", "completionMs",
                                        "requestedPromptTokens", "repetition", "promptArtifactSha256",
                                        "startedUtc", "endedUtc"])
        self.assertAlmostEqual(sample["promptTokensPerSecond"], 1000.0 * sample["promptTokens"] / 50.0)
        self.assertAlmostEqual(sample["generationTokensPerSecond"], 1000.0 * 8 / 400.0)
        self.assertGreater(sample["timeToFirstTextMs"], 0)
        self.assertLess(sample["timeToFirstTextMs"], sample["completionMs"])
        self.assertLess(sample["startedUtc"], sample["endedUtc"])
        for entry in report["summary"]:
            self.assertEqual(entry["generation"]["count"], 5)
            self.assertIs(entry["generation"]["p95Caution"], True)

    def test_prompt_count_off_by_more_than_one_is_refused(self):
        self.server(prompt_extra=5)
        self.assertRefused("prompt-length-mismatch", self.run_bench)
        self.assertFalse(self.output.exists())

    def test_corpus_too_short_and_context_budget_refused(self):
        self.server(tokens=40)
        self.assertRefused("corpus-too-short", self.run_bench, prompt_tokens=(32, 64))
        self.assertRefused("context-budget", self.run_bench, prompt_tokens=(4090,))

    def test_stream_parser_rejects_malformed_streams(self):
        def make(events):
            return {"events": events, "eventTimesMs": [float(i + 1) for i in range(len(events))], "elapsedMs": 100.0}
        timings = {"prompt_n": 10, "prompt_ms": 5.0, "predicted_n": 4, "predicted_ms": 8.0}
        good = [{"content": "a", "stop": False}, {"content": "", "stop": True, "timings": timings}]
        self.assertEqual(benchmark.parse_sample(make(good), 4)["outputTokens"], 4)
        self.assertRefused("sample-invalid", benchmark.parse_sample, make([{"content": "a", "stop": "true"}]), 4)
        self.assertRefused("sample-invalid", benchmark.parse_sample, make(good[:1]), 4)
        self.assertRefused("sample-invalid", benchmark.parse_sample, make(good + good), 4)
        self.assertRefused("sample-invalid", benchmark.parse_sample, make(good), 5)
        silent = [{"content": "", "stop": True, "timings": timings}]
        self.assertRefused("sample-invalid", benchmark.parse_sample, make(silent), 4)
        for bad in (dict(timings, prompt_ms=0.0), dict(timings, predicted_n=True), dict(timings, prompt_ms=float("inf"))):
            events = [good[0], {"content": "", "stop": True, "timings": bad}]
            self.assertRefused("sample-invalid", benchmark.parse_sample, make(events), 4)
        late = make(good)
        late["eventTimesMs"] = [1.0, 500.0]
        self.assertRefused("sample-invalid", benchmark.parse_sample, late, 4)


class ParameterTests(Base):
    def test_minimum_repetitions_and_other_bounds_refuse_before_any_request(self):
        server = self.server()
        self.assertRefused("repetitions-below-minimum", self.run_bench, repetitions=4)
        self.assertRefused("warmup-invalid", self.run_bench, warmup=0)
        self.assertRefused("sample-rate-out-of-bounds", self.run_bench, sample_hz=0.1)
        self.assertRefused("sample-rate-out-of-bounds", self.run_bench, sample_hz=6)
        self.assertRefused("output-tokens-invalid", self.run_bench, output_tokens=0)
        self.assertRefused("prompt-lengths-invalid", self.run_bench, prompt_tokens=(32, 32))
        self.assertRefused("prompt-lengths-invalid", self.run_bench, prompt_tokens=(8,))
        self.assertEqual(server.requests, [])

    def test_non_loopback_endpoint_and_not_ready_state_are_refused(self):
        server = self.server()
        self.system.write_state(server.port, endpoint="http://10.0.0.5:18082/v1")
        self.assertRefused("non-loopback-endpoint", self.run_bench)
        self.system.write_state(server.port, endpoint="http://localhost:%d/v1" % server.port)
        self.assertRefused("non-loopback-endpoint", self.run_bench)
        self.system.write_state(server.port, phase="loading")
        self.assertRefused("run-not-ready", self.run_bench)
        self.assertEqual(server.requests, [])

    def test_unsafe_run_root_and_missing_state_are_refused(self):
        self.server()
        self.system.run_root.chmod(0o755)
        self.assertRefused("run-root-unsafe", self.run_bench)
        self.system.run_root.chmod(0o700)
        (self.system.run_root / "status.json").unlink()
        self.assertRefused("lab-state-unavailable", self.run_bench)

    def test_cli_refuses_non_linux_host_with_typed_json(self):
        with mock.patch.object(benchmark.platform, "system", return_value="Darwin"), \
             mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            code = benchmark.main(["host-facts"])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(out.getvalue())["refused"], "unsupported-host")

    def test_concurrent_benchmark_lock_is_refused(self):
        self.server()
        fd = benchmark._lock(self.system.run_root)
        try:
            self.assertRefused("benchmark-already-running", self.run_bench)
        finally:
            os.close(fd)


class IdentityTests(Base):
    def test_identity_change_mid_run_aborts_without_report(self):
        def swap(count):
            if count == 3:
                self.system.set_ticks(CHILD_PID, 999)
        server = self.server(on_completion=swap)
        error = self.assertRefused("identity-changed", self.run_bench)
        self.assertIn("server process", error.detail)
        self.assertEqual(server.completions, 3)  # the next pre-request check stopped the run
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.system.out_dir.iterdir()), [])

    def test_identity_change_after_final_request_still_aborts(self):
        total = (1 + 5) * 2
        server = self.server(on_completion=lambda count: self.system.set_ticks(SUP_PID, 5) if count == total else None)
        self.assertRefused("identity-changed", self.run_bench)
        self.assertEqual(server.completions, total)
        self.assertFalse(self.output.exists())

    def test_run_id_and_phase_changes_abort(self):
        for change in ({"runId": "cd" * 16}, {"phase": "failed"}, {"childPid": 7777}):
            system = FakeSystem()
            self.addCleanup(system.cleanup)
            server = FakeServer()
            self.addCleanup(server.close)
            system.write_state(server.port)
            state = system.write_state(server.port)
            expected = benchmark.identity_of(state)
            system.write_state(server.port, **change)
            with self.assertRaises(benchmark.IdentityChanged):
                benchmark.verify_identity(system.run_root, expected, system.roots())

    def test_proc_start_parses_comm_with_parentheses(self):
        write(self.system.proc / "55" / "stat", "55 (we ) ird) S " + " ".join(["0"] * 18) + " 4242 0 0\n")
        self.assertEqual(benchmark.proc_start(55, self.system.roots()), 4242)
        self.assertIsNone(benchmark.proc_start(56, self.system.roots()))


class SamplerTests(Base):
    def test_gap_accounting_is_exact(self):
        self.assertEqual(benchmark.gap_stats([0, 1, 2, 5, 6], 1.0), (3, 2))
        largest, dropped = benchmark.gap_stats([0, 1.2, 1.9, 3.1], 1.0)
        self.assertAlmostEqual(largest, 1.2)
        self.assertEqual(dropped, 0)
        self.assertEqual(benchmark.gap_stats([0], 1.0), (0.0, 0))

    def test_sampler_reports_cadence_first_last_and_dropped_after_a_stall(self):
        gpus = benchmark.discover_gpus(self.system.roots())
        calls = []

        def slow_once():
            calls.append(1)
            if len(calls) == 2:
                time.sleep(0.8)
            return {gpus[0]["bdf"]: {"vramUsedBytes": 1}}
        sampler = benchmark.Sampler(gpus, 5, read_fn=slow_once)
        sampler.start()
        time.sleep(1.4)
        result = sampler.finish()
        self.assertEqual(result["requestedHz"], 5.0)
        self.assertAlmostEqual(result["intervalSeconds"], 0.2)
        self.assertGreaterEqual(result["largestGapSeconds"], 0.8)
        self.assertGreaterEqual(result["droppedSampleCount"], 3)
        self.assertEqual(result["sampleCount"], len(result["samples"]))
        self.assertEqual(result["firstSampleUtc"], result["samples"][0]["utc"])
        self.assertEqual(result["lastSampleUtc"], result["samples"][-1]["utc"])

    def test_read_exceptions_are_counted_not_hidden(self):
        sampler = benchmark.Sampler([], 5, read_fn=mock.Mock(side_effect=OSError("boom")))
        sampler.start()
        time.sleep(0.3)
        result = sampler.finish()
        self.assertGreaterEqual(result["readFailureCount"], 1)
        self.assertEqual(result["sampleCount"], 0)
        self.assertIsNone(result["firstSampleUtc"])

    def test_gpu_sample_values_and_missing_hwmon_are_none_with_typed_availability(self):
        gpu = benchmark.discover_gpus(self.system.roots())[0]
        status = {}
        sample = benchmark.read_gpu_sample(gpu, status)
        self.assertEqual(sample, {"vramUsedBytes": 1000000, "gttUsedBytes": 2000000, "gpuBusyPercent": 7,
                                  "powerAverageMicroWatts": 45000000, "tempEdgeMilliC": 41000,
                                  "tempJunctionMilliC": 47000})
        shutil.rmtree(self.system.gpu / "hwmon")
        status = {}
        sample = benchmark.read_gpu_sample(gpu, status)
        self.assertIsNone(sample["powerAverageMicroWatts"])
        self.assertIsNone(sample["tempEdgeMilliC"])
        self.assertEqual(status["powerAverageMicroWatts"], "not-present")
        self.assertEqual(sample["vramUsedBytes"], 1000000)

    def test_full_run_records_telemetry_block_for_each_gpu(self):
        self.server()
        telemetry = self.run_bench()["telemetry"]
        self.assertGreaterEqual(telemetry["sampleCount"], 2)
        self.assertTrue(telemetry["windowStartUtc"] <= telemetry["firstSampleUtc"])
        self.assertIn("0000:03:00.0", telemetry["samples"][0]["gpus"])
        self.assertIs(telemetry["vramUsedIsPerDeviceNotPerProcess"], True)


class HostFactTests(Base):
    def test_link_walk_reports_every_level_separately(self):
        levels = benchmark.link_walk(Path(os.path.realpath(self.system.gpu)))
        self.assertEqual([level["bdf"] for level in levels], list(BDF_CHAIN))
        self.assertEqual([level["role"] for level in levels],
                         ["root-port", "upstream-bridge", "upstream-bridge", "gpu"])
        for level in levels:
            speed, max_speed, width, max_width = LEVEL_LINKS[level["bdf"]]
            self.assertEqual(level["currentLinkSpeed"], {"status": "ok", "value": speed})
            self.assertEqual(level["maxLinkSpeed"], {"status": "ok", "value": max_speed})
            self.assertEqual(level["currentLinkWidth"], {"status": "ok", "value": int(width)})
            self.assertEqual(level["maxLinkWidth"], {"status": "ok", "value": int(max_width)})

    def test_gpu_directly_under_root_port_has_two_levels(self):
        system = FakeSystem(chain=("0000:00:01.1", "0000:03:00.0"))
        self.addCleanup(system.cleanup)
        levels = benchmark.gpu_facts(benchmark.discover_gpus(system.roots())[0])["pcieLinkWalk"]
        self.assertEqual([level["role"] for level in levels], ["root-port", "gpu"])

    def test_gpu_identity_memory_and_power_cap_facts(self):
        facts = benchmark.collect_host_facts("before", self.system.roots())
        self.assertEqual(facts["phase"], "before")
        self.assertTrue(facts["utc"].endswith("Z"))
        self.assertEqual(len(facts["gpus"]), 1)  # card0-DP-1 and renderD128 are not GPUs
        gpu = facts["gpus"][0]
        self.assertEqual(gpu["bdf"], "0000:03:00.0")
        self.assertEqual(gpu["deviceId"]["value"], "0x744c")
        self.assertEqual(gpu["revisionId"]["value"], "0xcc")
        self.assertEqual(gpu["subsystemDeviceId"]["value"], "0x0e3a")
        self.assertEqual(gpu["vramTotalBytes"]["value"], 21458059264)
        self.assertEqual(gpu["gttUsedBytes"]["value"], 2000000)
        self.assertEqual(gpu["powerCap"]["powerCapMicroWatts"]["value"], 300000000)
        self.assertEqual(facts["osRelease"]["value"]["VERSION_ID"], "24.04")
        self.assertEqual(facts["kernel"]["value"]["release"], "6.8.0-fake")
        self.assertNotIn("nodename", facts["kernel"]["value"])
        self.assertEqual(facts["cpu"]["model"]["value"], "Fake Ryzen 7 9999X")
        self.assertEqual(facts["cpu"]["logicalCores"]["value"], 4)
        self.assertEqual(facts["cpu"]["physicalCores"]["value"], 2)
        self.assertEqual(facts["memory"]["memTotalKiB"]["value"], 65536000)
        self.assertEqual(facts["memory"]["memAvailableKiB"]["value"], 60000000)
        self.assertEqual(facts["amdgpuModule"]["version"]["value"], "6.8.5")
        self.assertEqual(facts["dmi"]["board_name"]["value"], "board_name-value")

    def test_missing_hwmon_is_typed_absence(self):
        system = FakeSystem(hwmon=False)
        self.addCleanup(system.cleanup)
        gpu = benchmark.gpu_facts(benchmark.discover_gpus(system.roots())[0])
        self.assertEqual(gpu["powerCap"]["status"], "not-present")

    @unittest.skipIf(os.geteuid() == 0, "root bypasses file permissions")
    def test_permission_denied_dmi_is_a_typed_refusal_not_empty(self):
        system = FakeSystem(dmi_denied=True)
        self.addCleanup(system.cleanup)
        facts = benchmark.collect_host_facts("before", system.roots())
        self.assertEqual(facts["dmi"]["bios_version"], {"status": "permission-denied"})
        self.assertNotIn("value", facts["dmi"]["bios_version"])
        self.assertEqual(facts["dmi"]["bios_vendor"]["status"], "ok")

    def test_fact_statuses_are_typed(self):
        base = self.system.base
        self.assertEqual(benchmark.fact(base / "absent"), {"status": "not-present"})
        write(base / "blank", "\n")
        self.assertEqual(benchmark.fact(base / "blank"), {"status": "empty"})
        write(base / "word", "abc\n")
        self.assertEqual(benchmark.fact(base / "word", "int"), {"status": "malformed"})
        write(base / "big", "a" * 5000)
        self.assertEqual(benchmark.fact(base / "big"), {"status": "oversize"})
        with mock.patch("builtins.open", side_effect=PermissionError()):
            self.assertEqual(benchmark.fact(base / "word"), {"status": "permission-denied"})
        err = OSError(5, "io")
        with mock.patch("builtins.open", side_effect=err):
            self.assertEqual(benchmark.fact(base / "word"), {"status": "unreadable:errno-5"})

    def test_non_amd_display_device_is_ignored(self):
        write(self.system.gpu / "vendor", "0x10de\n")
        self.assertEqual(benchmark.discover_gpus(self.system.roots()), [])

    def test_before_and_after_facts_are_both_recorded_with_phase_and_utc(self):
        self.server()
        facts = self.run_bench()["hostFacts"]
        self.assertEqual((facts["before"]["phase"], facts["after"]["phase"]), ("before", "after"))
        self.assertLessEqual(facts["before"]["utc"], facts["after"]["utc"])


class BindingTests(Base):
    def test_default_lab_state_is_unbound(self):
        self.server()
        binding = self.run_bench()["binding"]
        self.assertEqual(binding["status"], "unbound")
        self.assertEqual(binding["joinMethod"], "none")
        self.assertIsNone(binding["bdf"])
        self.assertIsNone(binding["selectedDevice"])
        self.assertEqual(binding["selectedDeviceSource"], "not-recorded-in-lab-state")
        self.assertEqual(binding["candidateAmdBdfs"], ["0000:03:00.0"])

    def test_unique_recorded_pci_bus_id_joins_and_names_never_do(self):
        gpus = benchmark.discover_gpus(self.system.roots())
        joined = benchmark.bind_device({"selectedDevice": "Vulkan0", "deviceProbe": {"pciBusId": "03:00.0"}}, gpus)
        self.assertEqual((joined["status"], joined["bdf"], joined["joinMethod"]),
                         ("joined", "0000:03:00.0", "lab-state-engine-pci-bus-id"))
        self.assertEqual(joined["selectedDevice"], "Vulkan0")
        wrong = benchmark.bind_device({"deviceProbe": {"pciBusId": "0000:09:00.0"}}, gpus)
        self.assertEqual(wrong["status"], "unbound")
        by_name = benchmark.bind_device({"selectedDevice": "AMD Radeon RX 7900 XT"}, gpus)
        self.assertEqual(by_name["status"], "unbound")
        twin = dict(gpus[0])
        self.assertEqual(benchmark.bind_device({"deviceProbe": {"pciBusId": "0000:03:00.0"}}, gpus + [twin])["status"],
                         "unbound")


class ReportTests(Base):
    def test_report_shape_flags_hashes_and_source_digest(self):
        self.server()
        report = self.run_bench()
        self.assertEqual(tuple(report), benchmark.TOP_LEVEL_ORDER)
        self.assertEqual(report["resultKind"], "native-linux-api-benchmark-not-full-qualification")
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["producer"]["sourceSha256"], hashlib.sha256((ROOT / "linux" / "benchmark.py").read_bytes()).hexdigest())
        self.assertEqual(report["modelSha256"], HASHES["modelSha256"])
        self.assertEqual(report["recipe"]["engineSha256"], HASHES["engineFileSha256"])
        self.assertEqual(report["recipe"]["catalogSha256"], HASHES["catalogSha256"])
        self.assertEqual(report["requestedLaunch"]["launchArgumentsSha256"], HASHES["launchArgumentsSha256"])
        self.assertIs(report["requestedLaunch"]["argumentsRecordedByLab"], False)
        self.assertEqual(report["run"]["runId"], RUN_ID)
        self.assertEqual(report["run"]["childStartTicks"], 222)
        self.assertEqual(report["os"], "Ubuntu 24.04.2 LTS, kernel 6.8.0-fake")
        self.assertEqual(report["serverProps"], {"totalSlots": 1, "nCtx": 4096})
        self.assertTrue(report["qualification"])
        self.assertTrue(all(value is False for value in report["qualification"].values()))
        self.assertEqual(json.loads(self.output.read_text()), report)
        self.assertEqual(oct(self.output.stat().st_mode & 0o777), "0o600")

    def test_field_order_is_deterministic_across_runs(self):
        self.server()
        first = self.run_bench()
        self.output.unlink()
        second = self.run_bench()

        def shape(value):
            if isinstance(value, dict):
                return [(key, shape(item)) for key, item in value.items() if key not in ("samples",)]
            return None
        self.assertEqual(list(first), list(second))
        self.assertEqual(shape(first["methodology"]), shape(second["methodology"]))
        self.assertEqual(first["methodology"]["promptArtifacts"], second["methodology"]["promptArtifacts"])
        self.assertEqual([list(s) for s in first["samples"]], [list(s) for s in second["samples"]])
        order = lambda report: [(s["requestedPromptTokens"], s["repetition"]) for s in report["samples"]]
        self.assertEqual(order(first), order(second))  # same seed, same randomized order

    def test_report_contains_no_prompt_text_completion_text_or_token_ids(self):
        self.server()
        self.run_bench()
        raw = self.output.read_text()
        self.assertNotIn("SECRET-COMPLETION-TEXT", raw)
        self.assertNotIn("A local inference system", raw)
        self.assertNotIn("Measure speed consistently", raw)
        self.assertNotIn('"content"', raw)
        self.assertNotIn('"prompt"', raw)
        self.assertNotIn('"tokens"', raw)
        self.assertNotIn("101, 102, 103", raw.replace("\n", " ").replace("  ", " "))
        self.assertIn("promptArtifactSha256", raw)

    def test_existing_output_is_never_overwritten(self):
        server = self.server()
        existing = self.system.out_dir / "report.json"
        existing.write_text("precious")
        self.assertRefused("output-exists", self.run_bench)
        self.assertEqual(existing.read_text(), "precious")
        self.assertEqual(server.requests, [])  # refused before touching the server

    def test_write_report_link_refuses_a_file_that_appears_late(self):
        target = self.system.out_dir / "late.json"
        real_link = os.link

        def racing_link(source, destination, *args, **kwargs):
            Path(destination).write_text("raced")
            return real_link(source, destination, *args, **kwargs)
        with mock.patch.object(benchmark.os, "link", side_effect=racing_link):
            self.assertRefused("output-exists", benchmark.write_report, target, {"a": 1})
        self.assertEqual(target.read_text(), "raced")
        self.assertEqual(sorted(path.name for path in self.system.out_dir.iterdir()), ["late.json"])

    def test_output_parent_must_exist(self):
        self.server()
        self.assertRefused("output-parent-missing", self.run_bench, output=self.system.out_dir / "nope" / "r.json")

    def test_no_amd_gpu_is_refused_before_measuring(self):
        server = self.server()
        write(self.system.gpu / "vendor", "0x10de\n")
        self.assertRefused("no-amd-gpu", self.run_bench)
        self.assertEqual([r for r in server.requests if r[1] == "/completion"], [])


if __name__ == "__main__":
    unittest.main()
