#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src/FastLlm.VulkanCoopmatScreen.ps1'
$tool=Join-Path $root 'tools/vulkan-coopmat-screen.ps1'
foreach($path in @($source,$tool)){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "Parser errors in $path"}
}
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -Force
$count=0
function Check($ok,$message){if(-not $ok){throw $message};$script:count++}
function Reject($action,$message){$failed=$false;try{& $action|Out-Null}catch{$failed=$true};Check $failed $message}
& $module {param($Script)
    . $Script
    $row=@{model_filename='C:\cached.gguf';devices='Vulkan0';n_gpu_layers=999;n_batch=2048;n_ubatch=512;
        type_k='f16';type_v='f16';split_mode='none';fit_target=0;fit_min_ctx=0;n_cpu_moe=0;
        backends='Vulkan';n_prompt=0;n_gen=128;n_depth=4096;avg_ns=123456;stddev_ns=100;avg_ts=35.25;stddev_ts=0.5;
        samples_ts=@(35.0,35.1,35.2,35.3,35.4);samples_ns=@(1,2,3,4,5)}
    $json=ConvertTo-Json -InputObject $row -Compress
    $rows=@(ConvertFrom-FastLlmCoopmatBenchRows -Text ("log line`n$json`n") -ExpectedModelPath 'C:\cached.gguf' -Workload tg)
    if($rows.Count -ne 1 -or $rows[0].workloadKey -cne '0/128/4096'){throw 'Good TG row failed.'}
    $row.n_prompt=512;$row.n_gen=0;$row.n_depth=0
    $pp1=ConvertTo-Json -InputObject $row -Compress
    $row.n_prompt=4096
    $pp2=ConvertTo-Json -InputObject $row -Compress
    $pp=@(ConvertFrom-FastLlmCoopmatBenchRows -Text "$pp1`n$pp2" -ExpectedModelPath 'C:\cached.gguf' -Workload pp)
    if($pp.Count -ne 2){throw 'Good PP rows failed.'}
    $reject={param($Text,$Kind)
        $threw=$false;try{ConvertFrom-FastLlmCoopmatBenchRows -Text $Text -ExpectedModelPath 'C:\cached.gguf' -Workload $Kind|Out-Null}catch{$threw=$true}
        if(-not $threw){throw 'Invalid bench rows were accepted.'}
    }
    & $reject "$pp1`n$pp1" pp
    & $reject "$pp1`n{bad" pp
    & $reject "$pp1" pp
    $row.n_prompt=0;$row.n_gen=128;$row.n_depth=4096;$row.devices='Vulkan1'
    & $reject (ConvertTo-Json -InputObject $row -Compress) tg
    $row.devices='Vulkan0';$row.samples_ts=@(1,2,3)
    & $reject (ConvertTo-Json -InputObject $row -Compress) tg
    $row.samples_ts=@(1,2,3,4,5);$row.n_prompt=0.5
    & $reject (ConvertTo-Json -InputObject $row -Compress) tg
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.EnvironmentVariables['GGML_VK_DISABLE_COOPMAT']='old'
    $info.EnvironmentVariables['VULKAN_ICD_FILENAMES']='unsafe'
    $info.EnvironmentVariables['LLAMA_ARG_CTX_SIZE']='unsafe'
    $sandbox=[pscustomobject]@{appData='C:\empty-a';programData='C:\empty-p'}
    Set-FastLlmCoopmatChildEnvironment -Info $info -Sandbox $sandbox -EngineDirectory 'C:\engine' -Variant default
    if($info.EnvironmentVariables.ContainsKey('GGML_VK_DISABLE_COOPMAT') -or
       $info.EnvironmentVariables.ContainsKey('VULKAN_ICD_FILENAMES') -or
       $info.EnvironmentVariables.ContainsKey('LLAMA_ARG_CTX_SIZE')){throw 'Default inherited override survived scrub.'}
    Set-FastLlmCoopmatChildEnvironment -Info $info -Sandbox $sandbox -EngineDirectory 'C:\engine' -Variant 'disable-coopmat'
    if($info.EnvironmentVariables['GGML_VK_DISABLE_COOPMAT'] -cne '1'){throw 'Opt-in coopmat override missing.'}
    $snapshot="load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 14674.45 MiB`nload_tensors: CPU_Mapped model buffer size = 682.03 MiB`nC:\sensitive\model.gguf"
    $failure=Get-FastLlmCoopmatPlacementFailureSummary -Placement $snapshot -Overflow $false -CpuBufferLikeLines 1
    if($failure -cnotmatch 'reason=host-model-buffer' -or $failure -cnotmatch 'offload=66/66' -or
       $failure -cnotmatch 'buffer=CPU_Mapped:682.03MiB' -or $failure.Contains('sensitive')){
        throw 'Host placement failure summary was not bounded and sanitized.'
    }
    $overflow=Get-FastLlmCoopmatPlacementFailureSummary -Placement $snapshot -Overflow $true -CpuBufferLikeLines 1
    if($overflow -cnotmatch 'reason=placement-overflow' -or $overflow -cnotmatch 'cpuBufferLikeLines=1'){
        throw 'Overflow and CPU count must remain distinguishable.'
    }
    $base="load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 14674.45 MiB"
    $host="$base`nload_tensors: CPU_Mapped model buffer size = 682.03 MiB"
    $baseline=ConvertFrom-FastLlmCoopmatPlacement -Placement $base -GeneralOutput $base -CpuBufferLikeLines 0 -Overflow $false -AllowHostModelBuffer $false
    if($baseline.placementClassification -cne 'all-reported-layers-no-host-model-buffer' -or
       @($baseline.hostModelBuffers).Count -ne 0){throw 'Strict zero-host placement failed.'}
    $allowed=ConvertFrom-FastLlmCoopmatPlacement -Placement $host -GeneralOutput $host -CpuBufferLikeLines 1 -Overflow $false -AllowHostModelBuffer $true
    if($allowed.placementClassification -cne 'all-reported-layers-with-host-model-buffer' -or
       $allowed.hostModelBuffers[0].device -cne 'CPU_Mapped' -or
       [double]$allowed.hostModelBuffers[0].sizeMiB -ne 682.03 -or
       $allowed.allWeightsOnGpuVerified -ne $false){throw 'Opt-in host placement classification failed.'}
    $regularCpu="$base`nload_tensors: CPU model buffer size = 682.03 MiB"
    $regularAllowed=ConvertFrom-FastLlmCoopmatPlacement -Placement $regularCpu -GeneralOutput $regularCpu -CpuBufferLikeLines 1 -Overflow $false -AllowHostModelBuffer $true
    if($regularAllowed.hostModelBuffers[0].device -cne 'CPU'){throw 'Ordinary CPU buffer classification failed.'}
    $rejectPlacement={param($Snapshot,$Raw,$Count,$Overflow,$Allow)
        $threw=$false
        try{ConvertFrom-FastLlmCoopmatPlacement -Placement $Snapshot -GeneralOutput $Raw -CpuBufferLikeLines $Count -Overflow $Overflow -AllowHostModelBuffer $Allow|Out-Null}catch{$threw=$true}
        if(-not $threw){throw 'Invalid host placement evidence was accepted.'}
    }
    & $rejectPlacement $host $host 1 $false $false
    & $rejectPlacement $base $base 0 $false $true
    & $rejectPlacement "$base`nload_tensors: CPU_Mapped model buffer size = bad MiB" "$base`nload_tensors: CPU_Mapped model buffer size = bad MiB" 1 $false $true
    & $rejectPlacement "$host`nload_tensors: CPU model buffer size = 5 MiB" "$host`nload_tensors: CPU model buffer size = 5 MiB" 2 $false $true
    & $rejectPlacement $host "$host`nload_tensors: CPU_Unknown model buffer size = 7 MiB" 1 $false $true
    & $rejectPlacement $base "$base`nload_tensors: CPU-Mapped model buffer size = 7 MiB" 0 $false $false
    & $rejectPlacement $base "$base`nload_tensors: cpu_unknown model buffer size = 7 MiB" 0 $false $false
    & $rejectPlacement $base "$base`nload_tensors: CPU Mapped model buffer size = 7 MiB" 0 $false $false
    & $rejectPlacement "$base`nload_tensors: CPU_Mapped model buffer size = 1024.01 MiB" "$base`nload_tensors: CPU_Mapped model buffer size = 1024.01 MiB" 1 $false $true
    & $rejectPlacement $host $host 0 $false $true
    & $rejectPlacement $host $host 1 $true $true
    & $rejectPlacement ($host -replace '66/66','65/66') ($host -replace '66/66','65/66') 1 $false $true
} $source
$count+=27
$body=Get-Content -LiteralPath $source -Raw
Check ($body.Contains("[IO.FileMode]::CreateNew")) 'Output must be exclusive CreateNew.'
Check ($body.Contains("$([char]36)child.OutputCompleted")) 'Child EOF must be bounded.'
Check ($body.Contains("$([char]36)child.OutputTruncated")) 'Truncated output must be rejected.'
Check ($body.Contains('Test-FastLlmOffloadExactConsent')) 'Existing exact consent must be checked.'
Check ($body.Contains('Test-FastLlmEngineInstallation')) 'Exact engine manifest must be checked.'
Check ($body.Contains('Get-FastLlmHardware')) 'Fresh native probe must be used.'
Check ($body.Contains('ConvertFrom-FastLlmPlacementLog')) 'Numeric placement evidence must be required.'
Check ($body.Contains('native-windows-llama-bench-vulkan-coopmat-screen-v2')) 'Experimental result kind must be distinct.'
Check ($body.Contains('allowHostModelBuffer=[bool]$AllowHostModelBuffer')) 'Host allowance must be explicit in the report.'
Check ($body.Contains('hostModelBuffers=@($placement.hostModelBuffers)')) 'Observed host buffers must be reported.'
Check ($body.Contains("@('--offline','-v'")) 'Offline verbose benchmark mode must be pinned.'
Check (-not $body.Contains('Write-FastLlmState')) 'Normal state must not be mutated.'
Check (-not $body.Contains('Invoke-FastLlmSupervisedServer')) 'No API server may be launched.'
Write-Host "Vulkan coopmat screen tests passed: $count"
