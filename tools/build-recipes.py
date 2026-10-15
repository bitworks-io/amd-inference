#!/usr/bin/env python3
"""Build config/recipes.json (bitworks.fastllm-recipes/v2) from data/verified-recipes.json and data/community-records.json.

Verified and community-reproduced entries ship only with a live evidence page (evidence.url on https://bitworks.io/ and
evidence.publishedAt); others are skipped and reported. Community entries get the compelling rule (>=15% generation OR >=50% prompt over the
best Bitworks recipe for the same card and GPU count, at the same or larger context; with no Bitworks recipe to compare
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

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LABELS = {
    "bitworks": "Measured by Bitworks on this card",
    "community-reproduced": "Community recipe, reproduced by Bitworks",
    "community-experimental": "Experimental community recipe, not reproduced by Bitworks",
}
MITIGATIONS = ("auto", "on", "off")
ID_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]{1,120}$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}")


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


def validate(entry, origin, catalog, variants):
    rid = entry.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise RecipeError(f"bad recipe id: {rid!r}")
    if entry.get("variant") not in variants:
        raise RecipeError(f"{rid}: unknown card variant {entry.get('variant')!r}")
    models = {m["id"]: m for m in catalog["models"]}
    model = models.get(entry.get("model"))
    if model is None:
        raise RecipeError(f"{rid}: model {entry.get('model')!r} is not in the catalog")
    if entry.get("engineBuild") != catalog["engine"]["version"]:
        raise RecipeError(f"{rid}: engine build {entry.get('engineBuild')!r} is not the shipped {catalog['engine']['version']!r}")
    runtime = entry.get("runtime") or {}
    if runtime.get("vulkanBarMitigation") not in MITIGATIONS:
        raise RecipeError(f"{rid}: runtime.vulkanBarMitigation must be one of {MITIGATIONS}")
    if not isinstance(runtime.get("contextSize"), int) or not 0 < runtime["contextSize"] <= int(model["contextSize"]):
        raise RecipeError(f"{rid}: runtime.contextSize must be 1..{model['contextSize']}")
    if not isinstance(entry.get("gpuCount"), int) or entry["gpuCount"] not in (1, 2):
        raise RecipeError(f"{rid}: gpuCount must be 1 or 2")
    expected = entry.get("expected") or {}
    for key in ("generationTokS", "promptTokS", "contextTokens"):
        if not positive(expected.get(key)):
            raise RecipeError(f"{rid}: expected.{key} must be a positive number")
    if expected.get("mitigation") not in ("on", "off"):
        raise RecipeError(f"{rid}: expected.mitigation must be on or off")
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
    return model


def has_live_evidence(entry):
    evidence = entry.get("evidence") or {}
    return bool(evidence.get("url")) and bool(DATE_RE.match(str(evidence.get("publishedAt") or "")))


def recipe_from(entry, origin):
    return {
        "id": entry["id"], "origin": origin, "label": LABELS[origin],
        "gpu": {"variant": entry["variant"], "count": entry["gpuCount"]},
        "components": {"engine": f"llama.cpp-{entry['engineBuild']}-vulkan", "model": entry["model"]},
        "runtime": entry["runtime"], "engineBuild": entry["engineBuild"], "recommended": bool(entry.get("recommended")),
        "expected": entry["expected"], "evidence": entry.get("evidence"), "source": entry.get("source"), "compelling": None,
    }


def compelling(candidate, bitworks_recipes):
    peers = [r for r in bitworks_recipes if r["gpu"] == candidate["gpu"]]
    exp = candidate["expected"]
    if not peers:
        return {"baselineRecipe": None, "generationGainPct": None, "promptGainPct": None, "isCompelling": True}
    best = max(peers, key=lambda r: (r["expected"]["generationTokS"], r["id"]))
    base = best["expected"]
    gen = round(100.0 * (exp["generationTokS"] / base["generationTokS"] - 1.0), 1)
    prompt = round(100.0 * (exp["promptTokS"] / base["promptTokS"] - 1.0), 1)
    same_or_larger = exp["contextTokens"] >= base["contextTokens"]
    return {"baselineRecipe": best["id"], "generationGainPct": gen, "promptGainPct": prompt,
            "isCompelling": bool(same_or_larger and (gen >= 15.0 or prompt >= 50.0))}


def build(root):
    catalog = load(root, "config/catalog.json")
    variants = {v["key"] for v in load(root, "config/gpu-variants.json")["variants"]}
    verified = load(root, "data/verified-recipes.json")
    community = load(root, "data/community-records.json")
    if verified.get("schema") != "bitworks.fastllm-verified-recipes/v1" or community.get("schema") != "bitworks.fastllm-community-recipes/v1":
        raise RecipeError("unexpected data schema")
    recipes, skipped, ids = [], [], set()
    for entry in verified["entries"]:
        validate(entry, "bitworks", catalog, variants)
        if not has_live_evidence(entry):
            skipped.append(f"{entry['id']}: no live evidence page (evidence.url and evidence.publishedAt are required)")
            continue
        recipes.append(recipe_from(entry, "bitworks"))
    bitworks_recipes = list(recipes)
    candidates = []
    for entry in community["records"]:
        origin = entry.get("origin")
        if origin not in ("community-reproduced", "community-experimental"):
            raise RecipeError(f"{entry.get('id')}: community origin must be community-reproduced or community-experimental")
        validate(entry, origin, catalog, variants)
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
        fastest = min(group, key=lambda r: (-r["expected"]["generationTokS"], r["id"]))
        for recipe in group:
            recipe["compelling"]["isCompelling"] = recipe is fastest
    for recipe in candidates:
        if recipe["origin"] == "community-experimental" and not recipe["compelling"]["isCompelling"]:
            skipped.append(f"{recipe['id']}: experimental entries must be compelling")
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
    recipes.sort(key=lambda r: (r["gpu"]["variant"], r["gpu"]["count"], r["origin"], r["id"]))
    inputs = {rel: sha256_file(root, rel) for rel in ("config/catalog.json", "config/gpu-variants.json",
                                                     "data/verified-recipes.json", "data/community-records.json")}
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
