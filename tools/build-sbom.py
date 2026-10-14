#!/usr/bin/env python3
"""Deterministic, offline CycloneDX SBOM and third-party notice inventory.

FastLLM itself is declared Apache-2.0 (owner decision 5, 2026-10-14).
Third-party licenses are only the values
declared in config/catalog.json or THIRD_PARTY_NOTICES.md. No network access.
"""

from __future__ import annotations

import argparse
import base64
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import uuid
import sys

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ("public-source", "windows-lab-runtime")
SPDX_IDS = frozenset({"MIT", "Apache-2.0"})
CATALOG_FILE = "config/catalog.json"
NOTICES_FILE = "THIRD_PARTY_NOTICES.md"
LICENSE_DIRS = ("licenses", "LICENSES", "third_party")
INFORMATIONAL = (
    "docs/research/LEMONADE-B1339-FILE-NOTICE-MATRIX.json",
    "docs/research/LEMONADE-B1339-NOTICE-PROVENANCE.json",
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class SbomError(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode(document) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("ascii")


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise SbomError(f"cannot read {path}: {exc}")


def rel(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def validate_catalog(catalog: dict) -> None:
    """Refuse any catalog artifact that lacks a well-formed SHA-256."""
    engine = catalog.get("engine") or {}
    for name, asset in sorted((engine.get("assets") or {}).items()):
        if not HEX64.match(str(asset.get("sha256", ""))):
            raise SbomError(f"engine asset '{name}' lacks a valid sha256")
        if not isinstance(asset.get("sizeBytes"), int):
            raise SbomError(f"engine asset '{name}' lacks sizeBytes")
    for model in catalog.get("models") or []:
        if not HEX64.match(str(model.get("sha256", ""))):
            raise SbomError(f"model '{model.get('id')}' lacks a valid sha256")


def license_entry(declared):
    if declared in SPDX_IDS:
        return [{"license": {"id": declared}}]
    if declared:
        return [{"license": {"name": declared}}]
    return [{"expression": "NOASSERTION"}]


def prop(name, value):
    return {"name": name, "value": str(value)}


def source_manifest(root: Path, public_tree: bool = False):
    spec = importlib.util.spec_from_file_location("fastllm_public_stage", root / "tools/stage-public-source.py")
    stage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stage)
    entries = []
    for relative, path in stage.source_map(root, public_tree).items():
        entries.append((relative, sha256_bytes(path.read_bytes())))
    return entries


def archive_license_files(asset: dict):
    """Names in the catalog's closed archive manifest that look like license texts."""
    return sorted(m["path"] for m in asset.get("manifest") or []
                  if re.search(r"licen[sc]e|notice|copying", m["path"], re.I))


def bundled_license_state(asset: dict) -> str:
    # The catalog only knows the archive contents when it pins a closed manifest.
    if not asset.get("manifest"):
        return "unknown"
    files = [f for f in archive_license_files(asset) if "llvm" not in f.lower()]
    return "true" if files else "false"


def build_sbom(root: Path, catalog_path: Path, profile: str, timestamp=None, public_tree: bool = False,
               nuget_lock: Path | None = None) -> bytes:
    catalog = load_json(catalog_path)
    validate_catalog(catalog)
    engine = catalog["engine"]
    components = []

    entries = source_manifest(root, public_tree)
    digest = sha256_bytes("".join(f"{h}  {p}\n" for p, h in entries).encode("utf-8"))
    components.append({
        "bom-ref": "fastllm-integration-source",
        "type": "application",
        "name": "FastLLM integration source",
        "licenses": [{"license": {"id": "Apache-2.0"}}],
        "hashes": [{"alg": "SHA-256", "content": digest}],
        "properties": [
            prop("bitworks:licenseDecision", "owner-decision-5-2026-10-14"),
            prop("bitworks:sourceFileCount", len(entries)),
            prop("bitworks:sourceManifestSha256", digest),
            prop("bitworks:sourceManifestRule", "sha256 of 'sha256  path' lines for tools/stage-public-source.py source_map"),
        ],
    })

    for key, asset in sorted(engine["assets"].items()):
        enabled = bool(asset.get("enabled"))
        props = [
            prop("bitworks:laneKey", key),
            prop("bitworks:backend", asset.get("backend", "")),
            prop("bitworks:enabled", str(enabled).lower()),
            prop("bitworks:sizeBytes", asset["sizeBytes"]),
            prop("bitworks:licenseDeclarationSource", f"{CATALOG_FILE}#$.engine.license"),
            prop("bitworks:licenseTextBundledInArchive", bundled_license_state(asset)),
        ]
        extra_files = archive_license_files(asset)
        if extra_files:
            props.append(prop("bitworks:archiveLicenseFiles", ",".join(extra_files)))
        if "expandedSizeBytes" in asset:
            props.append(prop("bitworks:expandedSizeBytes", asset["expandedSizeBytes"]))
        comp = {
            "bom-ref": f"engine-{engine['id']}-{key}",
            "type": "file",
            "name": asset["file"],
            "version": engine["version"],
            "group": engine["id"],
            "hashes": [{"alg": "SHA-256", "content": asset["sha256"]}],
            "licenses": license_entry(engine.get("license")),
            "externalReferences": [
                {"type": "distribution", "url": asset["url"]},
                {"type": "vcs", "url": engine["source"]},
            ],
            "properties": props,
        }
        if not enabled:
            comp["scope"] = "excluded"
            props.append(prop("bitworks:disabledReason", asset.get("disabledReason", "")))
        else:
            comp["scope"] = "required"
        components.append(comp)

    for model in catalog["models"]:
        components.append({
            "bom-ref": f"model-{model['id']}",
            "type": "machine-learning-model",
            "name": model["file"],
            "version": model["revision"],
            "scope": "optional",
            "hashes": [{"alg": "SHA-256", "content": model["sha256"]}],
            "licenses": license_entry(model.get("license")),
            "externalReferences": [{"type": "distribution", "url": model["url"]}],
            "properties": [
                prop("bitworks:catalogId", model["id"]),
                prop("bitworks:redistributed", "false"),
                prop("bitworks:repository", model.get("repository", "")),
                prop("bitworks:revision", model["revision"]),
                prop("bitworks:file", model["file"]),
                prop("bitworks:sizeBytes", model.get("sizeBytes", "")),
                prop("bitworks:upstreamModel", model.get("upstreamModel", "")),
                prop("bitworks:upstreamLicense", model.get("upstreamLicense", "")),
                prop("bitworks:artifactLicense", model.get("artifactLicense", "")),
                prop("bitworks:licenseDeclarationSource", f"{CATALOG_FILE}#$.models[{model['id']}].license"),
            ],
        })

    for excluded in catalog.get("excludedModels") or []:
        components.append({
            "bom-ref": f"model-{excluded['id']}",
            "type": "machine-learning-model",
            "name": excluded["id"],
            "scope": "excluded",
            "licenses": [{"expression": "NOASSERTION"}],
            "properties": [
                prop("bitworks:catalogId", excluded["id"]),
                prop("bitworks:redistributed", "false"),
                prop("bitworks:excludedReason", excluded.get("reason", "")),
                prop("bitworks:licenseDeclarationSource", "none in catalog"),
            ],
        })

    if profile == "windows-lab-runtime":
        if nuget_lock is None:
            raise SbomError("the windows-lab-runtime profile needs --nuget-lock")
        lock = load_json(nuget_lock)
        seen = set()
        for framework in sorted(lock.get("dependencies", {})):
            for name, info in sorted(lock["dependencies"][framework].items()):
                if info.get("type") == "Project" or "resolved" not in info:
                    continue
                key = (name, info["resolved"])
                if key in seen:
                    continue
                seen.add(key)
                comp = {
                    "bom-ref": f"nuget-{name}@{info['resolved']}",
                    "type": "library",
                    "name": name,
                    "version": info["resolved"],
                    "purl": f"pkg:nuget/{name}@{info['resolved']}",
                    "scope": "required",
                    "licenses": [{"expression": "NOASSERTION"}],
                    "properties": [
                        prop("bitworks:nuget.contentHash", info.get("contentHash", "")),
                        prop("bitworks:nuget.contentHashAlgorithm", "SHA-512 (base64, as given in lock file)"),
                        prop("bitworks:nuget.dependencyType", info.get("type", "")),
                        prop("bitworks:licenseDeclarationSource", "none in lock file"),
                    ],
                }
                try:
                    hexdigest = base64.b64decode(info["contentHash"], validate=True).hex()
                    if len(hexdigest) == 128:
                        comp["hashes"] = [{"alg": "SHA-512", "content": hexdigest}]
                except (KeyError, ValueError):
                    pass
                components.append(comp)

    components.sort(key=lambda c: c["bom-ref"])
    metadata = {"properties": [
        prop("bitworks:catalogSha256", sha256_bytes(catalog_path.read_bytes())),
        prop("bitworks:catalogStatus", catalog.get("status", "")),
        prop("bitworks:catalogVersion", catalog.get("catalogVersion", "")),
        prop("bitworks:profile", profile),
    ]}
    if timestamp:
        metadata["timestamp"] = timestamp
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": metadata,
        "components": components,
    }
    # Content-derived but RFC 4122-shaped (version 5 layout) so the value
    # satisfies the CycloneDX 1.5 serialNumber pattern.
    uid = sha256_bytes(encode(bom))
    bom["serialNumber"] = uuid.UUID(bytes=bytes.fromhex(uid[:32]), version=5).urn
    return encode(bom)


def license_text_present(root: Path, slug: str) -> bool:
    for directory in LICENSE_DIRS:
        base = root / directory / slug
        if base.is_dir() and any(p.is_file() for p in base.iterdir()):
            return True
    return False


def flash_next_license(root: Path):
    path = root / NOTICES_FILE
    if not path.is_file():
        return None
    match = re.search(r"uses ([A-Za-z0-9 .\-]+?) rather than Apache-2\.0", path.read_text(encoding="utf-8"))
    return match.group(1) if match else None


def build_notices(root: Path, catalog_path: Path, nuget_lock: Path | None = None) -> bytes:
    catalog = load_json(catalog_path)
    validate_catalog(catalog)
    engine = catalog["engine"]
    notices_text = (root / NOTICES_FILE).read_text(encoding="utf-8") if (root / NOTICES_FILE).is_file() else ""
    root_licenses = sorted(p.name for p in root.iterdir()
                           if p.is_file() and re.match(r"(LICENSE|COPYING)", p.name, re.I))
    gaps = []
    components = []

    def gap(gid, severity, message):
        gaps.append({"id": gid, "severity": severity, "message": message})

    project = {
        "name": "FastLLM integration source",
        "licenseDecision": "Apache-2.0",
        "licenseFilePresent": bool(root_licenses),
        "licenseFiles": root_licenses,
    }
    if not root_licenses:
        gap("fastllm-license-file-missing", "release-blocker",
            "No FastLLM LICENSE file; FastLLM is Apache-2.0 and the LICENSE file must ship.")

    present = license_text_present(root, "llama.cpp")
    engine_comp = {
        "id": engine["id"],
        "name": engine["id"],
        "version": engine["version"],
        "kind": "engine",
        "declaredLicense": engine.get("license"),
        "declarationSource": {"file": CATALOG_FILE, "jsonPath": "$.engine.license"},
        "licenseTextPresentInRepo": present,
        "upstream": engine["source"],
    }
    if f"License: {engine.get('license')}" not in notices_text:
        engine_comp["declarationDiscrepancy"] = f"{NOTICES_FILE} does not state the same engine license as the catalog"
    if not present:
        engine_comp["gap"] = "engine license text not present in repo"
        gap("engine-license-text-missing", "release-blocker",
            f"No {engine['id']} {engine.get('license')} license/notice text is bundled in the repo.")
    components.append(engine_comp)

    for key, asset in sorted(engine["assets"].items()):
        state = bundled_license_state(asset)
        if state != "true":
            gap(f"engine-archive-license-{key}", "release-blocker" if asset.get("enabled") else "info",
                f"Engine archive {asset['file']} ({'enabled' if asset.get('enabled') else 'disabled'}) "
                f"bundled license text status: {state}.")
        for name in archive_license_files(asset):
            components.append({
                "id": f"archive-{key}-{name}",
                "name": name,
                "kind": "archive-license-file",
                "declaredLicense": None,
                "declarationSource": {"file": CATALOG_FILE, "jsonPath": f"$.engine.assets.{key}.manifest[path={name}]"},
                "licenseTextPresentInRepo": False,
                "gap": "license file ships inside the archive only; component and license not identified by the catalog",
            })

    families = {}
    for model in catalog["models"]:
        families.setdefault((model.get("upstreamModel"), model.get("repository")), []).append(model)
    for (upstream, repository), group in sorted(families.items(), key=lambda kv: str(kv[0])):
        model = group[0]
        comp = {
            "id": f"model:{repository}",
            "name": repository,
            "kind": "model-reference-not-redistributed",
            "upstreamModel": upstream,
            "catalogIds": sorted(m["id"] for m in group),
            "declaredLicense": model.get("license"),
            "declarationSource": {"file": CATALOG_FILE, "jsonPath": f"$.models[id={model['id']}].license"},
            "upstreamLicenseUrl": model.get("upstreamLicenseUrl"),
            "upstreamLicenseSha256": model.get("upstreamLicenseSha256"),
            "licenseTextPresentInRepo": license_text_present(root, repository.split("/")[-1]),
        }
        if not model.get("license"):
            comp["gap"] = "catalog declares no license for this model"
        elif not comp["licenseTextPresentInRepo"]:
            comp["gap"] = "license text referenced by URL and sha256 in the catalog but not bundled in repo"
        components.append(comp)
    if any("gap" in c for c in components if c["kind"] == "model-reference-not-redistributed"):
        gap("model-license-text-not-bundled", "info",
            "Models are not redistributed; license text is only referenced by URL and sha256.")

    for excluded in catalog.get("excludedModels") or []:
        declared = flash_next_license(root) if "flash-next" in excluded["id"] else None
        components.append({
            "id": f"excluded-model:{excluded['id']}",
            "name": excluded["id"],
            "kind": "excluded-model",
            "declaredLicense": declared,
            "declarationSource": {"file": NOTICES_FILE if declared else CATALOG_FILE,
                                  "jsonPath": "section 'Qwen3.8-Flash-Next'" if declared else f"$.excludedModels[id={excluded['id']}]"},
            "licenseTextPresentInRepo": False,
            "gap": "excluded entry has no license field in the catalog" + (
                "; license taken from prose in THIRD_PARTY_NOTICES.md" if declared else ""),
        })

    if nuget_lock is not None and nuget_lock.is_file():
        lock = load_json(nuget_lock)
        lock_display = rel(nuget_lock, root)
        seen = set()
        for framework in sorted(lock.get("dependencies", {})):
            for name, info in sorted(lock["dependencies"][framework].items()):
                if info.get("type") == "Project" or "resolved" not in info or (name, info["resolved"]) in seen:
                    continue
                seen.add((name, info["resolved"]))
                components.append({
                    "id": f"nuget:{name}",
                    "name": name,
                    "version": info["resolved"],
                    "kind": "nuget-package",
                    "declaredLicense": None,
                    "declarationSource": {"file": lock_display, "jsonPath": f"$.dependencies.{framework}.{name}"},
                    "licenseTextPresentInRepo": False,
                    "gap": "lock file declares no license; consult the package nuspec before redistribution",
                })
        if seen:
            gap("nuget-licenses-undeclared", "release-blocker",
                "NuGet packages in the lab NuGet lock file have no recorded license.")

    informational = []
    for relative in INFORMATIONAL:
        path = root / relative
        if path.is_file():
            informational.append({"path": relative, "sha256": sha256_bytes(path.read_bytes()),
                                  "note": "private HIP experiment evidence; not part of any release inventory"})

    components.sort(key=lambda c: c["id"])
    gaps.sort(key=lambda g: g["id"])
    document = {
        "schema": "bitworks.third-party-notice-inventory/1",
        "catalogVersion": catalog.get("catalogVersion"),
        "catalogSha256": sha256_bytes(catalog_path.read_bytes()),
        "project": project,
        "components": components,
        "gaps": gaps,
        "informational": informational,
    }
    return encode(document)


def main(argv=None) -> int:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", required=True, type=Path)
    common.add_argument("--check", action="store_true",
                        help="recompute and compare with --out; exit 1 on drift")
    common.add_argument("--catalog", type=Path, default=None)
    common.add_argument("--root", type=Path, default=ROOT)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("sbom", parents=[common])
    s.add_argument("--profile", required=True, choices=PROFILES)
    s.add_argument("--timestamp", default=None)
    s.add_argument("--public-tree", action="store_true",
                   help="the root is a public checkout without ops/ (same meaning as tools/stage-public-source.py --public-tree)")
    s.add_argument("--nuget-lock", type=Path, default=None)
    n = sub.add_parser("notices", parents=[common])
    n.add_argument("--nuget-lock", type=Path, default=None)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    catalog = args.catalog or root / CATALOG_FILE
    lock = args.nuget_lock if args.nuget_lock is None or args.nuget_lock.is_absolute() else root / args.nuget_lock
    try:
        if args.command == "sbom":
            payload = build_sbom(root, catalog, args.profile, args.timestamp, public_tree=args.public_tree,
                                 nuget_lock=lock)
        else:
            payload = build_notices(root, catalog, lock)
    except (SbomError, OSError, ValueError, KeyError) as exc:
        print(f"build-sbom: refusing: {exc}", file=sys.stderr)
        return 2
    if args.check:
        if not args.out.is_file():
            print(f"build-sbom: DRIFT: {args.out} does not exist", file=sys.stderr)
            return 1
        existing = args.out.read_bytes()
        if existing != payload:
            diff = difflib.unified_diff(existing.decode("utf-8", "replace").splitlines(),
                                        payload.decode().splitlines(), "existing", "recomputed", lineterm="", n=1)
            print("build-sbom: DRIFT: " + "\n".join(list(diff)[:40]), file=sys.stderr)
            return 1
        print(f"build-sbom: OK {args.out} sha256={sha256_bytes(existing)}")
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(payload)
    print(f"build-sbom: wrote {args.out} sha256={sha256_bytes(payload)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
