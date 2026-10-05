# Security policy

FastLLM is pre-release software and is not yet suitable for untrusted network exposure.

## Safe defaults

- The server binds to `127.0.0.1` only.
- Browser CORS is explicitly restricted to llama.cpp's special `localhost` origin policy and credentials are disabled; the alpha still has no API key and is not an isolation boundary against other processes in the same user session.
- Vulkan is the only enabled engine lane, but it requires a working AMD Vulkan driver and Microsoft VC++ 2015–2022 x64 runtime. Before native execution, the alpha checks for the three imported VC14 DLL filenames and `vulkan-1.dll` in System32 and requires a 64-bit process; the isolated probe must then return an adapter whose reported name passes the alpha AMD/discrete heuristic. File presence and name matching do not attest prerequisite versions, signatures, architectures, loader vendor, or PCI vendor identity, and the alpha does not install those prerequisites. The cataloged ROCm b10698 archive is not downloaded or run because its imported `hipblas.dll` is absent.
- The resolver refuses to deliberately select CPU and requests all GPU layers. Readiness requires the engine's full layer-count and selected GPU-buffer report. That report is not proof of every operation's placement, dedicated-memory residency, or absence of WDDM paging/spill.
- Engine and model artifacts use immutable URLs, expected lengths, a live download-size ceiling, and SHA-256 verification. Interrupted downloader children are terminated before the destination lock is released. The exact extracted Vulkan manifest detects undeclared files even when hidden, rejects reparse points, and is reverified before probe and start; the complete model hash is reverified on every start.
- First acquisition of an exact model artifact requires interactive approval or an explicit `-AcceptModelLicense`. Approval writes a receipt bound to the exact upstream license revision and artifact digest. That matching receipt can authorize unattended reuse or repair of the same artifact; it never transfers to a changed revision or digest, and start rejects a missing or mismatched receipt.
- Heterogeneous and tensor-parallel GPU modes are not automatically enabled.
- Install, live planning/detection, doctor, and start reject administrator execution and use a per-user data root. Only an offline `plan -HardwareFile ...` may run elevated, and fixture injection cannot reach an executing action.
- No automatic telemetry upload is enabled. Explicit lab diagnostic/benchmark tools can write private local reports; review and sanitize them before sharing. No prompt logging is enabled by this project.
- Native probe/server children receive empty per-run `%APPDATA%`/`%PROGRAMDATA%` roots, a restricted executable search path, and no inherited `LLAMA_*`, `GGML_*`, `VK_*`, `HIP_*`, `ROCM_*`, `HSA_*`, `ROCBLAS_*`, `SMITHY_*`, `AIP_*`, `HF_TOKEN`, or `MTMD_BACKEND_DEVICE` overrides. The API-only server also passes `--offline`, `--no-mmproj`, `--spec-type none`, `--no-agent`, and `--no-ui`.
- One install/start operation owns each InstallRoot's exclusive file lock. Status is advisory local state, not trusted authorization. Stop requests name a run; the owning supervisor terminates its own process instead of trusting a stored PID. Recovery history never grants model consent, skips hashing, or authorizes a download. An explicit model selection cannot be replaced by recovery.
- The server/control-window process wrapper uses a kill-on-close Windows Job Object and captures bounded startup output in memory. After readiness, it discards engine output rather than writing request logs. Benchmark/soak exports contain measurements and diagnostics, not generated text. Same-user process access and crash dumps are outside that privacy boundary. Native Windows containment still requires validation.
- The readiness HTTP client accepts literal IPv4 loopback only, ignores proxies, refuses redirects, bounds responses, and enforces whole-request deadlines. An occupied-port preflight reduces accidental checks against another service, but a bind race remains. There is no authenticated private listener/gateway: clients must wait for Ready, and local processes are not isolated from one another.
- The lab ZIP/launcher is unsigned. It does not bypass PowerShell policy, disable security products, install machine prerequisites, or configure remote access. The allowlisted source manifest and archive checksum are integrity aids, not publisher authentication.

Do not change the host to `0.0.0.0` without adding authentication, restrictive CORS, firewall consent, and TLS or a trusted reverse proxy.

## Reporting

Do not open a public issue for a vulnerability that could expose local files, execute code, bypass artifact verification, or expose the inference API. Until Bitworks publishes a dedicated security address/process, contact the repository owner privately. A public GA release is blocked on publishing a complete coordinated-disclosure contact and response policy.

## Supply-chain expectations

Release builds must include signed targets, checksums, SBOM, provenance, and third-party notices. The alpha's hash checks do not provide publisher authentication and are not a substitute for signing. A future updater must accept only narrow, signed release targets and must not provide a privileged arbitrary-command path.
