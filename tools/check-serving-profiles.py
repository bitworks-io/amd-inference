#!/usr/bin/env python3
"""Validate config/serving-profiles.json (bitworks.fastllm-serving-profiles/v1) and its digest file. Exit 0 ok, 1 invalid.

Measured rows for the opt-in serving settings (context profile, slots). The planner offers an option only from a row whose
model sha256, engine id and backend equal the plan's; with no row the option is refused. Nothing is derived from a formula.

Shape:
  { "schema": "bitworks.fastllm-serving-profiles/v1", "profiles": [ Profile, ... ], "addOns": [ AddOn, ... ], "sidecars": [ Sidecar, ... ] }
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
  Sidecar = {                       # a second llama-server with its own model, beside the text model (embeddings)
    "role": "embedding",
    "componentId": str              # a config/components.json component of kind "embedding-model"
    "componentSha256": 64 lowercase hex # equals the sha256 of that component's model file (its entryPoint in the file manifest)
    "engineId": str                 # the built-in engine id only (llama.cpp-<catalog engine version>-vulkan)
    "backend": "vulkan"             # the backend of that engine
    "placement": "cpu"              # CPU placement only; a GPU placement is not offered
    "contextSize": int 1..1048576   # the context the sidecar is started with (-c)
    "pooling": "mean"|"cls"|"last"  # --pooling
    "dimension": int 1..65536       # the length of one embedding vector; the start check compares it
    "evidence": { "resultId": str, "measuredAt": "YYYY-MM-DDTHH:MM:SSZ", "gpuClasses": [str, ...] }
  }
  AddOn = {                         # the measured extra memory of an opt-in option: kind vision (a projector file beside the text model, --mmproj),
                                    # kind ngram (speculative decoding from the context, no extra file) or kind mtp (speculation with a separate draft file)
    "kind": "vision"|"ngram"|"mtp"
    "modelId": str                  # a config/catalog.json model id
    "modelSha256": 64 lowercase hex # equals that catalog model's sha256
    "engineId": str                 # the built-in engine id or a listed llama.cpp engine component (the planner uses the built-in engine only)
    "backend": "vulkan"|"hip"       # equals the backend of that engine
    "componentId": str              # vision: a config/components.json component of kind "projector"; mtp: one of kind "draft"; ngram: no such key
    "specType": str                 # ngram and mtp: the exact --spec-type value, from the closed allowlist of that engine id (SPECULATION_ALLOWLIST)
    "extraArguments": [str, ...]    # ngram and mtp: appended to the server arguments in this order; every flag from the engine's allowlist, each with at most one value
    "extraFreeVramMiB": { "default"|"long": int > 0, ... }   # a non-empty object: the free memory the add-on adds to that profile's requirement
                                    # (vision and mtp: > 0; ngram: >= 0)
    "evidence": { "resultId": str, "measuredAt": "YYYY-MM-DDTHH:MM:SSZ", "gpuClasses": [str, ...] }
  }
  A vision row has the keys kind, modelId, modelSha256, engineId, backend, componentId, extraFreeVramMiB, evidence. An ngram row has no componentId and
  adds specType and extraArguments. An mtp row has componentId (a draft component), specType and extraArguments.
One row per (modelSha256, engineId, backend, id), one sidecar row per (role, componentSha256, engineId, backend), and one add-on row per
(kind, modelSha256, engineId, backend). The planner adds the extra memory of the effective profile id to that profile's requirement; with no
value for the profile (a default-context plan has no profile id) the option is refused. Nothing is derived from a formula or a file size.
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
ADD_ON_SHARED_KEYS = {"kind", "modelId", "modelSha256", "engineId", "backend", "extraFreeVramMiB", "evidence"}
ADD_ON_KEYS_BY_KIND = {
    "vision": ADD_ON_SHARED_KEYS | {"componentId"},
    "ngram": ADD_ON_SHARED_KEYS | {"specType", "extraArguments"},
    "mtp": ADD_ON_SHARED_KEYS | {"componentId", "specType", "extraArguments"},
}
ADD_ON_KINDS = ("vision", "ngram", "mtp")
EXTRA_ARGUMENT_VALUE_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z._:,]{0,31}")
# The closed per-engine allowlist of the speculation rows: for each pinned engine id, the --spec-type values a row of each kind may use, the extra
# argument NAMES (flags; a value follows its flag) a row may append, and the flag the planner itself uses for the draft file of an mtp row. A row
# outside it is refused here and by the PowerShell loader (src/FastLlm.Speculation.ps1 holds the same table). Flag names differ between pins
# (--spec-draft-sampling and --spec-draft-n-ubatch exist from b11658; the old --draft* names are gone), so one list is never shared across engines.
# tests/test_serving_profiles.py proves every name is in the engine-surface fixture of the engine's tag. A pinned engine with no fixture would get an
# empty entry.
_NGRAM_FLAGS = ["--spec-ngram-size-n", "--spec-ngram-size-m", "--spec-ngram-min-hits",
                "--spec-ngram-simple-size-n", "--spec-ngram-simple-size-m", "--spec-ngram-simple-min-hits",
                "--spec-ngram-map-k-size-n", "--spec-ngram-map-k-size-m", "--spec-ngram-map-k-min-hits",
                "--spec-ngram-map-k4v-size-n", "--spec-ngram-map-k4v-size-m", "--spec-ngram-map-k4v-min-hits",
                "--spec-ngram-mod-n-match", "--spec-ngram-mod-n-max", "--spec-ngram-mod-n-min"]
_DRAFT_FLAGS = ["--spec-draft-n-max", "--spec-draft-n-min", "--spec-draft-p-min"]
_SPEC_TYPES = {"ngram": ["ngram-simple", "ngram-map-k", "ngram-map-k4v", "ngram-mod"], "mtp": ["draft-mtp"]}
_B10698 = {"specTypes": _SPEC_TYPES, "flags": _NGRAM_FLAGS + _DRAFT_FLAGS, "draftModelFlag": "--spec-draft-model"}
_B11658 = {"specTypes": _SPEC_TYPES, "flags": _NGRAM_FLAGS + _DRAFT_FLAGS + ["--spec-draft-n-ubatch", "--spec-draft-sampling"],
           "draftModelFlag": "--spec-draft-model"}
SPECULATION_ALLOWLIST = {
    "llama.cpp-b10698-vulkan": _B10698,
    "llama.cpp-hip-b11658": _B11658,
    "llama.cpp-hip-b11658-gfx1201": _B11658,
    "llama.cpp-hip-b11658-gfx1200": _B11658,
}
SIDECAR_KEYS = {"role", "componentId", "componentSha256", "engineId", "backend", "placement", "contextSize", "pooling", "dimension", "evidence"}
SIDECAR_POOLINGS = ("mean", "cls", "last")
SIDECAR_MAX_CONTEXT = 1048576
SIDECAR_MAX_DIMENSION = 65536
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


def check_model_and_engine(where, row, models, engines, errors):
    """The model and engine binding shared by a profile row and an add-on row. Returns (sha is well formed, the catalog model or None)."""
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
    return sha_ok, model


def check_profile(where, row, models, engines, errors):
    """Validates one row; returns its uniqueness key, or None when the row has no usable key."""
    if not check_keys(where, row, PROFILE_KEYS, errors):
        return None
    sha_ok, model = check_model_and_engine(where, row, models, engines, errors)
    sha = row["modelSha256"]
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


def embedding_models(components):
    """{component id: sha256 of its model file} for the listed components of kind embedding-model that name a model file."""
    models = {}
    listed = components.get("components", []) if isinstance(components, dict) else []
    for component in listed if isinstance(listed, list) else []:
        if not isinstance(component, dict) or component.get("kind") != "embedding-model" or not is_str(component.get("id")):
            continue
        entry = component.get("entryPoint")
        parts = [component["source"]] if isinstance(component.get("source"), dict) else component.get("sources")
        digest = None
        for part in parts if isinstance(parts, list) else []:
            manifest = part.get("fileManifest") if isinstance(part, dict) else None
            for item in manifest if isinstance(manifest, list) else []:
                if isinstance(item, dict) and is_str(entry) and item.get("path") == entry and isinstance(item.get("sha256"), str):
                    digest = item["sha256"].lower()
        models[component["id"]] = digest
    return models


def check_sidecar(where, row, catalog, components, errors):
    """Validates one sidecar row; returns its uniqueness key, or None when the row has no usable key."""
    if not check_keys(where, row, SIDECAR_KEYS, errors):
        return None
    role = row["role"]
    if not isinstance(role, str) or role != "embedding":
        errors.append(f"{where}: role must be 'embedding'")
        role = None
    sha = row["componentSha256"]
    sha_ok = isinstance(sha, str) and bool(SHA_RE.fullmatch(sha))
    if not sha_ok:
        errors.append(f"{where}: componentSha256 must be 64 lowercase hex characters")
    models = embedding_models(components)
    component_id = row["componentId"]
    if not isinstance(component_id, str) or component_id not in models:
        errors.append(f"{where}: componentId {component_id!r} is not a listed embedding-model component")
    elif sha_ok and models[component_id] != sha:
        errors.append(f"{where}: componentSha256 does not equal the sha256 of the model file of {component_id!r}")
    # A sidecar runs on the built-in engine only, whatever engine serves the text model.
    version = catalog.get("engine", {}).get("version") if isinstance(catalog, dict) and isinstance(catalog.get("engine"), dict) else None
    built_in = "llama.cpp-" + version + "-vulkan" if is_str(version) else None
    if built_in is None or not isinstance(row["engineId"], str) or row["engineId"] != built_in:
        errors.append(f"{where}: engineId must be the built-in engine ({built_in!r})")
    if not isinstance(row["backend"], str) or row["backend"] != "vulkan":
        errors.append(f"{where}: backend must be 'vulkan' (the built-in engine)")
    if not isinstance(row["placement"], str) or row["placement"] != "cpu":
        errors.append(f"{where}: placement must be 'cpu': a GPU placement is not offered")
    if not is_int(row["contextSize"]) or not 1 <= row["contextSize"] <= SIDECAR_MAX_CONTEXT:
        errors.append(f"{where}: contextSize must be a whole number from 1 to {SIDECAR_MAX_CONTEXT}")
    if not isinstance(row["pooling"], str) or row["pooling"] not in SIDECAR_POOLINGS:
        errors.append(f"{where}: pooling must be one of {list(SIDECAR_POOLINGS)}")
    if not is_int(row["dimension"]) or not 1 <= row["dimension"] <= SIDECAR_MAX_DIMENSION:
        errors.append(f"{where}: dimension must be a whole number from 1 to {SIDECAR_MAX_DIMENSION}")
    check_evidence(where, row["evidence"], errors)
    if role is not None and sha_ok and isinstance(row["engineId"], str) and isinstance(row["backend"], str):
        return (role, sha, row["engineId"], row["backend"])
    return None


def projector_ids(components):
    """The ids of the listed components of kind projector."""
    ids = set()
    listed = components.get("components", []) if isinstance(components, dict) else []
    for component in listed if isinstance(listed, list) else []:
        if isinstance(component, dict) and component.get("kind") == "projector" and is_str(component.get("id")):
            ids.add(component["id"])
    return ids


def draft_ids(components):
    """The ids of the listed components of kind draft."""
    ids = set()
    listed = components.get("components", []) if isinstance(components, dict) else []
    for component in listed if isinstance(listed, list) else []:
        if isinstance(component, dict) and component.get("kind") == "draft" and is_str(component.get("id")):
            ids.add(component["id"])
    return ids


def check_extra_arguments(where, row, allowed_flags, errors):
    """extraArguments: a list of strings: flags from the engine's allowlist, each with at most one plain value, no flag twice."""
    arguments = row["extraArguments"]
    if not isinstance(arguments, list) or not all(isinstance(a, str) for a in arguments):
        errors.append(f"{where}: extraArguments must be a list of strings")
        return
    seen = set()
    previous_was_flag = False
    for index, argument in enumerate(arguments):
        if argument.startswith("--"):
            if argument not in allowed_flags:
                errors.append(f"{where}: extraArguments flag {argument!r} is not allowed for engine {row['engineId']!r}")
            if argument in seen:
                errors.append(f"{where}: extraArguments names {argument!r} twice")
            seen.add(argument)
            previous_was_flag = True
            continue
        if index == 0:
            errors.append(f"{where}: extraArguments must start with a flag")
        elif not previous_was_flag:
            errors.append(f"{where}: extraArguments gives a flag more than one value")
        if not EXTRA_ARGUMENT_VALUE_RE.fullmatch(argument):
            errors.append(f"{where}: extraArguments value {argument!r} is not a short plain value")
        previous_was_flag = False


def check_add_on(where, row, models, engines, projectors, errors, drafts=None):
    """Validates one add-on row; returns its uniqueness key, or None when the row has no usable key."""
    if not isinstance(row, dict):
        errors.append(f"{where}: must be an object")
        return None
    kind = row.get("kind")
    if not isinstance(kind, str) or kind not in ADD_ON_KINDS:
        errors.append(f"{where}: kind must be 'vision', 'ngram' or 'mtp'")
        if "kind" not in row:
            errors.append(f"{where}: missing keys ['kind']")
        return None
    if not check_keys(where, row, ADD_ON_KEYS_BY_KIND[kind], errors):
        return None
    sha_ok, _model = check_model_and_engine(where, row, models, engines, errors)
    component_id = row.get("componentId")
    if kind == "vision" and (not isinstance(component_id, str) or component_id not in projectors):
        errors.append(f"{where}: componentId {component_id!r} is not a listed projector component")
    if kind == "mtp" and (not isinstance(component_id, str) or component_id not in (drafts or set())):
        errors.append(f"{where}: componentId {component_id!r} is not a listed draft component")
    if kind in ("ngram", "mtp"):
        entry = SPECULATION_ALLOWLIST.get(row["engineId"]) if isinstance(row["engineId"], str) else None
        spec_types = entry["specTypes"][kind] if entry else []
        flags = entry["flags"] if entry else []
        if not isinstance(row["specType"], str) or row["specType"] not in spec_types:
            errors.append(f"{where}: specType {row['specType']!r} is not allowed for a {kind} row on engine {row['engineId']!r}")
        check_extra_arguments(where, row, flags, errors)
    extra = row["extraFreeVramMiB"]
    minimum = 0 if kind == "ngram" else 1
    if not isinstance(extra, dict) or not extra:
        errors.append(f"{where}: extraFreeVramMiB must be a non-empty object of profile id to MiB")
    else:
        for profile_id, mib in extra.items():
            if profile_id not in PROFILE_IDS:
                errors.append(f"{where}: extraFreeVramMiB has the unknown profile id {profile_id!r}")
            if not is_int(mib) or mib < minimum:
                words = "a positive whole number of MiB" if minimum else "a whole number of MiB (0 or more)"
                errors.append(f"{where}: extraFreeVramMiB[{profile_id!r}] must be {words}")
    check_evidence(where, row["evidence"], errors)
    if sha_ok and isinstance(row["engineId"], str) and isinstance(row["backend"], str):
        return (kind, row["modelSha256"], row["engineId"], row["backend"])
    return None


def validate(document, catalog, components):
    """Returns a list of problems; empty means the document is valid against this catalog and component list."""
    errors = []
    if not check_keys("top level", document, TOP_KEYS, errors):
        return errors
    if document["schema"] != SCHEMA:
        errors.append(f"schema must be {SCHEMA!r}")
    add_ons = document["addOns"]
    if not isinstance(add_ons, list):
        errors.append("addOns must be a list")
        add_ons = []
    models = catalog_models(catalog)
    engines = known_engines(catalog, components)
    projectors = projector_ids(components)
    drafts = draft_ids(components)
    seen_add_ons = set()
    for index, row in enumerate(add_ons):
        where = f"addOns[{index}]"
        key = check_add_on(where, row, models, engines, projectors, errors, drafts)
        if key is None:
            continue
        if key in seen_add_ons:
            errors.append(f"{where}: duplicate add-on row for this kind, model, engine and backend")
        seen_add_ons.add(key)
    sidecars = document["sidecars"]
    if not isinstance(sidecars, list):
        errors.append("sidecars must be a list")
        sidecars = []
    seen_sidecars = set()
    for index, row in enumerate(sidecars):
        where = f"sidecars[{index}]"
        key = check_sidecar(where, row, catalog, components, errors)
        if key is None:
            continue
        if key in seen_sidecars:
            errors.append(f"{where}: duplicate sidecar row for this role, component, engine and backend")
        seen_sidecars.add(key)
    profiles = document["profiles"]
    if not isinstance(profiles, list):
        errors.append("profiles must be a list")
        return errors
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
    extras = []
    if document["sidecars"]:
        extras.append(f"sidecars {len(document['sidecars'])}")
    if document["addOns"]:
        extras.append(f"add-ons {len(document['addOns'])}")
    if extras:
        print(f"serving profiles ok ({len(document['profiles'])}, {', '.join(extras)})")
    else:
        print(f"serving profiles ok ({len(document['profiles'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
