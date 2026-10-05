# Supervised source lab guide

This is a source-review and controlled-test workflow for an unqualified integration alpha. It is not a consumer installation promise. See [the methodology](BENCHMARK-METHODOLOGY.md), [security policy](../SECURITY.md) and [notices](../THIRD_PARTY_NOTICES.md). Do not use production workloads or confidential prompts to qualify this code.

## Windows preparation

Use a supported Windows 11 x64 lab system with a current AMD driver providing Vulkan and Microsoft's Visual C++ x64 runtime. The application's prerequisite checks are limited and do not constitute a complete version/driver compatibility audit. Review the exact source before running it. Use 64-bit Windows PowerShell 5.1 or PowerShell 7 as a **standard user** and respect the machine's execution policy. Do not disable security protections to make a test pass.

The source tree must remain together. `FastLLM.cmd` opens the control window; it is not a service or signed installer. Keep it open while serving. A separate optional per-user source-ZIP setup exists for reviewed lab packages; unsigned hashes/manifests are not publisher authentication. The SSH lab-access scripts under `tools/` are opt-in administrative tooling and are not prerequisites for inference or benchmarking.

## Inspect before acquiring weights

An offline synthetic decision can be inspected without engine/model downloads:

```powershell
./fast-llm.ps1 plan -HardwareFile ./tests/fixtures/rx-7900-xtx-24gb.json -InstallRoot ./tmp-install
./fast-llm.ps1 models
```

Fixtures never authorize native serving. For actual hardware, the supervised install acquires the pinned engine, checks live devices, displays exact model provenance/license and requests consent before model download:

```powershell
./fast-llm.ps1 install
./fast-llm.ps1 start
```

Do not pass automatic license-acceptance options without separately reviewing the exact terms. Downloads can be large; free disk space, host RAM and GPU memory are separate requirements. Every live start refreshes hardware information and rechecks integrity/consent. The intended local API is `http://127.0.0.1:8080/v1`; wait for Ready. No firewall/LAN exposure is needed. In a second console with the same install root, `status` inspects the run and `stop` requests scoped shutdown.

## Optional managed app removal

The separately reviewed external `Install-FastLLM-Lab.cmd` companion includes a locally tested removal/restore precursor for newly ledgered per-user lab installations. Close the managed app and its CLI sessions, use **Preview uninstall**, and review the exact item count and preview digest before confirming. Only intact recorded versions, metadata and the owned shortcut move to recoverable `FastLLM-App-Quarantine`; models, consent receipts and reports stay in place. Keep the displayed path for **Restore**. Preview also identifies verified interrupted removal/restore recovery paths. Quarantine retains data and does not reclaim its disk space.

Do not run this companion from the installed version it would move. Automatic busy detection covers the managed control window and main CLI, not developer/experimental scripts launched directly from the installed source. Run experiments from a separate reviewed checkout and close those tools before removal or restore. Unknown or modified entries and pre-ledger installations are refused for manual review. A guarded new package cannot repair a pre-ledger app in place. The retained app root is not recursively deleted; use Restore rather than assuming a clean reinstall or permanent quarantine disposal is automated. These cooperative source checks are not publisher authentication, malicious same-user protection, native Windows lifecycle qualification or a signed consumer uninstall.

## Fixed-model experiments

Use an exact catalog `-ModelId` and a `-ContextSize` no greater than that artifact's current recipe ceiling when deliberately comparing a model/context configuration. A new artifact needs its own consent and integrity checks. Do not override the model on a card-swap test until the automatic decision has been recorded. Context reduction does not invent a lower VRAM fit threshold.

Only the normal single-slot Vulkan service is the baseline. A split, offload, HIP or future multi-slot/worker experiment must disclose its different configuration and retain its unqualified status. Do not edit catalog thresholds or bypass failed startup checks to obtain an attractive result.

## Benchmark a Ready run

Keep unrelated clients disconnected and use a new private report path in an existing directory. Reports contain measurements and potentially private host/diagnostic metadata; do not publish them unreviewed.

```powershell
./tools/benchmark.ps1 -OutputPath ./baseline-private.json -PromptTokens 512,4096 -GenerationTokens 128 -Repetitions 5
./tools/concurrency-benchmark.ps1 -OutputPath ./concurrency-private.json -PromptTokens 512,4096 -GenerationTokens 128 -Repetitions 5
```

The concurrency tool submits 1/2/4/8-client waves to the current normal one-slot server, using the same fixed numeric prompt for each client at a given length with prefix reuse disabled. It does not reconfigure slots, start a model, demonstrate GPU execution overlap, run multiple models simultaneously or implement an agent task harness. Its CLI contains the request collector in a child process while the parent holds the benchmark lock. Cooperative failures preserve partial reports; forced controller termination records a separate abort file without inventing samples. A controller abort takes precedence even if the child wrote a complete report just before termination: retain both files and do not interpret the child file alone as success. Review this deadline and failure behavior before native use. This new collector has not been qualified on physical Windows/AMD hardware. Longer inputs and queued requests can require substantially longer deadlines; a timeout is evidence to retain, not a sample to discard.

The offline matrix lists planned coverage, including configurations the current launcher/collector cannot execute:

```sh
python3 tools/benchmark-matrix.py
```

Inspect `tools/soak.ps1` and `tools/semantic-smoke.ps1` for their exact parameters. Existing single-client reliability and three-case semantic checks do not satisfy concurrent reliability or broad quality evaluation. Consult the methodology for pressure limits, actual input/output occupancy, quality datasets, repeats and public-result requirements.

## Development checks

```powershell
./tests/run-tests.ps1
./tests/runtime-tests.ps1
./tests/start-tests.ps1
./tests/benchmark-tests.ps1
./tests/benchmark-integration-tests.ps1
./tests/concurrency-benchmark-tests.ps1
```

Native/optional suites may have platform, archive or privilege prerequisites; inspect them before running. Mock services and synthetic fixtures test code behavior, not model accuracy, hardware fit, driver compatibility or speed. The CI workflow records the automated source test set, not a physical GPU qualification matrix.

## Linux

Linux source under `linux/` is a separate assessment/supervised lab path, not a released URL installer. Inspect its help, prerequisite and exact-artifact consent behavior before any acquisition or launch. No Windows benchmark certifies a Linux recipe, and this source snapshot makes no physical AMD/Linux serving claim.

## Public evidence

Keep original reports intact and private. A reviewed public derivative must remove credentials, hostnames, IPs, private paths and unique hardware identifiers while retaining specifications relevant to performance. Include exact source/model/engine/configuration identity, workload and cache settings, failures and missing observations. A source commit or a completed model load alone does not authorize a card-performance claim or installer release.
