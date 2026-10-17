# Changelog

FastLLM is in public Preview. Releases are signed by Bitworks LLC and published at https://github.com/bitworks-io/amd-inference/releases. Canary releases are pre-releases; the first stable release is still ahead.

## 2026.10.15.11 (canary)

The same changes were tagged as 2026.10.15.10, but that version was not published because a release check failed on the build runner.


- **No stale Ready after a restart:** after Stop and a new Start, the window no longer shows the previous run's Ready line, engine line or self-test results while the new server is still loading. They appear once the new run reports them.
- **The uninstaller shows the real size of downloaded data:** large model files were counted by their low 32 bits only, so a 16 GB model showed as a few GB. It also now offers to remove the downloaded engine components (the HIP engine and AMD runtime) together with the models and engines. Settings, consent records and logs are still kept, and the default answer is still No.
- **Clearer messages:**
  - After you stop a background run, the window says "Stopped. The background run ended." instead of asking you to review it. A run that ends or changes without your Stop keeps the cautious message.
  - When FastLLM opens, the status line reads "Not running. Install & start sets up and starts the best setup for your card." instead of telling you to install the driver and runtime first.
  - The empty list of installed components says "No engine components are installed."
- **Corrected setup warnings:** the Vulkan warning no longer says Vulkan is the only enabled engine, and a Bitworks-measured HIP setup is no longer called experimental. Community HIP setups keep that label.
- **The model license review opens without the text selected,** and Enter still cancels.
- **Long status lines are no longer cut off:** they end in an ellipsis and show the full text when you hover over them.

## 2026.10.15.9 (canary)

- **Install & start and Start / download work again from the window:** 2026.10.15.7 shortened the setup check's report, but it was printed as one long line that the window's output capture cut off. It is now printed on short lines.
- **Driver guidance opens again:** it read the full diagnostic report, which is larger than the window's output capture keeps. It now reads the shortened report, which keeps the driver guidance unchanged.

## 2026.10.15.8 (canary)

- **HIP is now the default on the RX 7900 XT and RX 7900 XTX:**
  - Lab results (result pages are linked under 2026.10.15.6 below): at a 512-token prompt, the XT reads 799.1 tok/s against 507.0 tok/s on Vulkan (+57.6%), and the XTX 876.3 against 654.1 (+34%). Generation speed is about the same (XT -1%, XTX +3%). The builds compared are HIP b11658 and Vulkan b10698.
  - FastLLM only makes a HIP setup the default when its measured prompt speed is at least the Vulkan setup's and its generation speed is at least 97% of it. The recipe build checks this.
- **Extra components on first use, about 565 MB (539 MiB) to download and about 2.33 GB (2.17 GiB) on disk once unpacked, decimal units unless noted:**
  - llama.cpp b11658 HIP (about 1.20 GB unpacked) from github.com, and the AMD ROCm 10.0 gfx1100 runtime (about 1.13 GB unpacked) from stable.repo.amd.com.
  - Bitworks hosts neither. Each file is checked against its pinned size and SHA-256.
- **One consent for the components, then the model license:**
  - The window shows **Install engine components** first, with each license link and one tick per component.
  - From the command line: `fast-llm.ps1 install -AcceptLicense`.
- **Optional setting to accept for you:**
  - Window: "Install engine components automatically (accept their licenses for me)", confirmed with "I accept these licenses".
  - Command line: `fast-llm.ps1 settings -ComponentLicenses accept-automatically -AcceptLicense`. Turn it off with `settings -ComponentLicenses ask`.
  - It covers only the licenses (matched by title and host) shown when you turned it on. If a component needs one that is not covered, FastLLM asks again.
- **A visible Vulkan fallback:**
  - If the license is declined, the HIP components are missing or fail their file check (and, in the window, if they cannot be installed), Windows blocks or cannot load the HIP files, the card cannot use HIP, or the HIP server does not start, FastLLM starts the Vulkan setup and says so. `status.json` records it as `fallback`, and the window's status line names the engine ("Running on HIP (AMD ROCm 10.0)" or "Running on Vulkan (fallback: ...)").
  - It never falls back after the server was ready.
  - A declined license is remembered for that setup and not asked again until you choose it under **Choose another setup** (or turn the automatic setting on).
  - An explicit `-Recipe`, or a setup you pick under **Choose another setup**, never falls back.
  - `start` never installs engine components.
- **Also:** new command-line options `start -PlannedRecipe <id>`, and `-UseFallback [-FallbackReason components-declined|components-install-failed]` on `plan`, `install` and `start`, and the `settings` command. The window notice now reads "Preview. Windows + AMD Radeon. Vulkan or HIP engine. Text-only models." The community screening tool reads `gpuVariants` and no longer flags HIP as unshipped on cards with a shipped HIP chain.
- **What has not changed:** Vulkan remains the fallback and the default on other cards, and experimental setups stay behind their switch.

## 2026.10.15.7 (canary)

- **Install & start and Start / download work again from the window:** they no longer stop at "The setup check returned no usable bounded diagnostic." The setup check now asks for a compact report, so it fits well within the size the window reads. Diagnostics still shows the full report.
- **Background hint text:** the hint under the background controls now shows "Install & start" instead of "Install  start".

## 2026.10.15.6 (canary)

- **HIP setups for the RX 7900 XT and RX 7900 XTX are now measured by Bitworks:**
  - [RX 7900 XT result](https://bitworks.io/amd-inference/recipes/rx-7900-xt-20gb-windows-hip-qwen3-8-27b-iq4xs/#lab-observation): 32.3 tok/s generation and 799.0 tok/s prompt, at a 512-token prompt.
  - [RX 7900 XTX result](https://bitworks.io/amd-inference/recipes/rx-7900-xtx-24gb-windows-hip-qwen3-8-27b-q4km/#lab-observation): 33.7 tok/s generation and 876.3 tok/s prompt, at a 512-token prompt.
  - The builds differ: HIP b11658, Vulkan b10698.
- **Where they appear:** under **Choose another setup**, without turning on experimental components.
- **What has not changed:**
  - They are still never picked automatically.
  - They still need each component's license accepted before anything downloads.
  - The default Vulkan setup is unchanged.

## 2026.10.15.5 (canary)

- **HIP setups (experimental, off by default):**
  - On the RX 7900 XT and RX 7900 XTX, FastLLM can run llama.cpp's HIP build (b11658) with AMD's ROCm 10.0 runtime, as an alternative to the default Vulkan setup.
  - FastLLM downloads the HIP build from llama.cpp's GitHub releases, and AMD's runtime from AMD's own repository, straight to your PC. Bitworks hosts none of these files.
  - Each file is checked against its pinned size and SHA-256 before use.
- **License acceptance:**
  - Before anything downloads, FastLLM lists each component with a link to its license and asks you to accept each one.
  - Declining downloads nothing.
- **How to choose one:**
  - HIP setups are never picked automatically.
  - Turn on "Experimental community components" in settings and choose one under **Choose another setup**.
  - From the command line: `fast-llm.ps1 components -Install llama.cpp-hip-b11658 -AcceptLicense`, then `start -Recipe <id> -AcceptExperimental`.
  - Bitworks has not yet measured these setups on these cards.
- **If Windows blocks a file:** the AMD runtime files are not code-signed. If Windows blocks them (for example Smart App Control), FastLLM stops and says so. It never switches to Vulkan on its own.
- No change to the default Vulkan setup.

## 2026.10.15.4 (canary)

- **Components, experimental and off by default:**
  - FastLLM can install other engine builds side by side, under its own `components` folder.
  - Each component is downloaded only from its listed official source, and checked against its pinned size, SHA-256 and per-file list before use.
  - From the command line: `fast-llm.ps1 components -List`, `components -Install <id>` and `components -Remove <id>`.
  - The FastLLM window lists installed components with their disk use and a Remove button.
- **Experimental community recipes:**
  - They stay hidden unless you turn on "Experimental community components" in settings.
  - They are never picked automatically.
  - From the command line they need `-AcceptExperimental`.
  - This release ships none.
- No change to the default setup for the RX 7900 XT or RX 7900 XTX.

## 2026.10.15.3 (canary)

- Documentation: this changelog. No product change since 2026.10.15.2. This release also exercises the in-app update path from 2026.10.15.2.

## 2026.10.15.2 (canary)

- **In-app updates:**
  - FastLLM checks for a newer release at most once a day with a single request to the GitHub releases API; you can turn this off in settings.
  - A banner offers the update. FastLLM installs it only after you confirm, and only if it is signed by Bitworks LLC, carries the expected version, and matches the published `SHA256SUMS`.
  - From the command line: `fast-llm.ps1 update-check` and `fast-llm.ps1 update`.
- **Install integrity:** `fast-llm.ps1 doctor` and the first launch of each version verify the installed files against the signed catalog.
- **Documentation:** a public README and security policy for the Preview release.

## 2026.10.15.1 (canary)

- **Best setup per card.** FastLLM identifies the card and picks the setup Bitworks measured on it, linking to the result page: RX 7900 XT (IQ4_XS, 16K context) and RX 7900 XTX (Q4_K_M, 32K context). Other cards get an estimated setup.
- **Self-test.** A short self-test runs before FastLLM reports ready. Results stay on your PC.
- **Resizable BAR.** On by default as Auto: FastLLM applies a workaround when Resizable BAR appears to be off, and tells you how to turn it on.
- **Fix:** the Start Menu launcher now works on PCs with Windows' default PowerShell script policy.

## 2026.10.14.2 (canary)

- First signed Preview release.
- **Known issue (fixed in 2026.10.15.1):** on PCs with Windows' default PowerShell script policy, the Start Menu launcher did not start FastLLM.
