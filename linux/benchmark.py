#!/usr/bin/env python3
"""Private Linux API benchmark producer for an already-Ready private lab server.

This ATTACHES to a run started by linux/lab.py or linux/serve.py. It never
starts, stops, repairs or downloads anything, talks only to 127.0.0.1, and
records sample semantics that mirror src/FastLlm.Benchmark.ps1. The report is
an experiment record, not a qualification: every qualification flag is false.
"""

import argparse
import datetime
import errno
import fcntl
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import stat
import sys
import threading
import time
import uuid

SCHEMA_VERSION = 1
RESULT_KIND = "native-linux-api-benchmark-not-full-qualification"
PRODUCER = "fastllm-linux-benchmark-v1"
ARTIFACT_FORMAT = "fastllm-prompt-tokens-v1"
CORPUS_ID = "fastllm-repeated-prose-v1-lf"
CORPUS_UNIT = ("A local inference system should produce accurate useful answers. "
               "Measure speed consistently while preserving model quality. \n")
MIN_REPETITIONS = 5
MAX_REPETITIONS = 100
MIN_PROMPT_TOKENS = 16
MAX_OUTPUT_TOKENS = 1024
MAX_WARMUP = 5
SAMPLE_HZ_MIN, SAMPLE_HZ_MAX = 0.2, 5.0
REQUEST_TIMEOUT = 180.0
TOKENIZE_TIMEOUT = 30.0
MAX_STATE_BYTES = 16384
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_STREAM_BYTES = 8 * 1024 * 1024
MAX_STREAM_EVENTS = 4096
MAX_LINE_BYTES = 1024 * 1024
MAX_FACT_BYTES = 4096
RUN_ID = re.compile(r"[0-9a-f]{32}\Z")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
BDF = re.compile(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]\Z")
CARD = re.compile(r"card[0-9]+\Z")
CPU_DIR = re.compile(r"cpu[0-9]+\Z")
DMI_FIELDS = ("board_vendor", "board_name", "bios_vendor", "bios_version", "bios_date",
              "sys_vendor", "product_name")
IDENTITY_HASHES = ("sourceFileSha256", "engineManifestSha256", "engineArchiveSha256",
                   "engineFileSha256", "catalogSha256", "modelSha256", "launchArgumentsSha256")
TOP_LEVEL_ORDER = ("schemaVersion", "resultKind", "recordedAt", "producer", "modelId", "modelSha256",
                   "recipe", "requestedLaunch", "run", "os", "processorCount", "methodology",
                   "serverProps", "hostFacts", "telemetry", "binding", "canary", "placement",
                   "samples", "summary", "qualification")


class Refusal(Exception):
    """Typed refusal: a stable machine-readable code plus a short detail."""

    def __init__(self, code, detail=""):
        super().__init__(code + (": " + detail if detail else ""))
        self.code = code
        self.detail = detail


class IdentityChanged(Refusal):
    def __init__(self, detail):
        super().__init__("identity-changed", detail)


class Roots(object):
    """Injectable filesystem roots so tests can supply a fake sysfs/procfs tree."""

    def __init__(self, sys_root="/sys", proc_root="/proc", etc_root="/etc", uname=os.uname):
        self.sys = Path(sys_root)
        self.proc = Path(proc_root)
        self.etc = Path(etc_root)
        self.uname = uname


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def source_sha256():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


# ---------------------------------------------------------------- typed facts

def read_bounded(path, limit=MAX_FACT_BYTES, truncate=False):
    """Return (status, text). Failure statuses are typed, never an empty string."""
    try:
        with open(path, "rb") as source:
            raw = source.read(limit + 1)
    except PermissionError:
        return "permission-denied", None
    except (FileNotFoundError, NotADirectoryError):
        return "not-present", None
    except OSError as exc:
        return "unreadable:errno-" + str(exc.errno), None
    if len(raw) > limit:
        if not truncate:
            return "oversize", None
        raw = raw[:limit]
    try:
        return "ok", raw.decode("utf-8")
    except UnicodeError:
        return "malformed", None


def fact(path, kind="text"):
    """One sysfs/procfs value as {status[, value]}. kind is text, int or hex-id."""
    status, text = read_bounded(path)
    if status != "ok":
        return {"status": status}
    value = text.strip()
    if kind == "int":
        try:
            if not re.fullmatch(r"[0-9]{1,20}", value):
                raise ValueError
            return {"status": "ok", "value": int(value)}
        except ValueError:
            return {"status": "malformed"}
    if not value:
        return {"status": "empty"}
    return {"status": "ok", "value": value}


def fact_value(item):
    return item.get("value") if isinstance(item, dict) and item.get("status") == "ok" else None


# ------------------------------------------------------------------ GPU sysfs

def discover_gpus(roots):
    """AMD (0x1002) display-class PCI devices via /sys/class/drm/card*/device."""
    found = {}
    drm = roots.sys / "class" / "drm"
    try:
        names = sorted(name for name in os.listdir(drm) if CARD.fullmatch(name))
    except OSError:
        return []
    for name in names:
        device = drm / name / "device"
        vendor = fact_value(fact(device / "vendor"))
        klass = fact_value(fact(device / "class"))
        if vendor is None or klass is None or vendor.lower() != "0x1002" or not klass.lower().startswith("0x03"):
            continue
        real = Path(os.path.realpath(device))
        if not BDF.fullmatch(real.name):
            continue
        found.setdefault(real.name, {"bdf": real.name, "device": device, "real": real, "card": name})
    return [found[key] for key in sorted(found)]


def pcie_chain(real):
    """BDFs along the sysfs device path: root port first, the GPU itself last."""
    return [part for part in Path(real).parts if BDF.fullmatch(part)]


def _link_level(real_path_of_level, bdf, role):
    return {"bdf": bdf, "role": role,
            "currentLinkSpeed": fact(real_path_of_level / "current_link_speed"),
            "maxLinkSpeed": fact(real_path_of_level / "max_link_speed"),
            "currentLinkWidth": fact(real_path_of_level / "current_link_width", "int"),
            "maxLinkWidth": fact(real_path_of_level / "max_link_width", "int")}


def link_walk(real):
    """Every level from the root port to the GPU, each with its own link facts."""
    real = Path(real)
    parts = real.parts
    levels = []
    chain_indexes = [index for index, part in enumerate(parts) if BDF.fullmatch(part)]
    for position, index in enumerate(chain_indexes):
        level_path = Path(*parts[:index + 1])
        if position == len(chain_indexes) - 1:
            role = "gpu"
        elif position == 0:
            role = "root-port"
        else:
            role = "upstream-bridge"
        levels.append(_link_level(level_path, parts[index], role))
    return levels


def _hwmon_dir(device):
    try:
        names = sorted(name for name in os.listdir(Path(device) / "hwmon") if name.startswith("hwmon"))
    except OSError:
        return None
    return Path(device) / "hwmon" / names[0] if names else None


def gpu_facts(gpu):
    device = gpu["device"]
    hwmon = _hwmon_dir(device)
    if hwmon is None:
        power_cap = {"status": "not-present", "detail": "no hwmon directory"}
    else:
        power_cap = {"powerCapMicroWatts": fact(hwmon / "power1_cap", "int"),
                     "powerCapMaxMicroWatts": fact(hwmon / "power1_cap_max", "int"),
                     "powerCapDefaultMicroWatts": fact(hwmon / "power1_cap_default", "int")}
    return {"bdf": gpu["bdf"], "card": gpu["card"],
            "vendorId": fact(device / "vendor"), "deviceId": fact(device / "device"),
            "revisionId": fact(device / "revision"), "classCode": fact(device / "class"),
            "subsystemVendorId": fact(device / "subsystem_vendor"),
            "subsystemDeviceId": fact(device / "subsystem_device"),
            "vramTotalBytes": fact(device / "mem_info_vram_total", "int"),
            "vramUsedBytes": fact(device / "mem_info_vram_used", "int"),
            "gttTotalBytes": fact(device / "mem_info_gtt_total", "int"),
            "gttUsedBytes": fact(device / "mem_info_gtt_used", "int"),
            "powerCap": power_cap,
            "pcieLinkWalk": link_walk(gpu["real"])}


# ------------------------------------------------------------------ host facts

def _os_release(roots):
    status, text = read_bounded(roots.etc / "os-release", 16384)
    if status != "ok":
        return {"status": status}
    values = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([A-Z_][A-Z0-9_]*)=(.*)", line.strip())
        if match:
            values[match.group(1)] = match.group(2).strip().strip('"')
    wanted = {key: values[key] for key in ("ID", "VERSION_ID", "VERSION_CODENAME", "PRETTY_NAME") if key in values}
    return {"status": "ok", "value": wanted} if wanted else {"status": "malformed"}


def _kernel(roots):
    try:
        info = roots.uname()
        return {"status": "ok", "value": {"sysname": info.sysname, "release": info.release,
                                          "version": info.version, "machine": info.machine}}
    except (OSError, AttributeError):
        return {"status": "unreadable"}


def _cpu(roots):
    status, text = read_bounded(roots.proc / "cpuinfo", 65536, truncate=True)
    model = {"status": status}
    if status == "ok":
        found = re.search(r"^model name\s*:\s*(.+)$", text, re.MULTILINE)
        model = {"status": "ok", "value": found.group(1).strip()} if found else {"status": "not-present"}
    base = roots.sys / "devices" / "system" / "cpu"
    try:
        cpus = sorted(name for name in os.listdir(base) if CPU_DIR.fullmatch(name))
    except OSError:
        return {"model": model, "logicalCores": {"status": "not-present"}, "physicalCores": {"status": "not-present"}}
    online = []
    for name in cpus:
        state = fact(base / name / "online")
        if state.get("status") == "ok" and state.get("value") == "0":
            continue
        online.append(name)
    cores = set()
    complete = True
    for name in online:
        package = fact_value(fact(base / name / "topology" / "physical_package_id"))
        core = fact_value(fact(base / name / "topology" / "core_id"))
        if package is None or core is None:
            complete = False
            break
        cores.add((package, core))
    physical = {"status": "ok", "value": len(cores)} if complete and online else {"status": "not-present"}
    return {"model": model, "logicalCores": {"status": "ok", "value": len(online)}, "physicalCores": physical}


def _memory(roots):
    status, text = read_bounded(roots.proc / "meminfo", 65536, truncate=True)
    if status != "ok":
        return {"memTotalKiB": {"status": status}, "memAvailableKiB": {"status": status}}
    result = {}
    for label, key in (("MemTotal", "memTotalKiB"), ("MemAvailable", "memAvailableKiB")):
        found = re.search(r"^" + label + r":\s+([0-9]{1,15}) kB\s*$", text, re.MULTILINE)
        result[key] = {"status": "ok", "value": int(found.group(1))} if found else {"status": "not-present"}
    return result


def _amdgpu_module(roots):
    base = roots.sys / "module" / "amdgpu"
    if not base.exists():
        return {"status": "not-present"}
    return {"status": "ok", "version": fact(base / "version"), "srcversion": fact(base / "srcversion"),
            "initstate": fact(base / "initstate")}


def collect_host_facts(phase, roots, gpus=None):
    gpus = discover_gpus(roots) if gpus is None else gpus
    return {"phase": phase, "utc": utc_now(),
            "osRelease": _os_release(roots), "kernel": _kernel(roots), "cpu": _cpu(roots),
            "memory": _memory(roots),
            "dmi": {name: fact(roots.sys / "class" / "dmi" / "id" / name) for name in DMI_FIELDS},
            "amdgpuModule": _amdgpu_module(roots),
            "gpus": [gpu_facts(gpu) for gpu in gpus]}


# ------------------------------------------------------------------- telemetry

def _read_int(path):
    item = fact(path, "int")
    return item.get("value") if item["status"] == "ok" else None, item["status"]


def read_gpu_sample(gpu, status_out=None):
    """One telemetry read for a GPU. Unreadable metrics are None, never zero."""
    device = gpu["device"]
    hwmon = _hwmon_dir(device)
    paths = {"vramUsedBytes": device / "mem_info_vram_used", "gttUsedBytes": device / "mem_info_gtt_used",
             "gpuBusyPercent": device / "gpu_busy_percent"}
    result, statuses = {}, {}
    for key, path in paths.items():
        result[key], statuses[key] = _read_int(path)
    if hwmon is None:
        for key in ("powerAverageMicroWatts", "tempEdgeMilliC", "tempJunctionMilliC"):
            result[key], statuses[key] = None, "not-present"
    else:
        value, state = _read_int(hwmon / "power1_average")
        if value is None and state == "not-present":
            value, state = _read_int(hwmon / "power1_input")
        result["powerAverageMicroWatts"], statuses["powerAverageMicroWatts"] = value, state
        labels = {}
        for index in range(1, 9):
            label = fact_value(fact(hwmon / ("temp%d_label" % index)))
            if label:
                labels[label.lower()] = index
        for key, label in (("tempEdgeMilliC", "edge"), ("tempJunctionMilliC", "junction")):
            if label in labels:
                result[key], statuses[key] = _read_int(hwmon / ("temp%d_input" % labels[label]))
            else:
                result[key], statuses[key] = None, "not-present"
    if status_out is not None:
        status_out.update(statuses)
    return result


def gap_stats(stamps, interval):
    gaps = [later - earlier for earlier, later in zip(stamps, stamps[1:])]
    largest = max(gaps) if gaps else 0.0
    dropped = sum(max(0, int(round(gap / interval)) - 1) for gap in gaps)
    return largest, dropped


class Sampler(threading.Thread):
    """Samples every AMD GPU on a fixed schedule for the whole timed window."""

    def __init__(self, gpus, hz, read_fn=None, clock=time.monotonic):
        super().__init__(name="fastllm-benchmark-sampler", daemon=True)
        if not isinstance(hz, (int, float)) or isinstance(hz, bool) or not SAMPLE_HZ_MIN <= hz <= SAMPLE_HZ_MAX:
            raise Refusal("sample-rate-out-of-bounds", "sampling must be %.1f-%.1f Hz" % (SAMPLE_HZ_MIN, SAMPLE_HZ_MAX))
        self.gpus = gpus
        self.hz = float(hz)
        self.interval = 1.0 / self.hz
        self.clock = clock
        self.read_fn = read_fn or self._read_all
        self.stop_event = threading.Event()
        self.records = []
        self.stamps = []
        self.read_failures = 0
        self.availability = {}
        self.t0 = None

    def _read_all(self):
        out = {}
        for gpu in self.gpus:
            status = {}
            out[gpu["bdf"]] = read_gpu_sample(gpu, status)
            self.availability.setdefault(gpu["bdf"], status)
        return out

    def _take(self):
        stamp = self.clock()
        utc = utc_now()
        try:
            values = self.read_fn()
        except Exception:
            self.read_failures += 1
            return
        self.stamps.append(stamp)
        self.records.append({"utc": utc, "tSeconds": round(stamp - self.t0, 6), "gpus": values})

    def run(self):
        self.t0 = self.clock()
        due = self.t0
        while True:
            self._take()
            due += self.interval
            now = self.clock()
            if now > due:
                due += (int((now - due) // self.interval) + 1) * self.interval
            if self.stop_event.wait(max(0.0, due - now)):
                break
        self._take()

    def finish(self):
        self.stop_event.set()
        self.join(timeout=10)
        largest, dropped = gap_stats(self.stamps, self.interval)
        return {"requestedHz": self.hz, "intervalSeconds": self.interval, "sampleCount": len(self.records),
                "firstSampleUtc": self.records[0]["utc"] if self.records else None,
                "lastSampleUtc": self.records[-1]["utc"] if self.records else None,
                "largestGapSeconds": largest, "droppedSampleCount": dropped,
                "readFailureCount": self.read_failures,
                "metricAvailabilityAtFirstSample": self.availability,
                "vramUsedIsPerDeviceNotPerProcess": True,
                "samples": self.records}


# ------------------------------------------------------------ run identity

def _private_dir(path):
    path = Path(path).expanduser().absolute()
    try:
        info = path.lstat()
    except OSError:
        raise Refusal("run-root-unavailable", "run root does not exist")
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise Refusal("run-root-unsafe", "run root must be a real, user-owned, mode 0700 directory")
    return path


def read_lab_state(run_root):
    root = _private_dir(run_root)
    path = root / "status.json"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        raise Refusal("lab-state-unavailable", "no readable lab status.json")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_size > MAX_STATE_BYTES \
                or info.st_mode & 0o022:
            raise Refusal("lab-state-unsafe", "status.json must be a user-owned regular file within the size ceiling")
        raw = os.read(fd, MAX_STATE_BYTES + 1)
    finally:
        os.close(fd)
    try:
        state = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError):
        raise Refusal("lab-state-malformed", "status.json is not JSON")
    if not isinstance(state, dict) or not RUN_ID.fullmatch(str(state.get("runId", ""))):
        raise Refusal("lab-state-malformed", "status.json lacks a run id")
    return state


def proc_start(pid, roots):
    try:
        raw = (roots.proc / str(pid) / "stat").read_text(encoding="ascii")
        return int(raw.rsplit(") ", 1)[1].split()[19])
    except (OSError, UnicodeError, ValueError, IndexError):
        return None


IDENTITY_FIELDS = ("runId", "supervisorPid", "supervisorStartTicks", "childPid", "childStartTicks")


def identity_of(state):
    for key in IDENTITY_FIELDS[1:]:
        if type(state.get(key)) is not int or state[key] <= 0:
            raise Refusal("lab-state-malformed", "status.json lacks a valid " + key)
    return {key: state[key] for key in IDENTITY_FIELDS}


def verify_identity(run_root, expected, roots):
    """Re-read the lab state and /proc; abort on any difference in run identity."""
    state = read_lab_state(run_root)
    if state.get("phase") != "ready":
        raise IdentityChanged("lab phase is no longer ready")
    if identity_of(state) != expected:
        raise IdentityChanged("lab run id, PID or start time recorded in state changed")
    if proc_start(expected["supervisorPid"], roots) != expected["supervisorStartTicks"]:
        raise IdentityChanged("supervisor process is gone or its /proc start time changed")
    if proc_start(expected["childPid"], roots) != expected["childStartTicks"]:
        raise IdentityChanged("server process is gone or its /proc start time changed")


def loopback_port(state):
    from urllib.parse import urlsplit
    endpoint = state.get("endpoint")
    try:
        parts = urlsplit(endpoint)
        port = parts.port
    except (TypeError, ValueError):
        raise Refusal("endpoint-malformed", "lab state endpoint is not a URL")
    if parts.scheme != "http" or parts.hostname != "127.0.0.1" or not port:
        raise Refusal("non-loopback-endpoint", "only http://127.0.0.1:PORT endpoints are allowed")
    return port


# ------------------------------------------------------------------ HTTP

def http_json(port, method, path, body=None, timeout=TOKENIZE_TIMEOUT):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        data = json.dumps(body, separators=(",", ":")).encode() if body is not None else None
        connection.request(method, path, body=data, headers={"Content-Type": "application/json"} if data else {})
        response = connection.getresponse()
        if response.status != 200:
            raise Refusal("http-status", "%s %s returned %d" % (method, path, response.status))
        raw = response.read(MAX_JSON_BYTES + 1)
        if len(raw) > MAX_JSON_BYTES:
            raise Refusal("http-oversize", path)
        value = json.loads(raw.decode("utf-8"))
        if not isinstance(value, dict):
            raise Refusal("http-malformed", path)
        return value
    except (OSError, http.client.HTTPException, UnicodeError, ValueError) as exc:
        raise Refusal("http-failed", "%s %s: %s" % (method, path, type(exc).__name__))
    finally:
        connection.close()


def stream_completion(port, prompt_tokens, n_predict, timeout=REQUEST_TIMEOUT, clock=time.perf_counter):
    """One streamed /completion request, timestamping every data event on arrival."""
    body = {"prompt": prompt_tokens, "n_predict": n_predict, "temperature": 0, "seed": 42,
            "cache_prompt": False, "ignore_eos": True, "stream": True}
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    events, times = [], []
    started_utc = utc_now()
    started = clock()
    try:
        connection.request("POST", "/completion", body=json.dumps(body, separators=(",", ":")).encode(),
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            raise Refusal("inference-failed", "completion returned %d" % response.status)
        total = 0
        while True:
            line = response.readline(MAX_LINE_BYTES + 1)
            now = clock()
            if not line:
                break
            total += len(line)
            if len(line) > MAX_LINE_BYTES or total > MAX_STREAM_BYTES or now - started > timeout:
                raise Refusal("inference-failed", "stream exceeded its size or time bound")
            if not line.startswith(b"data:"):
                continue
            payload = line[5:].decode("utf-8").strip()
            if payload == "[DONE]":
                continue
            events.append(json.loads(payload))
            times.append((now - started) * 1000.0)
            if len(events) > MAX_STREAM_EVENTS:
                raise Refusal("inference-failed", "stream has too many events")
        elapsed = (clock() - started) * 1000.0
    except (OSError, http.client.HTTPException, UnicodeError, ValueError) as exc:
        raise Refusal("inference-failed", type(exc).__name__)
    finally:
        connection.close()
    return {"events": events, "eventTimesMs": times, "elapsedMs": elapsed,
            "startedUtc": started_utc, "endedUtc": utc_now()}


# --------------------------------------------------- sample semantics (mirror)

def finite_number(value, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return False
    return value > 0 if positive else value >= 0


def positive_int(value):
    return type(value) is int and 1 <= value <= 2147483647


def parse_sample(response, expected_tokens):
    """Mirror ConvertFrom-FastLlmBenchmarkResponse for a streamed /completion."""
    events, times, elapsed = response["events"], response["eventTimesMs"], response["elapsedMs"]
    if len(events) != len(times) or not finite_number(elapsed):
        raise Refusal("sample-invalid", "benchmark event timing shape is invalid")
    prior = 0.0
    for moment in times:
        if not finite_number(moment) or moment < prior or moment > elapsed:
            raise Refusal("sample-invalid", "benchmark event timestamps are invalid")
        prior = moment
    first_ms, last, final_count = None, None, 0
    for index, item in enumerate(events):
        if not isinstance(item, dict):
            raise Refusal("sample-invalid", "stream event is not an object")
        content = item.get("content")
        if first_ms is None and isinstance(content, str) and content:
            first_ms = times[index]
        if "stop" in item:
            if type(item["stop"]) is not bool:
                raise Refusal("sample-invalid", "stop flags must be JSON booleans")
            if item["stop"]:
                last, final_count = item, final_count + 1
    if first_ms is None or final_count != 1 or not isinstance(last.get("timings"), dict):
        raise Refusal("sample-invalid", "stream needs first text and exactly one final stop with timings")
    timing = last["timings"]
    for name in ("prompt_n", "predicted_n"):
        if not positive_int(timing.get(name)):
            raise Refusal("sample-invalid", "token counts must be positive exact integers")
    for name in ("prompt_ms", "predicted_ms"):
        if not finite_number(timing.get(name), True):
            raise Refusal("sample-invalid", "durations must be finite positive numbers")
    if timing["predicted_n"] != expected_tokens:
        raise Refusal("sample-invalid", "predicted token count does not match the fixed workload")
    return {"promptTokens": timing["prompt_n"], "outputTokens": timing["predicted_n"],
            "promptTokensPerSecond": 1000.0 * timing["prompt_n"] / timing["prompt_ms"],
            "generationTokensPerSecond": 1000.0 * timing["predicted_n"] / timing["predicted_ms"],
            "timeToFirstTextMs": float(first_ms), "completionMs": float(elapsed)}


def statistics(values):
    if not values or any(not finite_number(value) for value in values):
        raise Refusal("sample-invalid", "statistics require finite non-negative samples")
    ordered = sorted(values)
    count = len(ordered)
    mid = count // 2
    median = ordered[mid] if count % 2 else (ordered[mid - 1] + ordered[mid]) / 2
    return {"count": count, "median": median, "minimum": ordered[0], "maximum": ordered[-1],
            "p95": ordered[int(math.ceil(count * 0.95)) - 1], "p95Caution": count < 20}


def prompt_artifact_sha256(token_ids):
    if not token_ids:
        raise Refusal("artifact-invalid", "prompt token artifact must not be empty")
    lines = [ARTIFACT_FORMAT, str(len(token_ids))]
    for token in token_ids:
        if type(token) is not int or token < 0 or token > 2147483647:
            raise Refusal("artifact-invalid", "prompt token artifact contains an invalid token ID")
        lines.append(str(token))
    return hashlib.sha256(("\n".join(lines) + "\n").encode("ascii")).hexdigest()


def build_corpus(maximum):
    return CORPUS_UNIT * (int(math.ceil(maximum / 16.0)) + 2)


def build_artifacts(tokens, lengths):
    """Exact-length prompt token arrays and their digests. Token IDs are not exported."""
    if len(tokens) < max(lengths):
        raise Refusal("corpus-too-short", "tokenized corpus has fewer tokens than the longest prompt")
    arrays, artifacts = {}, []
    for length in lengths:
        prompt = tokens[:length]
        if len(prompt) != length:
            raise Refusal("artifact-invalid", "prompt does not have the exact requested token count")
        arrays[length] = prompt
        artifacts.append({"requestedPromptTokens": length, "tokenCount": len(prompt),
                          "sha256": prompt_artifact_sha256(prompt), "format": ARTIFACT_FORMAT})
    return arrays, artifacts


# ----------------------------------------------------------------- binding

def _normalise_bdf(value):
    if not isinstance(value, str):
        return None
    value = value.strip().lower()
    if re.fullmatch(r"[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", value):
        value = "0000:" + value
    return value if BDF.fullmatch(value) else None


def bind_device(state, gpus):
    """Join the serving device to sysfs only through a recorded PCI bus id."""
    selected = state.get("selectedDevice")
    probe = state.get("deviceProbe") if isinstance(state.get("deviceProbe"), dict) else {}
    candidates = [gpu["bdf"] for gpu in gpus]
    base = {"selectedDevice": selected if isinstance(selected, str) else None,
            "selectedDeviceSource": "lab-state" if isinstance(selected, str) else "not-recorded-in-lab-state",
            "candidateAmdBdfs": candidates, "bdf": None}
    bus_id = _normalise_bdf(probe.get("pciBusId"))
    if bus_id is None:
        base.update(status="unbound", joinMethod="none",
                    reason="lab state records no engine-reported PCI bus id; names are never used to guess")
        return base
    matches = [bdf for bdf in candidates if bdf == bus_id]
    if len(matches) != 1:
        base.update(status="unbound", joinMethod="none",
                    reason="recorded PCI bus id does not match exactly one AMD sysfs device")
        return base
    base.update(status="joined", joinMethod="lab-state-engine-pci-bus-id", bdf=matches[0], reason=None)
    return base


# ----------------------------------------------------------------- the run

def parse_lengths(text):
    try:
        return [int(part) for part in text.split(",") if part.strip()]
    except ValueError:
        raise Refusal("prompt-lengths-invalid", "prompt lengths must be comma-separated integers")


def validate_parameters(lengths, output_tokens, warmup, repetitions, sample_hz):
    if not lengths or len(set(lengths)) != len(lengths) or any(type(item) is not int for item in lengths):
        raise Refusal("prompt-lengths-invalid", "prompt sizes must be nonempty and unique integers")
    if any(item < MIN_PROMPT_TOKENS for item in lengths):
        raise Refusal("prompt-lengths-invalid", "prompt sizes must be at least %d tokens" % MIN_PROMPT_TOKENS)
    if type(output_tokens) is not int or not 1 <= output_tokens <= MAX_OUTPUT_TOKENS:
        raise Refusal("output-tokens-invalid", "output tokens must be 1-%d" % MAX_OUTPUT_TOKENS)
    if type(warmup) is not int or not 1 <= warmup <= MAX_WARMUP:
        raise Refusal("warmup-invalid", "warmup rounds must be 1-%d" % MAX_WARMUP)
    if type(repetitions) is not int or repetitions < MIN_REPETITIONS:
        raise Refusal("repetitions-below-minimum", "a reportable group needs at least %d repetitions" % MIN_REPETITIONS)
    if repetitions > MAX_REPETITIONS:
        raise Refusal("repetitions-invalid", "at most %d repetitions" % MAX_REPETITIONS)
    if not isinstance(sample_hz, (int, float)) or isinstance(sample_hz, bool) or not SAMPLE_HZ_MIN <= sample_hz <= SAMPLE_HZ_MAX:
        raise Refusal("sample-rate-out-of-bounds", "sampling must be %.1f-%.1f Hz" % (SAMPLE_HZ_MIN, SAMPLE_HZ_MAX))


def _check_output(output):
    output = Path(output).expanduser().absolute()
    if os.path.lexists(output):
        raise Refusal("output-exists", "benchmark output already exists; choose a new result file")
    parent = output.parent
    try:
        info = parent.lstat()
    except OSError:
        raise Refusal("output-parent-missing", "output directory must already exist")
    if not stat.S_ISDIR(info.st_mode):
        raise Refusal("output-parent-unsafe", "output directory must be a real directory")
    return output


def write_report(output, report):
    """Atomic no-overwrite write: private temp file, then link() which fails if present."""
    payload = (json.dumps(report, indent=2) + "\n").encode("utf-8")
    temp = output.parent / (".benchmark-" + uuid.uuid4().hex + ".tmp")
    fd = os.open(temp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temp, output)
        except FileExistsError:
            raise Refusal("output-exists", "benchmark output already exists; choose a new result file")
    finally:
        try:
            os.unlink(temp)
        except OSError:
            pass


def _lock(run_root):
    path = Path(run_root) / "benchmark.lock"
    try:
        fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    except OSError:
        raise Refusal("benchmark-lock-unavailable", "cannot open the benchmark lock safely")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EAGAIN, errno.EACCES):
            raise Refusal("benchmark-already-running", "another benchmark holds the lock")
        raise Refusal("benchmark-lock-unavailable", "cannot lock")
    return fd


def run_benchmark(run_root, output, *, prompt_tokens=(512, 4096), output_tokens=128, warmup=1,
                  repetitions=5, sample_hz=1.0, order_seed=None, roots=None, log=None):
    roots = roots or Roots()
    lengths = list(prompt_tokens)
    validate_parameters(lengths, output_tokens, warmup, repetitions, sample_hz)
    output = _check_output(output)
    run_root = _private_dir(run_root)
    lock_fd = _lock(run_root)
    try:
        return _run_locked(run_root, output, lengths, output_tokens, warmup, repetitions,
                           float(sample_hz), order_seed, roots, log or (lambda message: None))
    finally:
        os.close(lock_fd)


def _run_locked(run_root, output, lengths, output_tokens, warmup, repetitions, sample_hz, order_seed, roots, log):
    state = read_lab_state(run_root)
    if state.get("phase") != "ready":
        raise Refusal("run-not-ready", "start a private lab server and wait for ready before benchmarking")
    expected = identity_of(state)
    identity = state.get("identity")
    if not isinstance(identity, dict) or any(not SHA256.fullmatch(str(identity.get(key, ""))) for key in IDENTITY_HASHES):
        raise Refusal("lab-state-malformed", "lab identity hashes are missing")
    port = loopback_port(state)
    context = state.get("contextSize")
    if type(context) is not int or context <= 0:
        raise Refusal("lab-state-malformed", "lab state lacks a context size")
    for length in lengths:
        if length + output_tokens + 8 > context:
            raise Refusal("context-budget", "requested prompt/output exceeds the effective context budget")
    verify_identity(run_root, expected, roots)
    gpus = discover_gpus(roots)
    if not gpus:
        raise Refusal("no-amd-gpu", "no AMD display-class PCI device found in sysfs")
    health = http_json(port, "GET", "/health")
    if health.get("status") != "ok":
        raise Refusal("server-not-healthy", "health is not ok")
    props = http_json(port, "GET", "/props")
    settings = props.get("default_generation_settings")
    n_ctx = settings.get("n_ctx") if isinstance(settings, dict) else None
    if type(n_ctx) is not int or n_ctx != context or props.get("total_slots") != 1:
        raise Refusal("props-mismatch", "effective context or slot count differs from the lab record")
    # Exact-token artifacts through the server's own tokenizer, as the Windows producer does.
    corpus = build_corpus(max(lengths))
    tokenized = http_json(port, "POST", "/tokenize", {"content": corpus, "add_special": False})
    tokens = tokenized.get("tokens")
    if not isinstance(tokens, list) or any(type(item) is not int for item in tokens):
        raise Refusal("tokenize-failed", "tokenizer returned no integer token list")
    arrays, artifacts = build_artifacts(tokens, lengths)
    hashes = {item["requestedPromptTokens"]: item["sha256"] for item in artifacts}
    corpus_sha = hashlib.sha256(corpus.encode("utf-8")).hexdigest()

    seed = order_seed if order_seed is not None else int.from_bytes(os.urandom(4), "big")
    rng = random.Random(seed)
    before = collect_host_facts("before", roots, gpus)
    sampler = Sampler(gpus, sample_hz)
    samples, evaluated = [], {}
    window_started = utc_now()
    sampler.start()
    try:
        for round_index in range(warmup + repetitions):
            order = list(lengths)
            rng.shuffle(order)
            for length in order:
                verify_identity(run_root, expected, roots)
                response = stream_completion(port, arrays[length], output_tokens)
                sample = parse_sample(response, output_tokens)
                if sample["promptTokens"] not in (length, length + 1):
                    raise Refusal("prompt-length-mismatch",
                                  "server evaluated a different prompt length (possible cache reuse or truncation)")
                if length in evaluated and evaluated[length] != sample["promptTokens"]:
                    raise Refusal("prompt-length-mismatch", "warmup and measured runs evaluated different prompt counts")
                evaluated[length] = sample["promptTokens"]
                if round_index >= warmup:
                    sample["requestedPromptTokens"] = length
                    sample["repetition"] = round_index - warmup + 1
                    sample["promptArtifactSha256"] = hashes[length]
                    sample["startedUtc"] = response["startedUtc"]
                    sample["endedUtc"] = response["endedUtc"]
                    samples.append(sample)
                log("prompt %d, round %d/%d: %.2f generated tokens/s" % (
                    length, round_index + 1 - warmup, repetitions, sample["generationTokensPerSecond"]))
        verify_identity(run_root, expected, roots)
    finally:
        telemetry = sampler.finish()
    window_ended = utc_now()
    after = collect_host_facts("after", roots, gpus)
    verify_identity(run_root, expected, roots)

    summary = []
    for length in lengths:
        group = [item for item in samples if item["requestedPromptTokens"] == length]
        summary.append({"promptTokens": length,
                        "generation": statistics([item["generationTokensPerSecond"] for item in group]),
                        "prefill": statistics([item["promptTokensPerSecond"] for item in group]),
                        "firstText": statistics([item["timeToFirstTextMs"] for item in group]),
                        "completion": statistics([item["completionMs"] for item in group])})
    telemetry = dict(telemetry, windowStartUtc=window_started, windowEndUtc=window_ended)
    release = before["osRelease"]["value"].get("PRETTY_NAME") if before["osRelease"].get("status") == "ok" else None
    kernel = before["kernel"].get("value", {}).get("release") if before["kernel"].get("status") == "ok" else None
    report = {
        "schemaVersion": SCHEMA_VERSION, "resultKind": RESULT_KIND, "recordedAt": utc_now(),
        "producer": {"name": PRODUCER, "sourceSha256": source_sha256()},
        "modelId": state.get("modelId"), "modelSha256": identity["modelSha256"],
        "recipe": {"engineManifestSha256": identity["engineManifestSha256"],
                   "engineArchiveSha256": identity["engineArchiveSha256"],
                   "engineSha256": identity["engineFileSha256"],
                   "catalogSha256": identity["catalogSha256"], "modelSha256": identity["modelSha256"],
                   "labSourceSha256": identity["sourceFileSha256"], "contextSize": context, "slots": 1},
        "requestedLaunch": {"launchArgumentsSha256": identity["launchArgumentsSha256"],
                            "argumentsRecordedByLab": False, "endpoint": "http://127.0.0.1:%d" % port},
        "run": {"runId": expected["runId"], "supervisorPid": expected["supervisorPid"],
                "supervisorStartTicks": expected["supervisorStartTicks"], "childPid": expected["childPid"],
                "childStartTicks": expected["childStartTicks"], "identityVerifiedBeforeEveryRequest": True,
                "identityVerifiedAfterWindow": True},
        "os": ("%s, kernel %s" % (release, kernel)) if release and kernel else None,
        "processorCount": fact_value(before["cpu"]["logicalCores"]),
        "methodology": {"corpus": CORPUS_ID, "corpusSha256": corpus_sha, "sampling": "greedy-seed42",
                        "prefixCache": False, "warmupPerPrompt": warmup, "generationTokens": output_tokens,
                        "repetitions": repetitions, "concurrency": 1, "randomizedPromptOrder": True,
                        "promptOrderSeed": seed, "endpoint": "/completion", "streamed": True,
                        "ignoreEos": True, "promptArtifacts": artifacts},
        "serverProps": {"totalSlots": props["total_slots"], "nCtx": n_ctx},
        "hostFacts": {"before": before, "after": after},
        "telemetry": telemetry, "binding": bind_device(state, gpus),
        "canary": state.get("apiCanaries"), "placement": state.get("reportedPlacement"),
        "samples": samples, "summary": summary,
        "qualification": {"approved": False, "qualityEvaluation": False, "physicalResidency": False,
                          "peakVramMeasured": False, "soak": False, "exclusiveWorkloadConfirmed": False,
                          "deviceBindingVerified": False}}
    assert tuple(report) == TOP_LEVEL_ORDER
    write_report(output, report)
    return report


# --------------------------------------------------------------------- CLI

def require_host():
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64") or os.geteuid() == 0:
        raise Refusal("unsupported-host", "benchmarking requires a standard-user Linux x86_64 host")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run", help="attach to a Ready private lab server and measure")
    runner.add_argument("--run-root", type=Path, required=True, help="the lab run root holding status.json")
    runner.add_argument("--output", type=Path, required=True, help="new result file (never overwritten)")
    runner.add_argument("--prompt-tokens", default="512,4096")
    runner.add_argument("--output-tokens", type=int, default=128)
    runner.add_argument("--warmup", type=int, default=1)
    runner.add_argument("--repetitions", type=int, default=MIN_REPETITIONS)
    runner.add_argument("--sample-hz", type=float, default=1.0)
    runner.add_argument("--order-seed", type=int)
    commands.add_parser("host-facts", help="print one read-only host fact snapshot; no server needed")
    args = parser.parse_args(argv)
    try:
        require_host()
        if args.command == "host-facts":
            result = collect_host_facts("standalone", Roots())
        else:
            report = run_benchmark(args.run_root, args.output, prompt_tokens=parse_lengths(args.prompt_tokens),
                                   output_tokens=args.output_tokens, warmup=args.warmup,
                                   repetitions=args.repetitions, sample_hz=args.sample_hz,
                                   order_seed=args.order_seed, log=lambda message: print(message, file=sys.stderr))
            result = {"written": str(args.output), "summary": report["summary"]}
    except Refusal as refusal:
        print(json.dumps({"refused": refusal.code, "detail": refusal.detail}))
        return 2
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
