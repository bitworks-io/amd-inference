#!/usr/bin/env python3
"""Guided, explicitly opted-in Linux lab setup and foreground serving.

Run only from a separately checksum-verified FastLLM source checkout. This
orchestrates existing pinned components; it does not enable public serving.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


def _load(name, filename=None):
    path = Path(__file__).with_name(filename or name + ".py")
    spec = importlib.util.spec_from_file_location("fastllm_lab_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = _load("runtime")
models = _load("models")
serve = _load("serve")
probe = _load("probe")
preview = _load("preview", "fast-llm-linux.py")
ubuntu_packages = _load("ubuntu_packages")

DEFAULT_ROOT = Path.home() / ".fastllm-linux-lab"
AMD_NAME = re.compile(r"AMD Radeon (?:RX [A-Za-z0-9 ]+|AI PRO [A-Za-z0-9 ]+)\Z")


class LabError(ValueError):
    pass


def _root(path):
    serve.require_host()
    return models._private_root(Path(path))


def _stage(root, archive=None):
    with runtime.MANIFEST.open("rb") as source:
        manifest = source.read(probe.MAX_MANIFEST_BYTES + 1)
    if len(manifest) > probe.MAX_MANIFEST_BYTES or hashlib.sha256(manifest).hexdigest() != probe.PINNED_MANIFEST_SHA256:
        raise LabError("engine candidate manifest differs from reviewed bytes; no engine download attempted")
    reviewed = json.loads(manifest.decode("utf-8"))["assets"]["vulkan"]
    asset = runtime.load_asset()
    if (asset != reviewed or asset["sha256"] != probe.PINNED_ARCHIVE_SHA256
            or asset["url"] != probe.PINNED_ARCHIVE_URL or asset["executionEnabled"] is not False):
        raise LabError("engine candidate differs from the reviewed private Vulkan asset")
    stage = root / "engine"
    if stage.exists() or stage.is_symlink():
        try:
            runtime.verify_tree(stage, asset)
        except (OSError, ValueError) as exc:
            raise LabError("existing engine stage is invalid; move that exact private directory aside for inspection before retry") from exc
        return stage
    with tempfile.TemporaryDirectory(prefix="fastllm-engine-", dir=root) as scratch:
        scratch = Path(scratch)
        pending = scratch / "pending"
        if archive is not None:
            runtime.prepare_asset(Path(archive).expanduser().absolute(), pending, asset)
        else:
            downloaded = scratch / "vulkan.tar.gz"
            runtime.download_asset(downloaded, asset)
            runtime.prepare_asset(downloaded, pending, asset)
        runtime.verify_tree(pending, asset)
        if stage.exists() or stage.is_symlink():
            raise LabError("another setup created the engine stage; rerun to verify it")
        pending.rename(stage)
    runtime.verify_tree(stage, asset)
    return stage


def _host_plan(stage, catalog, profile, model_id):
    cards = [gpu for gpu in preview.inventory() if gpu["recipeEligible"]]
    hardware = probe.run(stage)
    devices = hardware["devices"]
    if hardware["fixture"] or len(cards) != 1 or len(devices) != 1 or devices[0]["device"] != "Vulkan0":
        raise LabError("lab setup needs exactly one recognized discrete AMD sysfs card and one live Vulkan0 device")
    if not AMD_NAME.fullmatch(devices[0]["name"]):
        raise LabError("engine-reported Vulkan device name does not pass the private AMD/discrete heuristic")
    free = min(cards[0]["vramFreeMiB"], devices[0]["reportedFreeMiB"])
    if free < 0:
        raise LabError("engine or sysfs free VRAM report is invalid")
    conservative = dict(cards[0], vramFreeMiB=free)
    if model_id:
        item = models._model(catalog, model_id)
        if free < item["requiredFreeVramMiB"]:
            raise LabError("exact model exceeds the current conservative free-VRAM estimate")
    else:
        recipe = preview.choose_recipe(catalog, [conservative], profile)
        if recipe is None:
            raise LabError("no catalog model fits the current conservative free-VRAM estimate")
        item = models._model(catalog, recipe["modelId"])
    return item, {"modelId": item["id"], "contextSize": item["contextSize"],
                  "artifactBytes": item["sizeBytes"], "conservativeFreeVramMiB": free,
                  "requiredFreeVramMiB": item["requiredFreeVramMiB"],
                  "hardwareBindingVerified": False, "fitVerified": False,
                  "deviceProbeCompleted": True}


def _model_ready(catalog, item, cache_root, *, confirm=input):
    cache_root = models._private_root(cache_root)
    try:
        with models._lock(cache_root, time.monotonic() + 10):
            path, _ = serve.verify_cached_model(catalog, item["id"], cache_root)
        return {"modelId": item["id"], "path": str(path), "sha256": item["sha256"], "reused": True}
    except FileNotFoundError:
        pass
    except serve.ServeError as exc:
        if str(exc) not in ("exact consent receipt or conversion provenance differs",
                            "cached model size differs", "cached model SHA-256 differs"):
            raise
    try:
        return models.acquire_model(catalog, item["id"], cache_root)
    except ValueError as exc:
        if not (str(exc).startswith("exact license consent required for ")
                or str(exc) == "consent receipt differs; renewed exact-provenance acceptance required"):
            raise
    return _display_and_accept_for_root(catalog, item, cache_root, confirm=confirm)


def _display_and_accept_for_root(catalog, item, cache_root, *, confirm=input):
    # Keep the cache path explicit; no global or ambient approval state.
    review = models.preview_license(catalog, item["id"])
    print("\nExact upstream license text follows (verified SHA-256 " + review["upstreamLicenseSha256"] + "):")
    print(review["licenseText"])
    print("\nModel: " + review["modelId"])
    print("Upstream revision: " + review["upstreamRevision"])
    print("Conversion repository/revision: " + review["conversionRepository"] + " @ " + review["conversionRevision"])
    print("Artifact license: " + review["artifactLicense"])
    print("Artifact SHA-256: " + review["artifactSha256"])
    print("Consent provenance SHA-256: " + review["consentProvenanceSha256"])
    response = "ACCEPT " + review["modelId"] + " " + review["upstreamLicenseSha256"] + " " + review["consentProvenanceSha256"]
    if confirm("Type " + response + " to accept this exact artifact/license: ") != response:
        raise LabError("exact model-license approval was not provided")
    return models.acquire_model(catalog, item["id"], cache_root,
                                accept_license_for=item["id"],
                                reviewed_license_sha256=review["upstreamLicenseSha256"],
                                reviewed_upstream_revision=review["upstreamRevision"],
                                reviewed_artifact_sha256=review["artifactSha256"],
                                reviewed_provenance_sha256=review["consentProvenanceSha256"])


def setup(root, *, profile="balanced", model_id=None, engine_archive=None,
          install_system_packages=False, confirm=input):
    root = _root(root)
    catalog = models.load_catalog()
    stage = _stage(root, engine_archive)
    packages = ubuntu_packages.check(stage)
    if packages["missing"]:
        if not install_system_packages:
            raise LabError("declared Ubuntu packages are missing: " + ", ".join(packages["missing"]) +
                           "; rerun with --install-system-packages to review normal APT root hooks and approvals")
        ubuntu_packages.install(stage, confirm=confirm)
    item, plan = _host_plan(stage, catalog, profile, model_id)
    print("LAB ONLY: reported free VRAM and catalog fit are estimates; sysfs PCI identity is not bound to Vulkan0.")
    print("Selected model/context: " + item["id"] + " / " + str(item["contextSize"]) +
          "; artifact bytes: " + str(item["sizeBytes"]))
    cache_root = models._private_root(root / "models")
    acquired = _model_ready(catalog, item, cache_root, confirm=confirm)
    return {"stage": stage, "cacheRoot": cache_root, "runRoot": root / "run",
            "modelId": item["id"], "plan": plan, "artifact": acquired}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "start", "status", "stop"))
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--lab", action="store_true", help="explicitly opt in to the unqualified Linux lab flow")
    parser.add_argument("--profile", choices=("fast", "balanced", "quality"), default="balanced")
    parser.add_argument("--model-id")
    parser.add_argument("--engine-archive", type=Path, help="optional existing exact pinned engine archive")
    parser.add_argument("--install-system-packages", action="store_true", help="interactive normal Ubuntu APT trust and approvals")
    args = parser.parse_args(argv)
    try:
        if args.command in ("setup", "start"):
            if not args.lab:
                parser.error("setup/start require --lab; this is not a qualified public installer")
            result = setup(args.root, profile=args.profile, model_id=args.model_id,
                           engine_archive=args.engine_archive,
                           install_system_packages=args.install_system_packages)
            if args.command == "start":
                print("Starting private foreground loopback serving; API Ready requires the existing native placement/API canaries.")
                result = serve.run(result["stage"], result["cacheRoot"], result["runRoot"], result["modelId"])
            else:
                result = {"labOnly": True, "publicServingEnabled": False,
                          "stage": str(result["stage"]), "modelId": result["modelId"],
                          "plan": result["plan"], "artifactSha256": result["artifact"]["sha256"],
                          "next": "run start --lab for a fresh hardware probe and supervised loopback trial"}
        else:
            if args.lab or args.model_id or args.engine_archive or args.install_system_packages or args.profile != "balanced":
                parser.error("status/stop accept only --root")
            serve.require_host()
            root = serve._private_dir(args.root)
            result = serve.read_status(root / "run") if args.command == "status" else serve.request_stop(root / "run")
    except (OSError, ValueError, TimeoutError, UnicodeError, KeyError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if args.command == "start" and result.get("phase") != "stopped" else 0


if __name__ == "__main__":
    sys.exit(main())
