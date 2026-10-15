# Changelog

FastLLM is in public Preview. Releases are signed by Bitworks LLC and published at https://github.com/bitworks-io/amd-inference/releases. Canary releases are pre-releases; the first stable release is still ahead.

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
