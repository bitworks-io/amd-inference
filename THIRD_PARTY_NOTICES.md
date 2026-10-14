# Third-party notices and provenance

This file records the initial alpha catalog. It is not a substitute for the complete legal review, license-text bundle, SBOM, and attribution set required before redistribution.

## FastLLM

FastLLM's own source code is licensed under the Apache License, Version 2.0. See `LICENSE` and `NOTICE`.

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

FastLLM downloads the llama.cpp Vulkan build `b10698` from https://github.com/ggml-org/llama.cpp/releases at the user's
request and verifies it against pinned SHA-256 hashes. FastLLM does not redistribute llama.cpp. llama.cpp is licensed
under the MIT License; the full text is in `licenses/llama.cpp/LICENSE`. The Vulkan build needs the Microsoft Visual
C++ 2015–2022 x64 runtime, which FastLLM does not bundle.

## Qwen models

- Upstream organization: <https://huggingface.co/Qwen>
- Core catalog families: Qwen3.5 and Qwen3.8-27B
- Declared upstream license: Apache-2.0
- GGUF conversion provider: <https://huggingface.co/unsloth>
- Exact repository revisions, filenames, byte sizes, and SHA-256 values: [`config/catalog.json`](./config/catalog.json)

The selected GGUFs are community conversions, not first-party Qwen GGUF releases. Both upstream and conversion provenance must be shown before first download. The alpha records acceptance in a local receipt bound to the exact upstream license revision and artifact digest; an exact receipt may be reused for unattended reacquisition or repair of that same artifact, but not for a changed revision or digest. This mechanism does not replace legal review.

Model files are downloaded from Hugging Face at the user's request, after the user reviews and accepts the model license
in FastLLM. FastLLM recommends only models whose upstream license is Apache-2.0 (Qwen). The GGUF conversions are published
by Unsloth (https://huggingface.co/unsloth). Credit to the Qwen team and to Unsloth.

## Qwen3.8-Flash-Next

Flash-Next is excluded from automatic selection. Its approximately 180B stored parameters include roughly 4B MTP parameters. Its upstream artifact uses Qwen Community 1.0 rather than Apache-2.0. Any future experimental distribution requires separate review and user-visible terms.

## Microsoft Visual C++ runtime

If the Microsoft Visual C++ 2015–2022 x64 runtime is missing, FastLLM offers to download Microsoft's signed installer from
Microsoft and runs it only when the user clicks. The runtime is licensed by Microsoft under its own terms.
