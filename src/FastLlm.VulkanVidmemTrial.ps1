#requires -Version 5.1
# Private, supervised b10698 Vulkan host-visible-VRAM A/B diagnostic. Never a normal serving or qualification state.
# Single variable: child environment GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1, applied after environment sanitisation.
# Private port 18090 (distinct from 8080/18080/18082-18089).

function Get-FastLlmVulkanVidmemPort {return 18090}

function Assert-FastLlmVulkanVidmemPort {
    param([int]$Port)
    $forbidden=@(8080,18080,18082,18083,18084,18085,18086,18087,18088,18089)
    if($Port -in $forbidden -or $Port -ne 18090){
        throw 'Vulkan vidmem trial port collides with a reserved lab port or is not the declared private port.'
    }
}

function Assert-FastLlmVulkanVidmemVariant {
    param([string]$Variant)
    if($Variant -cnotin @('default','disable-host-visible-vidmem')){
        throw 'Vulkan vidmem variant must be exactly default or disable-host-visible-vidmem.'
    }
}

function Get-FastLlmVulkanVidmemTupleSpec {
    # Closed allowlist of exactly two (model, context, adapter) tuples.
    param([string]$Tuple)
    if($Tuple -ceq 'xtx-q4-32k'){
        return [pscustomobject]@{tuple='xtx-q4-32k';modelId='qwen3.8-27b-ud-q4-k-m';
            modelSha256='322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482';sizeBytes=[long]16464440224;
            contextSize=32768;fitTargetMiB=768;adapterName='AMD Radeon RX 7900 XTX'}
    }
    if($Tuple -ceq 'xt-iq4-16k'){
        return [pscustomobject]@{tuple='xt-iq4-16k';modelId='qwen3.8-27b-ud-iq4-xs';
            modelSha256='40fac4050e940397dbf13087afd50f4734a11805bf9d65ef8ddd7483470e6199';sizeBytes=[long]14252845984;
            contextSize=16384;fitTargetMiB=512;adapterName='AMD Radeon RX 7900 XT'}
    }
    throw 'Vulkan vidmem tuple must be exactly xtx-q4-32k or xt-iq4-16k.'
}

function Assert-FastLlmVulkanVidmemArm {
    param([string]$Arm,[string]$Variant)
    if($Arm -cnotin @('A1','B1','B2','A2')){throw 'Vulkan vidmem arm must be exactly A1, B1, B2 or A2.'}
    Assert-FastLlmVulkanVidmemVariant $Variant
    $expected=if($Arm.StartsWith('A')){'disable-host-visible-vidmem'}else{'default'}
    if($Variant -cne $expected){throw 'Vulkan vidmem arm label contradicts the variant (A = override, B = default).'}
}

function Get-FastLlmVulkanVidmemPins {
    # Pinned reviewed inputs (XTX host: host-visible-vidmem A-B-B-A protocol). Any other composition is refused.
    return [ordered]@{
        producerSha256='c8b64fe0a2e78e3974b63a127da9ae385ca84b51fba69505ee323ab5d464a43b'
        parserSha256='f214f8b498eff554fe78836c6448e1f5008b0c2763e182e1f9013a575fe7028b'
        catalogSha256='65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6'
        engineSha256='9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7'
    }
}

function Assert-FastLlmVulkanVidmemIdleHost {
    param([Parameter(Mandatory=$true)][string]$Stage,
          [scriptblock]$GetInferenceProcesses={@(Get-Process -Name llama-server,llama-bench -ErrorAction SilentlyContinue)},
          [scriptblock]$TestPortFree={param($Port)
              $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
              try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start();return $true}catch{return $false}
              finally{try{$listener.Stop()}catch{}}})
    $procs=@(& $GetInferenceProcesses)
    if($procs.Count -ne 0){throw "Another llama-server or llama-bench process exists ($Stage); the vidmem trial requires an idle host."}
    $busy=@(foreach($port in @(8080,18090)){if(-not [bool](& $TestPortFree $port)){$port}})
    if($busy.Count -ne 0){throw "Port $($busy -join ',') already has a listener ($Stage); the vidmem trial requires an idle host."}
    return [ordered]@{stage=$Stage;checkedAtUtc=(Get-Date).ToUniversalTime().ToString('o');
        inferenceProcessCount=0;port8080Free=$true;port18090Free=$true;verified=$true}
}

function Get-FastLlmVulkanVidmemListenerOwners {
    param([int]$Port,[scriptblock]$Query={param($p)
        if(-not ('Bitworks.FastLlm.WindowsGpuTelemetry' -as [type])){
            Add-Type -Path (Join-Path $PSScriptRoot 'WindowsGpuTelemetry.cs') -ErrorAction Stop
        }
        [Bitworks.FastLlm.WindowsGpuTelemetry]::GetLoopbackListenerOwners($p)})
    # One retry on a transient table-read exception (known size-change race in the native lookup).
    try{return @(& $Query $Port)}
    catch{Start-Sleep -Milliseconds 150;return @(& $Query $Port)}
}

function Get-FastLlmVulkanVidmemEnvironmentOverride {
    param([string]$Variant)
    Assert-FastLlmVulkanVidmemVariant $Variant
    if($Variant -ceq 'disable-host-visible-vidmem'){return [ordered]@{GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM='1'}}
    return [ordered]@{}
}

function Get-FastLlmVulkanVidmemTrialSourceSha256 {
    $path=Join-Path $PSScriptRoot 'FastLlm.VulkanVidmemTrial.ps1'
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       $item.Length -le 0 -or $item.Length -gt 262144){throw 'Vulkan vidmem trial source is unavailable or unsafe.'}
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-FastLlmVulkanVidmemRoots {
    param([string]$ArtifactRoot,[string]$RunRoot)
    Assert-FastLlmOffloadRoots -ArtifactRoot $ArtifactRoot -LabRunRoot $RunRoot
    $profile=[IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $run=[IO.Path]::GetFullPath($RunRoot).TrimEnd('\')
    if(-not $run.StartsWith($profile+'\',[StringComparison]::OrdinalIgnoreCase)){
        throw 'Private Vulkan vidmem run root must be inside the current standard-user profile.'
    }
}

function Get-FastLlmVulkanVidmemModel {
    param([string]$CatalogPath,[Parameter(Mandatory=$true)][string]$Tuple)
    $spec=Get-FastLlmVulkanVidmemTupleSpec -Tuple $Tuple
    $entry=Get-FastLlmOffloadModel -CatalogPath $CatalogPath -ModelId $spec.modelId
    $model=$entry.model
    if([string]$model.sha256 -cne $spec.modelSha256 -or
       [long]$model.sizeBytes -ne $spec.sizeBytes -or [int]$model.contextSize -lt $spec.contextSize -or
       [int]$model.fitTargetMiB -ne $spec.fitTargetMiB -or [string]$model.cacheTypeK -cne 'f16' -or
       [int]$model.parallel -ne 1 -or
       [string]$model.cacheTypeV -cne 'f16' -or [string]$model.servingMode -notmatch '^text-only;'){
        throw "Vulkan vidmem trial requires the exact catalog artifact for tuple $Tuple."
    }
    return $entry
}

function Assert-FastLlmVulkanVidmemCachedModel {
    param($Model,[string]$ArtifactRoot)
    $modelRoot=Join-FastLlmContainedPath -Root $ArtifactRoot -Child 'models'
    Assert-FastLlmOffloadRootPath $modelRoot
    $path=Join-FastLlmContainedPath -Root $modelRoot -Child ([string]$Model.file)
    $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
       [long]$item.Length -ne [long]$Model.sizeBytes -or
       -not (Test-FastLlmFileHash -Path $path -Sha256 ([string]$Model.sha256)) -or
       -not (Test-FastLlmOffloadExactConsent -Model $Model -ArtifactRoot $ArtifactRoot)){
        throw 'Exact Qwen model hash or consent is absent; this trial never downloads or accepts licenses.'
    }
    return $path
}

function Get-FastLlmVulkanVidmemLiveAdapter {
    # Returns {adapter; hardware}. The adapter name must equal the tuple's expected adapter exactly.
    param([string]$CatalogPath,[string]$ArtifactRoot,[string]$EnginePath,[long]$RequiredFreeMiB,[Parameter(Mandatory=$true)][string]$Tuple)
    $spec=Get-FastLlmVulkanVidmemTupleSpec -Tuple $Tuple
    $hardware=Get-FastLlmHardware -CatalogPath $CatalogPath -InstallRoot $ArtifactRoot
    $adapters=@($hardware.adapters)
    if($hardware.backend -cne 'Vulkan' -or $hardware.enginePath -cne $EnginePath -or
       $adapters.Count -ne 1 -or $adapters[0].device -cne 'Vulkan0' -or
       -not $adapters[0].isAmd -or $adapters[0].isIntegrated -or
       [long]$adapters[0].freeVramMiB -lt $RequiredFreeMiB){
        throw 'Private Vulkan vidmem trial requires exactly one current discrete AMD Vulkan0 meeting the catalog free-VRAM estimate.'
    }
    if([string]$adapters[0].name -cne $spec.adapterName){
        throw "Private Vulkan vidmem tuple $Tuple requires the adapter named exactly '$($spec.adapterName)'."
    }
    return [pscustomobject]@{adapter=$adapters[0];hardware=$hardware}
}

function New-FastLlmVulkanVidmemArguments {
    param([string]$ModelPath,[Parameter(Mandatory=$true)][string]$Tuple,[int]$Port=18090)
    Assert-FastLlmVulkanVidmemPort -Port $Port
    $spec=Get-FastLlmVulkanVidmemTupleSpec -Tuple $Tuple
    return @('--model',$ModelPath,'--offline','--no-mmproj','--spec-type','none',
        '--alias',$spec.modelId,'--host','127.0.0.1','--port',[string]$Port,
        '--cors-origins','localhost','--no-cors-credentials','--ctx-size',[string]$spec.contextSize,
        '--parallel','1','--n-gpu-layers','all','--fit','on','--fit-target',[string]$spec.fitTargetMiB,
        '--device','Vulkan0','--split-mode','none','--flash-attn','auto',
        '--cache-type-k','f16','--cache-type-v','f16','--jinja','--metrics',
        '--log-verbosity','4','--no-agent','--no-ui')
}

function Assert-FastLlmVulkanVidmemPlanParity {
    # The lane arguments must be the normal planner's exact arguments for the explicit model and context,
    # differing only in the private port value.
    param([Parameter(Mandatory=$true)][string]$Tuple,$Hardware,[string]$CatalogPath,[string]$ArtifactRoot,[string]$ModelPath)
    $spec=Get-FastLlmVulkanVidmemTupleSpec -Tuple $Tuple
    $plan=Get-FastLlmPlan -Hardware $Hardware -CatalogPath $CatalogPath -InstallRoot $ArtifactRoot -ModelId $spec.modelId -ContextSize $spec.contextSize
    if([string]$plan.modelPath -cne $ModelPath){throw 'Planner model path differs from the verified cached model path.'}
    $expected=@($plan.serverArguments)
    $portAt=[Array]::IndexOf($expected,'--port')
    if($portAt -lt 0 -or $portAt+1 -ge $expected.Count){throw 'Planner arguments carry no --port.'}
    $expected[$portAt+1]=[string](Get-FastLlmVulkanVidmemPort)
    $actual=@(New-FastLlmVulkanVidmemArguments -ModelPath $ModelPath -Tuple $Tuple)
    if($actual.Count -ne $expected.Count){throw 'Vulkan vidmem argument count differs from the normal planner for this tuple.'}
    for($i=0;$i -lt $actual.Count;$i++){
        if([string]$actual[$i] -cne [string]$expected[$i]){throw "Vulkan vidmem arguments differ from the normal planner at position $i."}
    }
    return $true
}

function New-FastLlmVulkanVidmemStartInfo {
    param([string]$EnginePath,[string[]]$Arguments,$Sandbox,[string]$Variant)
    Assert-FastLlmVulkanVidmemVariant $Variant
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$EnginePath
    $info.Arguments=Join-FastLlmProcessArguments -Arguments $Arguments
    $info.WorkingDirectory=Split-Path -Parent $EnginePath
    foreach($name in @($info.EnvironmentVariables.Keys)){
        if(Test-FastLlmEnvironmentNameRequiresClearing -Name $name){$info.EnvironmentVariables.Remove([string]$name)}
    }
    $info.EnvironmentVariables['APPDATA']=$Sandbox.appData
    $info.EnvironmentVariables['PROGRAMDATA']=$Sandbox.programData
    $info.EnvironmentVariables['PATH']="$($info.WorkingDirectory);$([Environment]::SystemDirectory);$env:SystemRoot"
    # The single variable is applied strictly AFTER sanitisation.
    $override=Get-FastLlmVulkanVidmemEnvironmentOverride -Variant $Variant
    foreach($key in $override.Keys){$info.EnvironmentVariables[[string]$key]=[string]$override[$key]}
    $null=Assert-FastLlmVulkanVidmemStartInfo -Info $info -Variant $Variant
    return $info
}

function Assert-FastLlmVulkanVidmemStartInfo {
    param($Info,[string]$Variant)
    Assert-FastLlmVulkanVidmemVariant $Variant
    $ggml=@(@($Info.EnvironmentVariables.Keys) | Where-Object {([string]$_) -like 'GGML_*'})
    $present=$Info.EnvironmentVariables.ContainsKey('GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM')
    if($ggml.Count -gt 0 -and @($ggml|Where-Object {[string]$_ -cne 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'}).Count -ne 0){
        throw 'Vidmem start info carries a GGML_* variable other than the single exact-case override.'
    }
    if($Variant -ceq 'default'){
        if($ggml.Count -ne 0){throw 'Default vidmem variant start info must carry no GGML_* environment variable.'}
    }else{
        if(-not $present -or $ggml.Count -ne 1 -or
           [string]$Info.EnvironmentVariables['GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'] -cne '1'){
            throw 'Override vidmem variant start info must carry exactly GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM=1 and no other GGML_*.'
        }
    }
    foreach($name in @($Info.EnvironmentVariables.Keys)){
        $n=[string]$name
        if($n -ceq 'GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'){continue}
        if(Test-FastLlmEnvironmentNameRequiresClearing -Name $n){
            throw 'Vidmem start info retains an unsanitised engine environment variable.'
        }
    }
    return $true
}

function Get-FastLlmVulkanVidmemDigestExclusions {
    # Closed list of session-volatile or per-run variables excluded from the launch-environment digest.
    # C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE is injected by Win32-OpenSSH per session (its fd-state value differed
    # between two otherwise identical arm sessions on the XT host, harm-check attempt "a", 2026-10-06); llama-server never reads it.
    return @('SSH_CLIENT','SSH_CONNECTION','SSH_TTY','SSH_AUTH_SOCK','SESSIONNAME','CLIENTNAME','APPDATA','PROGRAMDATA',
        'C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE')
}

function Get-FastLlmVulkanVidmemObservedEnvironment {
    # Observed from the actual ProcessStartInfo. Per-variable value digests are recorded (values are not, except GGML_*).
    # The base digest also excludes the single override so it must be identical across all four arms.
    param($Info,[string]$RunRoot,[string]$WorkingDirectory)
    $override='GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM'
    $exclusions=@(Get-FastLlmVulkanVidmemDigestExclusions)
    $placeholders=@()
    if($RunRoot){$placeholders+= ,@([IO.Path]::GetFullPath($RunRoot).TrimEnd('\','/'),'<RUNROOT>')}
    $work=if($WorkingDirectory){$WorkingDirectory}else{[string]$Info.WorkingDirectory}
    if($work){$placeholders+= ,@($work.TrimEnd('\','/'),'<WORKDIR>')}
    $sha=[Security.Cryptography.SHA256]::Create()
    $hex={param($text) ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]$text)))).Replace('-','').ToLowerInvariant()}
    try{
        $base=New-Object Collections.Generic.List[string]
        $withOverride=New-Object Collections.Generic.List[string]
        $variables=@()
        $ggml=[ordered]@{}
        foreach($name in @(@($Info.EnvironmentVariables.Keys)|Sort-Object {([string]$_).ToUpperInvariant()})){
            $n=[string]$name;$raw=[string]$Info.EnvironmentVariables[$name];$u=$n.ToUpperInvariant()
            if($n -like 'GGML_*'){$ggml[$n]=$raw}
            if($u -in $exclusions){$variables+= [ordered]@{name=$u;excluded='session-volatile-or-per-run'};continue}
            $v=$raw
            foreach($pair in $placeholders){$v=[regex]::Replace($v,[regex]::Escape($pair[0]),$pair[1],[Text.RegularExpressions.RegexOptions]::IgnoreCase)}
            $valueSha=& $hex $v
            $entry=[ordered]@{name=$u;valueSha256=$valueSha}
            if($u -ceq $override){$entry.overrideVariable=$true}
            $variables+= $entry
            $line=$u+'='+$valueSha
            $withOverride.Add($line)
            if($u -cne $override){$base.Add($line)}
        }
        $digest={param($list)
            $array=$list.ToArray();[Array]::Sort($array,[StringComparer]::Ordinal)
            & $hex ($array -join "`n")}
        $argSha=& $hex ([string]$Info.Arguments)
        return [ordered]@{variableCount=@($Info.EnvironmentVariables.Keys).Count;ggmlEnvironment=$ggml;
            variables=$variables;excludedFromDigest=$exclusions;
            launchEnvironmentSha256=(& $digest $base);launchEnvironmentWithOverrideSha256=(& $digest $withOverride);
            launchArgumentsSha256=$argSha;
            digestScope='closed exclusion list (SSH_CLIENT, SSH_CONNECTION, SSH_TTY, SSH_AUTH_SOCK, SESSIONNAME, CLIENTNAME, APPDATA, PROGRAMDATA, C28FC6F98A2C44ABBBD89D6A3037D0D9_POSIX_FD_STATE); base digest also excludes GGML_VK_DISABLE_HOST_VISIBLE_VIDMEM; every other variable is hashed by value with the run RunRoot and WorkingDirectory replaced by placeholders'}
    }finally{$sha.Dispose()}
}

function ConvertFrom-FastLlmVulkanVidmemBufferEvidence {
    param([string]$Text,[int]$CpuBufferLikeLines,[bool]$Overflow,[long]$ModelBytes,
          [bool]$AllowHostModelBuffer)
    if($Overflow -or $Text.Length -gt 8192 -or $CpuBufferLikeLines -lt 0 -or $CpuBufferLikeLines -gt 64){
        throw 'Bounded Vulkan model-buffer capture overflowed or is malformed.'
    }
    $rows=@($Text -split "`r?`n" | Where-Object {$_})
    if($rows.Count -gt 64){throw 'Vulkan model-buffer capture has too many lines.'}
    $gpu=@();$hostBuffers=@();$offload=@()
    foreach($line in $rows){
        if($line -cmatch '^load_tensors: offloaded ([0-9]{1,5})/([0-9]{1,5}) layers to GPU$'){
            $offload+= [pscustomobject]@{loaded=[int]$Matches[1];total=[int]$Matches[2]}
        }elseif($line -cmatch '^load_tensors: (Vulkan0|CPU_Mapped|CPU) model buffer size = ([0-9]{1,32}(?:\.[0-9]{1,32})?) MiB$'){
            $size=[double]0
            if(-not [double]::TryParse($Matches[2],[Globalization.NumberStyles]::AllowDecimalPoint,
                [Globalization.CultureInfo]::InvariantCulture,[ref]$size) -or
                $size -le 0 -or [double]::IsNaN($size) -or [double]::IsInfinity($size)){
                throw 'Vulkan model-buffer size is not positive finite numeric evidence.'
            }
            $entry=[pscustomobject]@{device=$Matches[1];sizeMiB=$size}
            if($Matches[1] -ceq 'Vulkan0'){$gpu+= $entry}else{$hostBuffers+= $entry}
        }else{throw 'Vulkan model-buffer capture contains an unrecognized row.'}
    }
    if($offload.Count -ne 1 -or $offload[0].loaded -ne 66 -or $offload[0].total -ne 66 -or
       $gpu.Count -ne 1 -or $CpuBufferLikeLines -ne $hostBuffers.Count){
        throw 'Vulkan vidmem placement did not report exactly 66/66 layers and one selected GPU buffer.'
    }
    if($hostBuffers.Count){
        if(-not $AllowHostModelBuffer -or $hostBuffers.Count -ne 1 -or $hostBuffers[0].device -cne 'CPU_Mapped' -or
           $hostBuffers[0].sizeMiB -gt 1024.0 -or $hostBuffers[0].sizeMiB -gt ([double]$ModelBytes / 1MB)){
            throw 'CPU_Mapped model buffer requires explicit opt-in and must not exceed the 1024 MiB trial cap.'
        }
    }
    $hostBuffer=if($hostBuffers.Count){$hostBuffers[0]}else{$null}
    $classification=if($hostBuffers.Count){'all-reported-layers-with-host-model-buffer'}else{'all-reported-layers-no-host-model-buffer'}
    return [pscustomobject]@{status='captured';reportedGpuLayers=66;reportedTotalLayers=66;
        gpuModelBuffer=$gpu[0];hostModelBuffer=$hostBuffer;
        classification=$classification;
        physicalResidencyVerified=$false;allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false}
}

function Assert-FastLlmVulkanVidmemPlacementCounters {
    param([string]$Diagnostics,$Evidence)
    if($Diagnostics -cnotmatch '^tensorLines=([0-9]{1,5}), offloadLike=([0-9]{1,5}), bufferLike=([0-9]{1,5}), captured=([0-9]{1,5}), dropped=([0-9]{1,5}), generalOutputTruncated=(True|False)$'){
        throw 'Private Vulkan placement counters are malformed.'
    }
    $tensor=[int]$Matches[1];$offload=[int]$Matches[2];$buffers=[int]$Matches[3]
    $captured=[int]$Matches[4];$dropped=[int]$Matches[5]
    $expectedBuffers=if($null -eq $Evidence.hostModelBuffer){1}else{2}
    if($tensor -lt ($expectedBuffers+1) -or $tensor -gt 1024 -or $offload -ne 1 -or
       $buffers -ne $expectedBuffers -or $captured -ne ($expectedBuffers+1) -or $dropped -ne 0){
        throw 'Unrecognized or ambiguous model placement lines were observed outside bounded capture.'
    }
    return [pscustomobject]@{offloadLike=$offload;bufferLike=$buffers;captured=$captured;dropped=$dropped}
}

function ConvertTo-FastLlmVulkanVidmemStatus {
    param($State)
    if($null -eq $State.PSObject.Properties['schemaVersion'] -and $null -eq $State.PSObject.Properties['kind']){
        # Initial default state (no status document yet): well-formed not-ready status instead of a strict-mode error.
        return [pscustomobject]@{schemaVersion=1;kind='fastllm-vulkan-vidmem-b10698-private-trial';
            phase='vulkan-vidmem-not-ready';active=[bool]$State.active;ready=$false}
    }
    if([int]$State.schemaVersion -ne 1 -or [string]$State.kind -cne 'fastllm-vulkan-vidmem-b10698-private-trial'){
        throw 'RunRoot does not contain a Vulkan vidmem private-trial state.'
    }
    if(-not $State.active -and $State.phase -in @('vulkan-vidmem-loading','vulkan-vidmem-checking','vulkan-vidmem-ready')){
        $State.phase='vulkan-vidmem-interrupted'
    }
    return $State
}

function Get-FastLlmVulkanVidmemStatus {
    param([Parameter(Mandatory=$true)][string]$RunRoot)
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmOffloadRootPath $RunRoot
    return ConvertTo-FastLlmVulkanVidmemStatus -State (Get-FastLlmStatus -InstallRoot $RunRoot)
}

function Request-FastLlmVulkanVidmemStop {
    param([Parameter(Mandatory=$true)][string]$RunRoot)
    $state=Get-FastLlmVulkanVidmemStatus -RunRoot $RunRoot
    if(-not $state.active -or $state.phase -notin @('vulkan-vidmem-loading','vulkan-vidmem-checking','vulkan-vidmem-ready') -or
       $state.runId -cnotmatch '^[0-9a-f]{32}$'){
        throw 'No active private Vulkan vidmem trial belongs to this run root.'
    }
    $root=Get-FastLlmStateRoot -InstallRoot $RunRoot
    $path=Join-FastLlmContainedPath -Root $root -Child ('stop-'+$state.runId)
    if(Test-Path -LiteralPath $path){
        if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unsafe Vulkan vidmem stop path.'}
    }else{$stream=[IO.File]::Open($path,'CreateNew','Write','None');$stream.Dispose()}
}

function Assert-FastLlmVulkanVidmemListenerOwner {
    param([Diagnostics.Process]$Process,[long]$StartUtcTicks)
    $owners=@(Get-FastLlmVulkanVidmemListenerOwners -Port 18090)
    if($owners.Count -ne 1 -or [int]$owners[0] -ne [int]$Process.Id -or
       $Process.HasExited -or [long]$Process.StartTime.ToUniversalTime().Ticks -ne $StartUtcTicks){
        throw 'Vulkan vidmem loopback listener owner differs from the exact supervised child.'
    }
}

function Start-FastLlmVulkanVidmemTrial {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ArtifactRoot,
          [Parameter(Mandatory=$true)][string]$RunRoot,
          [Parameter(Mandatory=$true)][string]$CatalogPath,
          [Parameter(Mandatory=$true)][string]$Variant,
          [Parameter(Mandatory=$true)][string]$Arm,
          [Parameter(Mandatory=$true)][string]$Tuple,
          [ValidateRange(30,1800)][int]$LoadTimeoutSeconds=600)
    $tupleSpec=Get-FastLlmVulkanVidmemTupleSpec -Tuple $Tuple
    Assert-FastLlmVulkanVidmemVariant $Variant
    Assert-FastLlmVulkanVidmemArm -Arm $Arm -Variant $Variant
    Assert-FastLlmOffloadLabHost
    Assert-FastLlmVulkanVidmemRoots -ArtifactRoot $ArtifactRoot -RunRoot $RunRoot
    if(Test-Path -LiteralPath $RunRoot){throw 'Use a fresh, non-existent Vulkan vidmem RunRoot for every start; previous trial state is retained.'}
    $entry=Get-FastLlmVulkanVidmemModel -CatalogPath $CatalogPath -Tuple $Tuple
    $sourceSha=Get-FastLlmVulkanVidmemTrialSourceSha256
    $normal=Get-FastLlmStatus -InstallRoot $ArtifactRoot
    if($normal.active){throw 'Stop normal inference before a private Vulkan vidmem trial.'}
    $preLockIdle=Assert-FastLlmVulkanVidmemIdleHost -Stage 'before-locks'
    $artifactLock=Enter-FastLlmOperation $ArtifactRoot
    try{
        $runLock=Enter-FastLlmOperation $RunRoot
        try{
            $model=$entry.model;$catalog=$entry.catalog;$asset=$catalog.engine.assets.vulkan
            if(-not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)){
                throw 'Exact pinned b10698 Vulkan engine is not installed and verified.'
            }
            $enginePath=Get-FastLlmEngineExecutable -InstallRoot $ArtifactRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -EntryPoint ([string]$asset.entryPoint)
            $initialLive=Get-FastLlmVulkanVidmemLiveAdapter -CatalogPath $CatalogPath -ArtifactRoot $ArtifactRoot -EnginePath $enginePath -RequiredFreeMiB ([long]$model.requiredFreeVramMiB) -Tuple $Tuple
            $initial=$initialLive.adapter
            $modelPath=Assert-FastLlmVulkanVidmemCachedModel -Model $model -ArtifactRoot $ArtifactRoot
            $freshLive=Get-FastLlmVulkanVidmemLiveAdapter -CatalogPath $CatalogPath -ArtifactRoot $ArtifactRoot -EnginePath $enginePath -RequiredFreeMiB ([long]$model.requiredFreeVramMiB) -Tuple $Tuple
            $fresh=$freshLive.adapter
            if([string]$fresh.name -cne [string]$initial.name -or [long]$fresh.vramMiB -ne [long]$initial.vramMiB){
                throw 'Vulkan0 identity changed during private trial preparation.'
            }
            if((Get-FileHash -LiteralPath $CatalogPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.catalogSha256 -or
               -not (Test-FastLlmEngineInstallation -InstallRoot $ArtifactRoot -EngineVersion 'b10698' -BackendKey 'vulkan' -Asset $asset)){
                throw 'Pinned catalog or engine changed before private process launch.'
            }
            $modelPath=Assert-FastLlmVulkanVidmemCachedModel -Model $model -ArtifactRoot $ArtifactRoot
            if((Get-FastLlmVulkanVidmemTrialSourceSha256) -cne $sourceSha){throw 'Vulkan vidmem trial source changed during preparation.'}
            $pins=Get-FastLlmVulkanVidmemPins
            $engineSha=(Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if($entry.catalogSha256 -cne $pins.catalogSha256 -or $engineSha -cne $pins.engineSha256){
                throw 'Catalog or engine hash differs from the pinned reviewed inputs.'
            }
            $args=New-FastLlmVulkanVidmemArguments -ModelPath $modelPath -Tuple $Tuple
            $null=Assert-FastLlmVulkanVidmemPlanParity -Tuple $Tuple -Hardware $freshLive.hardware -CatalogPath $CatalogPath -ArtifactRoot $ArtifactRoot -ModelPath $modelPath
            $plan=[pscustomobject]@{model=$model;modelPath=$modelPath;enginePath=$enginePath;
                serverArguments=$args;tuple=$Tuple;tupleSpec=$tupleSpec;variant=$Variant;arm=$Arm;preLockIdle=$preLockIdle;environmentOverride=(Get-FastLlmVulkanVidmemEnvironmentOverride -Variant $Variant);adapter=$fresh;catalogSha256=$entry.catalogSha256;
                sourceSha256=$sourceSha;allowHostModelBuffer=$true;
                engineSha256=$engineSha}
            return Invoke-FastLlmVulkanVidmemSupervisor -Plan $plan -RunRoot $RunRoot -LoadTimeoutSeconds $LoadTimeoutSeconds
        }finally{$runLock.Dispose()}
    }finally{$artifactLock.Dispose()}
}

function Invoke-FastLlmVulkanVidmemSupervisor {
    param($Plan,[string]$RunRoot,[int]$LoadTimeoutSeconds)
    Initialize-FastLlmProcessHost
    $state=[ordered]@{schemaVersion=1;kind='fastllm-vulkan-vidmem-b10698-private-trial';runId=[Guid]::NewGuid().ToString('N');
        tuple=[string]$Plan.tuple;variant=[string]$Plan.variant;arm=[string]$Plan.arm;preLockIdle=$Plan.preLockIdle;preStartIdle=$null;observedEnvironment=$null;
        hostModelBufferPolicy='implicit-lane-policy-normal-recipe-reports-CPU_Mapped';launchedAtUtc=$null;healthyAtUtc=$null;modelLoadSeconds=$null;readyAtUtc=$null;environmentOverride=$Plan.environmentOverride;startInfoEnvironmentVerified=$false;
        phase='vulkan-vidmem-loading';updatedAt=(Get-Date).ToUniversalTime().ToString('o');endpoint='http://127.0.0.1:18090/v1';
        modelId=$Plan.model.id;modelSha256=$Plan.model.sha256;engineVersion='b10698';engineSha256=$Plan.engineSha256;
        catalogSha256=$Plan.catalogSha256;trialSourceSha256=$Plan.sourceSha256;
        recipe=[ordered]@{backend='Vulkan';device='Vulkan0';contextSize=[int]$Plan.tupleSpec.contextSize;slots=1;gpuLayers='all';
            fitMode='on';fitTargetMiB=[int]$Plan.tupleSpec.fitTargetMiB;splitMode='none';cacheTypeK='f16';cacheTypeV='f16';
            flashAttention='auto';speculation='none';allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer;
            requestedArguments=@($Plan.serverArguments | ForEach-Object {if($_ -ceq $Plan.modelPath){'<verified-model>'}else{$_}});
            configurationIsolation='empty-per-run-config-roots-and-targeted-environment-sanitization'};
        selectedDevice=[ordered]@{device='Vulkan0';name=$Plan.adapter.name;reportedFreeMiB=$Plan.adapter.freeVramMiB};
        placement=$null;placementEvidence=$null;placementCounters=$null;placementClassification=$null;allowHostModelBuffer=[bool]$Plan.allowHostModelBuffer;
        allWeightsOnGpuVerified=$false;allOperationsOnGpuVerified=$false;cpuInputEvidence='not-attested';physicalResidencyVerified=$false;
        dynamicClosureVerified=$false;semanticCorrectnessQualified=$false;performanceQualified=$false;
        experimental=$true;processIdentity=$null;canary=$null;failureCode=$null}
    $stateRoot=Get-FastLlmStateRoot -InstallRoot $RunRoot -Create
    $stopPath=Join-FastLlmContainedPath -Root $stateRoot -Child ('stop-'+$state.runId)
    $sandbox=New-FastLlmRuntimeSandbox -InstallRoot $RunRoot
    $child=New-Object Bitworks.FastLlm.ProcessHost
    $baseUrl='http://127.0.0.1:18090'
    try{
        $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,18090)
        try{$listener.Server.ExclusiveAddressUse=$true;$listener.Start()}finally{$listener.Stop()}
        # Hard failure before launch if the actual start info does not match the declared variant.
        $info=New-FastLlmVulkanVidmemStartInfo -EnginePath $Plan.enginePath -Arguments $Plan.serverArguments -Sandbox $sandbox -Variant $Plan.variant
        $state.startInfoEnvironmentVerified=$true
        $state.observedEnvironment=Get-FastLlmVulkanVidmemObservedEnvironment -Info $info -RunRoot $RunRoot -WorkingDirectory $info.WorkingDirectory
        if((Get-FastLlmVulkanVidmemTrialSourceSha256) -cne $Plan.sourceSha256){throw 'Vulkan vidmem source changed before spawn.'}
        $state.preStartIdle=Assert-FastLlmVulkanVidmemIdleHost -Stage 'immediately-before-start'
        $state.launchedAtUtc=(Get-Date).ToUniversalTime().ToString('o')
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        $child.Start($info)
        if((Get-FastLlmVulkanVidmemTrialSourceSha256) -cne $Plan.sourceSha256){throw 'Vulkan vidmem source changed during process launch.'}
        $state.processIdentity=[ordered]@{pid=[int]$child.Process.Id;startUtcTicks=[long]$child.Process.StartTime.ToUniversalTime().Ticks}
        $state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state
        $timer=[Diagnostics.Stopwatch]::StartNew();$healthy=$false
        while($timer.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds){
            if(Test-Path -LiteralPath $stopPath){$state.phase='vulkan-vidmem-stopped';return 0}
            if($child.Process.HasExited){throw 'Private Vulkan vidmem server exited before readiness.'}
            try{$health=Invoke-FastLlmHttp -BaseUrl $baseUrl -Path '/health' -TimeoutMs 1000
                $healthy=$health.Status -eq 200 -and (ConvertFrom-Json $health.Body).status -eq 'ok'}catch{$healthy=$false}
            if($healthy){$state.healthyAtUtc=(Get-Date).ToUniversalTime().ToString('o');$state.modelLoadSeconds=[Math]::Round($timer.Elapsed.TotalSeconds,3);Assert-FastLlmVulkanVidmemListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks);break}
            Start-Sleep -Milliseconds 200
        }
        if(-not $healthy){throw 'Private Vulkan vidmem model-load deadline exceeded.'}
        $startupText=$child.FreezeStartupDiagnostics()
        $state.phase='vulkan-vidmem-checking';$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o')
        $state.startupDiagnostics=ConvertFrom-FastLlmStartupDiagnostics -Text $startupText -Overflow $child.StartupDiagnosticsOverflow -RequestedFlashAttention 'auto'
        $placementText=$child.PlacementSnapshot()
        if($child.PlacementOverflow){throw 'Vulkan vidmem bounded placement capture overflowed.'}
        $state.placement=ConvertFrom-FastLlmPlacementLog -Text $placementText -Devices @('Vulkan0')
        $state.placementEvidence=ConvertFrom-FastLlmVulkanVidmemBufferEvidence -Text $placementText -CpuBufferLikeLines $child.CpuBufferLikeLines -Overflow $child.PlacementOverflow -ModelBytes ([long]$Plan.model.sizeBytes) -AllowHostModelBuffer ([bool]$Plan.allowHostModelBuffer)
        $state.placementCounters=Assert-FastLlmVulkanVidmemPlacementCounters -Diagnostics ($child.PlacementDiagnostics()) -Evidence $state.placementEvidence
        $state.placementClassification=$state.placementEvidence.classification
        Write-FastLlmState -InstallRoot $RunRoot -State $state
        Assert-FastLlmVulkanVidmemListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        $state.canary=Test-FastLlmApiCanary -BaseUrl $baseUrl -ModelId $Plan.model.id -ContextSize ([int]$Plan.tupleSpec.contextSize)
        Assert-FastLlmVulkanVidmemListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        if($child.Process.HasExited){throw 'Vulkan vidmem server exited during API canaries.'}
        $child.DiscardOutput()
        $state.phase='vulkan-vidmem-ready';$state.readyAtUtc=(Get-Date).ToUniversalTime().ToString('o');$state.updatedAt=$state.readyAtUtc;Write-FastLlmState -InstallRoot $RunRoot -State $state
        Write-Host "Private Vulkan vidmem $($Plan.variant) lab ready on $($state.endpoint); not fit/residency/quality/performance qualified."
        while(-not $child.Process.WaitForExit(250)){
            if(Test-Path -LiteralPath $stopPath){$state.phase='vulkan-vidmem-stopped';return 0}
            Assert-FastLlmVulkanVidmemListenerOwner -Process $child.Process -StartUtcTicks ([long]$state.processIdentity.startUtcTicks)
        }
        if($child.Process.ExitCode -ne 0){throw 'Private Vulkan vidmem server exited unexpectedly.'}
        $state.phase='vulkan-vidmem-stopped';return 0
    }catch{$state.phase='vulkan-vidmem-failed';$state.failureCode='private-startup-or-runtime-check-failed';throw}
    finally{
        try{$child.Dispose()}finally{
            try{$state.updatedAt=(Get-Date).ToUniversalTime().ToString('o');Write-FastLlmState -InstallRoot $RunRoot -State $state}
            finally{try{Remove-FastLlmRuntimeSandbox $sandbox}finally{if(Test-Path -LiteralPath $stopPath){Remove-Item -LiteralPath $stopPath -Force}}}
        }
    }
}
