#requires -Version 5.1
# Settings additions: opening Settings and saving without touching the new rows must leave settings.json byte for byte as it was, whatever it held.
# The page's own Save argument logic (the @extra build and the one Set-FastLlmServingSettings call, taken from the page source by AST) runs through the real
# writer and reader on a temporary install root, for an empty file, each non-default value alone, all four, an unknown key, and values the reader normalises
# (slots 3, a wrong-case profile). The same logic with only one row toggled must write that one key and touch nothing else. Planted mutants of the page
# text prove each check. No WPF, GPU, network or bench; runs on every platform.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/FastLlm.ServingProfileRun.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.UiState.ps1')
$script:count=0
function Check([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$work=Join-Path ([IO.Path]::GetTempPath()) ('ui-fluent-settings-additions-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$script:installPath=$work
$noBom=New-Object Text.UTF8Encoding($false)
$pageText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentSettings.ps1'))

# The statements of the page's Save that build the serving write: $values, $savedThinking, $savedIdle, $extra and its four tests, and the one write.
function Get-PageSaveSnippet([string]$Text){
    $ast=[System.Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $fns=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-FastLlmUiFluentSettingsSave'},$true))
    if($fns.Count -ne 1){return $null}
    $try=@($fns[0].Body.EndBlock.Statements|Where-Object{$_ -is [System.Management.Automation.Language.TryStatementAst]})
    if($try.Count -lt 1){return $null}
    $parts=New-Object System.Collections.ArrayList
    $assigned=@('$values','$savedThinking','$savedIdle','$extra')
    foreach($st in @($try[0].Body.Statements)){
        $keep=$false
        if($st -is [System.Management.Automation.Language.AssignmentStatementAst] -and ($assigned -ccontains $st.Left.Extent.Text -or $st.Left.Extent.Text.StartsWith('$extra['))){$keep=$true}
        elseif($st -is [System.Management.Automation.Language.IfStatementAst] -and $st.Extent.Text.Contains('$extra[')){$keep=$true}
        elseif($st -is [System.Management.Automation.Language.PipelineAst] -and $st.Extent.Text.StartsWith('Set-FastLlmServingSettings ')){$keep=$true}
        if($keep){[void]$parts.Add($st.Extent.Text)}
    }
    # Nine statements on the real page; a planted mutant may drop one of the four (a bare $extra[...]= assignment stands in for its if), so at least eight.
    if($parts.Count -lt 8){return $null}
    return ($parts -join "`n")
}
$realSnippet=Get-PageSaveSnippet $pageText
Check ($null -ne $realSnippet) 'the page Save snippet is found (values, saved idle and thinking, @extra with its four tests, and the one serving write)'

function Write-Fixture([string]$Path,$Ordered){
    [IO.File]::WriteAllText($Path,(([pscustomobject]$Ordered)|ConvertTo-Json -Depth 6),$noBom)
}
# Runs the page's snippet against the file at the install root with the held values changed by $Change (a scriptblock over $held); returns the bytes before and after.
function Invoke-PageSave([string]$Snippet,$Change){
    $current=Get-FastLlmServingSettings -InstallRoot $script:installPath
    $current | Add-Member -NotePropertyName allowSwitch -NotePropertyValue $false -Force
    $savedHeld=ConvertTo-FastLlmUiSettingsHeld -Current $current
    $held=ConvertTo-FastLlmUiSettingsHeld -Current $current
    $st=@{ Saved=$savedHeld; Held=$held }
    if($null -ne $Change){ & $Change $held }
    $path=Join-Path $script:installPath 'settings.json'
    $before=[IO.File]::ReadAllBytes($path)
    $file=Join-Path $script:installPath ('snippet-'+[Guid]::NewGuid().ToString('N')+'.ps1')
    [IO.File]::WriteAllText($file,$Snippet,$noBom)
    . $file
    Remove-Item -LiteralPath $file -Force
    return [pscustomobject]@{ Before=$before; After=([IO.File]::ReadAllBytes($path)) }
}
function Get-Prop($Object,[string]$Name){ $p=$Object.PSObject.Properties[$Name]; if($null -eq $p){return $null}; return $p.Value }
function ConvertFrom-Bytes([byte[]]$Bytes){ return (ConvertFrom-Json ($noBom.GetString($Bytes))) }

$fixtures=[ordered]@{
    'empty file'=[ordered]@{}
    'profile long alone'=[ordered]@{contextProfile='long'}
    'slots 2 alone'=[ordered]@{slots=2}
    'embeddings on alone'=[ordered]@{embeddings='on'}
    'embedding port alone'=[ordered]@{embeddingPort=9100}
    'all four non-default'=[ordered]@{contextProfile='long';slots=2;embeddings='on';embeddingPort=9100}
    'an unknown key'=[ordered]@{zzUnknownKey='keep me'}
    'an unknown key beside all four'=[ordered]@{zzUnknownKey='keep me';contextProfile='long';slots=2;embeddings='on';embeddingPort=9100}
    'classic values beside all four'=[ordered]@{serverPort=9090;thinking='off';chatPage='on';idleStopMinutes=30;contextProfile='long';slots=2;embeddings='on';embeddingPort=9100}
    'invalid slots 3'=[ordered]@{slots=3}
    'wrong-case profile'=[ordered]@{contextProfile='Long'}
    'invalid embeddings and port'=[ordered]@{embeddings='ON';embeddingPort=70000}
    'every invalid saved value'=[ordered]@{zzUnknownKey='keep me';contextProfile='Long';slots=3;embeddings='ON';embeddingPort=70000}
}
$toggles=[ordered]@{
    embeddings=@{ Change={param($h) $h.embeddings=$(if([string]$h.embeddings -ceq 'on'){'off'}else{'on'})} }
    slots=@{ Change={param($h) $h.slots=$(if([int]$h.slots -eq 2){1}else{2})} }
    contextProfile=@{ Change={param($h) $h.contextProfile=$(if([string]$h.contextProfile -ceq 'long'){'default'}else{'long'})} }
    embeddingPort=@{ Change={param($h) $h.embeddingPort=$(if([int]$h.embeddingPort -eq 9200){9300}else{9200})} }
}

# One pass over every fixture for a page text. Returns the findings (an empty list when the page behaves).
function Get-ByteFindings([string]$Text){
    $f=New-Object System.Collections.ArrayList
    $snippet=Get-PageSaveSnippet $Text
    if($null -eq $snippet){[void]$f.Add('the page Save snippet is not found');return ,$f.ToArray()}
    $path=Join-Path $script:installPath 'settings.json'
    foreach($name in $fixtures.Keys){
        # Untouched: Held equals Saved, so the file must be byte for byte as it was.
        Write-Fixture $path $fixtures[$name]
        $r=Invoke-PageSave $snippet $null
        if([Convert]::ToBase64String($r.Before) -cne [Convert]::ToBase64String($r.After)){[void]$f.Add("untouched Save rewrote the file for: $name")}
    }
    # Only one row toggled: that one key is written and nothing else moves (the file as an object, key by key).
    foreach($tog in $toggles.Keys){
        foreach($name in @('empty file','every invalid saved value','an unknown key beside all four')){
            Write-Fixture $path $fixtures[$name]
            $r=Invoke-PageSave $snippet $toggles[$tog].Change
            $before=ConvertFrom-Bytes $r.Before
            $after=ConvertFrom-Bytes $r.After
            foreach($p in @($before.PSObject.Properties)){
                if($p.Name -ceq $tog){continue}
                $ap=$after.PSObject.Properties[$p.Name]
                if($null -eq $ap -or ($ap.Value|ConvertTo-Json -Compress) -cne ($p.Value|ConvertTo-Json -Compress)){[void]$f.Add("toggling only $tog changed '$($p.Name)' for: $name")}
            }
            foreach($p in @($after.PSObject.Properties)){
                if($p.Name -cne $tog -and $null -eq $before.PSObject.Properties[$p.Name]){[void]$f.Add("toggling only $tog added '$($p.Name)' for: $name")}
            }
        }
    }
    # The lead's case in full: an invalid saved slots and profile stay, an unknown key stays, and embeddings is written.
    Write-Fixture $path $fixtures['every invalid saved value']
    $r=Invoke-PageSave $snippet $toggles['embeddings'].Change
    $a=ConvertFrom-Bytes $r.After
    if([string](Get-Prop $a 'embeddings') -cne 'on'){[void]$f.Add('toggling only embeddings did not write embeddings on')}
    if([string](Get-Prop $a 'slots') -cne '3' -or [string](Get-Prop $a 'contextProfile') -cne 'Long' -or [string](Get-Prop $a 'zzUnknownKey') -cne 'keep me'){[void]$f.Add('toggling only embeddings touched slots, contextProfile or the unknown key')}
    # The key is written when the user does change it (the toggle is not a no-op), and a default is removed as the writer always did.
    Write-Fixture $path $fixtures['empty file']
    $r=Invoke-PageSave $snippet $toggles['slots'].Change
    if([string](Get-Prop (ConvertFrom-Bytes $r.After) 'slots') -cne '2'){[void]$f.Add('requests at once 2 was not written when changed')}
    Write-Fixture $path $fixtures['slots 2 alone']
    $r=Invoke-PageSave $snippet $toggles['slots'].Change
    if($null -ne (ConvertFrom-Bytes $r.After).PSObject.Properties['slots']){[void]$f.Add('requests at once back to 1 was not removed')}
    return ,$f.ToArray()
}

try{
    $real=Get-ByteFindings $pageText
    foreach($x in $real){Write-Host "FINDING: $x"}
    Check ($real.Count -eq 0) 'saving untouched leaves settings.json byte for byte as it was for every fixture, and toggling one row writes only that key'

    $lines=@{
        profile="        if([string]`$values.contextProfile -cne [string]`$st['Saved'].contextProfile){`$extra['KvContextProfile']=[string]`$values.contextProfile}`n"
        slots="        if([int]`$values.slots -ne [int]`$st['Saved'].slots){`$extra['KvSlots']=[int]`$values.slots}`n"
        embeddings="        if([string]`$values.embeddings -cne [string]`$st['Saved'].embeddings){`$extra['Embeddings']=[string]`$values.embeddings}`n"
        port="        if([int]`$values.embeddingPort -ne [int]`$st['Saved'].embeddingPort){`$extra['EmbeddingPort']=[int]`$values.embeddingPort}`n"
    }
    foreach($k in $lines.Keys){ Check ($pageText.Contains($lines[$k])) "self-check: the $k changed-test line anchors for the planted mutants" }
    # ONE predicate decides "caught on bytes": a mutant expects it true and the comment-only control expects it false. The finder returns its list with a leading
    # comma; wrapping the call in @() would nest it and always count 1, so the list is read as it is, and a missing snippet does not count.
    function Test-BytesCaught([string]$Text){
        $found=Get-ByteFindings $Text
        return [bool](@($found|Where-Object{$_ -cne 'the page Save snippet is not found'}).Count -ge 1)
    }
    function Test-Mutant([string]$Name,[string]$Plant){
        Check ($Plant -cne $pageText) "mutant is a real change: $Name"
        $bytesCaught=Test-BytesCaught $Plant
        Check $bytesCaught "mutation check: the byte-identical test flags $Name on bytes (not only as a missing snippet)"
    }
    # A permanent CONTROL: a comment-only change to the page text must give no finding on bytes, so a finder or counter that flags everything fails here.
    Check (-not (Test-BytesCaught ($pageText+"`n# control: a comment-only change`n"))) 'control check: a comment-only change to the page text is not flagged'
    Test-Mutant 'KvSlots always passed with 1 (it resets a saved 2)' $pageText.Replace($lines.slots,"        `$extra['KvSlots']=1`n")
    Test-Mutant 'KvSlots always passed from the held value (it rewrites a saved 3)' $pageText.Replace($lines.slots,"        `$extra['KvSlots']=[int]`$values.slots`n")
    Test-Mutant 'the Embeddings key always passed' $pageText.Replace($lines.embeddings,"        `$extra['Embeddings']=[string]`$values.embeddings`n")
    Test-Mutant 'the profile key always passed (it rewrites a wrong-case Long)' $pageText.Replace($lines.profile,"        `$extra['KvContextProfile']=[string]`$values.contextProfile`n")
    Test-Mutant 'the port key always passed (it rewrites an invalid saved port)' $pageText.Replace($lines.port,"        `$extra['EmbeddingPort']=[int]`$values.embeddingPort`n")
    Test-Mutant 'the slots changed-test inverted' $pageText.Replace('[int]$values.slots -ne [int]$st[''Saved''].slots','[int]$values.slots -eq [int]$st[''Saved''].slots')
    Test-Mutant 'the embeddings changed-test inverted' $pageText.Replace('[string]$values.embeddings -cne [string]$st[''Saved''].embeddings','[string]$values.embeddings -ceq [string]$st[''Saved''].embeddings')
    Test-Mutant 'the profile changed-test inverted' $pageText.Replace('[string]$values.contextProfile -cne [string]$st[''Saved''].contextProfile','[string]$values.contextProfile -ceq [string]$st[''Saved''].contextProfile')
    Test-Mutant 'the embeddings key dropped (a toggle is never written)' $pageText.Replace($lines.embeddings,'')
    Test-Mutant 'the slots changed-test comparing the wrong saved field' $pageText.Replace('[int]$values.slots -ne [int]$st[''Saved''].slots','[int]$values.slots -ne [int]$st[''Saved''].embeddingPort')
    Write-Host "Settings additions byte-identical tests passed ($($script:count) checks)."
}
finally{
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
