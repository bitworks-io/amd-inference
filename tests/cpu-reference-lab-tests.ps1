#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$repo=Split-Path $PSScriptRoot -Parent
$source=Join-Path $repo 'src/FastLlm.CpuReferenceLab.ps1'
$toolPath=Join-Path $repo 'tools/cpu-reference-lab.ps1'
foreach($path in @($source,$toolPath)){
    $tokens=$null;$errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ('CPU reference lab parser errors in '+$path+': '+(@($errors | ForEach-Object Message) -join ' | '))}
}
. $source
$script:passes=0
function Assert($condition,$message){if(-not $condition){throw $message};$script:passes++}
function Fails($operation,$message){$failed=$false;try{& $operation}catch{$failed=$true};Assert $failed $message}
$fixed=Get-FastLlmCpuReferenceFixed
$text=[IO.File]::ReadAllText($source)

# --- Fixed contract ---
Assert ($fixed.modelId -ceq 'qwen3.8-27b-ud-q4-k-m' -and $fixed.contextSize -eq 32768 -and $fixed.slots -eq 1 -and $fixed.port -eq 18089) 'fixed lab contract changed'
Assert ($fixed.catalogSha256 -ceq '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6' -and
    $fixed.engineSha256 -ceq '9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7' -and
    $fixed.modelSha256 -ceq '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482') 'protocol hashes changed'
$others=Get-ChildItem -LiteralPath (Join-Path $repo 'src') -Filter '*.ps1' | Where-Object {$_.Name -cne 'FastLlm.CpuReferenceLab.ps1'}
foreach($file in $others){
    Assert (-not ([IO.File]::ReadAllText($file.FullName) -match "'--port',\s*'18089'|--port.{0,12}18089")) ("port 18089 is used elsewhere: "+$file.Name)
}
Assert (-not $text.Contains('Get-FastLlmPlan') -and -not $text.Contains('Invoke-FastLlmSupervisedServer') -and -not $text.Contains('Start-FastLlmServer')) 'normal all-GPU path leaked into the CPU lab'
Assert ($text.Contains("kind='fastllm-cpu-reference-lab-run'") -or $text.Contains("stateKind='fastllm-cpu-reference-lab-run'")) 'state kind missing'
Assert ($text.Contains('Test-FastLlmModelConsentReceipt') -and $text.Contains('GlobalMemoryStatusEx') -and -not ($text -match '(?i)Get-CimInstance|Get-WmiObject|Win32_')) 'consent or non-CIM memory contract missing'
Assert (-not ($text -cmatch '\?\?|-AsHashtable|ForEach-Object -Parallel')) 'PowerShell 7-only syntax present'
$toolText=[IO.File]::ReadAllText($toolPath)
Assert ($toolText.Contains("'start','status','stop'") -and -not $toolText.Contains('AcceptModelLicense') -and -not $toolText.Contains('prepare')) 'tool actions or acquisition surface wrong'
Fails {Assert-FastLlmCpuReferenceRoots '/tmp/artifacts' '/tmp/artifacts/lab'} 'nested roots passed'
Fails {Assert-FastLlmCpuReferenceRoots '/tmp/artifacts' '/tmp/artifacts'} 'identical roots passed'
if($env:OS -ne 'Windows_NT'){Fails {Assert-FastLlmCpuReferenceHost} 'non-Windows host passed'}

# --- Memory preflight (model bytes plus 4 GiB) ---
$modelBytes=[int64]16464440224
$required=$modelBytes+[int64]4GB
$ok=Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes $required -ModelBytes $modelBytes
Assert ($ok.requiredBytes -eq $required -and $ok.fitVerified -eq $false) 'exact RAM boundary refused or fit claimed'
Fails {Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes ($required-1) -ModelBytes $modelBytes} 'one byte below the RAM requirement passed'
Fails {Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes 0 -ModelBytes $modelBytes} 'zero RAM passed'
Fails {Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes ($modelBytes+3GB) -ModelBytes $modelBytes} 'a 3 GiB reserve passed'
Fails {Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes -1 -ModelBytes $modelBytes} 'negative RAM passed'
Fails {Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes 100 -ModelBytes 0} 'zero model size passed'
Fails {Assert-FastLlmCpuReferenceMemoryBudget -AvailableBytes 100 -ModelBytes ([long]::MaxValue)} 'overflowing model size passed'

# --- Exact argument construction against the normal Q4 recipe ---
$catalogPath=Join-Path $repo 'config/catalog.json'
$catalogJson=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($catalogPath))
$model=@($catalogJson.models | Where-Object {$_.id -ceq 'qwen3.8-27b-ud-q4-k-m'})[0]
$modelPath='/verified/models/Qwen3.8-27B-UD-Q4_K_M.gguf'
$cpuArgs=@(Get-FastLlmCpuReferenceArguments -Model $model -ModelPath $modelPath)
$repoModule=Import-Module (Join-Path $repo 'src/FastLlm.psm1') -Force -PassThru
$hardware=& $repoModule {param($P) Read-FastLlmJson $P} (Join-Path $PSScriptRoot 'fixtures/rx-7900-xtx-24gb.json')
$plan=& $repoModule {param($H,$C) Get-FastLlmPlan -Hardware $H -CatalogPath $C -InstallRoot '/verified' -ModelId 'qwen3.8-27b-ud-q4-k-m'} $hardware $catalogPath
$normal=@($plan.serverArguments | ForEach-Object {if([string]$_ -ceq [string]$plan.modelPath){$modelPath}else{[string]$_}})
Assert ($plan.model.contextSize -eq 32768 -and [string]$normal[$normal.IndexOf('--ctx-size')+1] -ceq '32768') 'normal Q4 recipe is not 32768 context'
$expected=New-Object 'System.Collections.Generic.List[string]'
for($i=0;$i -lt $normal.Count;$i++){
    $item=[string]$normal[$i]
    if($item -ceq '--port'){$expected.Add($item);$expected.Add('18089');$i++}
    elseif($item -ceq '--n-gpu-layers'){$expected.Add($item);$expected.Add('0');$i++}
    elseif($item -ceq '--fit'){$expected.Add($item);$expected.Add('off');$i++}
    elseif($item -ceq '--device'){$expected.Add($item);$expected.Add('none');$i++}
    elseif($item -ceq '--split-mode'){$expected.Add($item);$expected.Add([string]$normal[$i+1]);$i++;$expected.Add('--no-op-offload');$expected.Add('--no-kv-offload')}
    else{$expected.Add($item)}
}
Assert (($cpuArgs -join [char]31) -ceq ($expected.ToArray() -join [char]31)) 'CPU arguments differ from the normal Q4 recipe by more than the declared changes'
Assert ((@($normal) -contains '--n-gpu-layers') -and [string]$normal[$normal.IndexOf('--device')+1] -ceq 'Vulkan0' -and [string]$normal[$normal.IndexOf('--fit')+1] -ceq 'on' -and
    [string]$normal[$normal.IndexOf('--port')+1] -ceq '8080') 'comparison baseline is not the normal GPU recipe'
foreach($pair in @(@('--device','none'),@('--n-gpu-layers','0'),@('--fit','off'),@('--port','18089'),@('--ctx-size','32768'),@('--parallel','1'),
    @('--spec-type','none'),@('--flash-attn','auto'),@('--cache-type-k','f16'),@('--cache-type-v','f16'),@('--host','127.0.0.1'),@('--split-mode','none'))){
    Assert (Test-FastLlmCpuReferenceArgument $cpuArgs $pair[0] $pair[1]) ('argument '+$pair[0]+' wrong')
}
foreach($flag in @('--no-op-offload','--no-kv-offload','--offline','--no-mmproj','--jinja','--no-agent','--no-ui')){
    Assert (@($cpuArgs | Where-Object {$_ -ceq $flag}).Count -eq 1) ("flag $flag count wrong")
}
Assert (@($cpuArgs | Where-Object {$_ -ceq 'Vulkan0' -or $_ -ceq 'all' -or $_ -ceq '8080' -or $_ -ceq '--tensor-split'}).Count -eq 0) 'GPU-oriented argument survived'
Assert ($cpuArgs -notcontains '--cache-ram' -and @($cpuArgs | Where-Object {$_ -ceq '--no-op-offload'}).Count -eq 1) 'extra argument introduced'

# --- Catalog resolution (needs module scope) ---
$entry=& $repoModule {param($S,$C) . $S; Get-FastLlmCpuReferenceModel $C} $source $catalogPath
Assert ($entry.model.id -ceq $fixed.modelId -and $entry.catalogSha256 -ceq $fixed.catalogSha256 -and $entry.model.sizeBytes -eq 16464440224) 'catalog resolution failed'
$tempParent=if($env:OS -eq 'Windows_NT'){[IO.Path]::GetTempPath()}elseif(Test-Path -LiteralPath '/private/tmp' -PathType Container){'/private/tmp'}else{[IO.Path]::GetTempPath()}
$tempRoot=Join-Path $tempParent ('fast-llm-cpu-reference-test-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $tempRoot
try{
    $changedCatalog=Join-Path $tempRoot 'catalog.json'
    [IO.File]::WriteAllText($changedCatalog,([IO.File]::ReadAllText($catalogPath)+"`n"))
    Fails {& $repoModule {param($S,$C) . $S; Get-FastLlmCpuReferenceModel $C} $source $changedCatalog} 'a changed catalog was accepted'

    # --- Placement acceptance and every rejection path ---
    $placement="load_tensors: offloaded 0/65 layers to GPU`nload_tensors: CPU_Mapped model buffer size = 15700.50 MiB"
    $startup="kv CPU 512.00`ncompute CPU 80.00"
    $script:defaultStartup=$startup
    function Invoke-Placement {
        param([string]$PlacementText,[string]$StartupText=$script:defaultStartup,[string]$OutputText='',
              [bool]$PlacementOverflow=$false,[bool]$StartupOverflow=$false,[bool]$OutputTruncated=$false,
              [int]$CpuBufferLikeLines=-1,[int]$SelectedDeviceLikeLines=0)
        ConvertFrom-FastLlmCpuReferencePlacementLog -PlacementText $PlacementText -StartupText $StartupText -OutputText $OutputText `
            -PlacementOverflow $PlacementOverflow -StartupOverflow $StartupOverflow -OutputTruncated $OutputTruncated `
            -CpuBufferLikeLines $CpuBufferLikeLines -SelectedDeviceLikeLines $SelectedDeviceLikeLines
    }
    $accepted=Invoke-Placement -PlacementText $placement -StartupText $startup -OutputText "ggml_vulkan: Found 1 Vulkan devices:`nload_tensors: CPU_Mapped model buffer size = 15700.50 MiB"
    Assert ($accepted.reportedGpuLayers -eq 0 -and $accepted.reportedTotalLayers -eq 65 -and $accepted.cpuModelBufferMiB -eq 15700.5 -and
        $accepted.cpuModelBufferKinds[0] -ceq 'CPU_Mapped' -and $accepted.gpuBufferLinesObserved -eq 0 -and
        -not $accepted.physicalResidencyVerified -and -not $accepted.performanceQualified) 'valid CPU placement was rejected or overstated'
    $two=Invoke-Placement -PlacementText ($placement+"`nload_tensors: CPU model buffer size = 100.00 MiB")
    Assert ($two.cpuModelBufferLineCount -eq 2 -and $two.cpuModelBufferMiB -eq 15800.5) 'CPU plus CPU_Mapped buffers were not both accepted'
    Fails {Invoke-Placement -PlacementText $placement -OutputTruncated $true} 'a truncated general output capture was accepted'
    Assert ((Invoke-Placement -PlacementText $placement -CpuBufferLikeLines 1).cpuModelBufferLineCount -eq 1) 'matching native CPU-like count rejected'
    # Any Vulkan model, KV or compute buffer line, in any capture, for any device.
    $vulkanLines=@('load_tensors: Vulkan0 model buffer size = 10.00 MiB','load_tensors: Vulkan1 model buffer size = 10.00 MiB',
        'llama_kv_cache: Vulkan0 KV buffer size = 256.00 MiB','llama_kv_cache: Vulkan_Host KV buffer size = 8.00 MiB',
        'sched_reserve: Vulkan0 compute buffer size = 64.00 MiB','sched_reserve: Vulkan_Host compute buffer size = 4.00 MiB',
        '0.01 I llama load_tensors: ROCm0 model buffer size = 3.00 MiB')
    foreach($line in $vulkanLines){
        Fails {Invoke-Placement -PlacementText ($placement+"`n"+$line)} ("placement capture accepted: $line")
        Fails {Invoke-Placement -PlacementText $placement -OutputText ("0.02 I "+$line+" /untrusted")} ("output capture accepted: $line")
    }
    Fails {Invoke-Placement -PlacementText $placement -StartupText "kv Vulkan0 256.00"} 'startup Vulkan KV accepted'
    Fails {Invoke-Placement -PlacementText $placement -StartupText "kv CPU 1.00`ncompute Vulkan1 64.00"} 'startup Vulkan compute accepted'
    Fails {Invoke-Placement -PlacementText $placement -StartupText "compute ROCm0 64.00"} 'startup ROCm compute accepted'
    # Nonzero or inconsistent GPU layers.
    foreach($bad in @('1/65','64/65','65/65','0/0')){
        Fails {Invoke-Placement -PlacementText ($placement -replace '0/65',$bad)} "layers $bad accepted"
    }
    Fails {Invoke-Placement -PlacementText 'load_tensors: CPU_Mapped model buffer size = 15700.50 MiB'} 'missing offload-layer evidence accepted'
    Fails {Invoke-Placement -PlacementText ($placement+"`nload_tensors: offloaded 0/65 layers to GPU")} 'duplicate offload evidence accepted'
    # Missing, malformed, duplicate or non-positive CPU evidence.
    Fails {Invoke-Placement -PlacementText 'load_tensors: offloaded 0/65 layers to GPU'} 'missing CPU buffer accepted'
    Fails {Invoke-Placement -PlacementText ("load_tensors: offloaded 0/65 layers to GPU`nload_tensors: Other model buffer size = 5.00 MiB")} 'a non-CPU buffer satisfied CPU evidence'
    Fails {Invoke-Placement -PlacementText ($placement+"`nload_tensors: CPU_Mapped model buffer size = 1.00 MiB")} 'duplicate CPU_Mapped accepted'
    Fails {Invoke-Placement -PlacementText ($placement+"`nload_tensors: CPU model buffer size = 1.00 MiB`nload_tensors: CPU model buffer size = 2.00 MiB")} 'three CPU buffers accepted'
    Fails {Invoke-Placement -PlacementText ($placement+"`nload_tensors: CPU model buffer size = NaN MiB")} 'malformed CPU buffer accepted'
    Fails {Invoke-Placement -PlacementText ($placement -replace '15700.50','0.00')} 'zero CPU buffer accepted'
    Fails {Invoke-Placement -PlacementText ($placement -replace '15700.50',('9'*40))} 'oversized CPU buffer accepted'
    Fails {Invoke-Placement -PlacementText $placement -CpuBufferLikeLines 2} 'native CPU-like count mismatch accepted'
    # Capture overflow.
    Fails {Invoke-Placement -PlacementText $placement -PlacementOverflow $true} 'placement overflow accepted'
    Fails {Invoke-Placement -PlacementText $placement -StartupOverflow $true} 'startup overflow accepted'

    # --- S1/S2/N10: selected-device lines, CPU KV/compute evidence, truncation and CPU_REPACK ---
    Fails {Invoke-Placement -PlacementText $placement -SelectedDeviceLikeLines 1} 'a native selected-device count was ignored'
    Fails {Invoke-Placement -PlacementText $placement -OutputText 'llama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 24000 MiB free'} 'a selected-device line in the output was ignored'
    Fails {Invoke-Placement -PlacementText ($placement+"`nllama_prepare_model_devices: using device Vulkan0 (AMD) (unknown id) - 1 MiB free")} 'a selected-device line in the placement capture was ignored'
    Fails {Invoke-Placement -PlacementText $placement -StartupText 'compute CPU 80.00'} 'missing CPU KV evidence accepted'
    Fails {Invoke-Placement -PlacementText $placement -StartupText 'kv CPU 512.00'} 'missing CPU compute evidence accepted'
    Fails {Invoke-Placement -PlacementText $placement -StartupText ''} 'an empty startup capture accepted'
    Fails {Invoke-Placement -PlacementText 'load_tensors: offloaded 0/65 layers to GPU' -StartupText $startup} 'offloaded 0/N alone was accepted'
    Fails {Invoke-Placement -PlacementText $placement -StartupText "kv CPU 512.00`nkv Vulkan0 1.00`ncompute CPU 80.00"} 'a Vulkan KV line beside CPU evidence accepted'
    Fails {Invoke-Placement -PlacementText $placement -OutputTruncated $true -OutputText 'harmless'} 'truncation with harmless text accepted'
    Fails {Invoke-Placement -PlacementText $placement -OutputText 'sched_reserve: Vulkan_Host compute buffer size = 4.00 MiB'} 'a Vulkan_Host buffer line in the general capture accepted'
    $repackLine='load_tensors: CPU_REPACK model buffer size = 300.00 MiB'
    $withRepack=Invoke-Placement -PlacementText $placement -OutputText $repackLine
    Assert ($withRepack.cpuModelBufferMiB -eq 16000.5 -and @($withRepack.cpuModelBufferKinds) -contains 'CPU_REPACK' -and @($withRepack.cpuModelBufferKinds) -contains 'CPU_Mapped' -and $withRepack.cpuModelBufferLineCount -eq 2) 'CPU_REPACK was not included in the CPU model-buffer total'
    Fails {Invoke-Placement -PlacementText $placement -OutputText ($repackLine+"`n"+$repackLine)} 'duplicate CPU_REPACK accepted'
    Fails {Invoke-Placement -PlacementText $placement -OutputText 'load_tensors: CPU_REPACK model buffer size = NaN MiB'} 'malformed CPU_REPACK accepted'
    Assert ($accepted.cpuKvBufferLines -eq 1 -and $accepted.cpuComputeBufferLines -eq 1 -and $accepted.selectedDeviceLines -eq 0) 'CPU KV/compute evidence not summarised'

    # Realistic --device none log: Vulkan is enumerated but nothing is placed on it.
    $noneLog=@('ggml_vulkan: Found 1 Vulkan devices:','ggml_vulkan: 0 = AMD Radeon RX 7900 XTX (AMD proprietary driver) | uma: 0 | fp16: 1',
        'load_backend: loaded Vulkan backend from C:\engine\ggml-vulkan.dll','load_backend: loaded CPU backend from C:\engine\ggml-cpu-haswell.dll',
        'llama_model_loader: loaded meta data with 40 key-value pairs and 800 tensors','print_info: file type   = Q4_K - Medium',
        'load_tensors: offloaded 0/65 layers to GPU','load_tensors: CPU_Mapped model buffer size = 15700.50 MiB',
        'llama_context: n_ctx = 32768','llama_context: flash_attn = auto','llama_kv_cache: CPU KV buffer size = 512.00 MiB',
        'sched_reserve: CPU compute buffer size = 80.00 MiB','resolve_fused_ops: Flash Attention enabled') -join "`n"
    $nonePlacement="load_tensors: offloaded 0/65 layers to GPU`nload_tensors: CPU_Mapped model buffer size = 15700.50 MiB"
    $noneStartup="kv CPU 512.00`ncompute CPU 80.00`nflash-mode auto`nflash-resolved enabled"
    $noneResult=Invoke-Placement -PlacementText $nonePlacement -StartupText $noneStartup -OutputText $noneLog
    Assert ($noneResult.reportedGpuLayers -eq 0 -and $noneResult.cpuModelBufferMiB -eq 15700.5 -and $noneResult.cpuKvBufferLines -eq 1) 'realistic --device none log was refused'
    # Counterfactual: the engine ignored --device none and selected the GPU anyway.
    $ignoredLog=$noneLog+"`nllama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 24000 MiB free"
    Fails {Invoke-Placement -PlacementText $nonePlacement -StartupText $noneStartup -OutputText $ignoredLog} 'a log with a selected GPU device was accepted'
    Fails {Invoke-Placement -PlacementText $nonePlacement -StartupText $noneStartup -OutputText $noneLog -SelectedDeviceLikeLines 1} 'the native selected-device count was ignored for a realistic log'
    $ignoredFull=$ignoredLog+"`nload_tensors: Vulkan0 model buffer size = 15000.00 MiB`nllama_kv_cache: Vulkan0 KV buffer size = 512.00 MiB"
    Fails {Invoke-Placement -PlacementText ($nonePlacement+"`nload_tensors: Vulkan0 model buffer size = 15000.00 MiB") -StartupText "kv Vulkan0 512.00`ncompute Vulkan0 80.00" -OutputText $ignoredFull} 'a fully GPU-placed log was accepted'

    # N4: refusal evidence is counts plus normalized allowlisted lines, never free text.
    $summary=Get-FastLlmCpuReferencePlacementSummary -PlacementText ($placement+"`nsecret-placement-text /private/path") `
        -StartupText ($startup+"`nsecret-startup-text") `
        -OutputText ("x Vulkan0 model buffer size = 1.00 MiB /private/x`nllama_prepare_model_devices: using device Vulkan0 (AMD Radeon RX 7900 XTX) (0000:03:00.0) - 1 MiB free") `
        -SelectedDeviceLikeLines 1 -OutputTruncated $true
    $summaryJson=ConvertTo-Json -InputObject $summary -Depth 6
    Assert ($summary.gpuBufferLineCount -eq 1 -and $summary.usingDeviceLineCount -eq 1 -and $summary.selectedDeviceLikeLines -eq 1 -and $summary.outputTruncated -eq $true -and
        @($summary.placementLines).Count -eq 2 -and @($summary.startupLines).Count -eq 2) 'placement summary counts wrong'
    Assert (-not ($summaryJson -match 'secret|/private|AMD Radeon')) 'placement summary retained free text'
    $emptySummary=Get-FastLlmCpuReferencePlacementSummary -PlacementText ''
    Assert (@($emptySummary.placementLines).Count -eq 0 -and $emptySummary.gpuBufferLineCount -eq 0) 'empty placement summary wrong'

    # --- Ready-state assertion and binding ---
    function New-CpuLabState {
        $args=@('--model','<verified-model>','--offline','--no-mmproj','--spec-type','none','--alias',$fixed.modelId,'--host','127.0.0.1','--port','18089',
            '--cors-origins','localhost','--no-cors-credentials','--ctx-size','32768','--parallel','1','--n-gpu-layers','0','--fit','off','--fit-target','768',
            '--device','none','--split-mode','none','--no-op-offload','--no-kv-offload','--flash-attn','auto','--cache-type-k','f16','--cache-type-v','f16',
            '--jinja','--metrics','--log-verbosity','4','--no-agent','--no-ui')
        [pscustomobject]@{schemaVersion=1;kind=$fixed.stateKind;active=$true;phase='lab-ready';runId=('c'*32);endpoint='http://127.0.0.1:18089/v1'
            modelId=$fixed.modelId;modelSha256=$fixed.modelSha256;engineVersion='b10698'
            processIdentity=[pscustomobject]@{pid=77;startUtcTicks=638000000000000000}
            canary=[pscustomobject]@{modelIdentity=$true;repeatableToken=$true;synchronousChat=$true;streaming=$true;effectiveContext=32768;semanticCorrectnessQualified=$false}
            startupDiagnostics=[pscustomobject]@{status='captured';reportedFlashAttentionMode='auto';reportedFlashAttentionResolved=$true}
            placement=[pscustomobject]@{reportedGpuLayers=0;reportedTotalLayers=65;cpuModelBufferMiB=15700.5;gpuBufferLinesObserved=0}
            recipe=[pscustomobject]@{device='none';gpuLayers=0;contextSize=32768;slots=1;engineSha256=$fixed.engineSha256;catalogSha256=$fixed.catalogSha256;requestedArguments=$args}}
    }
    $good=New-CpuLabState
    $binding=Assert-FastLlmCpuReferenceState -State $good
    Assert ($binding -cmatch '^[0-9a-f]{64}$' -and (Assert-FastLlmCpuReferenceState -State (New-CpuLabState) -ExpectedBinding $binding) -ceq $binding) 'ready state or binding rejected'
    $mutations=[ordered]@{
        'inactive'={param($s)$s.active=$false}
        'phase'={param($s)$s.phase='lab-checking'}
        'kind'={param($s)$s.kind='fastllm-offload-lab-run'}
        'endpoint'={param($s)$s.endpoint='http://127.0.0.1:8080/v1'}
        'model'={param($s)$s.modelId='qwen3.8-27b-ud-q5-k-m'}
        'model hash'={param($s)$s.modelSha256=('0'*64)}
        'engine hash'={param($s)$s.recipe.engineSha256=('0'*64)}
        'catalog hash'={param($s)$s.recipe.catalogSha256=('0'*64)}
        'context'={param($s)$s.recipe.contextSize=8192}
        'slots'={param($s)$s.recipe.slots=2}
        'gpu layers'={param($s)$s.placement.reportedGpuLayers=1}
        'gpu buffer lines'={param($s)$s.placement.gpuBufferLinesObserved=1}
        'cpu buffer'={param($s)$s.placement.cpuModelBufferMiB=0}
        'canary'={param($s)$s.canary.streaming=$false}
        'canary qualified'={param($s)$s.canary.semanticCorrectnessQualified=$true}
        'pid'={param($s)$s.processIdentity.pid=0}
        'device arg'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | ForEach-Object {if($_ -ceq 'none'){'Vulkan0'}else{$_}})}
        'port arg'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | ForEach-Object {if($_ -ceq '18089'){'8080'}else{$_}})}
        'missing no-kv-offload'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | Where-Object {$_ -cne '--no-kv-offload'})}
        'missing no-op-offload'={param($s)$s.recipe.requestedArguments=@($s.recipe.requestedArguments | Where-Object {$_ -cne '--no-op-offload'})}
    }
    foreach($name in $mutations.Keys){
        $state=New-CpuLabState
        & $mutations[$name] $state
        Fails {Assert-FastLlmCpuReferenceState -State $state} "ready state accepted mutation: $name"
    }
    $flashChanged=New-CpuLabState;$flashChanged.startupDiagnostics.reportedFlashAttentionResolved=$false
    Fails {Assert-FastLlmCpuReferenceState -State $flashChanged -ExpectedBinding $binding} 'a changed flash-attention resolution kept the binding'
    $other=New-CpuLabState;$other.runId=('d'*32)
    Fails {Assert-FastLlmCpuReferenceState -State $other -ExpectedBinding $binding} 'run-ID change kept the binding'
    $moved=New-CpuLabState;$moved.processIdentity.startUtcTicks=638000000000000001
    Fails {Assert-FastLlmCpuReferenceState -State $moved -ExpectedBinding $binding} 'start-tick change kept the binding'

    # --- Canary with mocked requests ---
    $script:canaryCalls=@()
    $script:canaryMode='ok'
    $canaryRequest={param($Path,$Body,$Timeout)
        $script:canaryCalls+=,@($Path,$Timeout)
        switch($Path){
            '/v1/models'{if($script:canaryMode -ceq 'wrong-model'){return [pscustomobject]@{Status=200;Body='{"data":[{"id":"other"}]}'}};return [pscustomobject]@{Status=200;Body='{"data":[{"id":"m"}]}'}}
            '/props'{$ctx=$(if($script:canaryMode -ceq 'wrong-context'){4096}else{32768});return [pscustomobject]@{Status=200;Body=('{"default_generation_settings":{"n_ctx":'+$ctx+'},"total_slots":1}')}}
            '/completion'{$script:tokenCounter=$(if(Test-Path variable:script:tokenCounter){$script:tokenCounter+1}else{1});$token=$(if($script:canaryMode -ceq 'unrepeatable'){$script:tokenCounter}else{7});return [pscustomobject]@{Status=200;Body=('{"tokens":['+$token+']}')}}
            '/v1/chat/completions'{
                if($Body.stream -eq $true){
                    $sse=$(if($script:canaryMode -ceq 'no-done'){"data: {`"choices`":[{`"delta`":{`"content`":`"Hi`"}}]}`n`n"}else{"data: {`"choices`":[{`"delta`":{`"content`":`"Hi`"}}]}`n`ndata: [DONE]`n`n"})
                    return [pscustomobject]@{Status=200;Body=$sse}
                }
                return [pscustomobject]@{Status=200;Body='{"choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}]}'}
            }
        }
        throw 'unexpected path'
    }
    $result=Test-FastLlmCpuReferenceApiCanary -BaseUrl 'http://127.0.0.1:1' -ModelId 'm' -ContextSize 32768 -Request $canaryRequest -TimeoutMs 150000
    Assert ($result.modelIdentity -and $result.repeatableToken -and $result.synchronousChat -and $result.streaming -and -not $result.semanticCorrectnessQualified -and $result.effectiveContext -eq 32768) 'valid canary failed'
    Assert (@($script:canaryCalls | Where-Object {$_[0] -ceq '/completion'}).Count -eq 2 -and @($script:canaryCalls | Where-Object {$_[1] -eq 150000}).Count -eq 4) 'canary request pattern or CPU timeout changed'
    foreach($mode in @('wrong-model','wrong-context','unrepeatable','no-done')){
        $script:canaryMode=$mode;$script:tokenCounter=0
        Fails {Test-FastLlmCpuReferenceApiCanary -BaseUrl 'http://127.0.0.1:1' -ModelId 'm' -ContextSize 32768 -Request $canaryRequest} "canary accepted $mode"
    }

    # --- Start-FastLlmCpuReferenceLab preflight refusals with mocks: nothing installs, downloads or launches ---
    $startPreflight={
        param($Source,$Catalog,$Artifact,$Lab,$Scenario)
        . $Source
        $global:CpuRefInstallCalls=0;$global:CpuRefSupervised=0
        function Install-FastLlmEngines {$global:CpuRefInstallCalls++}
        function Install-FastLlmModel {$global:CpuRefInstallCalls++}
        function Save-FastLlmVerifiedFile {$global:CpuRefInstallCalls++}
        function Write-FastLlmModelConsentReceipt {$global:CpuRefInstallCalls++}
        function Invoke-WebRequest {$global:CpuRefInstallCalls++}
        function Invoke-FastLlmCpuReferenceLabSupervisor {$global:CpuRefSupervised++;0}
        function Assert-FastLlmCpuReferenceHost {}
        function Enter-FastLlmOperation {
            param($Root)
            $lockStub=[pscustomobject]@{}
            Add-Member -InputObject $lockStub -MemberType ScriptMethod -Name Dispose -Value {}
            return $lockStub
        }
        function Test-FastLlmEngineInstallation {param($InstallRoot,$EngineVersion,$BackendKey,$Asset) return [bool]$Scenario.engineVerified}
        function Get-FastLlmEngineExecutable {param($InstallRoot,$EngineVersion,$BackendKey,$EntryPoint) return [string]$Scenario.enginePath}
        function Get-FileHash {
            param([string]$LiteralPath,[string]$Algorithm='SHA256')
            if($Scenario.engineHash -and $LiteralPath -ceq [string]$Scenario.enginePath){return [pscustomobject]@{Hash=([string]$Scenario.engineHash).ToUpperInvariant()}}
            return Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
        }
        $message='no exception'
        try{Start-FastLlmCpuReferenceLab -ArtifactRoot $Artifact -LabRunRoot $Lab -CatalogPath $Catalog -LoadTimeoutSeconds 30 | Out-Null}
        catch{$message=[string]$_.Exception.Message}
        return [pscustomobject]@{message=$message;installs=[int]$global:CpuRefInstallCalls;supervised=[int]$global:CpuRefSupervised}
    }
    $preflightRoot=Join-Path $tempRoot 'preflight'
    $preArtifact=Join-Path $preflightRoot 'artifacts'
    $preLab=Join-Path $preflightRoot 'lab'
    $preModels=Join-Path $preArtifact 'models'
    $null=New-Item -ItemType Directory -Path $preModels,$preLab -Force
    $fakeEngine=Join-Path $preflightRoot 'llama-server-fake.exe'
    [IO.File]::WriteAllText($fakeEngine,'not an engine')
    $modelFile=Join-Path $preModels ([string]$entry.model.file)
    $scenarios=[ordered]@{
        'engine not verified'=@{engineVerified=$false;enginePath=$fakeEngine;engineHash=$null;catalog=$catalogPath;artifact=$preArtifact;pattern='not installed and verified'}
        'engine hash differs'=@{engineVerified=$true;enginePath=$fakeEngine;engineHash=('f'*64);catalog=$catalogPath;artifact=$preArtifact;pattern='differs from the protocol-bound engine'}
        'model absent'=@{engineVerified=$true;enginePath=$fakeEngine;engineHash=$fixed.engineSha256;catalog=$catalogPath;artifact=$preArtifact;pattern='absent or failed verification'}
        'model wrong size'=@{engineVerified=$true;enginePath=$fakeEngine;engineHash=$fixed.engineSha256;catalog=$catalogPath;artifact=$preArtifact;pattern='absent or failed verification';model='tiny'}
        'catalog changed'=@{engineVerified=$true;enginePath=$fakeEngine;engineHash=$fixed.engineSha256;catalog=$changedCatalog;artifact=$preArtifact;pattern='differs from the protocol-bound catalog'}
        'overlapping roots'=@{engineVerified=$true;enginePath=$fakeEngine;engineHash=$fixed.engineSha256;catalog=$catalogPath;artifact=$preLab;pattern='non-overlapping'}
    }
    foreach($name in $scenarios.Keys){
        $scenario=$scenarios[$name]
        if(Test-Path -LiteralPath $modelFile){Remove-Item -LiteralPath $modelFile -Force}
        if($scenario.ContainsKey('model')){[IO.File]::WriteAllText($modelFile,'tiny')}
        $lab=$preLab
        if($name -ceq 'overlapping roots'){$lab=Join-Path $preLab 'nested'}
        $outcome=& $repoModule $startPreflight $source $scenario.catalog $scenario.artifact $lab $scenario
        Assert ($outcome.message -match $scenario.pattern) ("Start preflight refusal '$name' had the wrong reason: "+$outcome.message)
        Assert ($outcome.installs -eq 0 -and $outcome.supervised -eq 0) "Start preflight '$name' installed, downloaded or launched something"
    }
    if(Test-Path -LiteralPath $modelFile){Remove-Item -LiteralPath $modelFile -Force}
    $startText=$text.Substring($text.IndexOf('function Start-FastLlmCpuReferenceLab {'),$text.IndexOf('function Invoke-FastLlmCpuReferenceLabSupervisor {')-$text.IndexOf('function Start-FastLlmCpuReferenceLab {'))
    Assert (-not ($startText -match 'Install-|Invoke-WebRequest|Invoke-RestMethod|Save-FastLlmVerifiedFile|Write-FastLlmModelConsentReceipt|DownloadFile|Start-BitsTransfer')) 'Start-FastLlmCpuReferenceLab contains an acquisition path'
    Assert ($startText.IndexOf('Assert-FastLlmCpuReferenceMemoryBudget') -lt $startText.IndexOf('Invoke-FastLlmCpuReferenceLabSupervisor')) 'memory preflight is not ahead of the launch'

    # --- Native bounded capture and supervisor behaviour (mock stand-in, no model) ---
    & $repoModule {Initialize-FastLlmProcessHost}
    $pwsh=(Get-Process -Id $PID).Path
    $mock=Join-Path $PSScriptRoot 'helpers/cpu-reference-mock-server.ps1'
    $worker=Join-Path $PSScriptRoot 'helpers/cpu-reference-supervisor-worker.ps1'
    $labPort=18189
    function New-MockPlan([string]$Mode){
        [pscustomobject]@{
            model=[pscustomobject]@{id='lab-mock';sha256=('a'*64);cacheTypeK='f16';cacheTypeV='f16'}
            enginePath=$pwsh;modelPath='mock-model'
            serverArguments=@('-NoLogo','-NoProfile','-File',$mock,'-Port',[string]$labPort,'-Mode',$Mode,'-Model','lab-mock','-Context','1024')
            endpoint=('http://127.0.0.1:'+$labPort+'/v1');contextSize=1024
            memoryPreflight=[pscustomobject]@{fitVerified=$false};catalogSha256=('b'*64);engineSha256=('c'*64)}
    }
    function Wait-ProcessGone([int]$ProcessId,[long]$StartTicks){
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while($clock.ElapsedMilliseconds -lt 5000){
            $probe=$null
            try{
                $probe=[Diagnostics.Process]::GetProcessById($ProcessId)
                if($probe.HasExited -or [long]$probe.StartTime.ToUniversalTime().Ticks -ne $StartTicks){return $true}
            }catch [ArgumentException]{return $true}
            finally{if($probe){$probe.Dispose()}}
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
    $rejections=[ordered]@{'vulkan-model'='GPU model, KV or compute buffer';'vulkan-kv'='GPU model, KV or compute buffer';
        'vulkan-compute'='GPU model, KV or compute buffer';'gpu-layers'='nonzero GPU layer';'no-cpu-buffer'='Missing CPU model-buffer';
        'no-offload-line'='Missing or ambiguous offload-layer';'using-device'='selected GPU device';'vulkan-host'='GPU model, KV or compute buffer';
        'no-cpu-kv'='Missing CPU KV or compute';'no-cpu-compute'='Missing CPU KV or compute'}
    foreach($mode in $rejections.Keys){
        $runRoot=Join-Path $tempRoot ('reject-'+$mode)
        $lock=& $repoModule {param($R) Enter-FastLlmOperation $R} $runRoot
        try{
            $mockPlan=New-MockPlan $mode
            $reason='no exception'
            try{& $repoModule {param($S,$P,$R,$Port) . $S; Invoke-FastLlmCpuReferenceLabSupervisor -Plan $P -LabRunRoot $R -LoadTimeoutSeconds 20 -Port $Port -OwnerCheck {param($ChildPid,$LabPort)}} $source $mockPlan $runRoot $labPort}
            catch{$reason=[string]$_.Exception.Message}
            Assert ($reason -match [regex]::Escape($rejections[$mode])) ("supervisor rejected mock mode $mode for the wrong reason: $reason")
            $status=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $runRoot 'state/status.json')))
            Assert ($status.kind -ceq $fixed.stateKind -and $status.phase -ceq 'lab-failed' -and $null -eq $status.placement -and $null -eq $status.canary -and $status.processIdentity.pid -gt 0) "placement rejection for $mode did not fail before the canary"
            Assert (Wait-ProcessGone ([int]$status.processIdentity.pid) ([long]$status.processIdentity.startUtcTicks)) "child was not stopped after rejection of $mode"
            # N4: the refusal keeps counts and normalized lines only.
            $rawStatus=[IO.File]::ReadAllText((Join-Path $runRoot 'state/status.json'))
            Assert ($null -ne $status.placementRefusal -and -not [string]::IsNullOrEmpty([string]$status.placementRefusal.reason) -and
                $null -ne $status.placementRefusal.summary.placementLines -and $status.startupDiagnostics.reportedFlashAttentionMode -ceq 'auto') "refusal evidence missing for $mode"
            Assert (-not ($rawStatus -match 'AMD Radeon|untrusted')) "free text retained in the refusal state for $mode"
            if($mode -ceq 'using-device'){Assert ($status.placementRefusal.summary.usingDeviceLineCount -ge 1 -and $status.placementRefusal.summary.selectedDeviceLikeLines -ge 1) 'using-device counts missing'}
            if($mode -ceq 'vulkan-model'){Assert ($status.placementRefusal.summary.gpuBufferLineCount -ge 1) 'GPU buffer count missing'}
        }finally{$lock.Dispose()}
    }
    # N6: the child must own the listener before the canary; a failed owner check refuses before any request.
    $runRoot=Join-Path $tempRoot 'owner-refused'
    $lock=& $repoModule {param($R) Enter-FastLlmOperation $R} $runRoot
    try{
        $reason='no exception'
        try{& $repoModule {param($S,$P,$R,$Port) . $S; Invoke-FastLlmCpuReferenceLabSupervisor -Plan $P -LabRunRoot $R -LoadTimeoutSeconds 20 -Port $Port -OwnerCheck {param($ChildPid,$LabPort) throw 'The supervised CPU reference child does not own the loopback listener.'}} $source (New-MockPlan 'cpu') $runRoot $labPort}
        catch{$reason=[string]$_.Exception.Message}
        Assert ($reason -match 'does not own the loopback listener') ('owner refusal wrong: '+$reason)
        $status=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $runRoot 'state/status.json')))
        Assert ($status.phase -ceq 'lab-failed' -and $null -eq $status.placement -and $null -eq $status.canary -and $null -eq $status.placementRefusal) 'owner refusal did not fail before placement and canary'
        Assert (Wait-ProcessGone ([int]$status.processIdentity.pid) ([long]$status.processIdentity.startUtcTicks)) 'child survived the owner refusal'
    }finally{$lock.Dispose()}
    Assert ($text.Contains('Assert-FastLlmCpuReferenceListenerOwner') -and $text.IndexOf('OwnerCheck ([int]$child.Process.Id)') -lt $text.IndexOf('Test-FastLlmCpuReferenceApiCanary -BaseUrl $baseUrl')) 'owner check is not ahead of the canary'
    $runRoot=Join-Path $tempRoot 'success'
    $lock=& $repoModule {param($R) Enter-FastLlmOperation $R} $runRoot
    $host1=New-Object Bitworks.FastLlm.ProcessHost
    try{
        $planPath=Join-Path $tempRoot 'plan.json'
        [IO.File]::WriteAllText($planPath,(New-MockPlan 'cpu' | ConvertTo-Json -Depth 8))
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$pwsh
        $info.Arguments=& $repoModule {param($A) Join-FastLlmProcessArguments $A} @('-NoLogo','-NoProfile','-File',$worker,'-PlanPath',$planPath,'-LabRunRoot',$runRoot,'-SourcePath',$source,'-ModulePath',(Join-Path $repo 'src/FastLlm.psm1'),'-Port',[string]$labPort)
        $host1.Start($info)
        $ready=$null;$lastError='none';$clock=[Diagnostics.Stopwatch]::StartNew()
        while($clock.Elapsed.TotalSeconds -lt 40 -and $null -eq $ready){
            if($host1.Process.HasExited){throw ('Worker exited before lab-ready: '+$host1.Snapshot())}
            $state=$null
            try{$state=& $repoModule {param($S,$R) . $S; Get-FastLlmCpuReferenceLabStatus -LabRunRoot $R} $source $runRoot}catch{$lastError=[string]$_.Exception.Message}
            if($null -ne $state){
                if($state.phase -ceq 'lab-ready'){$ready=$state}
                if($state.phase -ceq 'lab-failed'){throw 'worker lab-failed'}
            }
            if($null -eq $ready){Start-Sleep -Milliseconds 150}
        }
        Assert ($null -ne $ready -and $ready.active -and $ready.kind -ceq $fixed.stateKind) ('CPU mock did not reach active lab-ready: '+$(if($null -eq $ready){'null; '+$lastError}else{[string]$ready.phase}))
        Assert ($ready.placement.reportedGpuLayers -eq 0 -and $ready.placement.reportedTotalLayers -eq 41 -and $ready.placement.cpuModelBufferMiB -eq 1200 -and
            $ready.placement.gpuBufferLinesObserved -eq 0 -and $ready.placement.cpuKvBufferLines -eq 1 -and $ready.placement.cpuComputeBufferLines -eq 1 -and
            $ready.startupDiagnostics.reportedFlashAttentionMode -ceq 'auto' -and $ready.startupDiagnostics.reportedFlashAttentionResolved -eq $true -and $ready.canary.streaming -and -not $ready.performanceQualified -and -not $ready.physicalResidencyVerified) 'ready placement or qualification state wrong'
        Assert ($ready.recipe.device -ceq 'none' -and $ready.recipe.gpuLayers -eq 0 -and $ready.recipe.opOffload -eq $false -and $ready.recipe.kvOffload -eq $false) 'lab recipe state wrong'
        & $repoModule {param($S,$R) . $S; Request-FastLlmCpuReferenceLabStop -LabRunRoot $R} $source $runRoot | Out-Null
        Assert ($host1.Process.WaitForExit(20000)) 'supervisor worker ignored the run-scoped stop'
        Assert ($host1.Process.ExitCode -eq 0) 'supervisor worker did not stop cleanly'
        $final=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $runRoot 'state/status.json')))
        Assert ($final.phase -ceq 'lab-stopped' -and -not (Test-Path (Join-Path $runRoot ('state/stop-'+$final.runId)))) 'stop request was not honoured and cleaned up'
        Assert (Wait-ProcessGone ([int]$final.processIdentity.pid) ([long]$final.processIdentity.startUtcTicks)) 'owned child survived the stop'
        Fails {& $repoModule {param($S,$R) . $S; Request-FastLlmCpuReferenceLabStop -LabRunRoot $R} $source $runRoot} 'a stop was accepted without an active run'
    }finally{
        $host1.Dispose()
        $lock.Dispose()
    }
}finally{
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force}
}
Write-Host "$script:passes CPU reference lab focused assertions passed. Native Windows loading and placement remain unqualified."
