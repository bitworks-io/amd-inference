# Bitworks AMD inference integration

**Supervised lab alpha — not a consumer installer release or a performance recommendation.**

FastLLM is Bitworks' name for an integration and configuration package. It brings together existing inference engines, model artifacts and AMD hardware checks to reduce the work involved in deploying local inference. **It is not a new inference engine.** The initial Windows path uses pinned llama.cpp Vulkan binaries; model provenance and upstream licenses remain visible.

The intended user experience is simple: inspect the installed hardware at each start, choose a suitable reviewed model/configuration, obtain verified components with explicit consent, and serve a local OpenAI-compatible API. The implementation does not yet deliver a qualified one-click consumer deployment. Source availability is not a claim of hardware compatibility, memory fit, answer quality or speed.

- Learn about the project and candidate card recipes at [Bitworks AMD inference](https://bitworks.io/amd-inference/).
- Read the [benchmark methodology](https://github.com/bitworks-io/amd-inference/blob/main/docs/BENCHMARK-METHODOLOGY.md) and [supervised lab guide](https://github.com/bitworks-io/amd-inference/blob/main/docs/PUBLIC-LAB-GUIDE.md).
- Review [security boundaries](https://github.com/bitworks-io/amd-inference/blob/main/SECURITY.md) and [third-party provenance and pending source-license decision](https://github.com/bitworks-io/amd-inference/blob/main/THIRD_PARTY_NOTICES.md) before use.

## What is in this source snapshot

- Windows per-user control window and CLI for acquisition, live planning, start/stop/status and diagnostics.
- A versioned, integrity-pinned engine/model catalog and exact-artifact model consent receipts.
- Fresh serving-engine device probes, free-memory-based candidate selection and startup/API checks.
- Loopback-only serving, bounded downloads and process supervision. Reported GPU layers/buffers are checked, but full physical residency and every operation's placement remain unverified.
- Linux assessment and explicit supervised experimental paths; Windows evidence is not Linux qualification.
- Benchmark, reliability, narrow semantic-check and diagnostic tools, plus source and mock-process tests.

The current normal Windows service has **one server slot**. The private concurrent-client collector measures contention and queue pressure at 1/2/4/8 clients; this does not establish multi-slot parallel decoding. A separate eight-task screen checks correctly completed work at C1/C2/C4, with strict answer grading and explicit failure counts; it is not a general intelligence benchmark. Dual-card model splitting is distinct from independent per-card workers. Multi-slot orchestration, independent-worker routing and broader task-quality evaluation remain development/qualification work.

Only the normal pinned Vulkan lane is enabled. Experimental HIP/offload tools are explicitly separate and do not enable or qualify an automatic production backend. The integration does not bundle model weights, engine binaries, AMD drivers or Microsoft installers in this repository.

## Benchmark suite

| Source | Purpose |
|---|---|
| [Methodology](https://github.com/bitworks-io/amd-inference/blob/main/docs/BENCHMARK-METHODOLOGY.md) | Workloads, useful context, concurrency, metrics, correctness and disclosure requirements |
| [Catalog-wide matrix](https://github.com/bitworks-io/amd-inference/blob/main/tools/benchmark-matrix.py) | Offline planning for every catalog artifact; explicit untested/outside-policy cells, no model execution |
| [Single-request API benchmark](https://github.com/bitworks-io/amd-inference/blob/main/tools/benchmark.ps1) | Fixed token workloads against a supervised Ready service |
| [Concurrent-client benchmark](https://github.com/bitworks-io/amd-inference/blob/main/tools/concurrency-benchmark.ps1) | Private request-pressure measurements; not yet native Windows/hardware-qualified |
| [Task-quality screen](https://github.com/bitworks-io/amd-inference/blob/main/tools/task-quality-benchmark.ps1) | Same eight tasks at C1/C2/C4; correctness, completion latency and useful work; mock-tested, not hardware-qualified |
| [Reliability runner](https://github.com/bitworks-io/amd-inference/blob/main/tools/soak.ps1) | Existing single-client soak; not proof of concurrent reliability |
| [Semantic smoke](https://github.com/bitworks-io/amd-inference/blob/main/tools/semantic-smoke.ps1) | Narrow known-answer checks, not an intelligence leaderboard |
| [Strict comparison](https://github.com/bitworks-io/amd-inference/blob/main/tools/compare_benchmarks.py) | Rejects missing/incompatible recorded evidence; no automatic qualification |
| [Tests](https://github.com/bitworks-io/amd-inference/tree/main/tests) | Source, policy and mock-process checks; these are not GPU benchmarks |

Inspect the planned coverage without downloading or executing a model:

```sh
python3 tools/benchmark-matrix.py
```

Run the portable Python tests:

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

PowerShell suites are documented in the lab guide and CI workflow. Do not treat a passing mock test as a physical AMD result. No performance leaderboard, sanitized physical result bundle or approved consumer installer is supplied by this initial source snapshot.

## Current limits

Public qualification still requires measured context/concurrency operating envelopes on each card/platform, authoritative serving-device/driver identity, physical memory/placement evidence, broader semantic checks, concurrent reliability, clean-machine/GUI/prerequisite testing, reviewed dependency redistribution, signing, repair/uninstall and release approval. Catalog memory thresholds are estimates, not measured fit guarantees. A higher concurrency or context setting can reduce responsiveness or exhaust memory.

## Publication and licensing

This repository contains a reviewed source-only subset of the working project. Private bench reports, addresses, access keys, website coordination records, downloads and generated packages are excluded. [The source staging tool](https://github.com/bitworks-io/amd-inference/blob/main/tools/stage-public-source.py) uses an explicit allowlist; the separate lab ZIP builder is for reviewed lab packaging and must not be used to publish an internal checkout wholesale.

Bitworks has not yet selected a license for its integration code. **No open-source license grant or production-release approval should be inferred from this source publication.** Upstream components and models retain their own terms; see the notices. Do not add a license, redistribute dependencies or represent candidate performance as qualified without the corresponding review and approval.
