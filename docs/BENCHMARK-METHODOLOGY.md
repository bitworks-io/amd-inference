# FastLLM benchmark methodology

Protocol proposal v1, 2026-10-05. This is a test and publication specification, not evidence that every case has run. Current public recipe pages remain candidates. The original single-request producer and its reports stay unchanged; new concurrency reports require a separate reviewed publication contract.

## Purpose and scope

Measure useful work from the exact model artifact on the whole system, including responsiveness under concurrent agent requests, long-context behavior, correctness, capacity limits and sustained reliability. A short single-request throughput result is insufficient. Every serving artifact in the versioned catalog, including non-automatic experiments, receives an explicit coverage record for the applicable GPU/platform recipes. Mark untested, blocked, outside-policy and failed cells; never silently omit them or represent an unsupported recipe as a completed test.

The headline sequence prioritizes the catalog's automatic candidates on 7900 XT, 7900 XTX and R9700, followed by their other applicable quantizations and smaller tiers. This ordering does not exempt other catalog models from concurrency testing. Different artifacts, operating systems, backends, offload strategies and acceleration settings are separate configurations.

## Configuration identity

Before a measurement, bind the supervised run/process/listener to exact source, catalog, executable, model and launch-argument digests. Record quantization, context/KV types, attention, speculative decoding, fit behavior, selected devices, slot count and cache policy. Record the requested configuration and the effective server properties separately. An unknown physical adapter or driver binding remains unknown and prevents public promotion under the current result contract.

Include CPU model, active cores/threads, installed and usable RAM, DIMM capacities/configured speeds, motherboard/BIOS, OS patch level, GPU variant/count, driver/runtime, power plan/limits, display use and background-workload controls. Measure negotiated PCIe links/topology under a declared phase where supported. Memory bandwidth, channel operation and topology must not be inferred from nominal specifications. Record collection phase and uncertainty; do not retrofit later hardware observations into an earlier run. Public derivatives remove private identifiers while preserving relevant specifications.

## Three independent concurrency controls

| Control | Meaning | Required disclosure |
|---|---|---|
| Client concurrency C | Outstanding API requests submitted by the load generator | Submission/release timing, actual overlapping request intervals, queueing, completions and failures |
| Server slots S | Inference sequences the configured server can service | Requested and effective slots, per-sequence context and total context allocation |
| Worker count W | Separate serving processes/model copies | Exact per-worker GPU binding, routing, model and shared simultaneous measurement window |

Current normal Windows Ready checks require **S=1, W=1**. C=2/4/8 against it is a queue-pressure test, not evidence of parallel decoding. HTTP request overlap alone does not prove simultaneous GPU execution. Multi-slot continuous batching and dual-card workers require separate implementation and qualification; one model layer-split across two cards is neither two workers nor proof of a throughput gain.

For a future multi-slot experiment, compare two explicitly different policies: fixed per-user context while increasing total allocation, and fixed total allocation while dividing it among slots. Never label a total server allocation as context available to every user. Client concurrency alone does not multiply or divide a one-slot context budget. Effective per-sequence properties must be checked rather than assumed from arithmetic.

## Context and workload ladder

Start with useful **4K, 8K, 16K and 32K per-request windows**, adding the exact catalog ceiling when it is between tiers. Include smaller 1K/2K cases for calibration and mixed workloads. Add 64K/128K only in a separately reviewed experimental configuration when the exact model/backend and memory budget allow it. The current catalog ceiling is a recipe policy, not the model's architectural maximum or a measured fit curve; the current catalog tops out at 32K.

Every case records configured total/per-slot context, actual tokenizer-counted input, output target and actual output, including template/system/tool overhead. Reserve space for the output before constructing the input. A configured 32K server processing a 512-token prompt is not a 32K-context result. Confirm no truncation or context shifting altered the intended workload. If it did, fail that cell rather than calling the requested context tested.

| Workload family | Test intent |
|---|---|
| Historical baseline | Retain the exact 512/4,096 input and 128-output protocol for continuity; do not silently rewrite its producer or old reports. |
| Interactive | Short/medium actual inputs and 256/512 outputs; measure first visible text and completion latency. |
| Sustained output | 512 and, where output/context permits, 1,024 output tokens to reduce reliance on brief decode bursts. |
| Long occupied context | Increase actual input toward the effective per-request window, reserving output and protocol overhead. Check retrieval/answer quality separately from synthetic token speed. |
| Homogeneous contention | C=1,2,4,8 with equal input/output lengths; disclose S and W and retain queue delays. |
| Mixed lengths | A versioned short/long request mix in a declared order/seed; expose head-of-line blocking and per-class latency. |
| Agent fan-out | The same versioned collection of independent tasks run sequentially and concurrently; score task correctness, retries, total work completion and fairness. This needs its own task harness, not merely a throughput request batch. |

No input payload or completion text is exported by the performance collector. Preserve deterministic prompt-token digests and workload-generator provenance. Quality datasets and graders require their own version, license review, sample identifiers and privacy handling. A synthetic/repeated-prose workload is not evidence of realistic task accuracy.

## Execution, pressure and stopping

Run a single-client baseline first. Warm the exact configuration outside the measured window; report warmup count and warm/cold model state. The uncached baseline disables prefix reuse; a shared-prefix agent scenario is a separate named test with hit behavior and reuse policy recorded. Change one setting at a time for causal comparisons and counterbalance order where run-to-run drift is material.

Increase C through 1,2,4,8 at each safe applicable context. Start with five bounded measured waves per cell as a screening pass. Public latency-tail or capacity claims require a predeclared larger run: at least 100 request observations per workload/concurrency cell across at least three fresh serving runs, with errors and run-level variation retained. This minimum is a reporting floor, not a guarantee of precision. Report uncertainty and sample counts; do not present a five-sample p95 as a stable service-level estimate.

Barrier-released waves are a finite burst/closed-loop experiment. They do not measure a sustainable open-loop arrival rate or a production requests-per-second SLA. A later arrival-rate experiment must report scheduling lag, offered load and dropped/deadline requests to avoid hiding overload. Do not blend these workload types.

Predeclare per-request and whole-run deadlines, output/response limits and memory/cancellation guards. On OOM, server exit, identity change, wrong artifact/context, truncated output or failed correctness gate, retain the failure and stop escalation for that configuration. Do not reduce context, quantization, output length or offload policy silently. Retest an explicitly changed configuration under a new identity. Stop rather than attempt a destructive out-of-memory stress of the OS. Unknown memory peaks are not evidence of headroom.

After screening, qualify the proposed operating point with a bounded concurrent soak and post-run responsiveness/cleanup checks. Existing two-hour single-client soaks do not qualify concurrent use. Do not change drivers, clocks or power settings during a timed run. Telemetry collected outside timing cannot establish load-time peaks or throttling; telemetry inside timing needs declared scope, cadence/coverage and overhead assessment.

## Metrics and denominators

- Per request: actual input/output tokens, submit/start/first non-empty streamed text/end timestamps, end-to-end latency, engine-reported prefill/decode timing when valid, deadline/error/finish reason and output completeness. Client first-text latency includes queueing; do not relabel it as a measured server queue time without server evidence.
- Whole wave: elapsed time from release to the last request's terminal state, including failure/deadline time. **Successful complete output tokens / this common elapsed interval** is completed-output throughput; **successful complete requests / the same interval** is completed-request throughput. Disclose incomplete output separately. Never sum independently measured per-request token rates or discard a slow failed request from the denominator.
- Concurrency: client in-flight overlap is measured from request intervals; server execution overlap needs separate engine evidence. Neither is inferred from the requested C value.
- Summaries: median, range and distributions per request class, successful/failed/attempted counts, run-to-run variation and explicit small-sample warnings. Quality-adjusted goodput counts tasks meeting the predeclared correctness and latency criteria, not just responses with HTTP 200.
- Memory and power: dedicated/shared GPU memory, host pressure and energy per completed task where valid, phase-bound and supported. A model buffer log alone is not physical residency or total memory usage.

## Correctness and intelligence

Keep throughput and quality panels separate. The existing three-case semantic smoke is a startup diagnostic, not an intelligence score. A broader evaluation must identify dataset revision/license, exact model/tokenizer/chat template, task/sample split, sample count and denominator, selection seed, grader/version, sampling/thinking settings and permitted tools. Include structured-output/tool-call validity, retrieval at different positions in long inputs and task completion under contention. Repeat the same quality checks when changing quantization, KV cache, speculative decoding, offload or backend. Do not execute model-produced programs on a bench outside a separately reviewed isolation boundary.

A community score or another engine's published result is an external reference, not a Bitworks measurement. Different context, acceleration, data subsets and grading choices prevent an unqualified ranking.

## Reproduction and publication

Existing entry points are `tools/benchmark.ps1` (single request), `tools/soak.ps1` (single-client reliability), `tools/semantic-smoke.ps1` (narrow correctness) and `tools/compare_benchmarks.py` (strict comparisons). `tools/benchmark-matrix.py` now emits a deterministic offline plan for every catalog artifact; it executes nothing. `tools/concurrency-benchmark.ps1` is a new private single-slot request-pressure collector with mock-process coverage, not a physically qualified concurrent Windows/AMD result. It uses a uniform fixed prompt per length, not a mixed subagent task set. Its CLI contains the collector in a child process; a controller abort record takes precedence over any child report, including one written immediately before forced termination. Preserve both files. Mixed-length task orchestration, multi-slot serving and dual-worker measurements remain separate implementation/qualification work. New private report kinds do not automatically pass the website's existing result binder.

The owner-approved public source repository is [bitworks-io/amd-inference](https://github.com/bitworks-io/amd-inference). FastLLM names Bitworks' integration package for existing engines/models, not a new inference engine. The public methodology page links to the runner, workload definitions and tests; each future result must pin their immutable revision and a reviewed report schema/sanitized example. No sanitized physical result bundle is approved yet. Publish raw/sanitized evidence digests, complete settings, failures, context/concurrency coverage and limitations for each reviewed result. Source visibility does not itself qualify performance, grant an unselected source license or release an installer.

## Reference examples, not AMD evidence

[oMLX performance](https://omlx.ai/benchmarks/performance) and [intelligence](https://omlx.ai/benchmarks/intelligence) pages separate speed and quality and expose configuration/sample information. Its [public benchmark source](https://github.com/jundot/omlx/blob/main/scripts/bench.py) includes separate single-request and batching tests. These are useful transparency examples, not numerical baselines for Windows/AMD or code executed by FastLLM. The supplied shared Gemini summary was not accessible and is not a technical authority for this protocol.
