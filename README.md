# FastLLM for AMD Radeon (Preview)

> **Preview.** FastLLM is in public preview for Windows PCs with AMD Radeon graphics. Releases are signed by Bitworks LLC.
> Licensed under the Apache License 2.0 (see `LICENSE`).

FastLLM is Bitworks' integration and configuration package for running a local, OpenAI-compatible model server on an AMD Radeon card. It is not a new inference engine: it uses pinned llama.cpp binaries (Vulkan, and HIP on the RX 7900 XT and XTX) and existing model files, and keeps model provenance and upstream licenses visible.

## What it does

FastLLM looks at your card each time it starts, then picks a model and settings that fit. Every choice carries a label that says how much evidence stands behind it:

- **Measured by Bitworks on this card**
- **Community recipe, reproduced by Bitworks**
- **Experimental community recipe, not reproduced by Bitworks**
- **Estimated for your card**
- **Chosen by you**

Measured recipes link to Bitworks results pages. Those pages are lab observations (not fully qualified): see for example the [RX 7900 XT recipe](https://bitworks.io/amd-inference/recipes/rx-7900-xt-20gb-windows-qwen3-8-27b-iq4xs/#lab-observation). Their class is "Bitworks lab observation (not fully qualified)". Four measured setups exist so far (Vulkan and HIP on each of the RX 7900 XT and XTX). Estimates for other cards are estimates, not promises about fit, answer quality or speed.

More about the project and its recipes: [Bitworks AMD inference](https://bitworks.io/amd-inference/).

## Requirements

- Windows 10 or 11, x64.
- An AMD Radeon GPU with a working Vulkan driver.
- Vulkan is the engine on other cards and the fallback on the RX 7900 XT and XTX, where HIP (AMD ROCm) is the default. HIP needs extra components (about 565 MB to download, about 2.33 GB on disk), installed after you accept their licenses; if they are not installed or HIP cannot run, FastLLM starts the Vulkan setup and says so.
- Text-only models.
- A standard user account. No administrator rights are needed.

## Install

1. Open the [Releases page](https://github.com/bitworks-io/amd-inference/releases).
2. Download `FastLLM-Setup-<version>.exe` from the newest release.
3. Run it. The installer is per-user and needs no administrator rights. The publisher is Bitworks LLC.

If Windows SmartScreen shows a warning, choose "More info → Run anyway" after checking the publisher (see the next section).

## Verify a download

Each release publishes `SHA256SUMS`, `fastllm-<version>.zip`, an `.offer.json`, a `.signing-report.json`, the SBOM (`.cdx.json`) and `THIRD_PARTY_NOTICES.md`.

Compare the installer's hash with the `SHA256SUMS` entry:

```powershell
(Get-FileHash .\FastLLM-Setup-<version>.exe -Algorithm SHA256).Hash
```

Check the signature, and confirm the publisher is `O=Bitworks LLC`:

```powershell
Get-AuthenticodeSignature .\FastLLM-Setup-<version>.exe | Format-List Status, SignerCertificate
```

The exact certificate pins are described in [SECURITY.md](SECURITY.md). To check an existing install, run `fast-llm.ps1 doctor`; it reports `installIntegrity`.

## Updates

FastLLM checks for a newer release at most once a day, with a single unauthenticated request to the GitHub API. You can turn this off in settings (`updateCheck`). The release channel is the `updateChannel` setting; pre-releases are offered only on the canary channel.

Nothing installs without a click. `fast-llm.ps1 update-check` shows what is available and `fast-llm.ps1 update` installs it after your confirmation. Every update is verified before it runs; see "Update security" in [SECURITY.md](SECURITY.md).

## Privacy

- No telemetry.
- The server listens on 127.0.0.1 only.
- Self-test results stay on your PC (`selftest.json`).

## Resizable BAR

FastLLM checks Resizable BAR (Smart Access Memory) at each start and works around it being off. See [docs/RESIZABLE-BAR.md](docs/RESIZABLE-BAR.md) for what it does and how to turn it on.

## Port

The server listens on port 8080 by default. To change it, use Settings... in the window, or run `fast-llm.ps1 settings -Port <n>` (1024 to 65535); the change applies at the next start. The server always stays on 127.0.0.1, whatever the port. The diagnostic tools (semantic smoke, the concurrency benchmark, backend parity, the driver-module collector and the coopmat screen) need the default port 8080.

## Thinking

Thinking is Auto by default, and Auto leaves the server arguments exactly as they were. Settings... in the window (or `fast-llm.ps1 settings -Thinking off`) can turn it off. The choice reads "Off: faster answers. Quality with thinking off is not measured by Bitworks." and adds `--reasoning off` to the server arguments; the change applies at the next start. Benchmarks refuse a run started with thinking off, so set Thinking to Auto, start again, then benchmark. Each request can also ask for this itself, whatever the setting: send `reasoning_effort` or `chat_template_kwargs: {"enable_thinking": false}` in the request body.

## Local chat page

The local chat page is off by default, and FastLLM stays API-first. Settings... in the window (or `fast-llm.ps1 settings -ChatPage on`) can turn it on; the change applies at the next start, and an Open chat button then opens it in your browser while the run is serving. Turning it on omits only the `--no-ui` server argument: the page runs on 127.0.0.1 only, with the same port as the API, and has no built-in tools (`--no-agent` stays). Chats are kept by your browser, not by FastLLM. If the chat page still appears after you turn it off, clear the browser's site data for 127.0.0.1:<port>. Benchmarks refuse a run started with the page on, so turn it off, start again, then benchmark.

## Free up disk space

Downloaded models are 2 to 29 GB each. The Downloaded models button in the window lists them with their size and the free disk space; Remove asks first (the answer defaults to No) and deletes only that model, which you can download again later. Your licence consent records are kept, so a model you download again does not ask again. A model that FastLLM is serving, that a background run uses, or that is being downloaded cannot be removed; the window says so and removes nothing. The Remove leftover partial downloads button is enabled only when interrupted downloads and files that failed their check are left in the models folder, and asks a second time.

From a command line:

- `fast-llm.ps1 models -Installed` lists the downloaded models, the leftover files and the free disk space (add `-AsJson` for the rows).
- `fast-llm.ps1 models -Remove <model id>` shows what it removes and asks. Add `-Yes` to skip the question (a script has to).
- `fast-llm.ps1 models -RemoveQuarantined -Yes` deletes the leftover partial downloads it lists; without `-Yes` it only lists them and stops.

These take the same lock as an install or a start, so they stop with `operation-in-progress` while one is running.

## Uninstall

Use Windows Settings, Apps, FastLLM. Downloaded models and engines are kept unless you choose to delete them when asked.

## Optional ADLX probe

An optional component adds the card's PCI identity, PCIe link and in-run telemetry to benchmark reports. It is available from release `adlx-probe-v3`; install it with `fast-llm.ps1 components -Install bitworks-adlx-probe`, which asks you to accept its license. It is not Apache-2.0 (see `licenses/adlx-probe/EULA.md`) and is not installed by default. `tools/benchmark.ps1` uses it when it is installed and verified; `-NoAdlxProbe` turns that off.

## Building from source and tests

Release builds, signing and verification are in `release/` and `.github/workflows/`. Read the [benchmark methodology](docs/BENCHMARK-METHODOLOGY.md) and the [lab guide](docs/PUBLIC-LAB-GUIDE.md) for the measurement tools.

Run the portable Python tests:

```sh
python3 -m unittest discover -s tests
```

PowerShell suites run in CI on Windows. A passing mock test is not a physical AMD result.

## License

Apache-2.0; see `LICENSE`. Upstream engines and models keep their own terms: see `NOTICE` and `THIRD_PARTY_NOTICES.md`.
