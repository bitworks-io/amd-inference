# Security policy

FastLLM is Preview software and is not suitable for untrusted network exposure.

## Safe defaults

- The server binds to `127.0.0.1` only.
- Browser CORS is explicitly restricted to llama.cpp's special `localhost` origin policy and credentials are disabled; FastLLM has no API key and is not an isolation boundary against other processes in the same user session.
- Vulkan is the engine on every card and the fallback. On the RX 7900 XT and XTX, HIP is the default: its two components (the llama.cpp HIP engine from github.com and the AMD ROCm runtime from stable.repo.amd.com) are downloaded from those official sources to the user's PC, only after license consent or the opt-in automatic setting, and are checked against pinned sizes and SHA-256 hashes. Bitworks does not sign or redistribute them. The Vulkan setup requires a working AMD Vulkan driver and Microsoft VC++ 2015–2022 x64 runtime. Before native execution, FastLLM checks for the three imported VC14 DLL filenames and `vulkan-1.dll` in System32 and requires a 64-bit process; the isolated probe must then return an adapter whose reported name passes an AMD/discrete heuristic. File presence and name matching do not attest prerequisite versions, signatures, architectures, loader vendor, or PCI vendor identity. FastLLM never installs the Vulkan driver; it offers the Microsoft VC++ runtime only after showing a review, and installs it only when the user clicks, under Windows' own prompt. The cataloged ROCm b10698 archive is not downloaded or run because its imported `hipblas.dll` is absent.
- The resolver refuses to deliberately select CPU and requests all GPU layers. Readiness requires the engine's full layer-count and selected GPU-buffer report. That report is not proof of every operation's placement, dedicated-memory residency, or absence of WDDM paging/spill.
- Engine and model artifacts use immutable URLs, expected lengths, a live download-size ceiling, and SHA-256 verification. Interrupted downloader children are terminated before the destination lock is released. The exact extracted Vulkan manifest detects undeclared files even when hidden, rejects reparse points, and is reverified before probe and start; the complete model hash is reverified on every start.
- First acquisition of an exact model artifact requires interactive approval or an explicit `-AcceptModelLicense`. Approval writes a receipt bound to the exact upstream license revision and artifact digest. That matching receipt can authorize unattended reuse or repair of the same artifact; it never transfers to a changed revision or digest, and start rejects a missing or mismatched receipt.
- Heterogeneous and tensor-parallel GPU modes are not automatically enabled.
- Install, live planning/detection, doctor, and start reject administrator execution and use a per-user data root. Only an offline `plan -HardwareFile ...` may run elevated, and fixture injection cannot reach an executing action.
- No telemetry is sent. The update check makes one unauthenticated request to the GitHub releases API at most once a day, sends nothing beyond that request, and can be turned off in settings.
- No automatic telemetry upload is enabled. Explicit lab diagnostic/benchmark tools can write private local reports; review and sanitize them before sharing. No prompt logging is enabled by this project.
- Native probe/server children receive empty per-run `%APPDATA%`/`%PROGRAMDATA%` roots, a restricted executable search path, and no inherited `LLAMA_*`, `GGML_*`, `VK_*`, `HIP_*`, `ROCM_*`, `HSA_*`, `ROCBLAS_*`, `SMITHY_*`, `AIP_*`, `HF_TOKEN`, or `MTMD_BACKEND_DEVICE` overrides. The API-only server also passes `--offline`, `--no-mmproj`, `--spec-type none`, `--no-agent`, and `--no-ui`.
- One install/start operation owns each InstallRoot's exclusive file lock. Status is advisory local state, not trusted authorization. Stop requests name a run; the owning supervisor terminates its own process instead of trusting a stored PID. Recovery history never grants model consent, skips hashing, or authorizes a download. An explicit model selection cannot be replaced by recovery.
- The server/control-window process wrapper uses a kill-on-close Windows Job Object and captures bounded startup output in memory. After readiness, it discards engine output rather than writing request logs. Benchmark/soak exports contain measurements and diagnostics, not generated text. Same-user process access and crash dumps are outside that privacy boundary. Native Windows containment still requires validation.
- The readiness HTTP client accepts literal IPv4 loopback only, ignores proxies, refuses redirects, bounds responses, and enforces whole-request deadlines. An occupied-port preflight reduces accidental checks against another service, but a bind race remains. There is no authenticated private listener/gateway: clients must wait for Ready, and local processes are not isolated from one another.
- Releases are Authenticode-signed by Bitworks LLC (see Release signing), and `fast-llm.ps1 doctor` verifies the installed files against the signed catalog. The launcher (`FastLLM.cmd`) adds `-ExecutionPolicy RemoteSigned` for its own PowerShell process only when the effective policy is `Restricted` or `Undefined`; it never weakens `AllSigned` or Group Policy, disables security products, or configures remote access.

Do not change the host to `0.0.0.0` without adding authentication, restrictive CORS, firewall consent, and TLS or a trusted reverse proxy.

## Release signing

Installers are signed with Microsoft's Azure Artifact Signing and carry a timestamp. FastLLM accepts a signature only when all of these hold:

- The signer's organization is Bitworks LLC (`O=Bitworks LLC`).
- The chain ends at the Microsoft Identity Verification Root Certificate Authority 2020, thumbprint `F40042E2E5F7E8EF8189FED15519AECE42C3BFA2`.
- The leaf certificate carries both required EKUs: `1.3.6.1.4.1.311.97.1.0` and `1.3.6.1.4.1.311.97.990689314.800187930.133508941.234438932`.
- A certificate that is outside its validity period (`NotTimeValid` or `NotTimeNested`) is tolerated only when the signature carries a timestamp. A certificate that is still valid needs no timestamp.

The pins live in `src/FastLlm.Trust.ps1`.

## Update security

FastLLM checks for updates once a day, with one unauthenticated request to the GitHub API, and never installs without a click. Before an update runs it passes these six steps, and any failure stops it:

1. The server is stopped and confirmed stopped.
2. `SHA256SUMS` is downloaded (size-capped) and parsed strictly.
3. The installer is downloaded from the release and its SHA-256 and size must match.
4. The installer's signature must pass the pins above.
5. The installer's ProductVersion must equal the release version and be newer than the installed one.
6. The per-user installer runs, then the installed files are checked for integrity.

Download URLs must come from the project's GitHub release assets. `fast-llm.ps1 doctor` reports `installIntegrity` at any time.

## Reporting

Do not open a public issue for a vulnerability that could expose local files, execute code, bypass artifact verification, or expose the inference API. Until Bitworks publishes a dedicated security address/process, contact the repository owner privately. A public GA release is blocked on publishing a complete coordinated-disclosure contact and response policy.

## Supply-chain expectations

Releases include a signed installer, `SHA256SUMS`, an SBOM (`.cdx.json`) and `THIRD_PARTY_NOTICES.md`. Hash checks alone do not authenticate the publisher; the signature pins above do. The updater accepts only the signed installer for a newer release and has no privileged arbitrary-command path.
