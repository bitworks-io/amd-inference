"""Private Linux device probe tests; no staged binary or driver is executed."""

import importlib.util
import io
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_linux_probe", ROOT / "linux" / "probe.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)
ASSET = probe.runtime.load_asset()
GOOD = b"Available devices:\n Vulkan0: AMD Radeon RX 7900 XTX (24576 MiB, 23800 MiB free)\n"


class FakeChild:
    pid = 8123

    def __init__(self, output=b"", *, keep_open=False, exit_code=0):
        self.read_fd, self.write_fd = os.pipe()
        self.stdout = os.fdopen(self.read_fd, "rb", buffering=0)
        os.write(self.write_fd, output)
        if not keep_open:
            os.close(self.write_fd)
        self.exit_code = exit_code

    def wait(self, timeout=None):
        return self.exit_code

    def close(self):
        self.stdout.close()
        try:
            os.close(self.write_fd)
        except OSError:
            pass


class ProbeTests(unittest.TestCase):
    def test_pinned_manifest_and_no_public_execution_without_opt_in(self):
        self.assertEqual(ASSET["sha256"], probe.PINNED_ARCHIVE_SHA256)
        with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit) as denied:
            probe.main(["--stage", "/nonexistent"])
        self.assertEqual(denied.exception.code, 2)

    def test_parser_accepts_bounded_device_only_without_vendor_claim(self):
        result = probe.parse_devices(GOOD + b"untrusted path /tmp/secret\n")
        self.assertEqual(result[0]["device"], "Vulkan0")
        self.assertEqual(result[0]["reportedFreeMiB"], 23800)
        self.assertFalse(result[0]["amdIdentityVerified"])
        self.assertNotIn("secret", repr(result))
        for bad in (GOOD + GOOD, b"Vulkan0: malformed\n", b"Vulkan1: AMD GPU (10 MiB, 5 MiB free)\n",
                    b"Vulkan0: AMD GPU (10 MiB, 5 MiB free)\nAvailable devices:\n",
                    b"Available devices:\nAvailable devices:\n" + GOOD.split(b"\n", 1)[1],
                    b"Vulkan0: AMD GPU (10 MiB, 11 MiB free)\n", b"ROCm0: AMD GPU (10 MiB, 5 MiB free)\n",
                    b"Vulkan0: AMD GPU (10 MiB, 5 MiB free)\n" * 9,
                    b"x" * (probe.MAX_OUTPUT + 1)):
            with self.subTest(bad=bad[:40]), self.assertRaises(probe.ProbeError):
                probe.parse_devices(bad)

    def test_preflight_checks_native_host_and_metadata_before_probe(self):
        with mock.patch.object(probe.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(probe.ProbeError, "standard-user Linux"):
                probe.preflight(Path("/absent"), ASSET)
        with mock.patch.object(probe.platform, "system", return_value="Linux"), \
             mock.patch.object(probe.platform, "machine", return_value="x86_64"), \
             mock.patch.object(probe.os, "geteuid", return_value=0):
            with self.assertRaisesRegex(probe.ProbeError, "standard-user Linux"):
                probe.preflight(Path("/absent"), ASSET)
        with mock.patch.object(probe.platform, "system", return_value="Linux"), \
             mock.patch.object(probe.platform, "machine", return_value="x86_64"), \
             mock.patch.object(probe.os, "geteuid", return_value=1000), \
             mock.patch.object(probe.runtime, "verify_tree"), \
             mock.patch.object(probe.prereqs, "assess", return_value={"fixture": False,
                "osRelease": {"id": "fedora"}, "icdFileLimitReached": False}):
            with self.assertRaisesRegex(probe.ProbeError, "Ubuntu"):
                probe.preflight(Path("/absent"), ASSET)

    def test_manifest_pin_rejects_changed_members_or_dependency_list(self):
        with mock.patch.object(probe.platform, "system", return_value="Linux"), \
             mock.patch.object(probe.platform, "machine", return_value="x86_64"), \
             mock.patch.object(probe.os, "geteuid", return_value=1000):
            altered = dict(ASSET, members=[dict(item) for item in ASSET["members"]])
            altered["members"][0]["sha256"] = "0" * 64
            with self.assertRaisesRegex(probe.ProbeError, "supplied engine candidate differs"):
                probe.preflight(Path("/absent"), altered)
            altered = dict(ASSET, externalNeeded=ASSET["externalNeeded"][:-1])
            with self.assertRaisesRegex(probe.ProbeError, "supplied engine candidate differs"):
                probe.preflight(Path("/absent"), altered)
            with tempfile.TemporaryDirectory(dir=ROOT) as folder:
                mutated_manifest = Path(folder) / "engine-candidates.json"
                mutated_manifest.write_bytes(b"{" * (probe.MAX_MANIFEST_BYTES + 1))
                with mock.patch.object(probe.runtime, "MANIFEST", mutated_manifest):
                    with self.assertRaisesRegex(probe.ProbeError, "manifest differs"):
                        probe.preflight(Path("/absent"), ASSET)

    def test_preflight_requires_trusted_system_libraries_and_icd(self):
        report = {"fixture": False, "osRelease": {"id": "ubuntu"}, "icdFileLimitReached": False,
                  "vulkanLoaderCandidates": [{"candidate": str(probe.SYSTEM_LIB_DIRS[0] / "libvulkan.so.1"),
                                                "candidateStatus": "symlink-unverified"}],
                  "icdManifests": [{"files": [{"path": "/usr/share/vulkan/icd.d/amd.json",
                                      "status": "parsed-unverified", "libraryPathText": "libvulkan_radeon.so"}]}]}
        patches = [mock.patch.object(probe.platform, "system", return_value="Linux"),
                   mock.patch.object(probe.platform, "machine", return_value="x86_64"),
                   mock.patch.object(probe.os, "geteuid", return_value=1000),
                   mock.patch.object(probe.runtime, "verify_tree"),
                   mock.patch.object(probe.prereqs, "assess", return_value=report),
                   mock.patch.object(probe, "_glibc_version", return_value=(2, 39))]
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5]:
            with mock.patch.object(probe, "_trusted_system_file", return_value=False):
                with self.assertRaisesRegex(probe.ProbeError, "system library"):
                    probe.preflight(Path("/absent"), ASSET)
            with mock.patch.object(probe, "_trusted_system_file", return_value=True), \
                 mock.patch.object(probe, "_has_symbol_versions", return_value=False):
                with self.assertRaisesRegex(probe.ProbeError, r"C\+\+ library"):
                    probe.preflight(Path("/absent"), ASSET)
            with mock.patch.object(probe, "_trusted_system_file", return_value=True), \
                 mock.patch.object(probe, "_has_symbol_versions", return_value=True), \
                 mock.patch.object(probe, "_trusted_manifest", return_value=True), \
                 mock.patch.object(probe, "_trusted_icd_library", return_value=False):
                with self.assertRaisesRegex(probe.ProbeError, "ICD"):
                    probe.preflight(Path("/absent"), ASSET)
            with mock.patch.object(probe, "_trusted_system_file", return_value=True), \
                 mock.patch.object(probe, "_has_symbol_versions", return_value=True), \
                 mock.patch.object(probe, "_trusted_manifest", return_value=True), \
                 mock.patch.object(probe, "_trusted_icd_library", return_value=True):
                self.assertEqual(len(probe.preflight(Path("/absent"), ASSET)["icdManifests"]), 1)

    def test_bounded_capture_and_eof_without_native_child(self):
        for data, expected in ((GOOD, None), (b"X" * 513, "output exceeded")):
            child = FakeChild(data)
            try:
                if expected:
                    with mock.patch.object(probe, "MAX_OUTPUT", 512):
                        with self.assertRaisesRegex(probe.ProbeError, expected):
                            probe._capture(child, time.monotonic() + 1)
                else:
                    self.assertEqual(probe._capture(child, time.monotonic() + 1), GOOD)
            finally:
                child.close()
        stalled = FakeChild(keep_open=True)
        try:
            with self.assertRaisesRegex(probe.ProbeError, "deadline"):
                probe._capture(stalled, time.monotonic() + 0.02)
        finally:
            stalled.close()

    def test_run_uses_exact_fixed_argv_and_scrubbed_environment_with_mock_transport(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            stage = Path(folder) / "stage"
            stage.mkdir(mode=0o700)
            engine_hash = next(item["sha256"] for item in ASSET["members"] if item["path"] == "llama-server")
            fake = mock.Mock(pid=8123)
            with mock.patch.object(probe, "preflight", return_value={"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]}), \
                 mock.patch.object(probe.runtime, "verify_tree"), \
                 mock.patch.object(probe.runtime, "digest_file", return_value=engine_hash), \
                 mock.patch.object(probe.subprocess, "Popen", return_value=fake) as launched, \
                 mock.patch.object(probe, "_stop_group") as stopped, \
                 mock.patch.object(probe, "_capture", return_value=GOOD):
                result = probe.run(stage)
            stopped.assert_called_once_with(fake)
            fake.stdout.close.assert_called_once()
            arguments, options = launched.call_args
            self.assertEqual(arguments[0], [str(stage / "llama-server"), "--list-devices"])
            self.assertEqual(options["env"]["VK_DRIVER_FILES"], "/usr/share/vulkan/icd.d/amd.json")
            self.assertFalse(any(key in options["env"] for key in ("LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH",
                                                             "VK_ICD_FILENAMES", "VK_LAYER_PATH", "GGML_MODEL")))
            self.assertTrue(options["start_new_session"])
            self.assertIs(options["preexec_fn"].func, probe._parent_death)
            self.assertEqual(options["preexec_fn"].args, (os.getpid(),))
            self.assertFalse(result["executionEnabledForServing"])
            self.assertFalse(result["dependencyClosureVerified"])
            self.assertFalse(result["driverIdentityVerified"])
            failed = mock.Mock(pid=8124)
            with mock.patch.object(probe, "preflight", return_value={"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]}), \
                 mock.patch.object(probe.runtime, "verify_tree"), \
                 mock.patch.object(probe.subprocess, "Popen", return_value=failed), \
                 mock.patch.object(probe, "_stop_group") as stopped, \
                 mock.patch.object(probe, "_capture", side_effect=probe.ProbeError("deadline")):
                with self.assertRaisesRegex(probe.ProbeError, "deadline"):
                    probe.run(stage)
            stopped.assert_called_once_with(failed)
            failed.stdout.close.assert_called_once()

    def test_sigterm_during_capture_stops_owned_probe_group(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            stage = Path(folder) / "stage"
            stage.mkdir(mode=0o700)
            handlers = {}
            child = mock.Mock(pid=8125)

            def install_handler(sig, handler):
                handlers[sig] = handler

            def interrupted_capture(_child, _deadline, interrupted):
                handlers[signal.SIGTERM](signal.SIGTERM, None)
                self.assertTrue(interrupted())
                raise probe.ProbeError("device probe interrupted")

            with mock.patch.object(probe, "preflight", return_value={"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]}), \
                 mock.patch.object(probe.runtime, "verify_tree"), \
                 mock.patch.object(probe.subprocess, "Popen", return_value=child), \
                 mock.patch.object(probe.signal, "signal", side_effect=install_handler) as signal_calls, \
                 mock.patch.object(probe, "_stop_group") as stopped, \
                 mock.patch.object(probe, "_capture", side_effect=interrupted_capture):
                with self.assertRaisesRegex(probe.ProbeError, "interrupted"):
                    probe.run(stage)
            stopped.assert_called_once_with(child)
            child.stdout.close.assert_called_once()
            self.assertEqual(signal_calls.call_count, 4)  # install and restore SIGINT/SIGTERM

    def test_spawn_failure_restores_handlers_without_group_cleanup(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            stage = Path(folder) / "stage"
            stage.mkdir(mode=0o700)
            with mock.patch.object(probe, "preflight", return_value={"icdManifests": ["/usr/share/vulkan/icd.d/amd.json"]}), \
                 mock.patch.object(probe.runtime, "verify_tree"), \
                 mock.patch.object(probe.subprocess, "Popen", side_effect=OSError("spawn refused")), \
                 mock.patch.object(probe.signal, "signal") as signal_calls, \
                 mock.patch.object(probe, "_stop_group") as stopped:
                with self.assertRaisesRegex(OSError, "spawn refused"):
                    probe.run(stage)
            stopped.assert_not_called()
            self.assertEqual(signal_calls.call_count, 4)

    @unittest.skipUnless(sys.platform.startswith("linux") and Path("/proc").is_dir(),
                         "requires Linux parent-death signaling and procfs")
    def test_parent_death_signal_kills_disposable_child(self):
        source = str(ROOT / "linux" / "probe.py")
        parent_script = (
            "import functools, importlib.util, os, select, subprocess, sys\n"
            f"s=importlib.util.spec_from_file_location('probe_child_test', {source!r})\n"
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
            "expected_parent=os.getpid()\n"
            "p=subprocess.Popen([sys.executable,'-c',"
            "'import os,time; print(\"READY\",os.getpid(),flush=True); time.sleep(30)'], "
            "stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL, "
            "text=True,start_new_session=True,"
            "preexec_fn=functools.partial(m._parent_death,expected_parent))\n"
            "ready,_,_=select.select([p.stdout],[],[],3)\n"
            "if not ready: p.kill(); raise SystemExit(2)\n"
            "line=p.stdout.readline().strip()\n"
            "if line != 'READY '+str(p.pid) or p.poll() is not None: raise SystemExit(3)\n"
            "print(line,flush=True)\n"
            "sys.stdin.buffer.read(1)\n"
        )
        parent = subprocess.Popen([sys.executable, "-I", "-B", "-c", parent_script],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, start_new_session=True)
        child_pid = None
        try:
            ready, _, _ = select.select([parent.stdout], [], [], 5)
            self.assertTrue(ready, "disposable parent did not report a live child")
            reported = parent.stdout.readline().strip().split()
            self.assertEqual(reported[0], "READY")
            child_pid = int(reported[1])
            self.assertIsNone(parent.poll(), "parent exited before deliberate handoff")
            self.assertNotEqual(Path(f"/proc/{child_pid}/stat").read_text().split()[2], "Z")
            parent.stdin.write("x")
            parent.stdin.flush()
            parent.stdin.close()
            self.assertEqual(parent.wait(timeout=5), 0)
            stopped = False
            for _ in range(100):
                status = Path(f"/proc/{child_pid}/stat")
                try:
                    state = status.read_text().split()[2]
                except (FileNotFoundError, ProcessLookupError):
                    stopped = True
                    break
                if state == "Z":
                    stopped = True
                    break
                time.sleep(0.05)
            self.assertTrue(stopped, "disposable child survived its parent")
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.wait(timeout=5)
            parent.stdout.close()
            parent.stderr.close()
            if not parent.stdin.closed:
                parent.stdin.close()
            if child_pid is not None:
                try:
                    os.killpg(child_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux prctl")
    def test_parent_death_setup_fails_closed_on_wrong_expected_pid(self):
        child = subprocess.run([sys.executable, "-c", "raise SystemExit(0)"], timeout=5,
                               preexec_fn=lambda: probe._parent_death(os.getpid() + 1))
        self.assertEqual(child.returncode, 127)


if __name__ == "__main__":
    unittest.main()
