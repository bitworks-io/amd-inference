#requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.VulkanModuleBinding.ps1')
$passed=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:passed++}
function Reject([scriptblock]$Action,[string]$Message){
    $rejected=$false
    try{& $Action | Out-Null}catch{$rejected=$true}
    Check $rejected $Message
}

$run='a'*32
$sha='b'*64
$catalog='c'*64
$model='d'*64
$state=[pscustomobject]@{active=$true;phase='ready';runId=$run;engineVersion='b10698';
    endpoint='http://127.0.0.1:8080/v1';modelSha256=$model;
    recipe=[pscustomobject]@{backend='Vulkan';engineSha256=$sha;catalogSha256=$catalog};
    processIdentity=[pscustomobject]@{pid=1234;startUtcTicks=638000000000000000}}
Assert-FastLlmVulkanModuleState -State $state -RunId $run -ExpectedPid 1234 -ExpectedTicks 638000000000000000 -ExpectedEngineHash $sha
$passed++
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId ('e'*32)} 'Different run ID was accepted.'
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId $run -ExpectedPid 999} 'Different PID was accepted.'
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId $run -ExpectedTicks 638000000000000001} 'Different start time was accepted.'
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId $run -ExpectedEngineHash ('e'*64)} 'Different engine digest was accepted.'
$state.phase='stopped'
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId $run} 'Stopped run was accepted.'
$state.phase='ready';$state.recipe.catalogSha256='invalid'
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId $run} 'Invalid catalog digest was accepted.'
$state.recipe.catalogSha256=$catalog;$state.endpoint='http://192.168.1.1:8080/v1'
Reject {Assert-FastLlmVulkanModuleState -State $state -RunId $run} 'LAN endpoint was accepted.'
$state.endpoint='http://127.0.0.1:8080/v1'

$testTemp=if($env:OS -eq 'Windows_NT'){[IO.Path]::GetTempPath()}else{'/private/tmp'}
$base=Join-Path $testTemp ('fastllm-module-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base -ErrorAction Stop | Out-Null
try{
    $exe=Join-Path $base 'llama-server.exe'
    [IO.File]::WriteAllText($exe,'verified executable')
    $actualHash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    $state.recipe.engineSha256=$actualHash
    Assert-FastLlmVulkanModuleProcess -State $state -ListenerOwners @(1234) -ProcessName 'llama-server' -ProcessTicks 638000000000000000 -ActualExe $exe -ExpectedExe $exe -ActualExeSha256 $actualHash
    $passed++
    Reject {Assert-FastLlmVulkanModuleProcess -State $state -ListenerOwners @(2345) -ProcessName 'llama-server' -ProcessTicks 638000000000000000 -ActualExe $exe -ExpectedExe $exe -ActualExeSha256 $actualHash} 'Wrong listener owner was accepted.'
    Reject {Assert-FastLlmVulkanModuleProcess -State $state -ListenerOwners @(1234) -ProcessName 'llama-server' -ProcessTicks 638000000000000001 -ActualExe $exe -ExpectedExe $exe -ActualExeSha256 $actualHash} 'Reused PID was accepted.'
    Reject {Assert-FastLlmVulkanModuleProcess -State $state -ListenerOwners @(1234) -ProcessName 'llama-server' -ProcessTicks 638000000000000000 -ActualExe $exe -ExpectedExe $exe -ActualExeSha256 ('0'*64)} 'Changed executable hash was accepted.'
    $other=Join-Path $base 'other.exe';[IO.File]::WriteAllText($other,'verified executable')
    Reject {Assert-FastLlmVulkanModuleProcess -State $state -ListenerOwners @(1234) -ProcessName 'llama-server' -ProcessTicks 638000000000000000 -ActualExe $other -ExpectedExe $exe -ActualExeSha256 $actualHash} 'Wrong executable path was accepted.'

    $loader=Join-Path $base 'vulkan-1.dll'
    $driver=Join-Path $base 'amdvlk64.dll'
    $backend=Join-Path $base 'ggml-vulkan.dll'
    $rows=@([pscustomobject]@{ModuleName='vulkan-1.dll';FileName=$loader},
        [pscustomobject]@{ModuleName='amdvlk64.dll';FileName=$driver},
        [pscustomobject]@{ModuleName='ggml-vulkan.dll';FileName=$backend},
        [pscustomobject]@{ModuleName='not-a-driver.dll';FileName=(Join-Path $base 'other.dll')})
    $selected=@(Select-FastLlmVulkanModulePaths -Modules $rows)
    Check ($selected.Count -eq 3 -and $selected -contains $loader -and $selected -contains $driver -and $selected -contains $backend) 'Module selection lost loader, AMD ICD or backend.'
    $observations=@($selected | ForEach-Object {[pscustomobject]@{name=[IO.Path]::GetFileName($_);path=$_;
        sizeBytes=4096;sha256=('a'*64);signatureStatus='Valid';fileVersion='1.2.3.4';productVersion='1.2.3.4';signer='AMD'}})
    $report=[pscustomobject]@{selectedModules=$observations}
    Assert-FastLlmVulkanModuleReportRows -Report $report;$passed++
    $observations[0].sha256=$null
    Reject {Assert-FastLlmVulkanModuleReportRows -Report $report} 'Missing module digest was accepted.'
    $observations[0].sha256='a'*64
    $observations[0].path=$observations[1].path
    Reject {Assert-FastLlmVulkanModuleReportRows -Report $report} 'Duplicate/mismatched module path was accepted.'
    Reject {Select-FastLlmVulkanModulePaths -Modules @($rows[1],$rows[2])} 'Missing Vulkan loader was accepted.'
    Reject {Select-FastLlmVulkanModulePaths -Modules @([pscustomobject]@{ModuleName='vulkan-1.dll';FileName='relative.dll'})} 'Relative module path was accepted.'
    $tooMany=@(for($i=0;$i -lt 33;$i++){[pscustomobject]@{ModuleName='vulkan-1.dll';FileName=$loader}})
    Reject {Select-FastLlmVulkanModulePaths -Modules $tooMany} 'Excess selected-module count was accepted.'

    foreach($bad in @('\\server\share\report.json','C:\\report.txt','report.json','C:\\folder\..\report.json',
            'C:\\private\existing.txt:report.json','C:\\private\rep?ort.json')){
        Reject {Assert-FastLlmVulkanModuleOutputSyntax -Path $bad} "Unsafe output syntax accepted: $bad"
    }
    Assert-FastLlmVulkanModuleOutputComponents -FullPath (Join-Path $base 'fresh.json') -Root ([IO.Path]::GetPathRoot($base))
    $passed++
    $existing=Join-Path $base 'existing.json';[IO.File]::WriteAllText($existing,'owned')
    Reject {Assert-FastLlmVulkanModuleOutputComponents -FullPath $existing -Root ([IO.Path]::GetPathRoot($base))} 'Existing report could be overwritten.'
    $linked=Join-Path $base 'linked'
    try{
        New-Item -ItemType SymbolicLink -Path $linked -Target $base -ErrorAction Stop | Out-Null
        Reject {Assert-FastLlmVulkanModuleOutputComponents -FullPath (Join-Path $linked 'report.json') -Root ([IO.Path]::GetPathRoot($base))} 'Reparse-point output parent was accepted.'
    }catch{
        if(Test-Path -LiteralPath $linked){throw}
    }
    $module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/FastLlm.psm1') -Force -PassThru -DisableNameChecking
    & $module {Initialize-FastLlmProcessHost}
    Check ($null -ne ('Bitworks.FastLlm.ProcessHost' -as [type])) 'Root collector cannot resolve its ProcessHost initializer in module scope.'
}finally{Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue}
Write-Host "Vulkan driver module helper tests passed: $passed"
