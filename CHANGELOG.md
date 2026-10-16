# Changelog

FastLLM is in public Preview. Releases are signed by Bitworks LLC and published at https://github.com/bitworks-io/amd-inference/releases. Canary releases are pre-releases; the first stable release is still ahead.

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
