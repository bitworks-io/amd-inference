#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$source=Join-Path $root 'src/FastLlm.VulkanFitTrial.ps1'
$catalog=Join-Path $root 'config/catalog.json'
$count=0
function Check([bool]$ok,[string]$message){if(-not $ok){throw $message};$script:count++}
function Reject([scriptblock]$action,[string]$message){$failed=$false;try{& $action | Out-Null}catch{$failed=$true};Check $failed $message}
$result=& $module {param($path,$catalogPath)
    . $path
    $model=Get-FastLlmVulkanFitModel -CatalogPath $catalogPath
    $on=@(New-FastLlmVulkanFitArguments -ModelPath 'model.gguf' -ModelId $model.model.id -FitMode on)
    $off=@(New-FastLlmVulkanFitArguments -ModelPath 'model.gguf' -ModelId $model.model.id -FitMode off)
    $plain="load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 14925.00 MiB"
    $mapped=$plain+"`nload_tensors: CPU_Mapped model buffer size = 682.03 MiB"
    $evidence=ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $plain -CpuBufferLikeLines 0 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $false
    $hostEvidence=ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $mapped -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true
    return [pscustomobject]@{sha=Get-FastLlmVulkanFitTrialSourceSha256;model=$model.model;
        on=$on;off=$off;plain=$plain;mapped=$mapped;evidence=$evidence;hostEvidence=$hostEvidence;
        counters=(Assert-FastLlmVulkanFitPlacementCounters -Diagnostics 'tensorLines=4, offloadLike=1, bufferLike=1, captured=2, dropped=0, generalOutputTruncated=False' -Evidence $evidence)}
} $source $catalog
Check ($result.sha -ceq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) 'Trial source digest changed.'
Check ($result.model.id -ceq 'qwen3.8-27b-ud-q4-k-m' -and $result.model.sha256 -ceq '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482') 'Wrong Qwen artifact.'
Check ($result.on.Count -eq $result.off.Count -and @($result.on|Where-Object {$_ -ceq '--fit'}).Count -eq 1) 'Fit argument count changed.'
$deltas=@(for($i=0;$i -lt $result.on.Count;$i++){if($result.on[$i] -cne $result.off[$i]){$i}})
Check ($deltas.Count -eq 1 -and $result.on[$deltas[0]] -ceq 'on' -and $result.off[$deltas[0]] -ceq 'off' -and $result.on[$deltas[0]-1] -ceq '--fit') 'A/B argv differs beyond fit value.'
Check (($result.on -join '|').Contains('--fit-target|768') -and ($result.off -join '|').Contains('--fit-target|768') -and ($result.on -join '|').Contains('--n-gpu-layers|all')) 'Full-layer fit-target contract missing.'
Check ($result.evidence.reportedGpuLayers -eq 66 -and $null -eq $result.evidence.hostModelBuffer -and -not $result.evidence.allWeightsOnGpuVerified) 'No-host placement overstated.'
Check ($result.hostEvidence.hostModelBuffer.device -ceq 'CPU_Mapped' -and $result.hostEvidence.hostModelBuffer.sizeMiB -eq 682.03 -and $result.hostEvidence.classification -ceq 'all-reported-layers-with-host-model-buffer') 'Host-buffer numeric evidence lost.'
Check ($result.counters.bufferLike -eq 1 -and $result.counters.captured -eq 2) 'Exact raw-to-captured placement counters missing.'
Reject {& $module {param($path,$evidence) . $path;Assert-FastLlmVulkanFitPlacementCounters -Diagnostics 'tensorLines=4, offloadLike=1, bufferLike=2, captured=2, dropped=0, generalOutputTruncated=False' -Evidence $evidence} $source $result.evidence} 'Unrecognized CPU-Mapped model buffer line was not detected by raw counter.'
Reject {& $module {param($path,$evidence) . $path;Assert-FastLlmVulkanFitPlacementCounters -Diagnostics 'tensorLines=4, offloadLike=1, bufferLike=3, captured=3, dropped=0, generalOutputTruncated=False' -Evidence $evidence} $source $result.hostEvidence} 'Extra unrecognized host model buffer was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $false} $source $result.mapped} 'CPU_Mapped was accepted without opt-in.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 0 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true} $source $result.mapped} 'CPU-like count mismatch was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true} $source ($result.mapped.Replace('CPU_Mapped','CPU'))} 'Nonmapped CPU buffer was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true} $source ($result.mapped.Replace('682.03','NaN'))} 'Nonnumeric host buffer was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true} $source ($result.mapped.Replace('682.03','1024.01'))} 'Host buffer above the fixed trial cap was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 2 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true} $source ($result.mapped+"`nload_tensors: CPU_Mapped model buffer size = 1.00 MiB")} 'Duplicate host buffer was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 0 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $false} $source ($result.plain.Replace('66/66','65/66'))} 'Partial layer placement was accepted.'
Reject {& $module {param($path,$text) . $path;ConvertFrom-FastLlmVulkanFitBufferEvidence -Text $text -CpuBufferLikeLines 0 -Overflow $true -ModelBytes 16464440224 -AllowHostModelBuffer $false} $source $result.plain} 'Overflowed capture was accepted.'
$text=Get-Content -LiteralPath $source -Raw
Check ($text.Contains('Test-FastLlmEngineInstallation') -and $text.Contains('Test-FastLlmOffloadExactConsent') -and $text.Contains('Assert-FastLlmVulkanFitCachedModel') -and -not $text.Contains('Install-FastLlmModel')) 'Private trial must verify, never acquire.'
Check ($text.Contains('Test-FastLlmApiCanary') -and $text.Contains('GetLoopbackListenerOwners(18083)') -and $text.Contains('dynamicClosureVerified=$false') -and $text.Contains('performanceQualified=$false')) 'Private identity/canary/unqualified gates missing.'
"Vulkan fit trial checks: $count passed"
