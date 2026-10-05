"""Synthetic private Linux serving tests; no native engine or driver executes."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PRIVATE_TEST_PARENT = Path(tempfile.gettempdir()).resolve()
SPEC = importlib.util.spec_from_file_location("fastllm_linux_serve", ROOT / "linux" / "serve.py")
serve = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(serve)


def fixture_item(data):
    item = dict(serve.models.load_catalog()["models"][0])
    item["sha256"] = hashlib.sha256(data).hexdigest()
    item["sizeBytes"] = len(data)
    return item


class ServeTests(unittest.TestCase):
    def test_cli_requires_explicit_opt_in_and_native_host(self):
        with mock.patch.object(serve, "require_host"):
            with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit) as denied:
                serve.main(["start", "--stage", "/absent", "--model-id", "qwen3.5-4b-iq4-xs"])
            self.assertEqual(denied.exception.code, 2)
        with mock.patch.object(serve.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(serve.ServeError, "standard-user Linux"):
                serve.require_host()
        with mock.patch.object(serve.platform, "system", return_value="Linux"), \
             mock.patch.object(serve.platform, "machine", return_value="x86_64"), \
             mock.patch.object(serve.os, "geteuid", return_value=0):
            with self.assertRaisesRegex(serve.ServeError, "standard-user Linux"):
                serve.require_host()

    def test_cached_model_verifier_is_read_only_exact_consent_and_full_sha(self):
        data = b"pinned fixture only"
        item = fixture_item(data)
        catalog = {"models": [item]}
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            cache = Path(folder) / "cache"
            cache.mkdir(mode=0o700)
            stem = f"{item['id']}-{item['sha256']}"
            model = cache / (stem + ".gguf")
            receipt = cache / (stem + ".consent.json")
            model.write_bytes(data)
            receipt.write_text(json.dumps(serve.models._receipt(item)))
            model.chmod(0o600)
            receipt.chmod(0o600)
            found, _ = serve.verify_cached_model(catalog, item["id"], cache)
            self.assertEqual(found, model)
            self.assertEqual(model.read_bytes(), data)
            altered = dict(item, revision="0" * 40)
            with self.assertRaisesRegex(serve.ServeError, "consent"):
                serve.verify_cached_model({"models": [altered]}, item["id"], cache)
            receipt.write_text(json.dumps(serve.models._receipt(item)))
            model.write_bytes(b"same length but wrong"[:len(data)])
            with self.assertRaisesRegex(serve.ServeError, "SHA-256"):
                serve.verify_cached_model(catalog, item["id"], cache)
            model.unlink()
            model.symlink_to(receipt)
            with self.assertRaises(ValueError):
                serve.verify_cached_model(catalog, item["id"], cache)

    def test_cached_model_rejects_missing_or_unsafe_files_without_acquisition(self):
        data = b"a"
        item = fixture_item(data)
        catalog = {"models": [item]}
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            cache = Path(folder) / "cache"
            cache.mkdir(mode=0o700)
            with self.assertRaises(FileNotFoundError):
                serve.verify_cached_model(catalog, item["id"], cache)
            self.assertEqual(list(cache.iterdir()), [])
            stem = f"{item['id']}-{item['sha256']}"
            receipt = cache / (stem + ".consent.json")
            receipt.write_text(json.dumps(serve.models._receipt(item)))
            receipt.chmod(0o644)
            with self.assertRaises(ValueError):
                serve.verify_cached_model(catalog, item["id"], cache)

    def test_post_probe_recheck_rejects_receipt_and_model_mutation(self):
        data = b"pinned"
        item = fixture_item(data)
        catalog = {"models": [item]}
        asset = {"entryPoint": "llama-server"}
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            root = Path(folder)
            cache = root / "cache"; cache.mkdir(mode=0o700)
            stage = root / "stage"; stage.mkdir(mode=0o700)
            stem = f"{item['id']}-{item['sha256']}"
            model = cache / (stem + ".gguf")
            receipt = cache / (stem + ".consent.json")
            model.write_bytes(data); model.chmod(0o600)
            receipt.write_text(json.dumps(serve.models._receipt(item))); receipt.chmod(0o600)
            before = model.lstat()
            with mock.patch.object(serve.models, "load_catalog", return_value=catalog), \
                 mock.patch.object(serve.runtime, "load_asset", return_value=asset), \
                 mock.patch.object(serve.runtime, "verify_tree"):
                serve._recheck_after_probe(stage, cache, catalog, model, item, asset, before)
                receipt.write_text("{}")
                with self.assertRaisesRegex(serve.ServeError, "consent receipt changed"):
                    serve._recheck_after_probe(stage, cache, catalog, model, item, asset, before)
                receipt.write_text(json.dumps(serve.models._receipt(item)))
                model.write_bytes(b"alterd")
                with self.assertRaisesRegex(serve.ServeError, "cached model changed"):
                    serve._recheck_after_probe(stage, cache, catalog, model, item, asset, before)

    def test_placement_capture_strict_numeric_only_and_overflow(self):
        good = (b"noise /private/secret\n"
                b"load_tensors: offloaded 66/66 layers to GPU\n"
                b"load_tensors: Vulkan0 model buffer size = 14674.45 MiB\n")
        capture = serve.PlacementCapture(io.BytesIO(good))
        capture.thread.join(timeout=2)
        result = capture.freeze()
        self.assertEqual(result["reportedLayers"], 66)
        self.assertNotIn("secret", repr(result))
        self.assertFalse(result["physicalResidencyVerified"])
        for bad in (good + b"load_tensors: CPU_Mapped model buffer size = 682.03 MiB\n",
                    good + b"load_tensors: offloaded 66/66 layers to GPU\n",
                    good.replace(b"66/66", b"65/66"),
                    good.replace(b"14674.45", b"NaN"),
                    good.replace(b"Vulkan0 model", b"Vulkan1 model")):
            with self.subTest(bad=bad[-45:]):
                capture = serve.PlacementCapture(io.BytesIO(bad))
                capture.thread.join(timeout=2)
                with self.assertRaises(serve.ServeError):
                    capture.freeze()
        with mock.patch.object(serve, "MAX_OUTPUT", 8):
            capture = serve.PlacementCapture(io.BytesIO(good))
            capture.thread.join(timeout=2)
            with self.assertRaisesRegex(serve.ServeError, "output-total"):
                capture.freeze()

    def test_live_pipe_placement_is_visible_before_server_eof(self):
        read_fd, write_fd = os.pipe()
        stream = os.fdopen(read_fd, "rb")
        capture = serve.PlacementCapture(stream)
        try:
            os.write(write_fd, b"load_tensors: offloaded 66/66 layers to GPU\n"
                                b"load_tensors: Vulkan0 model buffer size = 1400.00 MiB\n")
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                with capture.lock:
                    if len(capture.lines) == 2:
                        break
                time.sleep(0.005)
            self.assertEqual(capture.freeze()["reportedLayers"], 66)
        finally:
            os.close(write_fd)
            capture.thread.join(timeout=2)
            stream.close()

    def test_fixed_argv_and_private_environment_do_not_inherit_overrides(self):
        item = fixture_item(b"a")
        args = serve._argv(Path("/stage/llama-server"), Path("/cache/fixture.gguf"), item)
        self.assertEqual(args[0:3], ["/stage/llama-server", "--model", "/cache/fixture.gguf"])
        self.assertEqual(args[args.index("--host") + 1], "127.0.0.1")
        self.assertEqual(args[args.index("--port") + 1], str(serve.PORT))
        self.assertEqual(args[args.index("--device") + 1], "Vulkan0")
        self.assertEqual(args[args.index("--n-gpu-layers") + 1], "all")
        self.assertIn("--offline", args)

    def test_run_reprobes_after_model_hash_and_rechecks_before_native_spawn(self):
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            base = Path(folder)
            cache = base / "cache"
            cache.mkdir(mode=0o700)
            stage = base / "stage"
            stage.mkdir(mode=0o700)
            run_root = base / "run"
            item = fixture_item(b"a")
            item["requiredFreeVramMiB"] = 10
            catalog = {"models": [item]}
            asset = {"entryPoint": "llama-server", "sha256": "a" * 64}
            reads = []
            def fresh(*_args):
                reads.append("hash-and-verify")
                return catalog, cache / "file.gguf", item, asset
            def fresh_probe(*_args):
                reads.append("native-probe")
                return {"devices": [{"device": "Vulkan0", "name": "AMD Radeon RX 7900 XTX",
                                     "reportedFreeMiB": 100, "amdIdentityVerified": False}],
                        "host": {"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]},
                        "engineArchiveSha256": asset["sha256"], "engineFileSha256": "b" * 64,
                        "fixture": False}
            with mock.patch.object(serve, "require_host"), \
                 mock.patch.object(serve, "_fresh_inputs", side_effect=fresh), \
                 mock.patch.object(serve.models, "_regular_private"), \
                 mock.patch.object(serve, "_recheck_after_probe", side_effect=lambda *_: reads.append("post-probe-recheck")), \
                 mock.patch.object(serve.probe, "run", side_effect=fresh_probe), \
                 mock.patch.object(serve.preview, "inventory", return_value=[{"recipeEligible": True, "vramFreeMiB": 100}]), \
                 mock.patch.object(serve, "_port_free", side_effect=serve.ServeError("occupied")):
                with self.assertRaisesRegex(serve.ServeError, "occupied"):
                    serve.run(stage, cache, run_root, item["id"])
            self.assertEqual(reads, ["hash-and-verify", "native-probe", "post-probe-recheck"])

    def test_run_rejects_ambiguous_hardware_changed_inputs_and_low_free_memory(self):
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            base = Path(folder)
            cache = base / "cache"; cache.mkdir(mode=0o700)
            stage = base / "stage"; stage.mkdir(mode=0o700)
            item = fixture_item(b"a")
            item["requiredFreeVramMiB"] = 100
            catalog = {"models": [item]}
            asset = {"entryPoint": "llama-server", "sha256": "a" * 64}
            probe_result = {"devices": [{"device": "Vulkan0", "name": "AMD Radeon RX 7900 XTX", "reportedFreeMiB": 99}],
                            "host": {"icdManifests": []}, "engineArchiveSha256": asset["sha256"],
                            "engineFileSha256": "b" * 64, "fixture": False}
            with mock.patch.object(serve, "require_host"), \
                 mock.patch.object(serve.probe, "run", return_value=probe_result), \
                 mock.patch.object(serve.models, "_regular_private"), \
                 mock.patch.object(serve.preview, "inventory", return_value=[{"recipeEligible": True, "vramFreeMiB": 200}]):
                with mock.patch.object(serve, "_recheck_after_probe"), \
                     mock.patch.object(serve, "_fresh_inputs", return_value=(catalog, base / "file", item, asset)):
                    with self.assertRaisesRegex(serve.ServeError, "free VRAM"):
                        serve.run(stage, cache, base / "run1", item["id"])
                with mock.patch.object(serve, "_fresh_inputs", return_value=(catalog, base / "file", item, asset)), \
                     mock.patch.object(serve, "_recheck_after_probe", side_effect=serve.ServeError("changed across")):
                    with self.assertRaisesRegex(serve.ServeError, "changed across"):
                        serve.run(stage, cache, base / "run2", item["id"])
                probe_result["devices"].append(dict(probe_result["devices"][0], device="Vulkan1"))
                with mock.patch.object(serve, "_recheck_after_probe"), \
                     mock.patch.object(serve, "_fresh_inputs", return_value=(catalog, base / "file", item, asset)):
                    with self.assertRaisesRegex(serve.ServeError, "exactly one"):
                        serve.run(stage, cache, base / "run3", item["id"])

    def test_status_and_stop_bind_exact_supervisor_identity(self):
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            root = Path(folder) / "run"; root.mkdir(mode=0o700)
            state = {"runId": "a" * 32, "phase": "ready", "supervisorPid": 8101,
                     "supervisorStartTicks": 555, "childPid": 8102, "childStartTicks": 555}
            serve._atomic_status(root, state)
            with mock.patch.object(serve, "_proc_start", return_value=555):
                self.assertTrue(serve.read_status(root)["supervisorAlive"])
                self.assertEqual(serve.request_stop(root)["stopRequestedFor"], state["runId"])
                self.assertTrue(serve._stop_requested(root, state))
            with mock.patch.object(serve, "_proc_start", return_value=556):
                self.assertEqual(serve.read_status(root)["phase"], "supervisor-lost-unverified")
                with self.assertRaisesRegex(serve.ServeError, "no matching"):
                    serve.request_stop(root)
            wrong = dict(state, runId="b" * 32)
            self.assertFalse(serve._stop_requested(root, wrong))
            (root / ("stop-" + state["runId"] + ".json")).write_text('{"runId":"wrong"}')
            with mock.patch.object(serve, "_proc_start", return_value=555):
                with self.assertRaisesRegex(serve.ServeError, "does not match"):
                    serve.request_stop(root)
            serve._atomic_status(root, dict(state, supervisorStartTicks=None))
            with self.assertRaisesRegex(serve.ServeError, "invalid supervisor identity"):
                serve.read_status(root)

    def test_api_canaries_reject_wrong_model_context_token_and_chat(self):
        good = iter([{"data": [{"id": "m"}]}, {"default_generation_settings": {"n_ctx": 8192}, "total_slots": 1},
                     {"tokens": [23]}, {"tokens": [23]}, {"choices": [{"message": {"role": "assistant", "content": "hi"}}]}])
        with mock.patch.object(serve, "_http", side_effect=lambda *_: next(good)), \
             mock.patch.object(serve, "_http_stream_chat", return_value=True):
            self.assertTrue(serve._canaries("m", 8192, time.monotonic() + 10)["streamingChat"])
        with mock.patch.object(serve, "_http", return_value={"data": [{"id": "other"}]}):
            with self.assertRaises(serve.ServeError):
                serve._canaries("m", 8192, time.monotonic() + 10)
        bad = iter([{"data": [{"id": "m"}]}, {"default_generation_settings": {"n_ctx": 4096}, "total_slots": 1}])
        with mock.patch.object(serve, "_http", side_effect=lambda *_: next(bad)):
            with self.assertRaises(serve.ServeError):
                serve._canaries("m", 8192, time.monotonic() + 10)

    def test_real_loopback_http_503_malformed_and_slow_drip_are_bounded(self):
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                if self.path == "/loading":
                    self.send_response(503); self.end_headers(); return
                if self.path == "/malformed":
                    self.send_response(200); self.end_headers(); self.wfile.write(b"not-json"); return
                if self.path == "/redirect":
                    self.send_response(302); self.send_header("Location", "https://example.invalid/")
                    self.end_headers(); return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                try:
                    self.wfile.write(b"{")
                    self.wfile.flush()
                    for _ in range(100):
                        time.sleep(0.02)
                        self.wfile.write(b" ")
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with mock.patch.object(serve, "PORT", server.server_port):
                with self.assertRaises(serve.HttpNotReady):
                    serve._http("GET", "/loading", None, time.monotonic() + 2)
                with self.assertRaisesRegex(serve.ServeError, "malformed"):
                    serve._http("GET", "/malformed", None, time.monotonic() + 2)
                with self.assertRaisesRegex(serve.ServeError, "not successful"):
                    serve._http("GET", "/redirect", None, time.monotonic() + 2)
                started = time.monotonic()
                with self.assertRaisesRegex(serve.ServeError, "deadline"):
                    serve._http("GET", "/drip", None, started + 0.12)
                self.assertLess(time.monotonic() - started, 0.8)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_real_streaming_chat_success_and_negative_transport_cases(self):
        first = {"object": "chat.completion.chunk", "model": "m", "choices": [
            {"index": 0, "delta": {"role": "assistant", "content": "He"}, "finish_reason": None}]}
        final = {"object": "chat.completion.chunk", "model": "m", "choices": [
            {"index": 0, "delta": {"content": "llo"}, "finish_reason": "stop"}]}
        def frame(value):
            return b"data: " + (value if isinstance(value, bytes) else json.dumps(value).encode()) + b"\n\n"
        valid = frame(first) + frame(final) + frame(b"[DONE]")
        paths = {
            "/good": valid,
            "/truncated": frame(first) + frame(final),
            "/partial": frame(first) + frame(final) + b"data: [DO",
            "/duplicate": valid + frame(b"[DONE]"),
            "/malformed": frame(first) + frame(b"{not-json}") + frame(b"[DONE]"),
            "/oversize": valid + b" " * (serve.MAX_HTTP + 1),
        }
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                length = min(int(self.headers.get("Content-Length", "0")), 4096)
                self.rfile.read(length)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                try:
                    if self.path == "/slow":
                        self.wfile.write(frame(first)); self.wfile.flush()
                        for _ in range(100):
                            time.sleep(0.02)
                            self.wfile.write(b" "); self.wfile.flush()
                    else:
                        self.wfile.write(paths[self.path]); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with mock.patch.object(serve, "PORT", server.server_port):
                # The fixed public entry point is exercised; path variants only
                # change this test server's response, never native launch flags.
                original = serve.http.client.HTTPConnection
                class RouteConnection(original):
                    def request(self, method, path, *args, **kwargs):
                        route = getattr(self, "test_route", "/good")
                        return super().request(method, route, *args, **kwargs)
                for route, good, reason in (("/good", True, None), ("/truncated", False, "completion"),
                                            ("/partial", False, "partial"), ("/duplicate", False, "misplaced"),
                                            ("/malformed", False, "JSON"), ("/oversize", False, "size ceiling")):
                    with self.subTest(route=route), mock.patch.object(serve.http.client, "HTTPConnection", RouteConnection):
                        RouteConnection.test_route = route
                        if good:
                            self.assertTrue(serve._http_stream_chat("m", time.monotonic() + 2))
                        else:
                            with self.assertRaisesRegex(serve.ServeError, reason):
                                serve._http_stream_chat("m", time.monotonic() + 2)
                with mock.patch.object(serve.http.client, "HTTPConnection", RouteConnection):
                    RouteConnection.test_route = "/slow"
                    started = time.monotonic()
                    with self.assertRaisesRegex(serve.ServeError, "deadline"):
                        serve._http_stream_chat("m", started + 0.12)
                    self.assertLess(time.monotonic() - started, 0.8)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_sse_parser_rejects_wrong_model_role_finish_and_choice(self):
        valid = (b'data: {"object":"chat.completion.chunk","model":"m","choices":'
                 b'[{"index":0,"delta":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]}\n\n'
                 b'data: [DONE]\n\n')
        self.assertTrue(serve._parse_chat_sse(valid, "m"))
        for bad in (valid.replace(b'"model":"m"', b'"model":"other"'),
                    valid.replace(b'"assistant"', b'"user"'),
                    valid.replace(b'"finish_reason":"stop"', b'"finish_reason":null'),
                    valid.replace(b'"index":0', b'"index":1'),
                    valid.replace(b'"content":"hello"', b'"content":""')):
            with self.subTest(bad=bad[:80]), self.assertRaises(serve.ServeError):
                serve._parse_chat_sse(bad, "m")

    def test_parent_death_rejects_changed_supervisor_before_prctl(self):
        with mock.patch.object(serve.os, "getppid", return_value=1), \
             mock.patch.object(serve.os, "_exit", side_effect=serve.ServeError("orphan rejected")) as exited, \
             mock.patch.object(serve.ctypes, "CDLL") as libc:
            with self.assertRaisesRegex(serve.ServeError, "orphan rejected"):
                serve._parent_death(9999)
            exited.assert_called_once_with(127)
            libc.assert_not_called()
        bad = iter([{"data": [{"id": "m"}]}, {"default_generation_settings": {"n_ctx": 8192}, "total_slots": 1},
                    {"tokens": [1]}, {"tokens": [2]}])
        with mock.patch.object(serve, "_http", side_effect=lambda *_: next(bad)):
            with self.assertRaises(serve.ServeError):
                serve._canaries("m", 8192, time.monotonic() + 10)

    def test_mock_foreground_lifecycle_scopes_status_environment_and_cleanup(self):
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            base = Path(folder)
            cache = base / "cache"; cache.mkdir(mode=0o700)
            stage = base / "stage"; stage.mkdir(mode=0o700)
            item = fixture_item(b"a")
            item["requiredFreeVramMiB"] = 10
            catalog = {"models": [item]}
            asset = {"entryPoint": "llama-server", "sha256": "a" * 64}
            output = (b"load_tensors: offloaded 66/66 layers to GPU\n"
                      b"load_tensors: Vulkan0 model buffer size = 1400.00 MiB\n")
            child = mock.Mock(pid=8123, stdout=io.BytesIO(output))
            child.poll.return_value = None
            hardware = {"devices": [{"device": "Vulkan0", "name": "AMD Radeon RX 7900 XTX",
                                     "reportedFreeMiB": 100}],
                        "host": {"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]},
                        "engineArchiveSha256": asset["sha256"], "engineFileSha256": "b" * 64,
                        "fixture": False}
            with mock.patch.object(serve, "require_host"), \
                 mock.patch.object(serve, "_fresh_inputs", return_value=(catalog, cache / "model.gguf", item, asset)), \
                 mock.patch.object(serve.models, "_regular_private"), \
                 mock.patch.object(serve, "_recheck_after_probe"), \
                 mock.patch.object(serve.probe, "run", return_value=hardware), \
                 mock.patch.object(serve.preview, "inventory", return_value=[{"recipeEligible": True, "vramFreeMiB": 100}]), \
                 mock.patch.object(serve, "_port_free"), \
                 mock.patch.object(serve, "_proc_start", return_value=777), \
                 mock.patch.object(serve, "_listener_owned_by", return_value=True), \
                 mock.patch.object(serve, "_http", side_effect=[serve.HttpNotReady("loading"), {"status": "ok"}]), \
                 mock.patch.object(serve, "_canaries", return_value={"modelIdentity": True}), \
                 mock.patch.object(serve, "_stop_requested", side_effect=[False, False, True]), \
                 mock.patch.object(serve.subprocess, "Popen", return_value=child) as launched, \
                 mock.patch.object(serve, "_kill_group") as stopped:
                state = serve.run(stage, cache, base / "run", item["id"], load_timeout=30)
            self.assertEqual(state["phase"], "stopped")
            self.assertEqual(state["reportedPlacement"]["reportedLayers"], 66)
            self.assertFalse(state["physicalResidencyVerified"])
            self.assertFalse(state["amdPciToVulkanBindingVerified"])
            self.assertFalse(state["publicServingEnabled"])
            self.assertNotIn("capital", repr(state))
            stopped.assert_called_once_with(child)
            arguments, options = launched.call_args
            self.assertEqual(arguments[0][arguments[0].index("--host") + 1], "127.0.0.1")
            self.assertEqual(options["env"]["VK_DRIVER_FILES"], "/usr/share/vulkan/icd.d/amd.json")
            self.assertFalse(any(name in options["env"] for name in ("LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
                                                                    "VK_ICD_FILENAMES", "VK_LAYER_PATH", "GGML_MODEL")))
            self.assertTrue(options["start_new_session"])
            with mock.patch.object(serve, "_parent_death") as parent_death:
                options["preexec_fn"]()
            parent_death.assert_called_once_with(os.getpid())
            self.assertEqual(json.loads((base / "run" / "status.json").read_text())["phase"], "stopped")

    def test_mock_canary_failure_never_reports_ready_and_cleans_group(self):
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            base = Path(folder)
            cache = base / "cache"; cache.mkdir(mode=0o700)
            stage = base / "stage"; stage.mkdir(mode=0o700)
            item = fixture_item(b"a"); item["requiredFreeVramMiB"] = 10
            asset = {"entryPoint": "llama-server", "sha256": "a" * 64}
            output = (b"load_tensors: offloaded 66/66 layers to GPU\n"
                      b"load_tensors: Vulkan0 model buffer size = 1400.00 MiB\n")
            child = mock.Mock(pid=8124, stdout=io.BytesIO(output)); child.poll.return_value = None
            hardware = {"devices": [{"device": "Vulkan0", "name": "AMD Radeon RX 7900 XTX",
                                     "reportedFreeMiB": 100}],
                        "host": {"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]},
                        "engineArchiveSha256": asset["sha256"], "engineFileSha256": "b" * 64,
                        "fixture": False}
            with mock.patch.object(serve, "require_host"), \
                 mock.patch.object(serve, "_fresh_inputs", return_value=({"models": [item]}, cache / "model", item, asset)), \
                 mock.patch.object(serve.models, "_regular_private"), \
                 mock.patch.object(serve, "_recheck_after_probe"), \
                 mock.patch.object(serve.probe, "run", return_value=hardware), \
                 mock.patch.object(serve.preview, "inventory", return_value=[{"recipeEligible": True, "vramFreeMiB": 100}]), \
                 mock.patch.object(serve, "_port_free"), \
                 mock.patch.object(serve, "_proc_start", return_value=778), \
                 mock.patch.object(serve, "_listener_owned_by", return_value=True), \
                 mock.patch.object(serve, "_http", return_value={"status": "ok"}), \
                 mock.patch.object(serve, "_canaries", side_effect=serve.ServeError("chat canary failed")), \
                 mock.patch.object(serve, "_stop_requested", return_value=False), \
                 mock.patch.object(serve.subprocess, "Popen", return_value=child), \
                 mock.patch.object(serve, "_kill_group") as stopped:
                state = serve.run(stage, cache, base / "run", item["id"], load_timeout=30)
            self.assertEqual(state["phase"], "failed")
            self.assertEqual(state["failureCode"], "chat canary failed")
            stopped.assert_called_once_with(child)
            self.assertNotEqual(json.loads((base / "run" / "status.json").read_text())["phase"], "ready")

    def test_mock_post_ready_health_loss_revokes_ready_and_cleans_group(self):
        with tempfile.TemporaryDirectory(dir=PRIVATE_TEST_PARENT) as folder:
            base = Path(folder)
            cache = base / "cache"; cache.mkdir(mode=0o700)
            stage = base / "stage"; stage.mkdir(mode=0o700)
            item = fixture_item(b"a"); item["requiredFreeVramMiB"] = 10
            asset = {"entryPoint": "llama-server", "sha256": "a" * 64}
            child = mock.Mock(pid=8125, stdout=io.BytesIO(
                b"load_tensors: offloaded 66/66 layers to GPU\n"
                b"load_tensors: Vulkan0 model buffer size = 1400.00 MiB\n"))
            child.poll.return_value = None
            hardware = {"devices": [{"device": "Vulkan0", "name": "AMD Radeon RX 7900 XTX",
                                     "reportedFreeMiB": 100}],
                        "host": {"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]},
                        "engineArchiveSha256": asset["sha256"], "engineFileSha256": "b" * 64,
                        "fixture": False}
            with mock.patch.object(serve, "require_host"), \
                 mock.patch.object(serve, "_fresh_inputs", return_value=({"models": [item]}, cache / "model", item, asset)), \
                 mock.patch.object(serve.models, "_regular_private"), \
                 mock.patch.object(serve, "_recheck_after_probe"), \
                 mock.patch.object(serve.probe, "run", return_value=hardware), \
                 mock.patch.object(serve.preview, "inventory", return_value=[{"recipeEligible": True, "vramFreeMiB": 100}]), \
                 mock.patch.object(serve, "_port_free"), \
                 mock.patch.object(serve, "_proc_start", return_value=779), \
                 mock.patch.object(serve, "_listener_owned_by", return_value=True), \
                 mock.patch.object(serve, "_http", side_effect=[{"status": "ok"}, serve.HttpNotReady("lost")]), \
                 mock.patch.object(serve, "_canaries", return_value={"modelIdentity": True}), \
                 mock.patch.object(serve, "_stop_requested", return_value=False), \
                 mock.patch.object(serve, "HEALTH_INTERVAL", 0), \
                 mock.patch.object(serve.subprocess, "Popen", return_value=child), \
                 mock.patch.object(serve, "_kill_group") as stopped:
                state = serve.run(stage, cache, base / "run", item["id"], load_timeout=30)
            self.assertEqual(state["phase"], "failed")
            self.assertEqual(state["failureCode"], "lost")
            stopped.assert_called_once_with(child)


if __name__ == "__main__":
    unittest.main()
