#!/usr/bin/env python3
"""Screen community records against the best Bitworks recipe (C2 spec section 3, step 2).

Usage: screen-community.py <input.json> [--out FILE] [--recipes F] [--components F] [--variants F]

Input is either the website export (bitworks.community-export/v0, {"byVariant": {key: [records]}})
or a plain list / {"records": [...]} of records carrying the bitworks.amd-community/v1 blocks
(exactModel, engine, settings, hostSummary) and a derived submissionComplete.

Output is a JSON list with one entry per record: id, variant, gpuCount, compellingOnPaper
(compelling, genGainPct, promptGainPct, baseline), candidate, reasons[], and for candidates
the components to pin. Prints "candidates=N records=M". Exit 0 ok, 1 unreadable or invalid input,
2 usage error.

Compelling (spec 1.1): >=15% generation OR >=50% prompt tok/s over the best bitworks entry for the
same variant and gpuCount, at the same or a larger context. With no bitworks entry, the fastest
screened record for that variant and count is compelling. Quality checks are not visible on paper;
they are enforced at reproduction.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GEN_PCT, PROMPT_PCT = 15.0, 50.0
# Fallback when config/gpu-variants.json has no matching key.
VARIANT_MAP = {"rx-7900-xt-20gb": "rx-7900-xt", "rx-7900-xtx-24gb": "rx-7900-xtx"}
AGGREGATE_RE = re.compile(r"aggregate|concurren|parallel|batch|throughput|total|multi|copies|\bc\d+\b|^c\d+$", re.I)
SHA_RE = re.compile(r"^[0-9a-fA-F]{64}$")
BUILD_RE = re.compile(r"^b\d+$")


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def variant_key(raw, gpu_variants):
    keys = {v["key"] for v in gpu_variants.get("variants", [])}
    if raw in keys:
        return raw
    if raw in VARIANT_MAP:
        return VARIANT_MAP[raw]
    stripped = re.sub(r"-\d+gb$", "", raw or "")
    return stripped if stripped in keys else raw


def best_by_variant(recipes):
    best = {}
    for e in recipes.get("entries", []):
        exp = e.get("expected") or {}
        if not isinstance(exp.get("generationTokS"), (int, float)):
            continue
        k = (e["variant"], int(e.get("gpuCount", 1)))
        if k not in best or exp["generationTokS"] > best[k]["generationTokS"]:
            best[k] = {"id": e.get("id"), "generationTokS": exp["generationTokS"],
                       "promptTokS": exp.get("promptTokS"), "contextTokens": exp.get("contextTokens")}
    return best


def flatten(doc):
    """Yield (variant_hint, record) for either input form."""
    if isinstance(doc, dict) and isinstance(doc.get("byVariant"), dict):
        for var, recs in doc["byVariant"].items():
            for r in recs:
                yield var, r
    else:
        recs = doc.get("records") if isinstance(doc, dict) else doc
        if not isinstance(recs, list):
            raise ValueError("input is neither a byVariant export nor a list of records")
        for r in recs:
            yield r.get("variant") or r.get("variantKey"), r


def _num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0 else None


def metrics(rec, key_list, scalar):
    """Return (single_stream_max or None, saw_aggregate)."""
    vals, agg = [], False
    for item in rec.get(key_list) or []:
        if isinstance(item, dict):
            v = _num(item.get("value", item.get("tps")))
            marks = " ".join(str(item.get(k, "")) for k in ("scope", "bench", "kind", "mode", "label"))
            if v is None:
                continue
            if AGGREGATE_RE.search(marks) or item.get("aggregate") is True:
                agg = True
            else:
                vals.append(v)
        elif _num(item) is not None:
            vals.append(item)
    if not vals and _num(rec.get(scalar)) is not None:
        vals.append(rec[scalar])
    return (max(vals) if vals else None), agg


def normalize(rec):
    """Common view over the display fields and the v1 blocks."""
    model, engine = rec.get("model") or {}, rec.get("engine") or {}
    em, ev, st = rec.get("exactModel") or {}, rec.get("engine") or {}, rec.get("settings") or {}
    serving = rec.get("serving") or {}
    sha = em.get("sha256") or model.get("sha256")
    prov, fname = em.get("provider") or model.get("provider"), em.get("fileName") or model.get("fileName")
    url = em.get("downloadUrl") or model.get("fileUrl") or model.get("downloadUrl")
    build = engine.get("version") or engine.get("build")
    topo = st.get("topology") or serving.get("topology")
    draft = st.get("draftModel") or rec.get("draftModel")
    spec = serving.get("speculative")
    return {
        "sha256": sha if isinstance(sha, str) and SHA_RE.match(sha) else None,
        "provider": prov, "fileName": fname, "url": url,
        "engineName": (engine.get("name") or "").strip(),
        "engineBuild": (str(build).strip() if build else ""),
        "backend": (engine.get("backend") or "").strip().lower(),
        "gpuCount": int(st.get("gpuCount") or rec.get("gpuCount") or 1),
        "topology": (str(topo).lower() if topo else None),
        "draft": bool(draft) or (bool(spec) and str(spec).lower() not in ("none", "off", "false", "0")),
        "contextSize": _num(st.get("contextSize") if "contextSize" in st else rec.get("contextSize")),
        "hasV1": any(k in rec for k in ("exactModel", "settings")),
        "engineFull": all(ev.get(k) for k in ("name", "version", "backend")),
    }


def submission_complete(rec, n):
    if n["hasV1"]:
        model_ok = bool(n["sha256"] or (n["provider"] and n["fileName"]) or n["url"])
        ctx = n["contextSize"]
        ctx_ok = isinstance(ctx, int) and ctx > 0
        return model_ok and n["engineFull"] and ctx_ok
    return bool(rec.get("submissionComplete"))


def screen(doc, recipes, components, gpu_variants):
    best = best_by_variant(recipes)
    engines = [c for c in components.get("components", []) if c.get("kind") == "engine"]
    rows = []
    for hint, rec in flatten(doc):
        n = normalize(rec)
        var = variant_key(hint, gpu_variants)
        gen, gagg = metrics(rec, "generationTps", "generationTokS")
        prm, pagg = metrics(rec, "promptTps", "promptTokS")
        rows.append((rec, n, var, gen, prm, gagg or pagg))
    # Fastest single-stream record per (variant, count) when no Bitworks entry exists.
    fastest = {}
    for rec, n, var, gen, prm, agg in rows:
        k = (var, n["gpuCount"])
        if k not in best and gen is not None and (k not in fastest or gen > fastest[k]):
            fastest[k] = gen
    out = []
    for rec, n, var, gen, prm, agg in rows:
        reasons = []
        if n["gpuCount"] > 1 or (n["topology"] not in (None, "", "single")):
            reasons.append("topology-unavailable")
        if gen is None and prm is None:
            reasons.append("aggregate-metric" if agg else "no-metric")
        if not (n["sha256"] or (n["provider"] and n["fileName"]) or n["url"]):
            reasons.append("model-not-pinned")
        name = n["engineName"].lower()
        is_llama = name in ("llama.cpp", "llama-cpp", "llamacpp")
        if not n["engineName"] or not n["engineBuild"] or (is_llama and not BUILD_RE.match(n["engineBuild"])):
            reasons.append("engine-not-pinnable")
        if not submission_complete(rec, n):
            reasons.append("submission-incomplete")
        if n["backend"] in ("hip", "rocm"):
            reasons.append("lane-not-shipped:hip")
        if n["draft"]:
            reasons.append("lane-not-shipped:draft")
        if n["engineName"] and not is_llama:
            reasons.append("lane-not-shipped:other-engine")

        base = best.get((var, n["gpuCount"]))
        comp = {"compelling": False, "genGainPct": None, "promptGainPct": None,
                "baseline": base["id"] if base else None}
        if gen is not None or prm is not None:
            if base:
                if gen is not None and base["generationTokS"]:
                    comp["genGainPct"] = round((gen / base["generationTokS"] - 1) * 100, 1)
                if prm is not None and base.get("promptTokS"):
                    comp["promptGainPct"] = round((prm / base["promptTokS"] - 1) * 100, 1)
                big_enough = (n["contextSize"] is None or not base.get("contextTokens")
                              or n["contextSize"] >= base["contextTokens"])
                comp["compelling"] = big_enough and (
                    (comp["genGainPct"] or 0) >= GEN_PCT or (comp["promptGainPct"] or 0) >= PROMPT_PCT)
            else:
                comp["compelling"] = gen is not None and gen == fastest.get((var, n["gpuCount"]))
            if not comp["compelling"]:
                reasons.append("not-compelling")
        candidate = comp["compelling"] and not reasons
        row = {"id": rec.get("id"), "variant": var, "gpuCount": n["gpuCount"],
               "generationTokS": gen, "promptTokS": prm,
               "compellingOnPaper": comp, "candidate": candidate, "reasons": reasons}
        if candidate:
            match = next((c for c in engines if c.get("version") == n["engineBuild"]
                          and c.get("platform", {}).get("backend") == n["backend"]), None)
            row["pin"] = {
                "engine": {"name": "llama.cpp", "build": n["engineBuild"], "backend": n["backend"],
                           "componentId": match["id"] if match else None,
                           "inComponentsJson": match is not None},
                "model": {k: v for k, v in (("sha256", n["sha256"]), ("provider", n["provider"]),
                                            ("fileName", n["fileName"]), ("downloadUrl", n["url"])) if v},
            }
        out.append(row)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Screen community records for reproduction.")
    ap.add_argument("input")
    ap.add_argument("--out")
    ap.add_argument("--recipes", default=str(ROOT / "data" / "verified-recipes.json"))
    ap.add_argument("--components", default=str(ROOT / "config" / "components.json"))
    ap.add_argument("--variants", default=str(ROOT / "config" / "gpu-variants.json"))
    args = ap.parse_args(argv)
    try:
        result = screen(load(args.input), load(args.recipes), load(args.components), load(args.variants))
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        print(f"screen-community: {e}", file=sys.stderr)
        return 1
    text = json.dumps(result, indent=2) + "\n"
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    print(f"candidates={sum(r['candidate'] for r in result)} records={len(result)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
