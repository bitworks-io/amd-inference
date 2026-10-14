#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -PassThru -ErrorAction Stop
$source=Join-Path $root 'src/FastLlm.VulkanVidmemTrial.ps1'
$fitSource=Join-Path $root 'src/FastLlm.VulkanFitTrial.ps1'
$catalog=Join-Path $root 'config/catalog.json'
$count=0
function Check([bool]$ok,[string]$message){if(-not $ok){throw $message};$script:count++}
function Reject([scriptblock]$action,[string]$message){$failed=$false;try{& $action | Out-Null}catch{$failed=$true};Check $failed $message}
$ovName='GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'
$sandbox=[pscustomobject]@{appData=(Join-Path ([IO.Path]::GetTempPath()) 'vidmem-appdata');programData=(Join-Path ([IO.Path]::GetTempPath()) 'vidmem-programdata')}
$enginePath=Join-Path ([IO.Path]::GetTempPath()) 'engine/llama-server.exe'

# Pre-existing GGML_*/LLAMA_*/VK_* values in the parent environment must never leak into either variant.
$saved=@{}
foreach($n in @($ovName,'GGML_VK_DISABLE_COOPMAT','GGML_FOO','LLAMA_ARG_PORT','VK_ICD_FILENAMES','ggml_vk_disable_host_visible_vidmem','ggml_lower_probe','llama_arg_lower','vk_lower_probe')){$saved[$n]=[Environment]::GetEnvironmentVariable($n)}
try{
    [Environment]::SetEnvironmentVariable($ovName,'1')
    [Environment]::SetEnvironmentVariable('GGML_VK_DISABLE_COOPMAT','1')
    [Environment]::SetEnvironmentVariable('GGML_FOO','x')
    [Environment]::SetEnvironmentVariable('LLAMA_ARG_PORT','9999')
    [Environment]::SetEnvironmentVariable('VK_ICD_FILENAMES','/tmp/x')
    [Environment]::SetEnvironmentVariable('ggml_vk_disable_host_visible_vidmem','1')
    [Environment]::SetEnvironmentVariable('ggml_lower_probe','1')
    [Environment]::SetEnvironmentVariable('llama_arg_lower','1')
    [Environment]::SetEnvironmentVariable('vk_lower_probe','1')
    $result=& $module {param($path,$fitPath,$catalogPath,$sandbox,$engine)
        . $path
        . $fitPath
        $model=Get-FastLlmVulkanVidmemModel -CatalogPath $catalogPath -Tuple 'xtx-q4-32k'
        $args=@(New-FastLlmVulkanVidmemArguments -ModelPath 'model.gguf' -Tuple 'xtx-q4-32k')
        $fitOn=@(New-FastLlmVulkanFitArguments -ModelPath 'model.gguf' -ModelId $model.model.id -FitMode on)
        $infoDefault=New-FastLlmVulkanVidmemStartInfo -EnginePath $engine -Arguments $args -Sandbox $sandbox -Variant 'default'
        $infoOverride=New-FastLlmVulkanVidmemStartInfo -EnginePath $engine -Arguments $args -Sandbox $sandbox -Variant 'disable-host-visible-vidmem'
        $envOf={param($i) $h=@{};foreach($k in @($i.EnvironmentVariables.Keys)){$h[[string]$k]=[string]$i.EnvironmentVariables[$k]};$h}
        $sandbox2=[pscustomobject]@{appData=(Join-Path ([IO.Path]::GetTempPath()) 'other-appdata');programData=(Join-Path ([IO.Path]::GetTempPath()) 'other-programdata')}
        $infoOverride2=New-FastLlmVulkanVidmemStartInfo -EnginePath $engine -Arguments $args -Sandbox $sandbox2 -Variant 'disable-host-visible-vidmem'
        $runChild={param($variant)
            if($env:OS -eq 'Windows_NT'){$exe=Join-Path $env:SystemRoot 'System32\cmd.exe';$argv=@('/c','set')}else{$exe='/usr/bin/env';$argv=@()}
            $ci=New-FastLlmVulkanVidmemStartInfo -EnginePath $exe -Arguments $argv -Sandbox $sandbox -Variant $variant
            $ci.UseShellExecute=$false;$ci.RedirectStandardOutput=$true;$ci.CreateNoWindow=$true
            $proc=[Diagnostics.Process]::Start($ci)
            try{$text=$proc.StandardOutput.ReadToEnd();$proc.WaitForExit()}finally{$proc.Dispose()}
            @($text -split "`r?`n"|Where-Object {$_ -match '^(?i)ggml_'})}
        return [pscustomobject]@{childDefault=@(& $runChild 'default');childOverride=@(& $runChild 'disable-host-visible-vidmem');
            obsDefault=(Get-FastLlmVulkanVidmemObservedEnvironment -Info $infoDefault);
            obsOverride=(Get-FastLlmVulkanVidmemObservedEnvironment -Info $infoOverride);
            obsOverride2=(Get-FastLlmVulkanVidmemObservedEnvironment -Info $infoOverride2);
            sha=Get-FastLlmVulkanVidmemTrialSourceSha256;model=$model.model;args=$args;fitOn=$fitOn;
            defaultEnv=(& $envOf $infoDefault);overrideEnv=(& $envOf $infoOverride);
            defaultArgs=$infoDefault.Arguments;overrideArgs=$infoOverride.Arguments;
            ovDefault=(Get-FastLlmVulkanVidmemEnvironmentOverride -Variant 'default');
            ovOverride=(Get-FastLlmVulkanVidmemEnvironmentOverride -Variant 'disable-host-visible-vidmem');
            port=(Get-FastLlmVulkanVidmemPort)}
    } $source $fitSource $catalog $sandbox $enginePath
}finally{foreach($n in $saved.Keys){[Environment]::SetEnvironmentVariable($n,$saved[$n])}}

# Identity and argument parity.
Check ($result.sha -ceq (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()) 'Trial source digest changed.'
Check ($result.model.id -ceq 'qwen3.8-27b-ud-q4-k-m' -and $result.model.sha256 -ceq '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482') 'Wrong Qwen artifact.'
Check ($result.port -eq 18090) 'Declared private port changed.'
$deltas=@(for($i=0;$i -lt $result.args.Count;$i++){if($result.args[$i] -cne $result.fitOn[$i]){$i}})
Check ($result.args.Count -eq $result.fitOn.Count -and $deltas.Count -eq 1 -and $result.args[$deltas[0]-1] -ceq '--port' -and
       $result.args[$deltas[0]] -ceq '18090' -and $result.fitOn[$deltas[0]] -ceq '18083') 'Arguments differ from the normal Q4 recipe beyond the port.'
$joined=$result.args -join '|'
Check ($joined.Contains('--fit|on|--fit-target|768') -and $joined.Contains('--ctx-size|32768') -and $joined.Contains('--parallel|1') -and
       $joined.Contains('--host|127.0.0.1') -and $joined.Contains('--n-gpu-layers|all') -and $joined.Contains('--cache-type-k|f16')) 'Normal Q4 recipe contract missing.'
Check (@($result.args|Where-Object {$_ -ceq '--fit'}).Count -eq 1 -and @($result.args|Where-Object {$_ -ceq '--port'}).Count -eq 1) 'Duplicate fit/port flag.'
Check ($result.defaultArgs -ceq $result.overrideArgs) 'Variants must launch with identical arguments.'
Check (-not ($result.args -join ' ').Contains('GGML')) 'Override leaked into argv.'

# Override present/absent from the actual start info; sanitisation precedes the override.
Check ($result.ovDefault.Count -eq 0) 'Default variant environmentOverride must be an empty map.'
Check ($result.ovOverride.Count -eq 1 -and $result.ovOverride[$ovName] -ceq '1') 'Override map must be exactly the single variable.'
Check (@($result.defaultEnv.Keys|Where-Object {$_ -like 'GGML_*'}).Count -eq 0) 'Default start info carries a GGML_* variable (parent leak).'
Check (-not $result.defaultEnv.ContainsKey($ovName)) 'Parent override leaked into the default variant.'
Check (-not $result.defaultEnv.ContainsKey('LLAMA_ARG_PORT') -and -not $result.defaultEnv.ContainsKey('VK_ICD_FILENAMES')) 'Parent LLAMA_/VK_ leaked into default start info.'
Check ($result.overrideEnv.ContainsKey($ovName) -and $result.overrideEnv[$ovName] -ceq '1') 'Override missing from the override start info.'
$ggmlOv=@($result.overrideEnv.Keys|Where-Object {$_ -like 'GGML_*'})
Check ($ggmlOv.Count -eq 1 -and $ggmlOv[0] -ceq $ovName) 'Override start info must carry only the single GGML_* variable (parent GGML_FOO/COOPMAT leaked).'
Check (-not $result.overrideEnv.ContainsKey('LLAMA_ARG_PORT') -and -not $result.overrideEnv.ContainsKey('VK_ICD_FILENAMES')) 'Parent LLAMA_/VK_ leaked into override start info.'
$lowerNames=@($result.defaultEnv.Keys+$result.overrideEnv.Keys|Where-Object {$_ -like 'ggml_*' -or $_ -like 'llama_*' -or $_ -like 'vk_*'})
Check ($lowerNames.Count -eq 1 -and $lowerNames[0] -ceq $ovName) 'Lowercase parent GGML_/LLAMA_/VK_ names leaked into a start info.'
Check (-not $result.defaultEnv.ContainsKey('ggml_vk_disable_host_visible_vidmem') -and -not $result.defaultEnv.ContainsKey($ovName)) 'Lowercase override name leaked into the default variant.'
Check ($result.childDefault.Count -eq 0) 'A real child process of the default variant received a GGML_* variable.'
Check ($result.childOverride.Count -eq 1 -and ([string]$result.childOverride[0]).Trim() -ceq 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1') 'A real child process of the override variant did not receive exactly the override.'
Check ($result.obsDefault.ggmlEnvironment.Count -eq 0 -and $result.obsOverride.ggmlEnvironment.Count -eq 1 -and $result.obsOverride.ggmlEnvironment[$ovName] -ceq '1') 'Observed GGML_* environment wrong.'
Check ($result.obsDefault.launchEnvironmentSha256 -ceq $result.obsOverride.launchEnvironmentSha256 -and $result.obsOverride.launchEnvironmentSha256 -ceq $result.obsOverride2.launchEnvironmentSha256) 'Base launch-environment digest differs across arms.'
Check ($result.obsDefault.launchEnvironmentWithOverrideSha256 -ceq $result.obsDefault.launchEnvironmentSha256 -and $result.obsOverride.launchEnvironmentWithOverrideSha256 -cne $result.obsDefault.launchEnvironmentWithOverrideSha256 -and
       $result.obsOverride.launchEnvironmentWithOverrideSha256 -ceq $result.obsOverride2.launchEnvironmentWithOverrideSha256) 'Override-inclusive digest does not isolate the single override or depends on sandbox paths.'
Check ($result.obsDefault.launchArgumentsSha256 -ceq $result.obsOverride.launchArgumentsSha256) 'Argument digest differs across variants.'
Check ($result.defaultEnv['APPDATA'] -ceq $sandbox.appData -and $result.overrideEnv['PROGRAMDATA'] -ceq $sandbox.programData) 'Sandbox config roots missing.'

# Refusals.
foreach($bad in @('Default','on','disable-host-visible-VIDMEM','','default ','GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1','disable-coopmat')){
    Reject {& $module {param($p,$v) . $p;Assert-FastLlmVulkanVidmemVariant $v} $source $bad} "Invalid variant '$bad' accepted."
    Reject {& $module {param($p,$v) . $p;Get-FastLlmVulkanVidmemEnvironmentOverride -Variant $v} $source $bad} "Override map built for invalid variant '$bad'."
}
foreach($port in @(8080,18080,18082,18083,18084,18085,18086,18087,18088,18089,18091,0)){
    Reject {& $module {param($p,$n) . $p;New-FastLlmVulkanVidmemArguments -ModelPath 'm' -Tuple 'xtx-q4-32k' -Port $n} $source $port} "Colliding or undeclared port $port accepted."
}
# Mismatch between start info and variant is a hard failure.
$mismatch=& $module {param($path,$sandbox,$engine)
    . $path
    $args=@(New-FastLlmVulkanVidmemArguments -ModelPath 'm' -Tuple 'xtx-q4-32k')
    $d=New-FastLlmVulkanVidmemStartInfo -EnginePath $engine -Arguments $args -Sandbox $sandbox -Variant 'default'
    $o=New-FastLlmVulkanVidmemStartInfo -EnginePath $engine -Arguments $args -Sandbox $sandbox -Variant 'disable-host-visible-vidmem'
    $out=@{}
    $out.defaultAsOverride=try{Assert-FastLlmVulkanVidmemStartInfo -Info $d -Variant 'disable-host-visible-vidmem';$false}catch{$true}
    $out.overrideAsDefault=try{Assert-FastLlmVulkanVidmemStartInfo -Info $o -Variant 'default';$false}catch{$true}
    $d.EnvironmentVariables['GGML_OTHER']='1'
    $out.extraGgmlDefault=try{Assert-FastLlmVulkanVidmemStartInfo -Info $d -Variant 'default';$false}catch{$true}
    $o.EnvironmentVariables[ 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM']='0'
    $out.wrongValue=try{Assert-FastLlmVulkanVidmemStartInfo -Info $o -Variant 'disable-host-visible-vidmem';$false}catch{$true}
    $o.EnvironmentVariables['GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM']='1';$o.EnvironmentVariables['LLAMA_ARG_X']='1'
    $out.llamaLeak=try{Assert-FastLlmVulkanVidmemStartInfo -Info $o -Variant 'disable-host-visible-vidmem';$false}catch{$true}
    $out
} $source $sandbox $enginePath
Check ($mismatch.defaultAsOverride) 'Missing override accepted for override variant.'
Check ($mismatch.overrideAsDefault) 'Override accepted for default variant.'
Check ($mismatch.extraGgmlDefault) 'Extra GGML_* accepted for default variant.'
Check ($mismatch.wrongValue) 'Override value other than 1 accepted.'
Check ($mismatch.llamaLeak) 'Unsanitised LLAMA_* accepted.'

# Placement evidence is reused from the fit lane approach.
$ev=& $module {param($p) . $p
    ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text "load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 14925.00 MiB`nload_tensors: CPU_Mapped model buffer size = 682.03 MiB" -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 16464440224 -AllowHostModelBuffer $true} $source
Check ($ev.reportedGpuLayers -eq 66 -and $ev.hostModelBuffer.sizeMiB -eq 682.03 -and -not $ev.physicalResidencyVerified) 'Placement evidence overstated or lost.'
Reject {& $module {param($p) . $p;ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text 'load_tensors: offloaded 66/66 layers to GPU' -CpuBufferLikeLines 0 -Overflow $true -ModelBytes 1 -AllowHostModelBuffer $false} $source} 'Overflowed capture accepted.'

# State/report fields, ordering and cleanup structure.
$text=Get-Content -LiteralPath $source -Raw
Check ($text.Contains('variant=[string]$Plan.variant') -and $text.Contains('environmentOverride=$Plan.environmentOverride') -and $text.Contains('startInfoEnvironmentVerified')) 'State lacks variant/environmentOverride/start-info verification.'
Check ($text.Contains('Assert-FastLlmVulkanVidmemVariant $Variant') -and $text.Contains('environmentOverride=(Get-FastLlmVulkanVidmemEnvironmentOverride -Variant $Variant)') -and $text.Contains('arm=$Arm')) 'Plan does not carry variant and override map.'
$startInfoAt=$text.IndexOf('New-FastLlmVulkanVidmemStartInfo -EnginePath $Plan.enginePath')
$spawnAt=$text.IndexOf('$child.Start($info)')
Check ($startInfoAt -gt 0 -and $spawnAt -gt $startInfoAt) 'Start-info verification must precede spawn.'
$sanitiseAt=$text.IndexOf('Test-FastLlmEnvironmentNameRequiresClearing')
$applyAt=$text.IndexOf('Get-FastLlmVulkanVidmemEnvironmentOverride -Variant $Variant',$sanitiseAt)
Check ($sanitiseAt -gt 0 -and $applyAt -gt $sanitiseAt) 'Override must be applied after sanitisation.'
Check ($text.Contains('catch{$state.phase=''vulkan-vidmem-failed''') -and $text.Contains('$child.Dispose()') -and $text.Contains('Remove-FastLlmRuntimeSandbox $sandbox') -and $text.Contains("stop-'+`$state.runId")) 'Failure/stop cleanup of the owned child, sandbox and stop file missing.'
Check ($text.Contains('Assert-FastLlmOffloadLabHost') -and $text.Contains('Assert-FastLlmVulkanVidmemRoots') -and $text.Contains('Test-FastLlmEngineInstallation') -and
       $text.Contains('Test-FastLlmOffloadExactConsent') -and -not $text.Contains('Install-FastLlmModel')) 'Standard-user/hash verification or verify-never-acquire missing.'
Check ($text.Contains('Get-FastLlmVulkanVidmemListenerOwners -Port 18090') -and $text.Contains('Test-FastLlmApiCanary') -and $text.Contains('performanceQualified=$false')) 'Port/identity/unqualified gates wrong.'
Check ($text.Contains('kind=''fastllm-vulkan-vidmem-b10698-private-trial''')) 'Distinct private state kind missing.'
Check ($text.Contains('preStartIdle=$null') -and $text.Contains("-Stage 'before-locks'") -and $text.Contains("-Stage 'immediately-before-start'") -and $text.Contains('observedEnvironment') -and $text.Contains('modelLoadSeconds') -and $text.Contains('readyAtUtc')) 'Idle/observed-environment/timing state missing.'
$idleAt=$text.IndexOf("-Stage 'immediately-before-start'")
Check ($idleAt -gt 0 -and $idleAt -lt $spawnAt -and $text.IndexOf("-Stage 'before-locks'") -lt $text.IndexOf('Enter-FastLlmOperation $ArtifactRoot')) 'Idle checks are not ordered before the locks and before spawn.'
Check ($text.Contains('Use a fresh, non-existent Vulkan vidmem RunRoot') -and -not $text.Contains('[switch]$AllowHostModelBuffer') -and $text.Contains('allowHostModelBuffer=$true')) 'Fresh RunRoot or implicit host-buffer policy missing.'
Check ($text.Contains('Get-FastLlmVulkanVidmemPins') -and $text.Contains('pinned reviewed inputs') -and $text.Contains('Assert-FastLlmVulkanVidmemPlanParity -Tuple $Tuple') -and $text.Contains('[Parameter(Mandatory=$true)][string]$Tuple')) 'Catalog/engine pin check missing from the launch path.'

# Arm labels.
foreach($pair in @(@('A1','disable-host-visible-vidmem'),@('A2','disable-host-visible-vidmem'),@('B1','default'),@('B2','default'))){
    $null=& $module {param($p,$a,$v) . $p;Assert-FastLlmVulkanVidmemArm -Arm $a -Variant $v} $source $pair[0] $pair[1];$count++
}
foreach($pair in @(@('A1','default'),@('B1','disable-host-visible-vidmem'),@('C1','default'),@('a1','disable-host-visible-vidmem'),@('','default'))){
    Reject {& $module {param($p,$a,$v) . $p;Assert-FastLlmVulkanVidmemArm -Arm $a -Variant $v} $source $pair[0] $pair[1]} "Arm '$($pair[0])' with variant '$($pair[1])' accepted."
}
# Pins.
$pins=& $module {param($p) . $p;Get-FastLlmVulkanVidmemPins} $source
Check ($pins.producerSha256 -ceq 'c8b64fe0a2e78e3974b63a127da9ae385ca84b51fba69505ee323ab5d464a43b' -and $pins.parserSha256 -ceq 'f214f8b498eff554fe78836c6448e1f5008b0c2763e182e1f9013a575fe7028b' -and
       $pins.catalogSha256 -ceq '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6' -and $pins.engineSha256 -ceq '9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7') 'Pinned hashes changed.'
# Idle-host refusal (mocked process and port probes).
$idle=& $module {param($p) . $p
    $ok=Assert-FastLlmVulkanVidmemIdleHost -Stage 'unit' -GetInferenceProcesses {@()} -TestPortFree {param($port) $true}
    $r=@{ok=$ok}
    $r.proc=try{Assert-FastLlmVulkanVidmemIdleHost -Stage 'unit' -GetInferenceProcesses {@([pscustomobject]@{Name='llama-bench'})} -TestPortFree {param($port) $true};$false}catch{$true}
    $r.p8080=try{Assert-FastLlmVulkanVidmemIdleHost -Stage 'unit' -GetInferenceProcesses {@()} -TestPortFree {param($port) $port -ne 8080};$false}catch{$true}
    $r.p18090=try{Assert-FastLlmVulkanVidmemIdleHost -Stage 'unit' -GetInferenceProcesses {@()} -TestPortFree {param($port) $port -ne 18090};$false}catch{$true}
    $r} $source
Check ($idle.ok.verified -and $idle.ok.inferenceProcessCount -eq 0 -and $idle.ok.port8080Free -and $idle.ok.port18090Free -and $idle.ok.stage -ceq 'unit') 'Idle record fields wrong.'
Check ($idle.proc) 'Existing llama-bench/llama-server process accepted.'
Check ($idle.p8080) 'Listener on 8080 accepted.'
Check ($idle.p18090) 'Listener on 18090 accepted.'
# Port-owner lookup retries exactly once.
$retry=& $module {param($p) . $p
    $script:calls=0
    $a=Get-FastLlmVulkanVidmemListenerOwners -Port 18090 -Query {param($port) $script:calls++;if($script:calls -eq 1){throw 'transient'};@(4242)}
    $first=@{owners=@($a);calls=$script:calls}
    $script:calls=0
    $failed=try{Get-FastLlmVulkanVidmemListenerOwners -Port 18090 -Query {param($port) $script:calls++;throw 'persistent'};$false}catch{$true}
    @{first=$first;failed=$failed;secondCalls=$script:calls}} $source
Check ($retry.first.owners.Count -eq 1 -and $retry.first.owners[0] -eq 4242 -and $retry.first.calls -eq 2) 'Transient listener lookup was not retried once.'
Check ($retry.failed -and $retry.secondCalls -eq 2) 'Persistent listener-lookup failure must surface after exactly one retry.'

# Tuples: exactly two allowlisted tuples, each with its own model, context, fit target and adapter.
$tup=& $module {param($p,$catalogPath,$repo) . $p
    $r=@{}
    $r.xtx=Get-FastLlmVulkanVidmemTupleSpec -Tuple 'xtx-q4-32k'
    $r.xt=Get-FastLlmVulkanVidmemTupleSpec -Tuple 'xt-iq4-16k'
    $r.xtModel=(Get-FastLlmVulkanVidmemModel -CatalogPath $catalogPath -Tuple 'xt-iq4-16k').model
    $r.xtxArgs=@(New-FastLlmVulkanVidmemArguments -ModelPath 'M' -Tuple 'xtx-q4-32k')
    $r.xtArgs=@(New-FastLlmVulkanVidmemArguments -ModelPath 'M' -Tuple 'xt-iq4-16k')
    $r.bad=@('','XTX-Q4-32K','xtx-q4-16k','xt-q4-32k','xt-iq4-32k','other')|ForEach-Object {try{Get-FastLlmVulkanVidmemTupleSpec -Tuple $_;'accepted:'+$_}catch{'refused'}}
    $r.badArgs=try{New-FastLlmVulkanVidmemArguments -ModelPath 'M' -Tuple 'bogus';$false}catch{$true}
    # Normal-planner parity for both tuples (explicit model and context), using the repo fixtures as Vulkan hardware.
    $xtxHw=Read-FastLlmJson (Join-Path $repo 'tests/fixtures/rx-7900-xtx-24gb.json')
    $xtHw=Read-FastLlmJson (Join-Path $repo 'tests/fixtures/rx-7900-xt-20gb.json')
    $xtHw.backend='Vulkan';$xtHw.adapters[0].device='Vulkan0';$xtHw.adapters[0].backend='Vulkan'
    $root='/verified'
    $planXtx=Get-FastLlmPlan -Hardware $xtxHw -CatalogPath $catalogPath -InstallRoot $root -ModelId 'qwen3.8-27b-ud-q4-k-m' -ContextSize 32768
    $planXt=Get-FastLlmPlan -Hardware $xtHw -CatalogPath $catalogPath -InstallRoot $root -ModelId 'qwen3.8-27b-ud-iq4-xs' -ContextSize 16384
    $r.parityXtx=Assert-FastLlmVulkanVidmemPlanParity -Tuple 'xtx-q4-32k' -Hardware $xtxHw -CatalogPath $catalogPath -ArtifactRoot $root -ModelPath $planXtx.modelPath
    $r.parityXt=Assert-FastLlmVulkanVidmemPlanParity -Tuple 'xt-iq4-16k' -Hardware $xtHw -CatalogPath $catalogPath -ArtifactRoot $root -ModelPath $planXt.modelPath
    $r.parityWrongPath=try{Assert-FastLlmVulkanVidmemPlanParity -Tuple 'xt-iq4-16k' -Hardware $xtHw -CatalogPath $catalogPath -ArtifactRoot $root -ModelPath '/other/model.gguf';$false}catch{$true}
    $r.parityWrongModel=try{Assert-FastLlmVulkanVidmemPlanParity -Tuple 'xtx-q4-32k' -Hardware $xtHw -CatalogPath $catalogPath -ArtifactRoot $root -ModelPath $planXtx.modelPath;$false}catch{$true}
    $r.planXt=$planXt;$r.planXtArgs=@($planXt.serverArguments)
    $r.xtPlacement=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text "load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 12726.34 MiB" -CpuBufferLikeLines 0 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true
    $r} $source $catalog $root
Check ($tup.xtx.contextSize -eq 32768 -and $tup.xtx.fitTargetMiB -eq 768 -and $tup.xtx.adapterName -ceq 'AMD Radeon RX 7900 XTX' -and $tup.xtx.modelSha256 -ceq '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482') 'XTX tuple changed.'
Check ($tup.xt.contextSize -eq 16384 -and $tup.xt.fitTargetMiB -eq 512 -and $tup.xt.adapterName -ceq 'AMD Radeon RX 7900 XT' -and $tup.xt.modelId -ceq 'qwen3.8-27b-ud-iq4-xs' -and $tup.xt.modelSha256 -ceq '40fac4050e940397dbf13087afd50f4734a11805bf9d65ef8ddd7483470e6199') 'XT tuple wrong.'
Check ($tup.xtModel.sha256 -ceq $tup.xt.modelSha256 -and [long]$tup.xtModel.sizeBytes -eq 14252845984) 'XT catalog model differs from the tuple.'
$xtJoined=$tup.xtArgs -join '|'
Check ($xtJoined.Contains('--alias|qwen3.8-27b-ud-iq4-xs') -and $xtJoined.Contains('--ctx-size|16384') -and $xtJoined.Contains('--fit|on|--fit-target|512') -and $xtJoined.Contains('--port|18090') -and $xtJoined.Contains('--parallel|1')) 'XT arguments wrong.'
$xtDeltas=@(for($i=0;$i -lt $tup.xtArgs.Count;$i++){if($tup.xtArgs[$i] -cne $tup.xtxArgs[$i]){$tup.xtArgs[$i-1]}})
Check ($tup.xtArgs.Count -eq $tup.xtxArgs.Count -and ($xtDeltas -join ',') -ceq '--alias,--ctx-size,--fit-target') 'XT and XTX arguments differ beyond alias, context and fit target.'
Check (@($tup.bad|Where-Object {$_ -ne 'refused'}).Count -eq 0 -and $tup.badArgs) 'An unlisted tuple was accepted.'
Check ($tup.parityXtx -and $tup.parityXt) 'Arguments differ from the normal planner for a tuple.'
Check ($tup.parityWrongPath -and $tup.parityWrongModel) 'Planner parity accepted a wrong model path or tuple/hardware mix.'
Check ($tup.xtPlacement.reportedGpuLayers -eq 66 -and $null -eq $tup.xtPlacement.hostModelBuffer) 'XT placement without a host buffer was not accepted.'
Check (@($tup.planXtArgs|Where-Object {$_ -ceq '--fit-target'}).Count -eq 1 -and $tup.planXtArgs[$tup.planXtArgs.IndexOf('--fit-target')+1] -ceq '512') 'Normal planner fit target for XT changed.'
# Post-load placement path for the XT IQ4 tuple (the exact sequence Invoke-FastLlmVulkanVidmemSupervisor runs before Ready):
# ConvertFrom-FastLlmPlacementLog -> ConvertFrom-FastLlmVulkanVidmemBufferEvidence -> Assert-FastLlmVulkanVidmemPlacementCounters.
# Inputs use the normalized snapshot ProcessHost.PlacementSnapshot() emits and the counters string PlacementDiagnostics() emits.
$xtLog={param($withHost,$hostMiB='521.00')
    $l="load_tensors: offloaded 66/66 layers to GPU`nload_tensors: Vulkan0 model buffer size = 12726.34 MiB`n"
    if($withHost){$l+="load_tensors: CPU_Mapped model buffer size = $hostMiB MiB`n"}
    $l}
$xtPath=& $module {param($p,$logSb) . $p
    $run={param($text,$cpuLike,$diag,$bytes=14252845984)
        $placement=ConvertFrom-FastLlmPlacementLog -Text $text -Devices @('Vulkan0')
        $ev=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $text -CpuBufferLikeLines $cpuLike -Overflow $false -ModelBytes $bytes -AllowHostModelBuffer $true
        $c=Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics $diag -Evidence $ev
        @{placement=$placement;evidence=$ev;counters=$c}}
    $r=@{}
    $r.host=& $run (& $logSb $true) 1 'tensorLines=3, offloadLike=1, bufferLike=2, captured=3, dropped=0, generalOutputTruncated=False'
    $r.noHost=& $run (& $logSb $false) 0 'tensorLines=2, offloadLike=1, bufferLike=1, captured=2, dropped=0, generalOutputTruncated=False'
    # Real b10698 logs also carry other load_tensors lines (tensorLines is unbounded up to 1024); CPU_Mapped printed before Vulkan0.
    $r.hostMoreTensorLines=& $run "load_tensors: offloaded 66/66 layers to GPU`nload_tensors: CPU_Mapped model buffer size = 521.00 MiB`nload_tensors: Vulkan0 model buffer size = 12726.34 MiB`n" 1 'tensorLines=9, offloadLike=1, bufferLike=2, captured=3, dropped=0, generalOutputTruncated=False'
    # Negative controls.
    $neg={param($sb) try{& $sb;'accepted'}catch{$_.Exception.Message}}
    $hostText=& $logSb $true;$noHostText=& $logSb $false
    $evHost=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $hostText -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true
    $evNo=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $noHostText -CpuBufferLikeLines 0 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true
    $r.nBufNoHost=& $neg {Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics 'tensorLines=3, offloadLike=1, bufferLike=2, captured=3, dropped=0, generalOutputTruncated=False' -Evidence $evNo}
    $r.nBufHost=& $neg {Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics 'tensorLines=2, offloadLike=1, bufferLike=1, captured=2, dropped=0, generalOutputTruncated=False' -Evidence $evHost}
    $r.nCapturedHost=& $neg {Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics 'tensorLines=3, offloadLike=1, bufferLike=2, captured=2, dropped=0, generalOutputTruncated=False' -Evidence $evHost}
    $r.nDropped=& $neg {Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics 'tensorLines=3, offloadLike=1, bufferLike=2, captured=3, dropped=1, generalOutputTruncated=False' -Evidence $evHost}
    $r.nOffload=& $neg {Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics 'tensorLines=3, offloadLike=2, bufferLike=2, captured=3, dropped=0, generalOutputTruncated=False' -Evidence $evHost}
    $r.nMalformed=& $neg {Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics 'tensorLines=3, offloadLike=1, bufferLike=2, captured=3, dropped=0' -Evidence $evHost}
    # An extra CPU-like buffer line the capture counted (cpuBufferLike=1) but the text does not carry -> evidence parser refuses.
    $r.nCpuLikeNoRow=& $neg {ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $noHostText -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true}
    $r.nCapHost=& $neg {ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text (& $logSb $true '1024.01') -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true}
    $r.atCapHost=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text (& $logSb $true '1024.00') -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $true
    $r.nNoOptIn=& $neg {ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $hostText -CpuBufferLikeLines 1 -Overflow $false -ModelBytes 14252845984 -AllowHostModelBuffer $false}
    $r} $source $xtLog
foreach($k in 'host','noHost','hostMoreTensorLines'){
    Check ($xtPath[$k].placement.reportedAllLayers -and $xtPath[$k].placement.modelBufferMiB.Count -eq 1 -and $xtPath[$k].placement.modelBufferMiB[0].sizeMiB -eq 12726.34) "XT placement log parse wrong for $k."
    Check ($xtPath[$k].counters.offloadLike -eq 1 -and $xtPath[$k].counters.dropped -eq 0) "XT counters wrong for $k."
}
Check ($xtPath.host.counters.bufferLike -eq 2 -and $xtPath.host.counters.captured -eq 3 -and $xtPath.host.evidence.classification -ceq 'all-reported-layers-with-host-model-buffer' -and $xtPath.host.evidence.hostModelBuffer.device -ceq 'CPU_Mapped' -and $xtPath.host.evidence.hostModelBuffer.sizeMiB -eq 521.0 -and $xtPath.host.evidence.gpuModelBuffer.sizeMiB -eq 12726.34) 'XT Vulkan0+CPU_Mapped shape not accepted or misclassified.'
Check ($xtPath.noHost.counters.bufferLike -eq 1 -and $xtPath.noHost.counters.captured -eq 2 -and $xtPath.noHost.evidence.classification -ceq 'all-reported-layers-no-host-model-buffer' -and $null -eq $xtPath.noHost.evidence.hostModelBuffer) 'XT Vulkan0-only shape not accepted or misclassified.'
Check ($xtPath.hostMoreTensorLines.evidence.classification -ceq 'all-reported-layers-with-host-model-buffer' -and $xtPath.hostMoreTensorLines.counters.captured -eq 3) 'XT shape with extra tensor lines / reversed order refused.'
foreach($k in 'nBufNoHost','nBufHost','nCapturedHost','nDropped','nOffload','nMalformed','nCpuLikeNoRow','nCapHost','nNoOptIn'){
    Check ($xtPath[$k] -cne 'accepted') "Negative control $k was accepted."
}
Check ($xtPath.nBufNoHost -clike '*ambiguous*' -and $xtPath.nBufHost -clike '*ambiguous*' -and $xtPath.nCapHost -clike '*1024 MiB*') 'Negative controls refused for an unexpected reason.'
Check ($xtPath.atCapHost.hostModelBuffer.sizeMiB -eq 1024.0) 'CPU_Mapped at exactly the 1024 MiB cap refused.'
"Vulkan vidmem trial checks: $count passed"
