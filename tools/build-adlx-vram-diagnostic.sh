#!/usr/bin/env bash
# Private lab build only. The existing v1 collector and its executable stay pinned.
set -euo pipefail

zig_bin="${1:-/opt/homebrew/bin/zig}"
if [[ "$("$zig_bin" version)" != '0.16.0' ]]; then
  echo 'Expected Zig 0.16.0.' >&2
  exit 1
fi
sdk_commit='32b5a740d42295c5dfe9026b9f52683da0f3af91'
sdk_zip_sha256='99850ddd58e3f5bbfdbe41c87248da8d5394227eaa32b19aad3206b4c3b2677c'
v1_source_sha256='f40506f015e3dd6ecaa9f11671ff3cc127896b539faac18ae572a12a4bb16a24'
repo_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
actual_v1_sha256="$(shasum -a 256 "$repo_dir/tools/adlx-telemetry.c" | awk '{print $1}')"
if [[ "$actual_v1_sha256" != "$v1_source_sha256" ]]; then
  echo 'Pinned v1 collector source digest mismatch.' >&2
  exit 1
fi
build_dir="$(mktemp -d /private/tmp/fastllm-adlx-vram-build.XXXXXX)"
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
  -I"$sdk_dir/SDK/Include" -I"$repo_dir/tools" \
  "$repo_dir/tools/adlx-vram-diagnostic.c" \
  -o "$build_dir/adlx-vram-diagnostic.exe"
echo "Private build directory: $build_dir"
shasum -a 256 \
  "$build_dir/sdk.zip" \
  "$sdk_dir/SDK/Include/IPerformanceMonitoring2.h" \
  "$sdk_dir/SDK/Include/IGPUTuning.h" \
  "$sdk_dir/SDK/Include/IGPUManualVRAMTuning.h" \
  "$sdk_dir/SDK/Include/IGPUManualPowerTuning.h" \
  "$sdk_dir/SDK/Include/IGPUPresetTuning.h" \
  "$sdk_dir/ADLX SDK License Agreement.pdf" \
  "$repo_dir/tools/adlx-telemetry.c" \
  "$repo_dir/tools/adlx-vram-diagnostic.c" \
  "$build_dir/adlx-vram-diagnostic.exe"
