#requires -Version 5.1
# Serving settings tests: port read/write, strict validation, precedence, and the bench-path tripwire.
# Pure file work in temp folders; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Throws([scriptblock]$Action,[string]$Pattern) {
    $caught=$false;$observed='no exception'
    try { & $Action | Out-Null } catch {
        $caught=[bool]([string]$_.Exception.Message -match $Pattern)
        $observed=[regex]::Replace([string]$_.Exception.Message,'[\x00-\x1f\x7f]',' ')
        if($observed.Length -gt 240){$observed=$observed.Substring(0,240)}
    }
    if(-not $caught){throw "FAIL: rejects $Pattern (observed: $observed)"}
    Check $true "rejects $Pattern"
}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}
function New-Root {
    $path=Join-Path ([IO.Path]::GetTempPath()) ('serving-settings-tests-'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}
$work=New-Root
try {
    # absent-file-defaults
    $r=Join-Path $work 'a'; New-Item -ItemType Directory -Path $r | Out-Null
    $s=Get-FastLlmServingSettings -InstallRoot $r
    Check ($s.serverPort -eq 8080) 'absent-file-defaults: port 8080'
    Check ($s.malformed -eq $false) 'absent-file-defaults: not malformed'
    Check ($s.thinking -ceq 'auto' -and $s.chatPage -ceq 'off') 'absent-file-defaults: thinking auto, chatPage off'

    # set-port-preserves-unknown
    $r=Join-Path $work 'b'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{"vulkanBarMitigation":"on","x":1}'
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18181
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check ($o.vulkanBarMitigation -ceq 'on' -and $o.x -eq 1 -and $o.serverPort -eq 18181) 'set-port-preserves-unknown: all three keys present'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 18181) 'set-port-preserves-unknown: Get reads 18181'
    Check (@(Get-ChildItem -LiteralPath $r -Filter '*.tmp-*').Count -eq 0) 'set-port-preserves-unknown: no temp file left'

    # default-port-removes-key
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 8080
    $o=Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw | ConvertFrom-Json
    Check (-not ($o.PSObject.Properties.Name -contains 'serverPort')) 'default-port-removes-key: serverPort absent'
    Check ($o.x -eq 1) 'default-port-removes-key: unknown key kept'

    # port-range
    $r=Join-Path $work 'c'; New-Item -ItemType Directory -Path $r | Out-Null
    foreach($bad in 1023,0,65536,-1){ Throws { Set-FastLlmServingSettings -InstallRoot $r -ServerPort $bad } 'serving-settings-invalid-port' }
    foreach($bad in ([double]18181.5),'18181.5','abc','',$null){ Throws { Set-FastLlmServingSettings -InstallRoot $r -ServerPort $bad } 'serving-settings-invalid-port' }
    Check (-not (Test-Path -LiteralPath (Join-Path $r 'settings.json'))) 'port-range: refused non-integers wrote nothing'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ServerPort=18181.5} } 'serving-settings-invalid-port'
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort '18181'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 18181) 'port-range: integer text accepted'
    foreach($good in 1024,65535){ Set-FastLlmServingSettings -InstallRoot $r -ServerPort $good; Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq $good) "port-range: $good accepted" }
    Check ((Test-FastLlmServerPort -Port 1023) -eq $false -and (Test-FastLlmServerPort -Port 1024) -eq $true -and (Test-FastLlmServerPort -Port 65535) -eq $true -and (Test-FastLlmServerPort -Port 65536) -eq $false) 'port-range: Test-FastLlmServerPort bounds'
    # invalid stored value reads as the default
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":80}'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 8080) 'port-range: invalid stored port reads as default'
    Write-Utf8 (Join-Path $r 'settings.json') '{"serverPort":"18181"}'
    Check ((Get-FastLlmServingSettings -InstallRoot $r).serverPort -eq 8080) 'port-range: non-integer stored port reads as default'

    # malformed-settings-refuse-write
    $r=Join-Path $work 'd'; New-Item -ItemType Directory -Path $r | Out-Null
    Write-Utf8 (Join-Path $r 'settings.json') '{bad'
    $s=Get-FastLlmServingSettings -InstallRoot $r
    Check ($s.malformed -eq $true -and $s.serverPort -eq 8080) 'malformed-settings-refuse-write: Get returns defaults with malformed'
    Throws { Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18181 } 'serving-settings-malformed'
    Check ((Get-Content -LiteralPath (Join-Path $r 'settings.json') -Raw) -ceq '{bad') 'malformed-settings-refuse-write: file untouched'

    # resolve-precedence
    $r=Join-Path $work 'e'; New-Item -ItemType Directory -Path $r | Out-Null
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 18181
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ServerPort=19191}
    Check ($x.serverPort -eq 19191 -and $x.source -ceq 'parameter') 'resolve-precedence: parameter wins'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{}
    Check ($x.serverPort -eq 18181 -and $x.source -ceq 'settings') 'resolve-precedence: settings next'
    $x=Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{} -IgnoreUserSettings
    Check ($x.serverPort -eq 8080 -and $x.source -ceq 'default') 'resolve-precedence: ignore settings gives default'
    Check ($x.thinking -ceq 'auto' -and $x.chatPage -ceq 'off') 'resolve-precedence: thinking and chatPage defaults'
    Throws { Resolve-FastLlmServingOptions -InstallRoot $r -Bound @{ServerPort=80} } 'serving-settings-invalid-port'

    # tripwire-plan-reads-no-settings
    $watched='FastLlm.psm1','FastLlm.Runtime.ps1','FastLlm.Preload.ps1','FastLlm.Recipes.ps1','FastLlm.RunLog.ps1','FastLlm.ModelStore.ps1'
    foreach($name in $watched){
        $file=Join-Path (Join-Path $root 'src') $name
        if(-not (Test-Path -LiteralPath $file -PathType Leaf)){ Check $true "tripwire: $name absent, skipped"; continue }
        $text=Get-Content -LiteralPath $file -Raw
        Check ($text -notmatch 'Get-FastLlmServingSettings' -and $text -notmatch 'Resolve-FastLlmServingOptions' -and $text -notmatch 'settings\.json') "tripwire-plan-reads-no-settings: $name"
    }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "serving-settings-tests: $script:count checks passed"
