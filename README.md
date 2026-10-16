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

## Uninstall

Use Windows Settings, Apps, FastLLM. Downloaded models and engines are kept unless you choose to delete them when asked.

## Building from source and tests

Release builds, signing and verification are in `release/` and `.github/workflows/`. Read the [benchmark methodology](docs/BENCHMARK-METHODOLOGY.md) and the [lab guide](docs/PUBLIC-LAB-GUIDE.md) for the measurement tools.

Run the portable Python tests:

```sh
python3 -m unittest discover -s tests
```

PowerShell suites run in CI on Windows. A passing mock test is not a physical AMD result.

## License

Apache-2.0; see `LICENSE`. Upstream engines and models keep their own terms: see `NOTICE` and `THIRD_PARTY_NOTICES.md`.
