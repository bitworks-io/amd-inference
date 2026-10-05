#!/usr/bin/env python3
"""Private, opt-in, foreground Linux Vulkan serving experiment.

This is not the public installer or an enabled catalog lane. It never downloads,
repairs, accepts a license, installs dependencies, or claims AMD device binding.
"""

import argparse
import ctypes
from contextlib import contextmanager
import fcntl
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def _load(name):
    source = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location("fastllm_linux_serve_" + name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


models = _load("models")
probe = _load("probe")
preview = _load("fast-llm-linux")
runtime = probe.runtime
PORT = 18082
MAX_OUTPUT = 8 * 1024 * 1024
MAX_LINE = 8192
MAX_PLACEMENT_LINES = 16
MAX_HTTP = 1024 * 1024
MAX_SSE_EVENTS = 64
LOAD_TIMEOUT = 300
HEALTH_INTERVAL = 5
LAYER = re.compile(r"^.*load_tensors: offloaded ([0-9]{1,4})/([0-9]{1,4}) layers to GPU\s*$")
BUFFER = re.compile(r"^.*load_tensors:\s+([A-Za-z][A-Za-z0-9_]*) model buffer size = ([0-9]{1,9}(?:\.[0-9]{1,4})?) MiB\s*$")
RUN_ID = re.compile(r"[0-9a-f]{32}\Z")


class ServeError(ValueError):
    pass


class HttpNotReady(ServeError):
    pass


def require_host():
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64") or os.geteuid() == 0:
        raise ServeError("private serving requires a standard-user Linux x86_64 host")


def _private_dir(path, *, create=False):
    path = Path(path).expanduser().absolute()
    models._real_ancestors(path.parent)
    if create and not path.exists() and not path.is_symlink():
        path.mkdir(mode=0o700)
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise ServeError("private directory must be real, user-owned and mode 0700")
    return path


def _private_bytes(path, ceiling):
    metadata = models._regular_private(path)
    if metadata.st_size > ceiling:
        raise ServeError("private file exceeds size ceiling")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        if (opened.st_ino != metadata.st_ino or opened.st_dev != metadata.st_dev
                or opened.st_size != metadata.st_size):
            raise ServeError("private file changed during open")
        data = bytearray()
        while len(data) <= ceiling:
            block = os.read(fd, min(65536, ceiling + 1 - len(data)))
            if not block:
                break
            data.extend(block)
        if len(data) != metadata.st_size:
            raise ServeError("private file changed during read")
        return bytes(data)
    finally:
        os.close(fd)


def verify_cached_model(catalog, model_id, cache_root):
    """Read-only exact consent and whole-file hash check; caller holds cache lock."""
    item = models._model(catalog, model_id)
    root = _private_dir(cache_root)
    stem = f"{item['id']}-{item['sha256']}"
    receipt = root / (stem + ".consent.json")
    model = root / (stem + ".gguf")
    try:
        recorded = json.loads(_private_bytes(receipt, 8192).decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ServeError("exact consent receipt is invalid") from exc
    if recorded != models._receipt(item):
        raise ServeError("exact consent receipt or conversion provenance differs")
    metadata = models._regular_private(model)
    if metadata.st_size != item["sizeBytes"]:
        raise ServeError("cached model size differs")
    fd = os.open(model, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened = os.fstat(fd)
        if (opened.st_ino != metadata.st_ino or opened.st_dev != metadata.st_dev
                or opened.st_size != metadata.st_size):
            raise ServeError("cached model changed during open")
        digest = hashlib.sha256()
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            digest.update(block)
        after = os.fstat(fd)
        path_after = model.lstat()
        if (after.st_ino != metadata.st_ino or path_after.st_ino != metadata.st_ino
                or after.st_size != metadata.st_size or after.st_mtime_ns != metadata.st_mtime_ns
                or path_after.st_mtime_ns != metadata.st_mtime_ns):
            raise ServeError("cached model changed during verification")
        if digest.hexdigest() != item["sha256"]:
            raise ServeError("cached model SHA-256 differs")
    finally:
        os.close(fd)
    return model, item


@contextmanager
def _operation_lock(root):
    lock = root / ".serve.lock"
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise ServeError("unsafe serving lock")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ServeError("a private serving operation already owns this run root") from exc
        yield
    finally:
        os.close(fd)


def _atomic_status(root, record):
    payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(payload) > 16384:
        raise ServeError("status exceeds size ceiling")
    temp = root / (".state-" + uuid.uuid4().hex)
    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, root / "status.json")
    finally:
        if temp.exists():
            temp.unlink()


def _proc_start(pid):
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        return int(raw.rsplit(") ", 1)[1].split()[19])
    except (OSError, UnicodeError, ValueError, IndexError):
        return None


def read_status(root):
    root = _private_dir(root)
    status = json.loads(_private_bytes(root / "status.json", 16384).decode("utf-8"))
    if not isinstance(status, dict) or not RUN_ID.fullmatch(str(status.get("runId", ""))):
        raise ServeError("invalid run-scoped status")
    pid = status.get("supervisorPid")
    ticks = status.get("supervisorStartTicks")
    if type(pid) is not int or pid <= 0 or type(ticks) is not int or ticks <= 0:
        raise ServeError("invalid supervisor identity in status")
    status["supervisorAlive"] = (_proc_start(pid) == ticks)
    if not status["supervisorAlive"] and status.get("phase") in ("loading", "ready"):
        status["phase"] = "supervisor-lost-unverified"
    elif status.get("phase") == "ready":
        child_pid = status.get("childPid")
        child_ticks = status.get("childStartTicks")
        if (type(child_pid) is not int or child_pid <= 0 or type(child_ticks) is not int
                or child_ticks <= 0 or _proc_start(child_pid) != child_ticks):
            status["phase"] = "child-lost-unverified"
    return status


def request_stop(root):
    root = _private_dir(root)
    state = read_status(root)
    if not state["supervisorAlive"] or state["phase"] not in ("loading", "ready", "child-lost-unverified"):
        raise ServeError("no matching live private supervisor")
    path = root / ("stop-" + state["runId"] + ".json")
    payload = json.dumps({"runId": state["runId"], "supervisorStartTicks": state["supervisorStartTicks"]}).encode()
    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        try:
            existing = json.loads(_private_bytes(path, 512).decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise ServeError("existing stop request is malformed") from exc
        if existing != {"runId": state["runId"], "supervisorStartTicks": state["supervisorStartTicks"]}:
            raise ServeError("existing stop request does not match this run")
        return {"stopRequestedFor": state["runId"]}
    with os.fdopen(fd, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    return {"stopRequestedFor": state["runId"]}


def _stop_requested(root, state):
    path = root / ("stop-" + state["runId"] + ".json")
    try:
        request = json.loads(_private_bytes(path, 512).decode("utf-8"))
        return request == {"runId": state["runId"], "supervisorStartTicks": state["supervisorStartTicks"]}
    except FileNotFoundError:
        return False


class PlacementCapture:
    """Drain continuously; retain only bounded placement numbers, never raw logs."""

    def __init__(self, stream):
        self.stream = stream
        self.lock = threading.Lock()
        self.lines = []
        self.total = 0
        self.error = None
        self.frozen = False
        self.thread = threading.Thread(target=self._drain, daemon=True)
        self.thread.start()

    def _record(self, raw):
        if len(raw) > MAX_LINE:
            self.error = "native-output-line-limit"
            return
        try:
            line = raw.decode("utf-8")
        except UnicodeError:
            self.error = "native-output-encoding"
            return
        if "load_tensors:" not in line:
            return
        # Only placement-shaped lines influence the gate; no descriptions,
        # paths, prompt text or arbitrary log tails survive in the report.
        if "offloaded" in line or "model buffer size" in line:
            match = LAYER.fullmatch(line) or BUFFER.fullmatch(line)
            if not match:
                self.error = "malformed-placement-line"
            elif self.frozen:
                self.error = "late-placement-line"
            else:
                if len(self.lines) >= MAX_PLACEMENT_LINES:
                    self.error = "placement-line-limit"
                else:
                    self.lines.append(("layer" if "offloaded" in line else "buffer", match.groups()))

    def _drain(self):
        pending = bytearray()
        try:
            while True:
                # BufferedReader.read(n) may wait to fill n bytes while the
                # server remains alive; read1 returns the available pipe data.
                reader = getattr(self.stream, "read1", self.stream.read)
                block = reader(65536)
                if not block:
                    break
                with self.lock:
                    self.total += len(block)
                    if self.total > MAX_OUTPUT:
                        self.error = "native-output-total-limit"
                    pending.extend(block)
                    if len(pending) > MAX_LINE and b"\n" not in pending:
                        self.error = "native-output-line-limit"
                        pending.clear()
                    while b"\n" in pending:
                        raw, _, remaining = pending.partition(b"\n")
                        pending = bytearray(remaining)
                        if self.total <= MAX_OUTPUT:
                            self._record(raw.rstrip(b"\r"))
            with self.lock:
                if pending and self.total <= MAX_OUTPUT:
                    self._record(bytes(pending))
        except (OSError, ValueError):
            with self.lock:
                self.error = "native-output-read-failed"

    def freeze(self):
        with self.lock:
            self.frozen = True
            if self.error:
                raise ServeError(self.error)
            layers = [item[1] for item in self.lines if item[0] == "layer"]
            buffers = [item[1] for item in self.lines if item[0] == "buffer"]
        if len(layers) != 1 or len(buffers) != 1:
            raise ServeError("missing or ambiguous all-GPU placement evidence")
        loaded, total = map(int, layers[0])
        device, mib = buffers[0]
        if loaded <= 0 or loaded != total or device != "Vulkan0" or float(mib) <= 0:
            raise ServeError("reported layers or model buffer differ from requested all-GPU device")
        return {"reportedLayers": loaded, "reportedTotalLayers": total,
                "reportedModelBufferDevice": device, "reportedModelBufferMiB": float(mib),
                "reportedAllLayers": True, "physicalResidencyVerified": False}


@contextmanager
def _absolute_alarm(deadline):
    """Main-thread Linux wall-clock guard for header/body slow-drip traffic."""
    if threading.current_thread() is not threading.main_thread():
        raise ServeError("loopback HTTP must run on the supervising main thread")
    started = time.monotonic()
    remaining = deadline - started
    if remaining <= 0:
        raise ServeError("loopback API deadline exceeded")
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    previous_handler = signal.getsignal(signal.SIGALRM)
    def expired(_signal, _frame):
        raise ServeError("loopback API deadline exceeded")
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, remaining)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        old_seconds, old_interval = previous_timer
        if old_seconds > 0:
            signal.setitimer(signal.ITIMER_REAL, max(0.000001, old_seconds - (time.monotonic() - started)), old_interval)


def _http(method, path, body, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ServeError("load deadline exceeded")
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=min(5, remaining))
    try:
        with _absolute_alarm(deadline):
            encoded = json.dumps(body, separators=(",", ":")).encode() if body is not None else None
            connection.request(method, path, body=encoded, headers={"Content-Type": "application/json"} if encoded else {})
            response = connection.getresponse()
            if response.status == 503:
                raise HttpNotReady("loopback API is still loading")
            if response.status != 200:
                raise ServeError("loopback API response is not successful")
            data = bytearray()
            while True:
                block = response.read1(min(65536, MAX_HTTP + 1 - len(data)))
                if not block:
                    break
                data.extend(block)
                if len(data) > MAX_HTTP:
                    raise ServeError("loopback API response is oversized")
            result = json.loads(data.decode("utf-8"))
            if not isinstance(result, dict):
                raise ServeError("loopback API response shape differs")
            return result
    except (OSError, UnicodeError, json.JSONDecodeError, http.client.HTTPException) as exc:
        if isinstance(exc, (UnicodeError, json.JSONDecodeError)):
            raise ServeError("loopback API response is malformed") from exc
        raise HttpNotReady("loopback API connection is not ready") from exc
    finally:
        connection.close()


def _parse_chat_sse(payload, model_id):
    try:
        text = payload.decode("utf-8")
    except UnicodeError as exc:
        raise ServeError("streaming chat is not UTF-8") from exc
    if "\r" in text.replace("\r\n", ""):
        raise ServeError("streaming chat has malformed line endings")
    text = text.replace("\r\n", "\n")
    if not text.endswith("\n\n"):
        raise ServeError("streaming chat ended with a partial event")
    frames = text[:-2].split("\n\n")
    if not 2 <= len(frames) <= MAX_SSE_EVENTS + 1:
        raise ServeError("streaming chat event count differs")
    role_seen = False
    text_seen = False
    finish_seen = False
    done_seen = False
    for index, frame in enumerate(frames):
        lines = frame.split("\n")
        if len(lines) != 1 or not lines[0].startswith("data: "):
            raise ServeError("streaming chat event frame is malformed")
        data = lines[0][6:]
        if data == "[DONE]":
            if done_seen or index != len(frames) - 1 or not finish_seen:
                raise ServeError("streaming chat completion marker is misplaced")
            done_seen = True
            continue
        if finish_seen:
            raise ServeError("streaming chat continued after its final choice")
        try:
            event = json.loads(data)
        except json.JSONDecodeError as exc:
            raise ServeError("streaming chat event JSON is malformed") from exc
        if (not isinstance(event, dict) or event.get("object") != "chat.completion.chunk"
                or event.get("model") != model_id):
            raise ServeError("streaming chat event model or shape differs")
        choices = event.get("choices")
        if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
            raise ServeError("streaming chat choice count differs")
        choice = choices[0]
        if type(choice.get("index")) is not int or choice["index"] != 0 or not isinstance(choice.get("delta"), dict):
            raise ServeError("streaming chat choice index or delta differs")
        delta = choice["delta"]
        if "role" in delta:
            if delta["role"] != "assistant" or role_seen:
                raise ServeError("streaming chat assistant role differs")
            role_seen = True
        for key in ("content", "reasoning_content", "reasoning"):
            if key in delta:
                if delta[key] is not None and not isinstance(delta[key], str):
                    raise ServeError("streaming chat text field is malformed")
                text_seen |= bool(delta[key])
        reason = choice.get("finish_reason")
        if reason is not None:
            if reason not in ("stop", "length"):
                raise ServeError("streaming chat finish reason differs")
            finish_seen = True
    if not role_seen or not text_seen or not finish_seen or not done_seen:
        raise ServeError("streaming chat lacked assistant text or completion")
    return True


def _http_stream_chat(model_id, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ServeError("load deadline exceeded")
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=min(5, remaining))
    try:
        body = {"model": model_id, "messages": [{"role": "user", "content": "Say hello."}],
                "max_tokens": 8, "temperature": 0, "seed": 42, "stream": True}
        with _absolute_alarm(deadline):
            connection.request("POST", "/v1/chat/completions",
                               body=json.dumps(body, separators=(",", ":")).encode(),
                               headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            if response.status != 200:
                raise ServeError("streaming chat response is not successful")
            if not response.getheader("Content-Type", "").lower().startswith("text/event-stream"):
                raise ServeError("streaming chat content type differs")
            payload = bytearray()
            while True:
                block = response.read1(min(65536, MAX_HTTP + 1 - len(payload)))
                if not block:
                    break
                payload.extend(block)
                if len(payload) > MAX_HTTP:
                    raise ServeError("streaming chat exceeded size ceiling")
            return _parse_chat_sse(bytes(payload), model_id)
    except (OSError, http.client.HTTPException) as exc:
        raise ServeError("streaming chat transport failed") from exc
    finally:
        connection.close()


def _listener_owned_by(pid):
    """Require this direct child to own the loopback LISTEN socket inode."""
    try:
        inode = None
        with open("/proc/net/tcp", encoding="ascii") as stream:
            for line in stream:
                fields = line.split()
                if len(fields) > 9 and fields[1] == f"0100007F:{PORT:04X}" and fields[3] == "0A":
                    if inode is not None:
                        return False
                    inode = fields[9]
        if inode is None:
            return False
        fd_dir = Path(f"/proc/{pid}/fd")
        for entry in fd_dir.iterdir():
            if os.readlink(entry) == f"socket:[{inode}]":
                return True
    except (OSError, ValueError):
        return False
    return False


def _canaries(model_id, context, deadline):
    listed = _http("GET", "/v1/models", None, deadline)
    if sum(item.get("id") == model_id for item in listed.get("data", []) if isinstance(item, dict)) != 1:
        raise ServeError("API model identity differs")
    props = _http("GET", "/props", None, deadline)
    settings = props.get("default_generation_settings", {})
    if type(settings.get("n_ctx")) is not int or settings["n_ctx"] != context or props.get("total_slots") != 1:
        raise ServeError("API context or slot count differs")
    tokens = []
    for _ in range(2):
        answer = _http("POST", "/completion", {"prompt": "The capital of France is", "n_predict": 1,
                       "temperature": 0, "seed": 42, "cache_prompt": False, "return_tokens": True,
                       "ignore_eos": True, "stream": False}, deadline)
        found = answer.get("tokens")
        if not isinstance(found, list) or len(found) != 1 or type(found[0]) is not int or found[0] < 0:
            raise ServeError("one-token inference canary failed")
        tokens.append(found[0])
    if tokens[0] != tokens[1]:
        raise ServeError("one-token inference was not repeatable")
    chat = _http("POST", "/v1/chat/completions", {"model": model_id,
                 "messages": [{"role": "user", "content": "Say hello."}],
                 "max_tokens": 8, "temperature": 0, "seed": 42, "stream": False}, deadline)
    choices = chat.get("choices")
    if not isinstance(choices, list) or len(choices) != 1 or not isinstance(choices[0], dict):
        raise ServeError("chat canary choice count differs")
    message = choices[0].get("message", {})
    if message.get("role") != "assistant" or not any(isinstance(message.get(key), str) and message[key]
            for key in ("content", "reasoning_content", "reasoning")):
        raise ServeError("chat canary returned no assistant text")
    _http_stream_chat(model_id, deadline)
    return {"modelIdentity": True, "effectiveContext": True, "repeatableOneToken": True,
            "synchronousChat": True, "streamingChat": True}


def _port_free():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", PORT))


def _parent_death(expected_parent):
    if os.getppid() != expected_parent:
        os._exit(127)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGKILL, 0, 0, 0) != 0 or os.getppid() != expected_parent:
        os._exit(127)


def _kill_group(child):
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired as exc:
        raise ServeError("native child could not be reaped") from exc


def _argv(engine, model, item):
    return [str(engine), "--model", str(model), "--offline", "--no-mmproj", "--spec-type", "none",
            "--alias", item["id"], "--host", "127.0.0.1", "--port", str(PORT),
            "--cors-origins", "localhost", "--no-cors-credentials", "--ctx-size", str(item["contextSize"]),
            "--parallel", "1", "--n-gpu-layers", "all", "--fit", "on",
            "--fit-target", str(item["fitTargetMiB"]), "--device", "Vulkan0", "--split-mode", "none",
            "--flash-attn", "auto", "--cache-type-k", item["cacheTypeK"],
            "--cache-type-v", item["cacheTypeV"], "--jinja", "--metrics", "--log-verbosity", "4",
            "--no-agent", "--no-ui"]


def _fresh_inputs(stage, cache_root, model_id):
    catalog = models.load_catalog()
    model, item = verify_cached_model(catalog, model_id, cache_root)
    asset = runtime.load_asset()
    runtime.verify_tree(stage, asset)
    return catalog, model, item, asset


def _recheck_after_probe(stage, cache_root, catalog, model, item, asset, initial_metadata):
    if models.load_catalog() != catalog or models._model(catalog, item["id"]) != item:
        raise ServeError("catalog or model policy changed after the native probe")
    receipt = cache_root / f"{item['id']}-{item['sha256']}.consent.json"
    try:
        if json.loads(_private_bytes(receipt, 8192).decode("utf-8")) != models._receipt(item):
            raise ServeError("consent receipt changed after the native probe")
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ServeError("consent receipt changed after the native probe") from exc
    current = models._regular_private(model)
    identity_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_nlink", "st_mode")
    if any(getattr(current, key) != getattr(initial_metadata, key) for key in identity_fields):
        raise ServeError("cached model changed after the native probe")
    if runtime.load_asset() != asset:
        raise ServeError("engine candidate changed after the native probe")
    runtime.verify_tree(stage, asset)


def run(stage, cache_root, run_root, model_id, *, load_timeout=LOAD_TIMEOUT):
    require_host()
    if not 30 <= load_timeout <= 600:
        raise ServeError("load timeout outside private lab bounds")
    stage = Path(stage).expanduser().absolute()
    cache_root = _private_dir(cache_root)
    run_root = _private_dir(run_root, create=True)
    with _operation_lock(run_root), models._lock(cache_root, time.monotonic() + 5):
        catalog, model, item, asset = _fresh_inputs(stage, cache_root, model_id)
        model_metadata = models._regular_private(model)
        # This executes the reviewed native --list-devices probe only after the
        # whole-file model check, then rechecks unchanged file/provenance state.
        hardware = probe.run(stage)
        _recheck_after_probe(stage, cache_root, catalog, model, item, asset, model_metadata)
        devices = hardware["devices"]
        eligible = [gpu for gpu in preview.inventory() if gpu["recipeEligible"]]
        if len(devices) != 1 or devices[0]["device"] != "Vulkan0" or len(eligible) != 1:
            raise ServeError("private trial requires exactly one Vulkan device and one recognized discrete AMD sysfs card")
        if not re.fullmatch(r"AMD Radeon (?:RX [A-Za-z0-9 ]+|AI PRO [A-Za-z0-9 ]+)", devices[0]["name"]):
            raise ServeError("engine-reported name does not pass the private discrete AMD heuristic")
        if min(devices[0]["reportedFreeMiB"], eligible[0]["vramFreeMiB"]) < item["requiredFreeVramMiB"]:
            raise ServeError("current reported free VRAM is below the catalog estimate")
        if hardware["engineArchiveSha256"] != asset["sha256"] or hardware["fixture"]:
            raise ServeError("native device probe did not bind the pinned engine candidate")
        # The sysfs card and Vulkan0 are deliberately NOT claimed to be joined.
        _port_free()
        engine = stage / asset["entryPoint"]
        args = _argv(engine, model, item)
        identity = {"sourceFileSha256": runtime.digest_file(Path(__file__)),
                    "engineManifestSha256": probe.PINNED_MANIFEST_SHA256,
                    "engineArchiveSha256": asset["sha256"],
                    "engineFileSha256": hardware["engineFileSha256"],
                    "catalogSha256": runtime.digest_file(models.CATALOG),
                    "modelSha256": item["sha256"],
                    "launchArgumentsSha256": hashlib.sha256(json.dumps(args, separators=(",", ":")).encode()).hexdigest()}
        run_id = uuid.uuid4().hex
        state = {"schemaVersion": 1, "privateLabOnly": True, "phase": "loading", "runId": run_id,
                 "supervisorPid": os.getpid(), "supervisorStartTicks": _proc_start(os.getpid()),
                 "childPid": None, "childStartTicks": None,
                 "modelId": model_id, "contextSize": item["contextSize"],
                 "endpoint": f"http://127.0.0.1:{PORT}/v1", "identity": identity,
                 "deviceProbeCompleted": True, "amdPciToVulkanBindingVerified": False,
                 "modelProcessMappingAttested": False,
                 "dynamicDependencyClosureVerified": False, "physicalResidencyVerified": False,
                 "semanticCorrectnessQualified": False, "performanceQualified": False,
                 "publicServingEnabled": False, "reportedPlacement": None, "apiCanaries": None,
                 "failureCode": None}
        if state["supervisorStartTicks"] is None:
            raise ServeError("supervisor process identity is unavailable")
        _atomic_status(run_root, state)
        deadline = time.monotonic() + load_timeout
        prior_handlers = {}
        interrupted = threading.Event()
        def interrupted_signal(_signal, _frame):
            interrupted.set()
        for sig in (signal.SIGINT, signal.SIGTERM):
            prior_handlers[sig] = signal.getsignal(sig)
            signal.signal(sig, interrupted_signal)
        child = None
        capture = None
        try:
            with tempfile.TemporaryDirectory(prefix="fastllm-serve-", dir=run_root) as scratch:
                private = Path(scratch)
                environment = {"PATH": "/usr/bin:/bin", "HOME": str(private), "TMPDIR": str(private),
                               "XDG_CONFIG_HOME": str(private), "XDG_DATA_HOME": str(private),
                               "LC_ALL": "C", "LANG": "C",
                               "VK_DRIVER_FILES": ":".join(hardware["host"]["icdManifests"]),
                               "VK_LOADER_LAYERS_DISABLE": "~implicit~"}
                child = subprocess.Popen(args, cwd=private, env=environment, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         start_new_session=True, close_fds=True,
                                         preexec_fn=lambda: _parent_death(state["supervisorPid"]))
                state["childPid"] = child.pid
                state["childStartTicks"] = _proc_start(child.pid)
                if state["childStartTicks"] is None:
                    raise ServeError("native child process identity is unavailable")
                _atomic_status(run_root, state)
                capture = PlacementCapture(child.stdout)
                while True:
                    if interrupted.is_set() or _stop_requested(run_root, state):
                        raise ServeError("run-scoped stop requested")
                    if child.poll() is not None:
                        raise ServeError("native server exited before readiness")
                    if time.monotonic() >= deadline:
                        raise ServeError("model-load deadline exceeded")
                    if capture.error:
                        raise ServeError(capture.error)
                    if _listener_owned_by(child.pid):
                        try:
                            health = _http("GET", "/health", None, deadline)
                            if health.get("status") == "ok":
                                state["reportedPlacement"] = capture.freeze()
                                state["apiCanaries"] = _canaries(model_id, item["contextSize"], deadline)
                                if capture.error:
                                    raise ServeError(capture.error)
                                if (child.poll() is not None or _proc_start(child.pid) != state["childStartTicks"]
                                        or not _listener_owned_by(child.pid)):
                                    raise ServeError("supervised loopback listener changed during API canaries")
                                state["phase"] = "ready"
                                _atomic_status(run_root, state)
                                break
                        except HttpNotReady:
                            pass
                        # Malformed HTTP 200, placement and canary failures are
                        # not loading transients and must fail this run.
                    time.sleep(0.2)
                next_health = time.monotonic() + HEALTH_INTERVAL
                while True:
                    if interrupted.is_set() or _stop_requested(run_root, state):
                        state["phase"] = "stopped"
                        break
                    if child.poll() is not None:
                        state["phase"] = "exited"
                        state["failureCode"] = "native-server-exited-after-ready"
                        break
                    if capture.error:
                        state["phase"] = "failed"
                        state["failureCode"] = capture.error
                        break
                    if time.monotonic() >= next_health:
                        if not _listener_owned_by(child.pid):
                            raise ServeError("supervised loopback listener was lost after Ready")
                        health = _http("GET", "/health", None, time.monotonic() + 5)
                        if health.get("status") != "ok":
                            raise ServeError("loopback health was lost after Ready")
                        next_health = time.monotonic() + HEALTH_INTERVAL
                    time.sleep(0.2)
        except Exception as exc:
            state["phase"] = "failed"
            state["failureCode"] = str(exc) if isinstance(exc, ServeError) else "private-supervisor-error"
        finally:
            for sig, handler in prior_handlers.items():
                signal.signal(sig, handler)
            if child is not None:
                try:
                    _kill_group(child)
                except ServeError:
                    state["phase"] = "failed"
                    state["failureCode"] = "native-child-cleanup-unverified"
                finally:
                    if child.stdout is not None:
                        child.stdout.close()
                    if capture is not None:
                        capture.thread.join(timeout=5)
            _atomic_status(run_root, state)
        return state


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("start", "status", "stop"))
    parser.add_argument("--run-root", type=Path, default=Path.home() / ".fastllm-linux-run")
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--cache-root", type=Path, default=Path.home() / ".fastllm-models")
    parser.add_argument("--model-id")
    parser.add_argument("--load-timeout", type=int, default=LOAD_TIMEOUT)
    parser.add_argument("--lab-serve", action="store_true", help="explicitly opt in to unqualified foreground native serving")
    args = parser.parse_args(argv)
    try:
        require_host()
        if args.command == "start":
            if not args.lab_serve or args.stage is None or args.model_id is None:
                parser.error("start requires --lab-serve, --stage and exact --model-id")
            result = run(args.stage, args.cache_root, args.run_root, args.model_id,
                         load_timeout=args.load_timeout)
        elif args.command == "status":
            result = read_status(args.run_root)
        else:
            result = request_stop(args.run_root)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2))
    return 0 if result.get("phase") not in ("failed", "exited", "supervisor-lost-unverified",
                                            "child-lost-unverified") else 1


if __name__ == "__main__":
    sys.exit(main())
