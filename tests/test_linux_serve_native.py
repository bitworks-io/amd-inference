"""Disposable Linux process tests for the private serving supervisor.

No inference engine, GPU, model, network download, or privileged operation is used.
These tests exercise kernel process behavior, not serving qualification.
"""

import importlib.util
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SERVE_SOURCE = ROOT / "linux" / "serve.py"
SPEC = importlib.util.spec_from_file_location("fastllm_linux_serve_native", SERVE_SOURCE)
serve = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(serve)


def _identity(pid):
    """Return (kernel state, start ticks), or None when this PID has gone."""
    try:
        fields = Path(f"/proc/{pid}/stat").read_text(encoding="ascii").rsplit(") ", 1)[1].split()
        return fields[0], int(fields[19])
    except (OSError, UnicodeError, ValueError, IndexError):
        return None


def _running(pid, ticks):
    found = _identity(pid)
    # A reparented zombie is not executing; some containers do not reap it
    # promptly. A reused PID is also not the original child.
    return found is not None and found[1] == ticks and found[0] not in ("Z", "X", "x")


def _await(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def _read_record(path):
    try:
        record = json.loads(path.read_text(encoding="ascii"))
        if type(record.get("pid")) is int and type(record.get("ticks")) is int:
            return record
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        pass
    return None


def _safe_kill(pid, ticks):
    if _running(pid, ticks):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


@unittest.skipUnless(platform.system() == "Linux" and Path("/proc/self/stat").exists(),
                     "requires the actual Linux /proc and prctl kernel interfaces")
class NativeLinuxServeTests(unittest.TestCase):
    def test_parent_death_preexec_rejects_wrong_expected_parent(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True,
                                 preexec_fn=lambda: serve._parent_death(os.getpid() + 1000000))
        try:
            self.assertEqual(child.wait(timeout=5), 127)
        finally:
            if child.poll() is None:
                serve._kill_group(child)

    def test_kill_group_reaps_direct_child_and_stops_grandchild(self):
        with tempfile.TemporaryDirectory() as folder:
            record_path = Path(folder) / "grandchild.json"
            code = (
                "import json,os,pathlib,subprocess,sys,time\n"
                "grand=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],"
                "stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\n"
                "raw=pathlib.Path('/proc/%d/stat'%grand.pid).read_text().rsplit(') ',1)[1].split()\n"
                "pathlib.Path(sys.argv[1]).write_text(json.dumps({'pid':grand.pid,'ticks':int(raw[19])}))\n"
                "time.sleep(30)\n"
            )
            child = subprocess.Popen([sys.executable, "-c", code, str(record_path)],
                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
            grandchild = None
            try:
                self.assertTrue(_await(lambda: _read_record(record_path) is not None),
                                "disposable grandchild did not start")
                grandchild = _read_record(record_path)
                self.assertTrue(_running(grandchild["pid"], grandchild["ticks"]))
                serve._kill_group(child)
                self.assertIsNotNone(child.poll(), "direct child was not reaped")
                self.assertTrue(_await(lambda: not _running(grandchild["pid"], grandchild["ticks"])),
                                "process-group kill left a running grandchild")
            finally:
                if child.poll() is None:
                    serve._kill_group(child)
                if grandchild is not None:
                    _safe_kill(grandchild["pid"], grandchild["ticks"])

    def test_supervisor_death_kills_its_direct_child(self):
        with tempfile.TemporaryDirectory() as folder:
            record_path = Path(folder) / "child.json"
            # This disposable supervisor imports the real helper. Popen does
            # not return until preexec_fn has installed PDEATHSIG in the child.
            code = (
                "import importlib.util,json,os,pathlib,subprocess,sys,time\n"
                "spec=importlib.util.spec_from_file_location('native_serve',sys.argv[1])\n"
                "serve=importlib.util.module_from_spec(spec);spec.loader.exec_module(serve)\n"
                "parent=os.getpid()\n"
                "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'],"
                "stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,"
                "start_new_session=True,preexec_fn=lambda:serve._parent_death(parent))\n"
                "ticks=serve._proc_start(child.pid)\n"
                "pathlib.Path(sys.argv[2]).write_text(json.dumps({'pid':child.pid,'ticks':ticks}))\n"
                "time.sleep(30)\n"
            )
            supervisor = subprocess.Popen([sys.executable, "-c", code,
                                           str(SERVE_SOURCE), str(record_path)],
                                          stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                          stderr=subprocess.DEVNULL, start_new_session=True)
            child = None
            try:
                self.assertTrue(_await(lambda: _read_record(record_path) is not None),
                                "disposable supervisor did not publish child identity")
                child = _read_record(record_path)
                self.assertTrue(_running(child["pid"], child["ticks"]))
                os.kill(supervisor.pid, signal.SIGKILL)
                supervisor.wait(timeout=5)
                self.assertTrue(_await(lambda: not _running(child["pid"], child["ticks"])),
                                "PDEATHSIG left a running direct child")
            finally:
                if supervisor.poll() is None:
                    supervisor.kill()
                    supervisor.wait(timeout=5)
                if child is not None:
                    _safe_kill(child["pid"], child["ticks"])


if __name__ == "__main__":
    unittest.main()
