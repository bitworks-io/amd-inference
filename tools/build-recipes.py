#!/usr/bin/env python3
"""Build config/recipes.json (bitworks.fastllm-recipes/v2) from data/verified-recipes.json and data/community-records.json.

Bitworks-authored experimental setups (data/bitworks-experimental-recipes.json, origin bitworks-experimental) need no evidence and are never
recommended; every component they name must be listed in config/components.json, and they name their own engine. They are gated like
community-experimental recipes and never auto-selected by the product.
A verified entry may name its own engine component (components.engine, e.g. the HIP lane): it is checked against config/components.json, carries
no vulkanBarMitigation, uses expected.mitigation "not-applicable", and is never recommended; the product never picks it automatically.
Verified and community-reproduced entries ship only with a live evidence page (evidence.url on https://bitworks.io/ and
evidence.publishedAt); others are skipped and reported. Community entries get the compelling rule (>=15% generation over the highest Bitworks generation OR >=50% prompt over the
highest Bitworks prompt rate, for the same card and GPU count, among Bitworks recipes at the same or a smaller context; with no Bitworks recipe to compare
against, only the fastest community record for that card and GPU count). Only verified Bitworks recipes may be
recommended. Deterministic output.
Usage: build-recipes.py [--root R] [--check]   (exit 0 ok, 1 drift, 2 refused)
"""
import argparse
import hashlib
import json
import os
import re
import sys

EXPERIMENTAL_FILE = "data/bitworks-experimental-recipes.json"
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS = {
    "bitworks": "Measured by Bitworks on this card",
    "community-reproduced": "Community recipe, reproduced by Bitworks",
    "community-experimental": "Experimental community recipe, not reproduced by Bitworks",
    "bitworks-experimental": "Experimental Bitworks setup, not yet measured by Bitworks on this card",
}
# The recipe never forces the Vulkan BAR mitigation; the start applies the user or UI policy (auto by default).
MITIGATIONS = ("auto",)
# expected.mitigation records whether the Vulkan BAR mitigation was on when the numbers were measured. A non-Vulkan (HIP) engine has none.
EXPECTED_MITIGATIONS = ("on", "off")
NOT_APPLICABLE = "not-applicable"
CACHE_TYPES = ("f32", "f16", "bf16", "q8_0", "q4_0", "q4_1", "iq4_nl", "q5_0", "q5_1")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]{1,120}$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


class RecipeError(Exception):
    pass


def load(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8") as handle:
        return json.load(handle)


def sha256_file(root, rel):
    with open(os.path.join(root, rel), "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0


def validate(entry, origin, catalog, variants, components=None):
    rid = entry.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise RecipeError(f"bad recipe id: {rid!r}")
    if entry.get("variant") not in variants:
        raise RecipeError(f"{rid}: unknown card variant {entry.get('variant')!r}")
    models = {m["id"]: m for m in catalog["models"]}
    model = models.get(entry.get("model"))
    if model is None:
        raise RecipeError(f"{rid}: model {entry.get('model')!r} is not in the catalog")
    # A Bitworks entry may name its own engine component (the HIP lane); every other entry runs on the built-in Vulkan engine.
    own_engine = None
    if origin == "bitworks" and (entry.get("components") or {}).get("engine"):
        if components is None:
            raise RecipeError(f"{rid}: an entry that names its own engine needs config/components.json to check it against")
        own_engine = check_engine_components(entry, model, components)
    non_vulkan = own_engine is not None and (own_engine.get("platform") or {}).get("backend") != "vulkan"
    if own_engine is None and entry.get("engineBuild") != catalog["engine"]["version"]:
        raise RecipeError(f"{rid}: engine build {entry.get('engineBuild')!r} is not the shipped {catalog['engine']['version']!r}")
    runtime = entry.get("runtime") or {}
    if non_vulkan:
        if "vulkanBarMitigation" in runtime:
            raise RecipeError(f"{rid}: runtime.vulkanBarMitigation is for Vulkan engines only")
        if entry.get("recommended"):
            raise RecipeError(f"{rid}: recommended is for Vulkan engines only (a recipe whose engine needs an accepted license is never picked automatically)")
    elif runtime.get("vulkanBarMitigation") not in MITIGATIONS:
        raise RecipeError(f"{rid}: runtime.vulkanBarMitigation must be one of {MITIGATIONS}")
    if not isinstance(runtime.get("contextSize"), int) or not 0 < runtime["contextSize"] <= int(model["contextSize"]):
        raise RecipeError(f"{rid}: runtime.contextSize must be 1..{model['contextSize']}")
    if "parallel" in runtime and (isinstance(runtime["parallel"], bool) or runtime["parallel"] != 1):
        raise RecipeError(f"{rid}: runtime.parallel must be 1 (the API check requires a single slot)")
    for field in ("cacheTypeK", "cacheTypeV"):
        if field in runtime and runtime[field] not in CACHE_TYPES:
            raise RecipeError(f"{rid}: runtime.{field} must be one of {CACHE_TYPES}")
    if "fitTargetMiB" in runtime and (not isinstance(runtime["fitTargetMiB"], int) or isinstance(runtime["fitTargetMiB"], bool) or runtime["fitTargetMiB"] <= 0):
        raise RecipeError(f"{rid}: runtime.fitTargetMiB must be a positive integer")
    if model.get("autoEligible") is False and origin != "community-experimental":
        raise RecipeError(f"{rid}: model {entry.get('model')!r} is not auto-eligible; only an experimental community recipe may use it")
    if not isinstance(entry.get("gpuCount"), int) or entry["gpuCount"] not in (1, 2):
        raise RecipeError(f"{rid}: gpuCount must be 1 or 2")
    expected = entry.get("expected") or {}
    for key in ("generationTokS", "promptTokS", "contextTokens"):
        if not positive(expected.get(key)):
            raise RecipeError(f"{rid}: expected.{key} must be a positive number")
    if non_vulkan:
        if expected.get("mitigation") != NOT_APPLICABLE:
            raise RecipeError(f"{rid}: expected.mitigation must be {NOT_APPLICABLE} for a non-Vulkan engine")
    elif expected.get("mitigation") not in EXPECTED_MITIGATIONS:
        raise RecipeError(f"{rid}: expected.mitigation must be on or off")
    # The self-test's below-expected comparison reads expected.engineBuild; a recipe without it would fail every self-test.
    if expected.get("engineBuild") != entry.get("engineBuild"):
        raise RecipeError(f"{rid}: expected.engineBuild must equal the recipe's engineBuild")
    evidence = entry.get("evidence") or {}
    url = evidence.get("url")
    if url is not None and not str(url).startswith("https://bitworks.io/"):
        raise RecipeError(f"{rid}: evidence.url must be on https://bitworks.io/")
    if origin != "bitworks":
        if entry.get("recommended"):
            raise RecipeError(f"{rid}: recommended is for verified Bitworks recipes only")
        source = entry.get("source") or {}
        if not all(source.get(k) for k in ("author", "url", "postedAt", "recordId")):
            raise RecipeError(f"{rid}: community entries need source author, url, postedAt and recordId")
    if origin == "community-reproduced":
        repro = entry.get("reproduction")
        if not isinstance(repro, dict):
            raise RecipeError(f"{rid}: community-reproduced entries need a reproduction block")
        if not isinstance(repro.get("resultId"), str) or not repro["resultId"]:
            raise RecipeError(f"{rid}: reproduction.resultId is required")
        if not isinstance(repro.get("batchManifestSha256"), str) or not SHA_RE.match(repro["batchManifestSha256"]):
            raise RecipeError(f"{rid}: reproduction.batchManifestSha256 must be 64 hex characters")
        if not DATE_RE.match(str(repro.get("measuredAt") or "")):
            raise RecipeError(f"{rid}: reproduction.measuredAt must be a date")
        for key in ("generationTokS", "promptTokS"):
            if not positive(repro.get(key)):
                raise RecipeError(f"{rid}: reproduction.{key} must be a positive number")
    return model


def check_engine_components(entry, model, components):
    """The entry's engine, runtime and draft components must all be listed in config/components.json, the engine's version must be the entry's
    engineBuild, and the runtime block must be valid for it. Returns the engine component."""
    rid = entry.get("id")
    refs = entry.get("components") or {}
    engine_id = refs.get("engine")
    by_id = {c["id"]: c for c in components["components"]}
    engine = by_id.get(engine_id)
    if engine is None or engine.get("kind") != "engine":
        raise RecipeError(f"{rid}: components.engine {engine_id!r} is not an engine in config/components.json")
    if entry.get("engineBuild") != engine.get("version"):
        raise RecipeError(f"{rid}: engineBuild {entry.get('engineBuild')!r} is not the engine component's version {engine.get('version')!r}")
    for key in ("runtime", "draft"):
        if refs.get(key) is not None and (refs[key] not in by_id or by_id[refs[key]].get("kind") != key):
            raise RecipeError(f"{rid}: components.{key} {refs[key]!r} is not a {key} in config/components.json")
    for required in engine.get("requires") or []:
        if required not in by_id:
            raise RecipeError(f"{rid}: the engine requires {required!r}, which is not in config/components.json")
    runtime = entry.get("runtime") or {}
    if "vulkanBarMitigation" in runtime:
        if (engine.get("platform") or {}).get("backend") != "vulkan":
            raise RecipeError(f"{rid}: runtime.vulkanBarMitigation is for Vulkan engines only")
        if runtime["vulkanBarMitigation"] not in MITIGATIONS:
            raise RecipeError(f"{rid}: runtime.vulkanBarMitigation must be one of {MITIGATIONS}")
    if not isinstance(runtime.get("contextSize"), int) or isinstance(runtime.get("contextSize"), bool) or not 0 < runtime["contextSize"] <= int(model["contextSize"]):
        raise RecipeError(f"{rid}: runtime.contextSize must be 1..{model['contextSize']}")
    if "parallel" in runtime and (isinstance(runtime["parallel"], bool) or runtime["parallel"] != 1):
        raise RecipeError(f"{rid}: runtime.parallel must be 1 (the API check requires a single slot)")
    for field in ("cacheTypeK", "cacheTypeV"):
        if field in runtime and runtime[field] not in CACHE_TYPES:
            raise RecipeError(f"{rid}: runtime.{field} must be one of {CACHE_TYPES}")
    if "fitTargetMiB" in runtime and (not isinstance(runtime["fitTargetMiB"], int) or isinstance(runtime["fitTargetMiB"], bool) or runtime["fitTargetMiB"] <= 0):
        raise RecipeError(f"{rid}: runtime.fitTargetMiB must be a positive integer")

    return engine


def validate_bitworks_experimental(entry, catalog, variants, components):
    """A Bitworks setup that is shipped so Bitworks can measure it through the product: no evidence yet, never recommended, and its own
    engine and other components must all be listed in config/components.json. The engine build is the component's, not the catalog's."""
    rid = entry.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise RecipeError(f"bad recipe id: {rid!r}")
    if components is None:
        raise RecipeError(f"{rid}: bitworks-experimental entries need config/components.json to check their components against")
    if entry.get("recommended"):
        raise RecipeError(f"{rid}: recommended is for verified Bitworks recipes only")
    for forbidden in ("expected", "evidence", "source", "reproduction"):
        if entry.get(forbidden):
            raise RecipeError(f"{rid}: a bitworks-experimental entry carries no {forbidden} block (it has not been measured)")
    if entry.get("variant") not in variants:
        raise RecipeError(f"{rid}: unknown card variant {entry.get('variant')!r}")
    model = {m["id"]: m for m in catalog["models"]}.get(entry.get("model"))
    if model is None:
        raise RecipeError(f"{rid}: model {entry.get('model')!r} is not in the catalog")
    if not isinstance(entry.get("gpuCount"), int) or isinstance(entry.get("gpuCount"), bool) or entry["gpuCount"] not in (1, 2):
        raise RecipeError(f"{rid}: gpuCount must be 1 or 2")
    check_engine_components(entry, model, components)


def has_live_evidence(entry):
    evidence = entry.get("evidence") or {}
    return bool(evidence.get("url")) and bool(DATE_RE.match(str(evidence.get("publishedAt") or "")))


def recipe_from(entry, origin):
    if origin == "bitworks-experimental":
        components = {"engine": entry["components"]["engine"], "model": entry["model"]}
        for key in ("runtime", "draft"):
            if entry["components"].get(key):
                components[key] = entry["components"][key]
        return {"id": entry["id"], "origin": origin, "label": LABELS[origin],
                "gpu": {"variant": entry["variant"], "count": entry["gpuCount"]}, "components": components,
                "runtime": entry["runtime"], "engineBuild": entry["engineBuild"], "recommended": False,
                "expected": None, "evidence": None, "source": None, "compelling": None}
    components = {"engine": f"llama.cpp-{entry['engineBuild']}-vulkan", "model": entry["model"]}
    if origin in ("bitworks", "community-experimental"):
        # An experimental entry may name its own engine, plus a runtime and a draft model; all are checked against components.json.
        for key in ("engine", "runtime", "draft"):
            ref = (entry.get("components") or {}).get(key)
            if ref:
                components[key] = ref
    recipe = {
        "id": entry["id"], "origin": origin, "label": LABELS[origin],
        "gpu": {"variant": entry["variant"], "count": entry["gpuCount"]},
        "components": components,
        "runtime": entry["runtime"], "engineBuild": entry["engineBuild"], "recommended": bool(entry.get("recommended")),
        "expected": entry["expected"], "evidence": entry.get("evidence"), "source": entry.get("source"), "compelling": None,
    }
    if origin == "community-reproduced":
        recipe["reproduction"] = entry["reproduction"]
    return recipe


def measured_rates(recipe):
    """A reproduced recipe is judged on Bitworks' reproduction numbers, never on the community claim."""
    source = recipe["reproduction"] if recipe["origin"] == "community-reproduced" else recipe["expected"]
    return source["generationTokS"], source["promptTokS"]


def compelling(candidate, bitworks_recipes):
    """Each metric is compared with the best Bitworks value for that metric (same card and GPU count, same or smaller measured context than the
    candidate): >=15% generation over the highest Bitworks generation, or >=50% prompt over the highest Bitworks prompt rate.
    baselineRecipe stays the generation baseline, for consumers that read a single baseline."""
    peers = [r for r in bitworks_recipes if r["gpu"] == candidate["gpu"]]
    exp = dict(candidate["expected"])
    exp["generationTokS"], exp["promptTokS"] = measured_rates(candidate)
    if not peers:
        return {"baselineRecipe": None, "baselineGeneration": None, "baselinePrompt": None, "generationGainPct": None, "promptGainPct": None, "isCompelling": True}
    eligible = [r for r in peers if exp["contextTokens"] >= r["expected"]["contextTokens"]]
    pool = eligible or peers
    best_gen = max(pool, key=lambda r: (r["expected"]["generationTokS"], r["id"]))
    best_prompt = max(pool, key=lambda r: (r["expected"]["promptTokS"], r["id"]))
    gen_ratio = exp["generationTokS"] / best_gen["expected"]["generationTokS"]
    prompt_ratio = exp["promptTokS"] / best_prompt["expected"]["promptTokS"]
    return {"baselineRecipe": best_gen["id"], "baselineGeneration": best_gen["id"], "baselinePrompt": best_prompt["id"],
            "generationGainPct": round(100.0 * (gen_ratio - 1.0), 1), "promptGainPct": round(100.0 * (prompt_ratio - 1.0), 1),
            "isCompelling": bool(eligible and (round(gen_ratio, 6) >= 1.15 or round(prompt_ratio, 6) >= 1.5))}


def check_component_refs(recipes, components):
    """Each recipe's components.engine must be an engine component whose version is the recipe's engineBuild;
    a runtime or draft reference must exist with the matching kind."""
    engines = {c["id"]: c for c in components["components"] if c.get("kind") == "engine"}
    for recipe in recipes:
        for key in ("runtime", "draft"):
            ref = recipe["components"].get(key)
            if ref is not None and not any(c["id"] == ref and c.get("kind") == key for c in components["components"]):
                raise RecipeError(f"{recipe['id']}: components.{key} {ref!r} is not a {key} in config/components.json")
        engine = engines.get(recipe["components"]["engine"])
        if engine is None:
            raise RecipeError(f"{recipe['id']}: components.engine {recipe['components']['engine']!r} is not an engine in config/components.json")
        if engine.get("version") != recipe["engineBuild"]:
            raise RecipeError(f"{recipe['id']}: engine component {engine['id']!r} is version {engine.get('version')!r}, not the recipe's engineBuild {recipe['engineBuild']!r}")


def build(root):
    catalog = load(root, "config/catalog.json")
    components_path = os.path.join(root, "config", "components.json")
    components = load(root, "config/components.json") if os.path.exists(components_path) else None
    variants = {v["key"] for v in load(root, "config/gpu-variants.json")["variants"]}
    verified = load(root, "data/verified-recipes.json")
    community = load(root, "data/community-records.json")
    if verified.get("schema") != "bitworks.fastllm-verified-recipes/v1" or community.get("schema") != "bitworks.fastllm-community-recipes/v1":
        raise RecipeError("unexpected data schema")
    recipes, skipped, ids = [], [], set()
    for entry in verified["entries"]:
        validate(entry, "bitworks", catalog, variants, components)
        if not has_live_evidence(entry):
            skipped.append(f"{entry['id']}: no live evidence page (evidence.url and evidence.publishedAt are required)")
            continue
        recipes.append(recipe_from(entry, "bitworks"))
    bitworks_recipes = list(recipes)
    # Optional input: Bitworks setups that ship before they are measured (no evidence, never recommended, never a compelling-rule baseline).
    experimental = load(root, EXPERIMENTAL_FILE) if os.path.exists(os.path.join(root, EXPERIMENTAL_FILE)) else None
    if experimental is not None:
        if experimental.get("schema") != "bitworks.fastllm-bitworks-experimental-recipes/v1":
            raise RecipeError("unexpected data schema in " + EXPERIMENTAL_FILE)
        for entry in experimental["entries"]:
            if entry.get("origin") != "bitworks-experimental":
                raise RecipeError(f"{entry.get('id')}: origin must be bitworks-experimental in {EXPERIMENTAL_FILE}")
            validate_bitworks_experimental(entry, catalog, variants, components)
            recipes.append(recipe_from(entry, "bitworks-experimental"))
    candidates = []
    for entry in community["records"]:
        origin = entry.get("origin")
        if origin not in ("community-reproduced", "community-experimental"):
            raise RecipeError(f"{entry.get('id')}: community origin must be community-reproduced or community-experimental")
        if entry.get("demotedAt") is not None or entry.get("demotionReason") is not None:
            if not DATE_RE.match(str(entry.get("demotedAt") or "")) or not str(entry.get("demotionReason") or "").strip():
                raise RecipeError(f"{entry.get('id')}: a demotion needs both demotedAt (a date) and demotionReason")
            skipped.append(f"{entry['id']}: demoted: {entry['demotionReason']}")
            continue
        validate(entry, origin, catalog, variants)
        if origin == "community-experimental" and components is None:
            raise RecipeError(f"{entry['id']}: experimental entries need config/components.json to check their components against")
        if origin == "community-reproduced" and not has_live_evidence(entry):
            # "Reproduced by Bitworks" needs a Bitworks result page behind it, the same gate as a verified entry.
            skipped.append(f"{entry['id']}: no live evidence page (evidence.url and evidence.publishedAt are required)")
            continue
        recipe = recipe_from(entry, origin)
        recipe["compelling"] = compelling(recipe, bitworks_recipes)
        candidates.append(recipe)
    # With no Bitworks recipe for a card and GPU count to compare against, only the fastest community record is compelling.
    peerless = {}
    for recipe in candidates:
        if recipe["compelling"]["baselineRecipe"] is None:
            peerless.setdefault((recipe["gpu"]["variant"], recipe["gpu"]["count"]), []).append(recipe)
    for group in peerless.values():
        fastest = min(group, key=lambda r: (-measured_rates(r)[0], r["id"]))
        for recipe in group:
            recipe["compelling"]["isCompelling"] = recipe is fastest
    for recipe in candidates:
        if not recipe["compelling"]["isCompelling"]:
            skipped.append(f"{recipe['id']}: " + ("not-compelling" if recipe["origin"] == "community-reproduced" else "experimental entries must be compelling"))
            continue
        recipes.append(recipe)
    for recipe in recipes:
        if recipe["id"] in ids:
            raise RecipeError(f"duplicate recipe id {recipe['id']}")
        ids.add(recipe["id"])
    seen = set()
    for recipe in recipes:
        key = (recipe["gpu"]["variant"], recipe["gpu"]["count"])
        if recipe["recommended"]:
            if key in seen:
                raise RecipeError(f"more than one recommended recipe for {key}")
            seen.add(key)
    if components is not None:
        check_component_refs(recipes, components)
    recipes.sort(key=lambda r: (r["gpu"]["variant"], r["gpu"]["count"], r["origin"], r["id"]))
    input_files = ["config/catalog.json", "config/gpu-variants.json", "data/verified-recipes.json", "data/community-records.json"]
    if components is not None:
        input_files.append("config/components.json")
    if experimental is not None:
        input_files.append(EXPERIMENTAL_FILE)
    inputs = {rel: sha256_file(root, rel) for rel in input_files}
    return {"schema": "bitworks.fastllm-recipes/v2", "inputs": inputs, "recipes": recipes}, skipped


def render(document):
    return (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=REPO_ROOT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        document, skipped = build(args.root)
    except (OSError, ValueError, KeyError, RecipeError) as error:
        print(f"build-recipes: refusing: {error}", file=sys.stderr)
        return 2
    for line in skipped:
        print(f"skipped: {line}")
    target = os.path.join(args.root, "config", "recipes.json")
    data = render(document)
    if args.check:
        try:
            with open(target, "rb") as handle:
                current = handle.read()
        except OSError:
            current = b""
        if current != data:
            print("build-recipes: config/recipes.json is out of date; run tools/build-recipes.py", file=sys.stderr)
            return 1
        return 0
    with open(target, "wb") as handle:
        handle.write(data)
    print(f"wrote {len(document['recipes'])} recipe(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
