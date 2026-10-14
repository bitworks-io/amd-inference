#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src/FastLlm.CardIdentity.ps1')
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; Write-Host "PASS: $Message" }
$variants = Get-FastLlmGpuVariants -Path (Join-Path $root 'config/gpu-variants.json')
function Dxgi($device, $rev, $mib, $vendor = 4098) { [pscustomobject]@{ vendorId = $vendor; deviceId = $device; revision = $rev; dedicatedVideoMiB = $mib } }
function Adapter($name, $mib) { [pscustomobject]@{ name = $name; vramMiB = $mib } }
$xt = Dxgi 29772 204 20422
$xtx = Dxgi 29772 200 24534

Check ((Get-FastLlmDxgiCardVariant -Adapter $xt -Variants $variants) -eq 'rx-7900-xt') 'XT resolves by device 744C revision CC'
Check ((Get-FastLlmDxgiCardVariant -Adapter $xtx -Variants $variants) -eq 'rx-7900-xtx') 'XTX resolves by device 744C revision C8'
Check ($null -eq (Get-FastLlmDxgiCardVariant -Adapter (Dxgi 29772 206 16368) -Variants $variants)) 'an unknown revision of the same device matches nothing'
Check ((Get-FastLlmDxgiCardVariant -Adapter ([pscustomobject]@{ vendorId = '0x1002'; deviceId = '744c'; revision = 'cc'; dedicatedVideoMiB = 20422 }) -Variants $variants) -eq 'rx-7900-xt') 'hex strings are accepted'

$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'AMD Radeon RX 7900 XT' 20464) -DxgiAdapters @($xt) -Variants $variants
Check ($r.status -eq 'matched' -and $r.variant -eq 'rx-7900-xt') 'planner adapter maps to XT by VRAM'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'Renamed Card' 24560) -DxgiAdapters @($xtx) -Variants $variants
Check ($r.variant -eq 'rx-7900-xtx') 'the marketed name is ignored'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'x' 20464) -DxgiAdapters @($xt, $xt) -Variants $variants
Check ($r.status -eq 'matched' -and $r.variant -eq 'rx-7900-xt') 'two identical XT cards still match'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'x' 20464) -DxgiAdapters @($xt, (Dxgi 29772 206 20422)) -Variants $variants
Check ($r.status -eq 'ambiguous' -and $null -eq $r.variant) 'a same-size card of an unknown variant makes the match ambiguous'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'x' 16368) -DxgiAdapters @($xt) -Variants $variants
Check ($r.status -eq 'unmatched') 'no DXGI adapter near the VRAM total gives unmatched'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'x' 20464) -DxgiAdapters @() -Variants $variants
Check ($r.status -eq 'no-identity') 'missing DXGI identity gives no-identity'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'x' 20464) -DxgiAdapters @((Dxgi 29772 204 20422 4318)) -Variants $variants
Check ($r.status -eq 'unmatched') 'a non-AMD adapter is never a candidate'
$r = Resolve-FastLlmAdapterVariant -PlannerAdapter (Adapter 'x' 24560) -DxgiAdapters @((Dxgi 5710 199 512), $xtx) -Variants $variants
Check ($r.variant -eq 'rx-7900-xtx') 'an integrated GPU with little VRAM does not disturb the match'
$bad = Join-Path ([IO.Path]::GetTempPath()) ('gv-' + [guid]::NewGuid().ToString('N') + '.json')
Set-Content -LiteralPath $bad -Value '{"schema":"bitworks.fastllm-gpu-variants/v1","variants":[{"key":"x"}]}' -Encoding ascii
$threw = $false; try { Get-FastLlmGpuVariants -Path $bad | Out-Null } catch { $threw = $true } finally { Remove-Item -LiteralPath $bad -Force }
Check $threw 'a variant missing required fields is refused'
Write-Host 'card-identity-tests: PASS'
