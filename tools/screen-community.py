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

Compelling (spec 1.1): >=15% generation over the best bitworks generation OR >=50% prompt tok/s over the best bitworks prompt rate for the
same variant and gpuCount, at the same or a larger context. Each metric is compared with the best
bitworks value for that metric (baselineGeneration, baselinePrompt; baseline is the generation baseline). With no bitworks entry, the fastest
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
AGGREGATE_RE = re.compile(r"aggregate|concurren|parallel|copies|(^|[^a-z0-9])c\d+($|[^a-z0-9])", re.I)
SHA_RE = re.compile(r"^[0-9a-fA-F]{64}$")
BUILD_RE = re.compile(r"^b\d+$")
BUILD_FIND = (re.compile(r"(?<![a-z0-9.])b(\d{4,6})(?![0-9])", re.I), re.compile(r"\bbuild\s+(\d{4,6})\b", re.I))
MULTI_CARD_RE = re.compile(r"\b(two|dual|2)\b|2\s*[x\u00d7]", re.I)


def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def D(x):
    """dict or {}."""
    return x if isinstance(x, dict) else {}


def S(x):
    """str or ''."""
    if isinstance(x, str):
        return x.strip()
    return str(x) if isinstance(x, (int, float)) and not isinstance(x, bool) else ""


def variant_key(raw, gpu_variants):
    raw = S(raw)
    keys = {v["key"] for v in D(gpu_variants).get("variants", []) if isinstance(v, dict) and "key" in v}
    if raw in keys:
        return raw
    if raw in VARIANT_MAP:
        return VARIANT_MAP[raw]
    stripped = re.sub(r"-\d+gb$", "", raw)
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


def entries_by_variant(recipes):
    """Every Bitworks entry with a generation rate, per (variant, gpuCount)."""
    entries = {}
    for e in recipes.get("entries", []):
        exp = e.get("expected") or {}
        if not isinstance(exp.get("generationTokS"), (int, float)):
            continue
        entries.setdefault((e["variant"], int(e.get("gpuCount", 1))), []).append(
            {"id": e.get("id"), "generationTokS": exp["generationTokS"], "promptTokS": exp.get("promptTokS"),
             "contextTokens": exp.get("contextTokens")})
    return entries


def best_of(entries, metric):
    rated = [e for e in entries if isinstance(e.get(metric), (int, float))]
    return max(rated, key=lambda e: (e[metric], str(e["id"]))) if rated else None


def flatten(doc):
    """Yield (variant_hint, record) for either input form. Records may be any JSON value."""
    if isinstance(doc, dict) and isinstance(doc.get("byVariant"), dict):
        for var, group in doc["byVariant"].items():
            recs = group.get("records") if isinstance(group, dict) else group
            for r in (recs if isinstance(recs, list) else []):
                yield var, r
    else:
        recs = doc.get("records") if isinstance(doc, dict) else doc
        if not isinstance(recs, list):
            raise ValueError("input is neither a byVariant export nor a list of records")
        for r in recs:
            yield (S(D(r).get("variant") or D(r).get("variantKey")) or None), r


def _num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0 else None


def _int(x):
    try:
        return int(x) if not isinstance(x, bool) and x is not None and str(x).strip() != "" else None
    except (TypeError, ValueError):
        return None


def metrics(rec, key_list, scalar, default_clients):
    """Return (single_stream_max or None, saw_aggregate)."""
    vals, agg = [], False
    items = rec.get(key_list)
    for item in (items if isinstance(items, list) else []):
        if isinstance(item, dict):
            v = _num(item.get("value", item.get("tps")))
            if v is None:
                continue
            marks = " ".join(S(item.get(k)) for k in ("scope", "bench", "kind", "mode", "label"))
            clients = _int(item.get("clients", default_clients))
            if AGGREGATE_RE.search(marks) or item.get("aggregate") is True or (clients or 1) > 1:
                agg = True
            else:
                vals.append(v)
        elif _num(item) is not None:
            vals.append(item)
    if not vals and not agg and _num(rec.get(scalar)) is not None:
        vals.append(rec[scalar])
    return (max(vals) if vals else None), agg


def parse_build(text):
    text = S(text)
    if BUILD_RE.match(text):
        return text
    for rx in BUILD_FIND:
        m = rx.search(text)
        if m:
            return "b" + m.group(1)
    return ""


def normalize(rec):
    """Common view over the display fields and the v1 blocks; tolerant of strings and nulls."""
    model = rec.get("model") if isinstance(rec.get("model"), dict) else {"name": S(rec.get("model"))}
    engine = rec.get("engine") if isinstance(rec.get("engine"), dict) else {"name": S(rec.get("engine"))}
    em, st, serving = D(rec.get("exactModel")), D(rec.get("settings")), D(rec.get("serving"))
    items = [i for k in ("generationTps", "promptTps") if isinstance(rec.get(k), list)
             for i in rec[k] if isinstance(i, dict)]
    sha = S(em.get("sha256") or model.get("sha256"))
    prov, fname = S(em.get("provider") or model.get("provider")), S(em.get("fileName") or model.get("fileName"))
    url = S(em.get("downloadUrl") or model.get("fileUrl") or model.get("downloadUrl"))
    ename = S(engine.get("name"))
    eraw = S(engine.get("version") or engine.get("build"))
    btext = (S(engine.get("backend")) + " " + ename).lower()
    if re.search(r"hip|rocm", btext):
        backend = "hip"
    elif "vulkan" in btext:
        backend = "vulkan"
    else:
        backend = S(engine.get("backend")).lower()
    topos = [S(st.get("topology") or serving.get("topology")).lower()] + [S(i.get("topology")).lower() for i in items]
    topo_bad = any(t not in ("", "single") for t in topos)
    count = _int(st.get("gpuCount") if st.get("gpuCount") is not None else rec.get("gpuCount"))
    if count is None and not S(st.get("topology") or serving.get("topology")):
        # unreported count: a card/topology note that mentions two cards is not single-card
        note = S(rec.get("card")) + " " + S(serving.get("topologyDetail"))
        count = 2 if MULTI_CARD_RE.search(note) else 1
    spec = S(serving.get("speculative")).lower()
    draft = bool(st.get("draftModel") or rec.get("draftModel")) \
        or spec not in ("", "none", "off", "false", "0") \
        or any(S(i.get("speculative")).lower() not in ("", "none", "off", "false", "0") for i in items)
    ctx = _num(st.get("contextSize")) or _num(D(rec.get("context")).get("configuredTokens")) \
        or _num(rec.get("contextSize"))
    return {
        "sha256": sha if SHA_RE.match(sha) else None,
        "provider": prov, "fileName": fname, "url": url,
        "engineName": ename, "engineRaw": eraw, "engineBuild": parse_build(eraw),
        "isLlama": bool(re.search(r"llama\.cpp|llama-cpp|llamacpp", ename, re.I))
                   and not re.search(r"fork|custom|via|patched", ename, re.I),
        "backend": backend,
        "gpuCount": count or 1, "topoBad": topo_bad,
        "draft": draft, "contextSize": ctx,
        "clients": _int(serving.get("clients")),
        "hasV1": any(isinstance(rec.get(k), dict) for k in ("exactModel", "settings")),
        "engineFull": all(S(D(rec.get("engine")).get(k)) for k in ("name", "version", "backend")),
    }


def submission_complete(rec, n):
    if n["hasV1"]:
        model_ok = bool(n["sha256"] or (n["provider"] and n["fileName"]) or n["url"])
        ctx = _int(D(rec.get("settings")).get("contextSize"))
        return model_ok and n["engineFull"] and ctx is not None and ctx > 0
    return rec.get("submissionComplete") is True


def screen(doc, recipes, components, gpu_variants):
    best = best_by_variant(recipes)
    peers_by_variant = entries_by_variant(recipes)
    engines = [c for c in components.get("components", []) if c.get("kind") == "engine"]
    rows, bad = [], []
    for hint, rec in flatten(doc):
        try:
            if not isinstance(rec, dict):
                raise TypeError("record is not an object")
            n = normalize(rec)
            var = variant_key(hint, gpu_variants)
            gen, gagg = metrics(rec, "generationTps", "generationTokS", n["clients"])
            prm, pagg = metrics(rec, "promptTps", "promptTokS", n["clients"])
            rows.append((rec, n, var, gen, prm, gagg or pagg))
        except Exception:  # unusable shape: report, never crash
            bad.append({"id": S(D(rec).get("id")) or None, "variant": variant_key(hint, gpu_variants) or None,
                        "gpuCount": None, "generationTokS": None, "promptTokS": None,
                        "compellingOnPaper": {"compelling": False, "genGainPct": None, "promptGainPct": None,
                                              "baseline": None, "baselineGeneration": None, "baselinePrompt": None},
                        "candidate": False, "reasons": ["unparseable-record"]})
    # Fastest single-stream record per (variant, count) when no Bitworks entry exists.
    fastest = {}
    for rec, n, var, gen, prm, agg in rows:
        k = (var, n["gpuCount"])
        if k not in best and gen is not None and (k not in fastest or gen > fastest[k]):
            fastest[k] = gen
    out = []
    for rec, n, var, gen, prm, agg in rows:
        reasons = []
        if n["gpuCount"] > 1 or n["topoBad"]:
            reasons.append("topology-unavailable")
        if gen is None and prm is None:
            reasons.append("aggregate-metric" if agg else "no-metric")
        if not (n["sha256"] or (n["provider"] and n["fileName"]) or n["url"]):
            reasons.append("model-not-pinned")
        is_llama = n["isLlama"]
        if not n["engineName"] or not n["engineRaw"] or (is_llama and not n["engineBuild"]) \
                or (not is_llama and re.search(r"unreport|unknown", n["engineRaw"], re.I)):
            reasons.append("engine-not-pinnable")
        if not submission_complete(rec, n):
            reasons.append("submission-incomplete")
        if n["backend"] == "hip":
            reasons.append("lane-not-shipped:hip")
        if n["draft"]:
            reasons.append("lane-not-shipped:draft")
        if n["engineName"] and not is_llama:
            reasons.append("lane-not-shipped:other-engine")

        peers = peers_by_variant.get((var, n["gpuCount"]), [])
        # Each metric is compared with the best Bitworks value for that metric, among entries at the same or a smaller context.
        eligible = [p for p in peers if n["contextSize"] is None or not p.get("contextTokens") or n["contextSize"] >= p["contextTokens"]]
        pool = eligible or peers
        base_gen, base_prompt = best_of(pool, "generationTokS"), best_of(pool, "promptTokS")
        comp = {"compelling": False, "genGainPct": None, "promptGainPct": None,
                "baseline": base_gen["id"] if base_gen else None,
                "baselineGeneration": base_gen["id"] if base_gen else None,
                "baselinePrompt": base_prompt["id"] if base_prompt else None}
        if gen is not None or prm is not None:
            if peers:
                if gen is not None and base_gen and base_gen["generationTokS"]:
                    comp["genGainPct"] = round((gen / base_gen["generationTokS"] - 1) * 100, 1)
                if prm is not None and base_prompt and base_prompt.get("promptTokS"):
                    comp["promptGainPct"] = round((prm / base_prompt["promptTokS"] - 1) * 100, 1)
                comp["compelling"] = bool(eligible) and (
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
                          and D(c.get("platform")).get("backend") == n["backend"]), None)
            row["pin"] = {
                "engine": {"name": "llama.cpp", "build": n["engineBuild"], "backend": n["backend"],
                           "componentId": match["id"] if match else None,
                           "inComponentsJson": match is not None},
                "model": {k: v for k, v in (("sha256", n["sha256"]), ("provider", n["provider"]),
                                            ("fileName", n["fileName"]), ("downloadUrl", n["url"])) if v},
            }
        out.append(row)
    return out + bad


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
    except (OSError, ValueError) as e:
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
