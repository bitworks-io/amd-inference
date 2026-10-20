#!/usr/bin/env bash
# Builds the ADLX identity collector (adlx-identity-vram.exe) from tools/adlx-identity-vram.c with Zig 0.16.0 against the pinned AMD ADLX SDK.
# The SDK is downloaded from AMD's repository, checked against its pinned SHA-256 and used only to compile; it is never stored in this repository.
# Usage: build-adlx-identity-vram.sh [path-to-zig]   (default: the zig on PATH, else /opt/homebrew/bin/zig)
set -euo pipefail

zig_bin="${1:-$(command -v zig || echo /opt/homebrew/bin/zig)}"
if [[ "$("$zig_bin" version)" != '0.16.0' ]]; then
  echo 'Expected Zig 0.16.0.' >&2
  exit 1
fi
sdk_commit='32b5a740d42295c5dfe9026b9f52683da0f3af91'
sdk_zip_sha256='99850ddd58e3f5bbfdbe41c87248da8d5394227eaa32b19aad3206b4c3b2677c'
repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/fastllm-adlx-identity-build.XXXXXX")"
curl -fLsS --retry 2 --max-time 60 \
  -o "$build_dir/sdk.zip" \
  "https://github.com/GPUOpen-LibrariesAndSDKs/ADLX/archive/${sdk_commit}.zip"
actual_zip_sha256="$(shasum -a 256 "$build_dir/sdk.zip" | awk '{print $1}')"
if [[ "$actual_zip_sha256" != "$sdk_zip_sha256" ]]; then
  echo 'Pinned AMD ADLX SDK archive digest mismatch.' >&2
  exit 1
fi
unzip -q "$build_dir/sdk.zip" -d "$build_dir"
sdk_dir="$build_dir/ADLX-${sdk_commit}"
# The SDK includes <Windows.h>; Zig's MinGW headers name it windows.h. A one-line forwarding header, searched LAST (-idirafter),
# makes the build work on case-sensitive file systems (Linux CI) without touching the SDK. On a case-insensitive file system the
# system header is found first and the shim is never used; on a case-sensitive one only the shim matches Windows.h exactly.
shim_dir="$build_dir/case-shim"
mkdir "$shim_dir"
printf '#include <windows.h>\n' > "$shim_dir/Windows.h"
"$zig_bin" cc -target x86_64-windows-gnu -D_M_AMD64 -O2 -s \
  -Wall -Wextra -Werror -Wno-unused-function \
  -I"$sdk_dir/SDK/Include" -idirafter "$shim_dir" \
  "$repo_dir/tools/adlx-identity-vram.c" \
  -o "$build_dir/adlx-identity-vram.exe"
echo "Private build directory: $build_dir"
shasum -a 256 \
  "$build_dir/sdk.zip" \
  "$sdk_dir/SDK/Include/ADLX.h" \
  "$sdk_dir/SDK/Include/ADLXDefines.h" \
  "$sdk_dir/SDK/Include/ADLXStructures.h" \
  "$sdk_dir/SDK/Include/ISystem.h" \
  "$sdk_dir/SDK/Include/ISystem1.h" \
  "$sdk_dir/SDK/Include/ISystem2.h" \
  "$sdk_dir/SDK/Include/IPerformanceMonitoring.h" \
  "$sdk_dir/ADLX SDK License Agreement.pdf" \
  "$repo_dir/tools/adlx-identity-vram.c" \
  "$build_dir/adlx-identity-vram.exe"
