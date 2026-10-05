#!/usr/bin/env python3
"""Read-only Linux AMD inventory and model recipe preview.

This is a lab preview. It does not install drivers, models, or an engine.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import sys

CATALOG = Path(__file__).resolve().parents[1] / "config" / "catalog.json"
MIB = 1024 * 1024
KNOWN_DISCRETE_PCI_IDS = {
    "0x744c": "Navi 31 (RX 7900 XT/XTX/GRE/M family)",
    "0x747e": "Navi 32 (RX 7700 XT/7800 XT family)",
    "0x7480": "Navi 33 (RX 7600/7600 XT family)",
    "0x7550": "Navi 48 (RX 9070/9070 XT family)",
    "0x7551": "Navi 48 (Radeon AI PRO R9700)",
    "0x7590": "Navi 44 (RX 9050/9060 XT family)",
}


def read_text(path):
    try:
        return path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return None


def read_nonnegative(path):
    value = read_text(path)
    try:
        result = int(value)
        return result if result >= 0 else None
    except (TypeError, ValueError):
        return None


def inventory(sysfs_root=Path("/sys/class/drm")):
    gpus = []
    for card in sorted(sysfs_root.glob("card[0-9]*")):
        if not card.name[4:].isdigit():
            continue
        device = card / "device"
        if (read_text(device / "vendor") or "").lower() != "0x1002":
            continue
        try:
            driver = (device / "driver").resolve(strict=True).name
        except OSError:
            driver = None
        total = read_nonnegative(device / "mem_info_vram_total")
        used = read_nonnegative(device / "mem_info_vram_used")
        free = total - used if total is not None and used is not None and used <= total else None
        pci_id = (read_text(device / "device") or "").lower()
        identity = KNOWN_DISCRETE_PCI_IDS.get(pci_id)
        gpus.append({
            "card": card.name,
            "pciDeviceId": pci_id or None,
            "identity": identity,
            "discreteClassification": "known-discrete-pci-family" if identity else "unknown",
            "driver": driver,
            "vramTotalMiB": total // MIB if total is not None else None,
            "vramUsedMiB": used // MIB if used is not None else None,
            "vramFreeMiB": free // MIB if free is not None else None,
            "recipeEligible": identity is not None and driver == "amdgpu" and free is not None,
        })
    return gpus


def choose_recipe(catalog, gpus, profile):
    candidates = [m for m in catalog["models"] if m.get("autoEligible", True)]
    matches = []
    for gpu in gpus:
        if not gpu["recipeEligible"]:
            continue
        for model in candidates:
            if gpu["vramFreeMiB"] >= model["requiredFreeVramMiB"]:
                matches.append((model["scores"][profile], model["requiredFreeVramMiB"], model["id"], gpu, model))
    if not matches:
        return None
    _, _, _, gpu, model = max(matches, key=lambda x: (x[0], x[1], x[2]))
    return {
        "gpu": gpu["card"], "modelId": model["id"],
        "modelFamily": model["family"], "quantization": model["quantization"],
        "requiredFreeVramMiB": model["requiredFreeVramMiB"],
        "observedFreeVramMiB": gpu["vramFreeMiB"],
        "contextSize": model["contextSize"],
        "artifactProvider": model["artifactProvider"],
        "upstreamModel": model["upstreamModel"],
        "license": model["upstreamLicense"],
        "licenseUrl": model["upstreamLicenseUrl"],
        "artifactBytes": model["sizeBytes"],
        "artifactSha256": model["sha256"],
        "artifactUrl": model["url"],
        "qualification": "estimated catalog candidate; Linux load, fit, placement and speed unverified",
    }


def load_catalog(path):
    digest_path = path.parent / "catalog.sha256"
    line = digest_path.read_text(encoding="ascii").strip()
    parts = line.split()
    if len(parts) != 2 or parts[1] != "catalog.json" or len(parts[0]) != 64 or any(c not in "0123456789abcdefABCDEF" for c in parts[0]):
        raise ValueError("invalid catalog.sha256 manifest")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != parts[0].lower():
        raise ValueError("catalog.json SHA-256 mismatch")
    return json.loads(raw)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("doctor", "recipes"))
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--sysfs-root", type=Path, default=Path("/sys/class/drm"))
    parser.add_argument("--profile", choices=("fast", "balanced", "quality"), default="balanced")
    parser.add_argument("--fixture", action="store_true", help="allow alternate catalog/sysfs paths; output is synthetic")
    args = parser.parse_args(argv)
    if getattr(os, "geteuid", lambda: -1)() == 0:
        parser.error("run as a standard user; root execution is refused")
    if (args.catalog != CATALOG or args.sysfs_root != Path("/sys/class/drm")) and not args.fixture:
        parser.error("alternate catalog or sysfs paths require --fixture")
    if platform.system() != "Linux" and not args.fixture:
        parser.error("native inventory requires Linux")
    try:
        catalog = load_catalog(args.catalog)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        parser.error(f"catalog verification failed: {exc}")
    gpus = inventory(args.sysfs_root)
    result = {
        "schemaVersion": 1,
        "fixture": args.fixture,
        "catalogVersion": catalog["catalogVersion"],
        "catalogStatus": catalog["status"],
        "system": platform.platform(),
        "kernelDriver": "amdgpu where reported per card",
        "gpus": gpus,
        "notes": ["VRAM counters are a point-in-time sysfs reading, not a verified engine allocation.",
                  "Driver package/version, ROCm support, Vulkan ICD and runtime compatibility are not established by this inventory.",
                  "Only explicitly recognized discrete PCI families are eligible for a recipe preview; all other identities remain unknown.",
                  "Multi-GPU ranking and measured tokens/sec require physical Linux qualification."],
    }
    if args.command == "recipes":
        result["recipe"] = choose_recipe(catalog, gpus, args.profile)
        result["profile"] = args.profile
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
