#requires -Version 5.1
# Downloaded-model manager tests: listing, safe removal with every refusal reason, leftover partials, and the models CLI verbs.
# Module cases use a copy of the catalog with tiny model sizes; the CLI cases use the real catalog's smallest model as a sparse file. No engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
$module=Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -PassThru -ErrorAction Stop
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function Write-Utf8([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false)))}

$work=Join-Path ([IO.Path]::GetTempPath()) ('model-store-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$holders=New-Object System.Collections.ArrayList
try {
    $realCatalog=Join-Path $root 'config/catalog.json'
    $smallDir=Join-Path $work 'small-catalog'
    New-Item -ItemType Directory -Path $smallDir -Force | Out-Null
    $doc=Get-Content -LiteralPath $realCatalog -Raw | ConvertFrom-Json
    foreach($m in @($doc.models)){ $m.sizeBytes=[int64]4096 }
    $smallCatalog=Join-Path $smallDir 'catalog.json'
    Write-Utf8 $smallCatalog ($doc | ConvertTo-Json -Depth 20)
    $catalogDoc=Get-Content -LiteralPath $smallCatalog -Raw | ConvertFrom-Json
    function Get-Entry([string]$Id) { @($catalogDoc.models | Where-Object { $_.id -eq $Id })[0] }
    $idA='qwen3.5-2b-q6-k'; $idB='qwen3.5-4b-iq4-xs'
    function New-Root([string[]]$ModelIds,[switch]$NoReceipt) {
        $dir=Join-Path $work ('install-'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'models') -Force | Out-Null
        foreach($id in $ModelIds){
            $m=Get-Entry $id
            $fs=[IO.File]::Create((Join-Path (Join-Path $dir 'models') ([string]$m.file)))
            try { $fs.SetLength([int64]$m.sizeBytes) } finally { $fs.Dispose() }
            if(-not $NoReceipt){ & $module { param($m,$r) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $r -AcceptanceMode explicit-switch } $m $dir }
        }
        return $dir
    }
    function ModelPath($Root,[string]$Id) { Join-Path (Join-Path $Root 'models') ([string](Get-Entry $Id).file) }
    function Remove-Model($Root,[string]$Id,[hashtable]$Extra=@{}) {
        $a=@{InstallRoot=$Root;CatalogPath=$smallCatalog;ModelId=$Id}
        foreach($k in $Extra.Keys){ $a[$k]=$Extra[$k] }
        Remove-FastLlmInstalledModel @a
    }
    function Hold-Lock([string]$Path) {
        $h=[IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        [void]$holders.Add($h); return $h
    }
    function Release($Handle) { $Handle.Dispose(); [void]$holders.Remove($Handle) }
    function Throw-Seam([Exception]$Exception) { { param($p) throw $Exception }.GetNewClosure() }

    # ---- list-installed-rows
    $r=New-Root @($idA,$idB)
    Remove-Item -LiteralPath (Join-Path $r 'consents') -Recurse -Force
    & $module { param($m,$r) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $r -AcceptanceMode explicit-switch } (Get-Entry $idA) $r
    $fs=[IO.File]::Open((ModelPath $r $idB),'Open','ReadWrite'); try { $fs.SetLength(10) } finally { $fs.Dispose() }
    $rows=@(Get-FastLlmInstalledModels -InstallRoot $r -CatalogPath $smallCatalog)
    Check ($rows.Count -eq 2) 'list-installed-rows: only models whose file is present are listed'
    Check ((@($rows[0].PSObject.Properties.Name) -join ',') -eq 'id,file,sizeBytes,present,sizeMatches,consent,inUse,inUseReason') 'list-installed-rows: row property names'
    $ra=@($rows | Where-Object { $_.id -eq $idA })[0]; $rb=@($rows | Where-Object { $_.id -eq $idB })[0]
    Check ($ra.present -and $ra.sizeMatches -and $ra.consent -and -not $ra.inUse -and $ra.inUseReason -eq '') 'list-installed-rows: a healthy model'
    Check ($rb.present -and -not $rb.sizeMatches -and -not $rb.consent -and -not $rb.inUse) 'list-installed-rows: a short, receipt-less file is reported, not hidden'
    Check (@(Get-FastLlmInstalledModels -InstallRoot (Join-Path $work 'nowhere') -CatalogPath $smallCatalog).Count -eq 0) 'list-installed-rows: a missing install root lists nothing'

    # ---- refusal reasons
    $res=Remove-Model $r 'no-such-model'
    Check ($res.removed -eq $false -and $res.reason -eq 'not-in-catalog') 'remove-refuses-not-in-catalog'
    $res=Remove-Model $r $idB
    Check ($res.removed -eq $false -and $res.reason -eq 'not-installed' -and (Test-Path -LiteralPath (ModelPath $r $idB))) 'remove-refuses-not-installed: a short file with no receipt stays'
    $res=Remove-Model (New-Root @()) $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'not-installed') 'remove-refuses-not-installed: nothing downloaded'

    # path-outside-install-root: a model file that is a link is never followed
    $rl=New-Root @()
    $outside=Join-Path $work 'outside.bin'
    [IO.File]::WriteAllBytes($outside,(New-Object byte[] 4096))
    $linked=$false
    try { New-Item -ItemType SymbolicLink -Path (ModelPath $rl $idA) -Target $outside -ErrorAction Stop | Out-Null; $linked=$true } catch { Write-Host 'SKIP: remove-refuses-path-outside-install-root (symbolic links not available here)' }
    if($linked){
        $res=Remove-Model $rl $idA
        Check ($res.removed -eq $false -and $res.reason -eq 'path-outside-install-root' -and (Test-Path -LiteralPath $outside)) 'remove-refuses-path-outside-install-root'
    }

    # serving: another process holds the operation lock and status.json names the model
    $rs=New-Root @($idA)
    $lockHandle=Enter-FastLlmOperation -InstallRoot $rs
    [void]$holders.Add($lockHandle)
    Write-FastLlmState -InstallRoot $rs -State ([ordered]@{schemaVersion=1;runId=[Guid]::NewGuid().ToString('N');phase='ready';modelId=$idA})
    $res=Remove-Model $rs $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'serving' -and (Test-Path -LiteralPath (ModelPath $rs $idA))) 'remove-refuses-serving'
    $listed=@(Get-FastLlmInstalledModels -InstallRoot $rs -CatalogPath $smallCatalog)[0]
    Check ($listed.inUse -eq $true -and $listed.inUseReason -eq 'serving') 'list-installed-rows: the served model is marked in use'
    Release $lockHandle

    # operation-in-progress: the lock is held, status says nothing about this model
    $ro=New-Root @($idA)
    $lockHandle=Enter-FastLlmOperation -InstallRoot $ro
    [void]$holders.Add($lockHandle)
    $res=Remove-Model $ro $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'operation-in-progress' -and (Test-Path -LiteralPath (ModelPath $ro $idA))) 'remove-refuses-operation-in-progress'
    $leftRes=@(Remove-FastLlmModelLeftovers -InstallRoot $ro -Names @('x.partial'))
    Check ($leftRes[0].removed -eq $false -and $leftRes[0].reason -eq 'operation-in-progress') 'remove-refuses-operation-lock: leftovers too'
    Release $lockHandle
    $res=Remove-Model $ro $idA
    Check ($res.removed -eq $true) 'remove-refuses-operation-lock: released lock lets the remove through'

    # background-owned: a live background record for this model
    $rb2=New-Root @($idA,$idB)
    $stateDir=Join-Path $rb2 'state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $record=Join-Path $stateDir 'background-host.json'
    Write-Utf8 $record (@{schemaVersion=1;phase='loading';modelId=$idA} | ConvertTo-Json)
    $res=Remove-Model $rb2 $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'background-owned' -and (Test-Path -LiteralPath (ModelPath $rb2 $idA))) 'remove-refuses-background-owned'
    $res=Remove-Model $rb2 $idB
    Check ($res.removed -eq $true) 'remove-refuses-background-owned: a record for another model does not block this one'
    Write-Utf8 $record (@{schemaVersion=1;phase='stopped';modelId=$idA} | ConvertTo-Json)
    $res=Remove-Model $rb2 $idA
    Check ($res.removed -eq $true) 'remove-refuses-background-owned: a stopped record does not block'
    $rb3=New-Root @($idA)
    New-Item -ItemType Directory -Path (Join-Path $rb3 'state') -Force | Out-Null
    Write-Utf8 (Join-Path (Join-Path $rb3 'state') 'background-host.json') '{not json'
    $res=Remove-Model $rb3 $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'background-owned') 'remove-refuses-background-owned: an unreadable record refuses (in doubt)'
    $rb4=New-Root @($idA)
    New-Item -ItemType Directory -Path (Join-Path $rb4 'state') -Force | Out-Null
    Write-Utf8 (Join-Path (Join-Path $rb4 'state') 'background-host.json') ('{"schemaVersion":1,"phase":"stopped","pad":"'+('x'*70000)+'"}')
    $res=Remove-Model $rb4 $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'background-owned') 'remove-refuses-background-owned: a record over 64 KiB refuses'

    # download-in-progress
    $rd=New-Root @($idA)
    $entry=Get-Entry $idA
    $lockPath=Join-Path (Join-Path $rd 'models') ([string]$entry.file+'.'+([string]$entry.sha256).Substring(0,16)+'.lock')
    $h=Hold-Lock $lockPath
    $res=Remove-Model $rd $idA
    Check ($res.removed -eq $false -and $res.reason -eq 'download-in-progress' -and (Test-Path -LiteralPath (ModelPath $rd $idA))) 'remove-refuses-held-download-lock'
    Check ((@(Get-FastLlmInstalledModels -InstallRoot $rd -CatalogPath $smallCatalog)[0]).inUseReason -eq 'download-in-progress') 'list-installed-rows: a held download lock marks the model in use'
    Release $h
    $res=Remove-Model $rd $idA
    Check ($res.removed -eq $true -and -not (Test-Path -LiteralPath (ModelPath $rd $idA))) 'remove-ignores-stale-lock: an openable .lock does not block'

    # delete failures stay plain refusals
    foreach($hr in @('80070020','80070021')){
        $rx=New-Root @($idA)
        $ex=New-Object IO.IOException('The process cannot access the file.',[Convert]::ToInt32($hr,16))
        $caught=$null; $res=$null
        try { $res=Remove-Model $rx $idA @{DeleteFile=(Throw-Seam $ex)} } catch { $caught=$_ }
        Check ($null -eq $caught -and $res.removed -eq $false -and $res.reason -eq 'in-use' -and (Test-Path -LiteralPath (ModelPath $rx $idA))) "remove-sharing-violation-in-use: HResult 0x$hr is in-use, no exception escapes"
    }
    $rx=New-Root @($idA)
    $caught=$null; $res=$null
    try { $res=Remove-Model $rx $idA @{DeleteFile=(Throw-Seam (New-Object UnauthorizedAccessException('Access to the path is denied.')))} } catch { $caught=$_ }
    Check ($null -eq $caught -and $res.removed -eq $false -and $res.reason -eq 'access-denied') 'access-denied-plain: UnauthorizedAccessException gives access-denied, no exception escapes'
    $res=Remove-Model $rx $idA @{DeleteFile=(Throw-Seam (New-Object IO.IOException('disk error')))}
    Check ($res.removed -eq $false -and $res.reason -eq 'delete-failed') 'remove: any other delete failure is a plain delete-failed'

    # ok + consent kept
    $rk=New-Root @($idA,$idB)
    $receipt=@(Get-ChildItem -LiteralPath (Join-Path $rk 'consents') -File | Where-Object { $_.Name -like "$idA-*" })[0]
    $before=[IO.File]::ReadAllBytes($receipt.FullName)
    $res=Remove-Model $rk $idA
    Check ($res.removed -eq $true -and $res.reason -eq 'ok' -and -not (Test-Path -LiteralPath (ModelPath $rk $idA)) -and (Test-Path -LiteralPath (ModelPath $rk $idB))) 'remove: ok removes only the named model'
    $after=[IO.File]::ReadAllBytes($receipt.FullName)
    Check (@(Get-ChildItem -LiteralPath (Join-Path $rk 'consents') -File).Count -eq 2 -and [Convert]::ToBase64String($before) -eq [Convert]::ToBase64String($after)) 'remove-keeps-consent: the receipts are untouched'
    $lockProbe=Enter-FastLlmOperation -InstallRoot $rk
    Check ($null -ne $lockProbe) 'remove: the operation lock is released afterwards'
    $lockProbe.Dispose()

    # ---- confirmation text
    $display=Get-FastLlmModelDisplayName -Model (Get-Entry $idA)
    Check ($display -eq 'Qwen3.5-2B Q6_K') "remove-confirmation-text: display name (observed: $display)"
    Check ((Get-FastLlmModelRemovalConfirmationText -DisplayName 'Qwen3.8-27B UD-IQ4_XS' -SizeBytes 14252845984) -ceq 'Removes Qwen3.8-27B UD-IQ4_XS (14.3 GB) from this PC. You can download it again later.') 'remove-confirmation-text: exact wording, decimal GB, one decimal'
    Check ((Get-FastLlmModelRemovalConfirmationText -DisplayName 'X' -SizeBytes 1574961408) -ceq 'Removes X (1.6 GB) from this PC. You can download it again later.') 'remove-confirmation-text: 1574961408 bytes is 1.6 GB'
    $savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('de-DE')
        Check ((Format-FastLlmModelStoreGigabytes -Bytes 14252845984) -ceq '14.3') 'remove-confirmation-text: the invariant culture keeps the decimal point'
    } catch { Write-Host 'SKIP: remove-confirmation-text culture case (de-DE not available here)' }
    finally { [Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture }

    # ---- leftovers
    $rlv=New-Root @($idA)
    $mdir=Join-Path $rlv 'models'
    $entry=Get-Entry $idA
    $sha16=([string]$entry.sha256).Substring(0,16)
    $partialName=[string]$entry.file+'.'+$sha16+'.partial'
    $names=@($partialName,
        ([string]$entry.file+'.corrupt.20261108010101.'+('a'*32)),
        ($partialName+'.corrupt.20261108010101.'+('b'*32)),
        ($partialName+'.corrupt.oversize.20261108010101.'+('c'*32)),
        ($partialName+'.corrupt.redirect.20261108010101.'+('d'*32)),
        '0123abcd.corrupt')
    foreach($n in $names){ [IO.File]::WriteAllBytes((Join-Path $mdir $n),(New-Object byte[] 100)) }
    $keepNames=@('notes.txt',([string]$entry.file+'.'+$sha16+'.lock'),'0123abcg.corrupt')
    foreach($n in $keepNames){ [IO.File]::WriteAllBytes((Join-Path $mdir $n),(New-Object byte[] 5)) }
    $left=@(Get-FastLlmModelLeftovers -InstallRoot $rlv)
    Check ((@($left | ForEach-Object { $_.name } | Sort-Object) -join '|') -ceq ((@($names | Sort-Object)) -join '|')) 'leftovers: lists the partial, every corrupt form and the short corrupt name only'
    Check ((@($left[0].PSObject.Properties.Name) -join ',') -eq 'name,sizeBytes,kind,locked') 'leftovers: row property names'
    Check (@($left | Where-Object { $_.kind -eq 'partial' }).Count -eq 1 -and @($left | Where-Object { $_.kind -eq 'corrupt' }).Count -eq 5 -and @($left | Where-Object { $_.sizeBytes -ne 100 }).Count -eq 0) 'leftovers: kinds and sizes'
    $h=Hold-Lock (Join-Path $mdir ([string]$entry.file+'.'+$sha16+'.lock'))
    $left=@(Get-FastLlmModelLeftovers -InstallRoot $rlv)
    Check ((@($left | Where-Object { $_.locked }) | ForEach-Object { $_.name }) -ceq $partialName) 'leftovers: the partial whose download lock is held is locked'
    $res=@(Remove-FastLlmModelLeftovers -InstallRoot $rlv -Names @($partialName))
    Check ($res[0].removed -eq $false -and $res[0].reason -eq 'download-in-progress' -and (Test-Path -LiteralPath (Join-Path $mdir $partialName))) 'leftovers: a locked partial is refused'
    Release $h

    # leftovers-need-explicit-names
    $res=@(Remove-FastLlmModelLeftovers -InstallRoot $rlv -Names @([string]$entry.file,'notes.txt','..\outside.partial','../outside.partial',($partialName.ToUpperInvariant()),'0123abcg.corrupt'))
    Check (@($res | Where-Object { $_.removed }).Count -eq 0 -and @($res | Where-Object { $_.reason -ne 'not-a-leftover' }).Count -eq 0) 'leftovers-need-explicit-names: a model file, a stranger, a path or a wrong-case name all refuse'
    Check ((Test-Path -LiteralPath (ModelPath $rlv $idA)) -and (Test-Path -LiteralPath (Join-Path $mdir 'notes.txt')) -and (Test-Path -LiteralPath (Join-Path $mdir $partialName))) 'leftovers-need-explicit-names: nothing was deleted'
    $res=@(Remove-FastLlmModelLeftovers -InstallRoot $rlv -Names @($partialName) -DeleteFile (Throw-Seam (New-Object UnauthorizedAccessException('denied'))))
    Check ($res[0].removed -eq $false -and $res[0].reason -eq 'access-denied') 'leftovers: access-denied is a plain result'
    $res=@(Remove-FastLlmModelLeftovers -InstallRoot $rlv -Names @($left | ForEach-Object { $_.name }))
    Check (@($res | Where-Object { -not $_.removed }).Count -eq 0 -and @(Get-FastLlmModelLeftovers -InstallRoot $rlv).Count -eq 0) 'leftovers: listed names are removed'
    Check ((Test-Path -LiteralPath (ModelPath $rlv $idA)) -and (Test-Path -LiteralPath (Join-Path $mdir 'notes.txt')) -and @(Get-ChildItem -LiteralPath (Join-Path $rlv 'consents') -File).Count -eq 1) 'leftovers: the model, other files and consent stay'
    Check (@(Get-FastLlmModelLeftovers -InstallRoot (Join-Path $work 'nowhere')).Count -eq 0) 'leftovers: a missing install root lists nothing'

    # ---- CLI (child processes; the real catalog's smallest model as a sparse file)
    $pwshPath=(Get-Process -Id $PID).Path
    $cli=Join-Path $root 'fast-llm.ps1'
    function Invoke-PwshChild([object[]]$ChildArgs) {
        $previous=$ErrorActionPreference
        $ErrorActionPreference='Continue'
        try {
            $text=(& $pwshPath @ChildArgs 2>&1 | ForEach-Object { if($_ -is [Management.Automation.ErrorRecord]){ $_.ToString() } else { [string]$_ } } | Out-String)
            $code=$LASTEXITCODE
        } finally { $ErrorActionPreference=$previous }
        [pscustomobject]@{Text=$text;Code=$code}
    }
    function Invoke-Cli([string[]]$CliArgs) { Invoke-PwshChild (@('-NoProfile','-NonInteractive','-File',$cli)+$CliArgs) }
    function Get-CliGuard([string]$CliArguments) {
        $command='try { & '''+$cli+''' '+$CliArguments+'; exit $LASTEXITCODE } catch { [Console]::Out.WriteLine($_.Exception.Message); exit 1 }'
        Invoke-PwshChild @('-NoProfile','-NonInteractive','-Command',$command)
    }
    $g=Get-CliGuard 'plan -Installed'
    Check ($g.Code -ne 0 -and $g.Text -match 'supported only by models') 'cli guard: -Installed only with models'
    $g=Get-CliGuard 'doctor -RemoveQuarantined'
    Check ($g.Code -ne 0 -and $g.Text -match 'supported only by models') 'cli guard: -RemoveQuarantined only with models'
    $g=Get-CliGuard 'status -Remove x'
    Check ($g.Code -ne 0 -and $g.Text -match 'only by components and models') 'cli guard: -Remove only with components and models'
    $g=Get-CliGuard 'status -Yes'
    Check ($g.Code -ne 0 -and $g.Text -match 'only by update and models') 'cli guard: -Yes only with update and models'
    $g=Get-CliGuard 'models -Installed -Remove qwen3.5-2b-q6-k'
    Check ($g.Code -ne 0 -and $g.Text -match 'models takes one of') 'cli guard: the models verbs exclude each other'
    $g=Get-CliGuard 'models -Yes'
    Check ($g.Code -ne 0 -and $g.Text -match 'only with models -Remove or -RemoveQuarantined') 'cli guard: -Yes needs a removing verb with models'

    $cliChildrenElevated=$false
    if($env:OS -eq 'Windows_NT'){ $cliChildrenElevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    if($cliChildrenElevated){ Write-Host 'SKIP: models CLI child cases (fast-llm.ps1 refuses elevation; they run as a standard user in the bench native gate)' }
    else {
        $real=(Get-Content -LiteralPath $realCatalog -Raw | ConvertFrom-Json)
        $realEntry=@($real.models | Where-Object { $_.id -eq $idA })[0]
        function New-CliRoot {
            $dir=Join-Path $work ('cli-'+[Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $dir 'models') -Force | Out-Null
            $file=Join-Path (Join-Path $dir 'models') ([string]$realEntry.file)
            [IO.File]::WriteAllBytes($file,(New-Object byte[] 0))
            if($env:OS -eq 'Windows_NT'){ & fsutil sparse setflag $file | Out-Null }
            $fs=[IO.File]::Open($file,'Open','ReadWrite'); try { $fs.SetLength([int64]$realEntry.sizeBytes) } finally { $fs.Dispose() }
            & $module { param($m,$r) Write-FastLlmModelConsentReceipt -Model $m -InstallRoot $r -AcceptanceMode explicit-switch } $realEntry $dir
            return $dir
        }
        $expectedText=Get-FastLlmModelRemovalConfirmationText -DisplayName (Get-FastLlmModelDisplayName -Model $realEntry) -SizeBytes ([int64]$realEntry.sizeBytes)
        Check ($expectedText -ceq 'Removes Qwen3.5-2B Q6_K (1.6 GB) from this PC. You can download it again later.') "remove-confirmation-text: the real catalog entry reads as expected (observed: $expectedText)"

        $cr=New-CliRoot
        $out=Invoke-Cli @('models','-Installed','-InstallRoot',$cr)
        Check ($out.Code -eq 0 -and $out.Text -match [regex]::Escape($idA) -and $out.Text -match 'Free disk space') 'cli: models -Installed lists the model and the free disk space'
        $out=Invoke-Cli @('models','-Installed','-AsJson','-InstallRoot',$cr)
        $json=$out.Text | ConvertFrom-Json
        Check ($out.Code -eq 0 -and @($json).Count -eq 1 -and $json[0].id -eq $idA -and $json[0].sizeMatches -eq $true) 'cli: models -Installed -AsJson prints the rows'

        $out=Invoke-Cli @('models','-Remove',$idA,'-InstallRoot',$cr)
        Check ($out.Code -ne 0 -and $out.Text -match 'confirmation-required' -and $out.Text.Contains($expectedText) -and (Test-Path -LiteralPath (Join-Path (Join-Path $cr 'models') ([string]$realEntry.file)))) 'cli-remove-asks: no -Yes in a non-interactive host prints the text, exits non-zero with confirmation-required and removes nothing'
        $out=Invoke-Cli @('models','-Remove','no-such-model','-Yes','-InstallRoot',$cr)
        Check ($out.Code -ne 0 -and $out.Text -match 'not-in-catalog') 'cli: an unknown model id fails with not-in-catalog'
        $out=Invoke-Cli @('models','-Remove',$idB,'-Yes','-InstallRoot',$cr)
        Check ($out.Code -ne 0 -and $out.Text -match 'not-installed') 'cli: a model that is not downloaded fails with not-installed'

        # remove-refuses-operation-lock
        $lockHandle=Enter-FastLlmOperation -InstallRoot $cr
        [void]$holders.Add($lockHandle)
        $out=Invoke-Cli @('models','-Remove',$idA,'-Yes','-InstallRoot',$cr)
        Check ($out.Code -ne 0 -and $out.Text -match 'operation-in-progress' -and (Test-Path -LiteralPath (Join-Path (Join-Path $cr 'models') ([string]$realEntry.file)))) 'remove-refuses-operation-lock: models -Remove exits non-zero with operation-in-progress while another handle holds the lock'
        $out=Invoke-Cli @('models','-RemoveQuarantined','-Yes','-InstallRoot',$cr)
        Check ($out.Code -eq 0 -and $out.Text -match 'no leftover') 'cli: -RemoveQuarantined with nothing to remove needs no lock'
        Release $lockHandle

        # leftovers-second-confirmation
        $mdir=Join-Path $cr 'models'
        $partial=Join-Path $mdir ([string]$realEntry.file+'.'+([string]$realEntry.sha256).Substring(0,16)+'.partial')
        [IO.File]::WriteAllBytes($partial,(New-Object byte[] 64))
        $out=Invoke-Cli @('models','-RemoveQuarantined','-InstallRoot',$cr)
        Check ($out.Code -ne 0 -and $out.Text -match 'confirmation-required' -and $out.Text.Contains([IO.Path]::GetFileName($partial)) -and (Test-Path -LiteralPath $partial)) 'leftovers-second-confirmation: lists the leftovers, then without -Yes exits non-zero with confirmation-required and deletes nothing'
        $out=Invoke-Cli @('models','-Installed','-InstallRoot',$cr)
        Check ($out.Text.Contains([IO.Path]::GetFileName($partial))) 'cli: models -Installed lists the leftovers after the table'
        $out=Invoke-Cli @('models','-RemoveQuarantined','-Yes','-InstallRoot',$cr)
        Check ($out.Code -eq 0 -and -not (Test-Path -LiteralPath $partial) -and (Test-Path -LiteralPath (Join-Path $mdir ([string]$realEntry.file)))) 'leftovers-second-confirmation: with -Yes the leftovers go and the model stays'

        # remove with -Yes
        $receiptCount=@(Get-ChildItem -LiteralPath (Join-Path $cr 'consents') -File).Count
        $out=Invoke-Cli @('models','-Remove',$idA,'-Yes','-InstallRoot',$cr)
        Check ($out.Code -eq 0 -and $out.Text.Contains($expectedText) -and -not (Test-Path -LiteralPath (Join-Path $mdir ([string]$realEntry.file)))) 'cli: models -Remove -Yes removes the model'
        Check (@(Get-ChildItem -LiteralPath (Join-Path $cr 'consents') -File).Count -eq $receiptCount) 'remove-keeps-consent: the CLI remove leaves the receipt'
    }

    # ---- source guards
    $storeText=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.ModelStore.ps1') -Raw
    Check ($storeText -notmatch 'Get-FileHash' -and $storeText -notmatch 'ComputeHash') 'the model store never hashes a model file'
} finally {
    foreach($h in @($holders)){ try { $h.Dispose() } catch { } }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "model-store-tests: $script:count checks passed"
$global:LASTEXITCODE = 0
