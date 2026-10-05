# Third-party notices and provenance

This file records the initial alpha catalog. It is not a substitute for the complete legal review, license-text bundle, SBOM, and attribution set required before redistribution.

## llama.cpp

- Project: <https://github.com/ggml-org/llama.cpp>
- License: MIT
- Pinned alpha build: `b10698`
- Enabled alpha artifact:
  - Windows Vulkan x64; archive hash-pinned and installed only when its exact extracted-file manifest matches.
- Cataloged but disabled artifact:
  - Windows ROCm 7.14 x64 (`b10698`); not downloaded or executed by the alpha.

The Windows ROCm archive imports `hipblas.dll` but does not contain a complete matched ROCm runtime. FastLLM disables the lane to prevent ambient DLL loading and must not redistribute AMD components until the complete runtime manifest and exact license/distribution terms are reviewed.

The enabled Vulkan archive imports Microsoft's `MSVCP140.dll`, `VCRUNTIME140.dll`, and `VCRUNTIME140_1.dll` and relies on the installed graphics stack for `vulkan-1.dll`; those files are not in the llama.cpp archive. Before native execution, the alpha checks for files with those names in System32 and a 64-bit host, then requires the isolated Vulkan probe to return an adapter whose reported name passes the alpha AMD/discrete heuristic. The presence/name check does not validate package versions, signatures, loader vendor, or PCI vendor identity. This source repository does not bundle those prerequisites. The control window has an optional verified Microsoft VC++ installer handoff, with a separate user review and UAC step; it does not accept Microsoft's terms or reboot automatically. That path still requires visible native/clean-machine qualification. AMD driver installation remains user-directed. Public binary packaging requires a separate Microsoft/AMD redistribution and trademark review or a signed engine with a closed dependency set.

## Qwen models

- Upstream organization: <https://huggingface.co/Qwen>
- Core catalog families: Qwen3.5 and Qwen3.8-27B
- Declared upstream license: Apache-2.0
- GGUF conversion provider: <https://huggingface.co/unsloth>
- Exact repository revisions, filenames, byte sizes, and SHA-256 values: [`config/catalog.json`](./config/catalog.json)

The selected GGUFs are community conversions, not first-party Qwen GGUF releases. Both upstream and conversion provenance must be shown before first download. The alpha records acceptance in a local receipt bound to the exact upstream license revision and artifact digest; an exact receipt may be reused for unattended reacquisition or repair of that same artifact, but not for a changed revision or digest. This mechanism does not replace legal review.

## Qwen3.8-Flash-Next

Flash-Next is excluded from automatic selection. Its approximately 180B stored parameters include roughly 4B MTP parameters. Its upstream artifact uses Qwen Community 1.0 rather than Apache-2.0. Any future experimental distribution requires separate review and user-visible terms.

## Project license

Bitworks has not yet selected the license for FastLLM integration code. Until a `LICENSE` file is added by the owner, no public-release license grant should be inferred. Choosing and publishing that license is a GA blocker.
