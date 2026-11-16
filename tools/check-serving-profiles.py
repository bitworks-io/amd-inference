#!/usr/bin/env python3
"""Validate config/serving-profiles.json (bitworks.fastllm-serving-profiles/v1) and its digest file. Exit 0 ok, 1 invalid.

Measured rows for the opt-in serving settings (context profile, slots). The planner offers an option only from a row whose
model sha256, engine id and backend equal the plan's; with no row the option is refused. Nothing is derived from a formula.

Shape:
  { "schema": "bitworks.fastllm-serving-profiles/v1", "profiles": [ Profile, ... ], "addOns": [], "sidecars": [] }
  Profile = {
    "modelId": str                  # a config/catalog.json model id
    "modelSha256": 64 lowercase hex # equals that catalog model's sha256
    "engineId": str                 # the built-in engine id (llama.cpp-<catalog engine version>-vulkan) or a listed llama.cpp engine component
    "backend": "vulkan"|"hip"       # equals the backend of that engine
    "id": "default"|"long"          # default: the catalog context and KV types (rows exist to allow 2 slots); long: more context
    "contextTotal": int > 0         # the TOTAL context (--ctx-size); each slot gets contextTotal / slots
    "cacheTypeK": "f16"|"q8_0", "cacheTypeV": "f16"|"q8_0",
    "slotsAllowed": [1] | [2] | [1, 2],
    "requiredFreeVramMiB": int > 0  # the fit number for this row; replaces the catalog number when the row applies
    "fitTargetMiB": int >= 0,
    "evidence": { "resultId": str, "measuredAt": "YYYY-MM-DDTHH:MM:SSZ", "gpuClasses": [str, ...] }
  }
One row per (modelSha256, engineId, backend, id). "addOns" and "sidecars" are reserved and must be empty lists for now.
config/serving-profiles.sha256 holds "<sha256 of the file>  serving-profiles.json" and a line feed.
Usage: check-serving-profiles.py [--root R]
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = "bitworks.fastllm-serving-profiles/v1"
FILE_NAME = "serving-profiles.json"
DIGEST_NAME = "serving-profiles.sha256"
TOP_KEYS = {"schema", "profiles", "addOns", "sidecars"}
PROFILE_KEYS = {"modelId", "modelSha256", "engineId", "backend", "id", "contextTotal", "cacheTypeK", "cacheTypeV", "slotsAllowed",
                "requiredFreeVramMiB", "fitTargetMiB", "evidence"}
EVIDENCE_KEYS = {"resultId", "measuredAt", "gpuClasses"}
PROFILE_IDS = ("default", "long")
CACHE_TYPES = ("f16", "q8_0")
SLOT_SETS = ([1], [2], [1, 2])
ENGINE_BACKENDS = ("vulkan", "hip")
SHA_RE = re.compile(r"[0-9a-f]{64}")
RESULT_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,119}")
GPU_CLASS_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}")
MEASURED_AT_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_str(value):
    return isinstance(value, str) and value != ""


def check_keys(label, obj, expected, errors):
    if not isinstance(obj, dict):
        errors.append(f"{label}: must be an object")
        return False
    keys = set(obj)
    missing = expected - keys
    extra = keys - expected
    if missing:
        errors.append(f"{label}: missing keys {sorted(missing)}")
    if extra:
        errors.append(f"{label}: unexpected keys {sorted(extra)}")
    return not missing and not extra


def catalog_models(catalog):
    """{model id: catalog model} for the models that have an id."""
    models = {}
    for model in catalog.get("models", []) if isinstance(catalog, dict) else []:
        if isinstance(model, dict) and is_str(model.get("id")):
            models[model["id"]] = model
    return models


def known_engines(catalog, components):
    """{engine id: backend}: the built-in engine of the catalog, plus every listed llama.cpp engine component."""
    engines = {}
    version = catalog.get("engine", {}).get("version") if isinstance(catalog, dict) and isinstance(catalog.get("engine"), dict) else None
    if is_str(version):
        engines["llama.cpp-" + version + "-vulkan"] = "vulkan"
    listed = components.get("components", []) if isinstance(components, dict) else []
    for component in listed if isinstance(listed, list) else []:
        if not isinstance(component, dict) or component.get("kind") != "engine" or component.get("adapter") != "llama.cpp":
            continue
        platform = component.get("platform")
        backend = platform.get("backend") if isinstance(platform, dict) else None
        if is_str(component.get("id")) and backend in ENGINE_BACKENDS:
            engines.setdefault(component["id"], backend)
    return engines


def is_measured_at(value):
    if not isinstance(value, str) or not MEASURED_AT_RE.fullmatch(value):
        return False
    try:
        datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def check_evidence(where, evidence, errors):
    if not check_keys(f"{where}: evidence", evidence, EVIDENCE_KEYS, errors):
        return
    if not isinstance(evidence["resultId"], str) or not RESULT_ID_RE.fullmatch(evidence["resultId"]):
        errors.append(f"{where}: evidence.resultId must be 1 to 120 letters, digits, dots, dashes or underscores")
    if not is_measured_at(evidence["measuredAt"]):
        errors.append(f"{where}: evidence.measuredAt must be a UTC time like 2026-01-31T12:00:00Z")
    classes = evidence["gpuClasses"]
    if not isinstance(classes, list) or not classes or not all(isinstance(c, str) and GPU_CLASS_RE.fullmatch(c) for c in classes):
        errors.append(f"{where}: evidence.gpuClasses must be a non-empty list of short names")


def check_profile(where, row, models, engines, errors):
    """Validates one row; returns its uniqueness key, or None when the row has no usable key."""
    if not check_keys(where, row, PROFILE_KEYS, errors):
        return None
    sha = row["modelSha256"]
    sha_ok = isinstance(sha, str) and bool(SHA_RE.fullmatch(sha))
    if not sha_ok:
        errors.append(f"{where}: modelSha256 must be 64 lowercase hex characters")
    model = models.get(row["modelId"]) if isinstance(row["modelId"], str) else None
    if model is None:
        errors.append(f"{where}: modelId {row['modelId']!r} is not a catalog model")
    elif sha_ok and str(model.get("sha256", "")).lower() != sha:
        errors.append(f"{where}: modelSha256 does not equal the catalog sha256 of {row['modelId']!r}")
    engine_backend = engines.get(row["engineId"]) if isinstance(row["engineId"], str) else None
    if engine_backend is None:
        errors.append(f"{where}: engineId {row['engineId']!r} is not the built-in engine or a listed llama.cpp engine component")
    elif row["backend"] != engine_backend:
        errors.append(f"{where}: backend must be {engine_backend!r} for engine {row['engineId']!r}")
    profile_id = row["id"]
    if profile_id not in PROFILE_IDS or not isinstance(profile_id, str):
        errors.append(f"{where}: id must be 'default' or 'long'")
        profile_id = None
    total = row["contextTotal"]
    total_ok = is_int(total) and total > 0
    if not total_ok:
        errors.append(f"{where}: contextTotal must be a positive integer")
    for key in ("cacheTypeK", "cacheTypeV"):
        if not isinstance(row[key], str) or row[key] not in CACHE_TYPES:
            errors.append(f"{where}: {key} must be one of {list(CACHE_TYPES)}")
    slots = row["slotsAllowed"]
    slots_ok = isinstance(slots, list) and all(is_int(s) for s in slots) and slots in SLOT_SETS
    if not slots_ok:
        errors.append(f"{where}: slotsAllowed must be [1], [2] or [1, 2]")
    elif total_ok and any(total % s for s in slots):
        errors.append(f"{where}: contextTotal must divide evenly by every allowed slot count")
    if not is_int(row["requiredFreeVramMiB"]) or row["requiredFreeVramMiB"] <= 0:
        errors.append(f"{where}: requiredFreeVramMiB must be a positive integer")
    if not is_int(row["fitTargetMiB"]) or row["fitTargetMiB"] < 0:
        errors.append(f"{where}: fitTargetMiB must be a non-negative integer")
    # The two profile ids mean something: default is the catalog context and KV types, long is more context than that.
    if model is not None and profile_id is not None and total_ok and is_int(model.get("contextSize")):
        if profile_id == "default":
            if total != model["contextSize"]:
                errors.append(f"{where}: a default profile must use the catalog context ({model['contextSize']})")
            if row["cacheTypeK"] != model.get("cacheTypeK") or row["cacheTypeV"] != model.get("cacheTypeV"):
                errors.append(f"{where}: a default profile must use the catalog KV types")
        elif total <= model["contextSize"]:
            errors.append(f"{where}: a long profile must have more context than the catalog ({model['contextSize']})")
    check_evidence(where, row["evidence"], errors)
    if sha_ok and isinstance(row["engineId"], str) and isinstance(row["backend"], str) and profile_id is not None:
        return (sha, row["engineId"], row["backend"], profile_id)
    return None


def validate(document, catalog, components):
    """Returns a list of problems; empty means the document is valid against this catalog and component list."""
    errors = []
    if not check_keys("top level", document, TOP_KEYS, errors):
        return errors
    if document["schema"] != SCHEMA:
        errors.append(f"schema must be {SCHEMA!r}")
    for reserved in ("addOns", "sidecars"):
        if not isinstance(document[reserved], list) or document[reserved]:
            errors.append(f"{reserved} must be an empty list: its rows are reserved and not accepted yet")
    profiles = document["profiles"]
    if not isinstance(profiles, list):
        errors.append("profiles must be a list")
        return errors
    models = catalog_models(catalog)
    engines = known_engines(catalog, components)
    seen = set()
    for index, row in enumerate(profiles):
        where = f"profiles[{index}]"
        key = check_profile(where, row, models, engines, errors)
        if key is None:
            continue
        if key in seen:
            errors.append(f"{where}: duplicate row for this model, engine, backend and profile id")
        seen.add(key)
    return errors


def check_digest(root):
    """Returns a list of problems with config/serving-profiles.sha256; empty means it matches the file."""
    config = os.path.join(root, "config")
    try:
        with open(os.path.join(config, FILE_NAME), "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        with open(os.path.join(config, DIGEST_NAME), "rb") as handle:
            recorded = handle.read()
    except OSError as error:
        return [f"config/{DIGEST_NAME} cannot be checked: {error.strerror or error}"]
    if recorded != (digest + "  " + FILE_NAME + "\n").encode("ascii"):
        return [f"config/{DIGEST_NAME} does not match config/{FILE_NAME} (expected '<sha256>  {FILE_NAME}' and a line feed)"]
    return []


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=REPO_ROOT)
    args = parser.parse_args(argv)
    document = None
    try:
        config = os.path.join(args.root, "config")
        with open(os.path.join(config, FILE_NAME), encoding="utf-8") as handle:
            document = json.load(handle)
        with open(os.path.join(config, "catalog.json"), encoding="utf-8") as handle:
            catalog = json.load(handle)
        with open(os.path.join(config, "components.json"), encoding="utf-8") as handle:
            components = json.load(handle)
        errors = validate(document, catalog, components)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        errors = [str(error)]
    errors.extend(check_digest(args.root))
    for line in errors:
        print(f"check-serving-profiles: {line}", file=sys.stderr)
    if errors:
        return 1
    print(f"serving profiles ok ({len(document['profiles'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
