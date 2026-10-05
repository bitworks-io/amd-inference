#!/usr/bin/env bash
# Private lab build only. Do not redistribute SDK material or this unsigned exe.
set -euo pipefail

zig_bin="${1:-/opt/homebrew/bin/zig}"
if [[ "$("$zig_bin" version)" != "0.16.0" ]]; then
  echo 'Expected Zig 0.16.0.' >&2
  exit 1
fi
sdk_commit='32b5a740d42295c5dfe9026b9f52683da0f3af91'
sdk_zip_sha256='99850ddd58e3f5bbfdbe41c87248da8d5394227eaa32b19aad3206b4c3b2677c'
repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
build_dir="$(mktemp -d /private/tmp/fastllm-adlx-build.XXXXXX)"
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
"$zig_bin" cc -target x86_64-windows-gnu -D_M_AMD64 -O2 -s \
  -Wall -Wextra -Werror -Wno-unused-function \
  -I"$sdk_dir/SDK/Include" \
  "$repo_dir/tools/adlx-telemetry.c" \
  -o "$build_dir/adlx-telemetry.exe"
echo "Private build directory: $build_dir"
shasum -a 256 \
  "$build_dir/sdk.zip" \
  "$sdk_dir/SDK/Include/ADLX.h" \
  "$sdk_dir/SDK/Include/ADLXDefines.h" \
  "$sdk_dir/SDK/Include/ISystem.h" \
  "$sdk_dir/SDK/Include/IPerformanceMonitoring.h" \
  "$sdk_dir/Samples/C/PerformanceMonitoring/PerfGPUMetrics/mainPerfGPUMetrics.c" \
  "$sdk_dir/ADLX SDK License Agreement.pdf" \
  "$repo_dir/tools/adlx-telemetry.c" \
  "$build_dir/adlx-telemetry.exe"
