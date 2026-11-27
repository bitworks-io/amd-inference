#requires -Version 5.1
# Off-screen WPF render and accessibility checks for the Fluent window pages: a clean sample page across a 40-case matrix (3 themes, scales,
# text sizes, window sizes, up to Windows' 225% text size), and one negative page per check to prove each one fires. Windows only; elsewhere it skips.
# PNGs go to FASTLLM_RENDER_DIR, else $env:RUNNER_TEMP\fastllm-fluent-render, else the temp folder. No window is shown and no message pump runs.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
$script:checks=0
$script:failures=New-Object System.Collections.ArrayList
function Check([bool]$Condition,[string]$Message){
    if($Condition){$script:checks++;Write-Host "PASS: $Message"}
    else{[void]$script:failures.Add($Message);Write-Host "FAIL: $Message"}
}

. (Join-Path $root 'src/FastLlm.UiTheme.ps1')
. (Join-Path $root 'src/FastLlm.UiWindow.ps1')
. (Join-Path $root 'src/FastLlm.UiXaml.ps1')
. (Join-Path $root 'tests/helpers/UiRenderHarness.ps1')

# Pure checks, any OS: they catch a matrix that is wrapped or shaped wrongly before the Windows-only part.
$matrix=@(Get-UiRenderMatrix)
$runStart=[DateTime]::UtcNow.AddSeconds(-2)
Check ($matrix.Count -eq 40) 'the matrix has 40 cases'
Check (@($matrix|Where-Object{$_ -is [hashtable]}).Count -eq 40) 'every matrix case is one hashtable'
Check (@($matrix|Where-Object{$_.theme -is [string] -and $_.scale -is [double] -and $_.textScale -is [double]}).Count -eq 40) 'every case has a single theme, scale and text scale'
Check (@($matrix|ForEach-Object{"$($_.theme)|$($_.scale)|$($_.textScale)|$($_.width)x$($_.height)"}|Sort-Object -Unique).Count -eq 40) 'the 40 cases are all different'
$bigText=@($matrix|Where-Object{[double]$_.textScale -eq 2.25})
Check ($bigText.Count -eq 1 -and $bigText[0].theme -ceq 'light' -and $bigText[0].scale -eq 1.0 -and $bigText[0].width -eq 640) 'the matrix has the one light 225% text case'
Check ((Remove-UiAccessKey '_Name') -ceq 'Name') 'an access key underscore is stripped'
Check ((Remove-UiAccessKey 'Na_me') -ceq 'Name') 'an access key underscore inside the text is stripped'
Check ((Remove-UiAccessKey 'a__b') -ceq 'a_b') 'a doubled underscore is one literal underscore'
Check ((Remove-UiAccessKey '__Name') -ceq '_Name') 'a doubled underscore at the start is kept as one'
Check ((Remove-UiAccessKey 'Plain') -ceq 'Plain') 'text without underscores is unchanged'
Check ((Remove-UiAccessKey 'a_b_c') -ceq 'ab_c') 'only the first single underscore is the access key'
Check ((Remove-UiAccessKey '_a__b') -ceq 'a_b') 'a key underscore plus a doubled underscore'
Check ((Remove-UiAccessKey 'a__b_c') -ceq 'a_bc') 'a doubled underscore, then the first single one is the key'
Check ((Remove-UiAccessKey 'x_') -ceq 'x_') 'a trailing lone underscore is literal'
$hcPal=Get-UiRenderHighContrastPalette
Check (@($hcPal.Values|Sort-Object -Unique).Count -eq 4) 'the high-contrast palette has four distinct colours'
# The x:Name values of a markup string that live in the page's own namescope: elements inside a ControlTemplate, DataTemplate, ItemsPanelTemplate,
# HierarchicalDataTemplate or Style (their Setters included) have a namescope of their own, which the page's FindName cannot reach.
function Get-UiPageElementNames([string]$Xaml){
    $xamlNs='http://schemas.microsoft.com/winfx/2006/xaml'
    $skip=@('ControlTemplate','DataTemplate','ItemsPanelTemplate','HierarchicalDataTemplate','Style')
    $doc=New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xaml)
    $names=New-Object System.Collections.ArrayList
    $walk=$null
    $walk={
        param($node)
        if($node.NodeType -ne [System.Xml.XmlNodeType]::Element){return}
        $local=[string]$node.LocalName
        if($skip -contains $local){return}
        $nm=$node.GetAttribute('Name',$xamlNs)
        if(-not [string]::IsNullOrEmpty($nm)){[void]$names.Add([string]$nm)}
        foreach($c in $node.ChildNodes){& $walk $c}
    }
    & $walk $doc.DocumentElement
    return ,@($names.ToArray())
}
# Pure check on any OS, from the shell file's own markup text: the page names are found and the template part names are not.
$shellText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentShell.ps1'))
$shellMatch=[regex]::Match($shellText,"(?s)\`$script:FastLlmUiXaml\['FastLlm\.Shell'\]\s*=\s*@'\r?\n(.*?)\r?\n'@")
Check $shellMatch.Success 'the shell markup was found in the shell file'
$pageNames=Get-UiPageElementNames $shellMatch.Groups[1].Value
Check (($pageNames -contains 'PaneColumn') -and ($pageNames -contains 'NavList') -and ($pageNames -contains 'MessageScroll')) "the page names include PaneColumn, NavList and MessageScroll (got $($pageNames -join ', '))"
$partHits=@('Bd','Hd','Arrow','Body','Bar')|Where-Object{$pageNames -contains $_}
Check (@($partHits).Count -eq 0) "the page names hold no template part name (found: $(@($partHits) -join ', '))"
# The Models page (pure, any OS): every x:Name of its registered markup is in the hand list Initialize-FastLlmUiFluentModels collects into Els, and the list holds no
# other name, so the stand-in (which collects the names the same way, through FindName) and the window see the same elements.
$modelsText=[IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentModels.ps1'))
$modelsMatch=[regex]::Match($modelsText,"(?s)\`$script:FastLlmUiXaml\['FastLlm\.Models'\]\s*=\s*@'\r?\n(.*?)\r?\n'@")
Check $modelsMatch.Success 'the Models markup was found in the Models file'
$listMatch=[regex]::Match($modelsText,'(?s)Add-FastLlmUiFluentElements -Els \$Els -Root \$Page -Names @\((.*?)\)')
Check $listMatch.Success 'the Models element name list was found in Initialize-FastLlmUiFluentModels'
if($modelsMatch.Success -and $listMatch.Success){
    $modelsRaw=Get-UiPageElementNames $modelsMatch.Groups[1].Value
    $modelsPageNames=@($modelsRaw|Sort-Object -Unique)
    $listedNames=@([regex]::Matches($listMatch.Groups[1].Value,"'([A-Za-z0-9]+)'")|ForEach-Object{$_.Groups[1].Value}|Sort-Object -Unique)
    $notListed=@($modelsPageNames|Where-Object{$listedNames -cnotcontains $_})
    $notInMarkup=@($listedNames|Where-Object{$modelsPageNames -cnotcontains $_})
    Check ($modelsPageNames.Count -ge 30 -and $modelsPageNames.Count -eq @($modelsRaw).Count) "the Models markup has at least 30 distinct page names (got $($modelsPageNames.Count) of $(@($modelsRaw).Count))"
    Check ($notListed.Count -eq 0) "every Models markup name is in the Initialize list (not listed: $($notListed -join ', '))"
    Check ($notInMarkup.Count -eq 0) "the Initialize list names no element that is not in the Models markup (extra: $($notInMarkup -join ', '))"
    Check (@('Bd','Hd','Arrow','Body','Bar'|Where-Object{$modelsPageNames -contains $_}).Count -eq 0) 'the Models page names hold no template part name'
}
# The clipped rule's arithmetic (pure, any OS; the derivation is in the harness above Get-UiTextGapBound). The planted numbers are the PR 3c CI rounds' own.
function Test-UiNear([double]$A,[double]$B){return ([Math]::Abs($A-$B) -lt 0.0000001)}
Check (Test-UiNear (Get-UiTextGapBound 1.0 $true 0) 0.500001) 'gap bound: half a device pixel is 0.5 DIP at live scale 1.0'
Check (Test-UiNear (Get-UiTextGapBound 1.25 $true 0) 0.400001) 'gap bound: half a device pixel is 0.4 DIP at live scale 1.25'
Check (Test-UiNear (Get-UiTextGapBound 1.5 $true 0) (0.5/1.5+0.000001)) 'gap bound: half a device pixel is a third of a DIP at live scale 1.5'
Check (Test-UiNear (Get-UiTextGapBound 2.0 $true 0) 0.250001) 'gap bound: half a device pixel is 0.25 DIP at live scale 2.0'
Check (Test-UiNear (Get-UiTextGapBound 1.25 $false 0) 0.000001) 'gap bound: without layout rounding only the float noise is left'
Check (Test-UiNear (Get-UiTextGapBound 1.25 $true 12) 0.400001) 'gap bound: a margin of whole pixels (12 DIP = 15 px at 1.25) adds nothing'
Check (Test-UiNear (Get-UiTextGapBound 1.25 $true 10.2) 0.600001) 'gap bound: a margin off the pixel grid (10.2 DIP = 12.75 px, rounded to 10.4) adds its own rounding'
# Round 2, NoWrap 'Driver guidance': one ideal width (97.2 to 97.5) is 97.0 on the live block's grid (scale 1.0) and 97.6 on the clone's (the case scale 1.25).
Check ((Test-UiNear (Get-UiRoundedLayoutValue 97.3 1.0) 97.0) -and (Test-UiNear (Get-UiRoundedLayoutValue 97.3 1.25) 97.6)) 'round 2: an ideal width of 97.3 rounds to 97.0 at scale 1.0 and to 97.6 at scale 1.25'
Check ((Get-UiRoundedLayoutValue 97.3 1.25) -gt ((Get-UiRoundedLayoutValue 97.3 1.0)+0.5)) 'round 2: the clone rounded at the case scale is more than 0.5 above the live block (the false positive)'
Check ((Get-UiTextGapState (97.3-(Get-UiRoundedLayoutValue 97.3 1.0)) (Get-UiTextGapBound 1.0 $true 0) $false) -ceq 'ok') 'the unrounded clone is inside the bound of the live block for the same width'
Check ((Test-UiNear (Get-UiRoundedLayoutValue 18.62 1.0) 19.0) -and (Test-UiNear (Get-UiRoundedLayoutValue 18.62 1.25) 18.4) -and (Test-UiNear (Get-UiRoundedLayoutValue 37.24 1.5) (56.0/1.5))) 'round 2: the line heights 18.62 and 37.24 give the logged 19.0, 18.4 and 37.3'
# The bound holds for every ideal size at every live scale (a rounded live size is never further than the bound from the ideal one), and it is tight:
# at scale 1.25 a gap of 0.45 DIP is more than half a device pixel.
$sweepBad=0
foreach($liveScale in 1.0,1.25,1.5,2.0){
    $liveBound=Get-UiTextGapBound $liveScale $true 0
    for($i=0;$i -lt 4000;$i++){
        $ideal=$i*0.0731
        if((Get-UiTextGapState ($ideal-(Get-UiRoundedLayoutValue $ideal $liveScale)) $liveBound $false) -cne 'ok'){$sweepBad++}
    }
}
Check ($sweepBad -eq 0) "an ideal size is never further than the bound from its layout-rounded size (4000 sizes at each of 4 scales, outside: $sweepBad)"
Check ((Get-UiTextGapState 0.45 (Get-UiTextGapBound 1.0 $true 0) $false) -ceq 'ok' -and (Get-UiTextGapState 0.45 (Get-UiTextGapBound 1.25 $true 0) $false) -ceq 'over') 'the bound follows the live scale: 0.45 DIP is inside it at 1.0 and above it at 1.25'
# Real clipping stays above the bound: round 1's NoWrap caption (645.1 wide in a 505.0 slot) and a fixed-width box (also with an explicit size).
Check ((Get-UiTextGapState (645.1-505.0) (Get-UiTextGapBound 1.0 $true 0) $false) -ceq 'over') 'a NoWrap caption wider than its slot is above the bound'
Check ((Get-UiTextGapState (400.0-60.0) (Get-UiTextGapBound 1.0 $true 0) $true) -ceq 'over') 'text wider than its explicit width is above the bound'
Check ((Get-UiTextGapState 0.6 (Get-UiTextGapBound 1.0 $true 0) $false) -ceq 'over') 'a gap of 0.6 DIP at live scale 1.0 is above the bound'
Check ((Get-UiTextGapState (-8.0) (Get-UiTextGapBound 1.0 $true 0) $true) -ceq 'sized' -and (Get-UiTextGapState (-8.0) (Get-UiTextGapBound 1.0 $true 0) $false) -ceq 'under') 'a clone smaller than the live block is sized with an explicit size and under without one'
# Wrapping text is measured at the live desired text width plus the bound: round 1's one-line caption (171.0 for 171.x) fits, and round 2's
# ConnectAgentWarningText (desired 511.0, arranged 533.0) is no longer measured wider than the live block (534.0).
$nan=[double]::NaN
$infinite=[double]::PositiveInfinity
Check (Test-UiNear (Get-UiWrapMeasureWidth 171.0 0.500001 $nan 0 $infinite 1.0 $true) 171.500001) 'a wrapping clone is measured at the desired text width plus the bound (171.0 gives 171.5)'
Check ((Get-UiWrapMeasureWidth 511.0 0.500001 $nan 0 $infinite 1.0 $true) -lt 533.0) 'a wrapping clone is never measured wider than the live block was arranged (511.5, not 534.0)'
Check (Test-UiNear (Get-UiWrapMeasureWidth 60.0 0.500001 60.0 0 $infinite 1.0 $true) 60.0) 'a wrapping clone in a fixed-width box is measured at the box width'
Check (Test-UiNear (Get-UiWrapMeasureWidth 277.5 0.250001 296.0 0 $infinite 2.0 $true) 296.0) 'a fixed-width box whose slot cut its desired width is still measured at the box width (296.0, not 277.75)'
Check (Test-UiNear (Get-UiWrapMeasureWidth 900.0 0.500001 $nan 0 900.0 1.0 $true) 900.0) 'a wrapping clone is never measured above MaxWidth'
Check (Test-UiNear (Get-UiWrapMeasureWidth 40.0 0.500001 $nan 120.0 $infinite 1.0 $true) 120.0) 'a wrapping clone is never measured below MinWidth'
Check (Test-UiNear (Get-UiWrapMeasureWidth 61.0 0.500001 60.6 0 $infinite 1.0 $true) 61.0) 'an explicit width off the pixel grid is measured at its rounded value (60.6 gives 61.0)'
Check (Test-UiNear (Get-UiWrapMeasureWidth 61.0 0.000001 60.6 0 $infinite 1.0 $false) 60.6) 'without layout rounding an explicit width is measured as it is'
Check (Test-UiNear (Get-UiWrapMeasureWidth 300.0 0.500001 500.0 0 200.0 1.0 $true) 200.0) 'MaxWidth below an explicit Width wins, as in WPF'
Check (Test-UiNear (Get-UiWrapMeasureWidth (-4.0) 0.500001 $nan 0 $infinite 1.0 $true) 0.500001) 'a negative desired text width measures at the bound'
Check ((Test-UiOnLayoutGrid 593.0 1.0) -and -not (Test-UiOnLayoutGrid 593.0 1.25) -and (Test-UiOnLayoutGrid 97.6 1.25) -and -not (Test-UiOnLayoutGrid 97.6 1.0) -and (Test-UiOnLayoutGrid (415.0/1.5) 1.5)) 'the pixel grid test tells the scale 1.0 grid from the 1.25 and 1.5 grids'
# The summary folds the per-case records per device scale and text scale, in that order.
$plantStatA=New-UiTextGapStat;$plantStatA['n']=2;Add-UiTextGapValue $plantStatA 'W' (-0.31);Add-UiTextGapValue $plantStatA 'W' 0.42;Add-UiTextGapValue $plantStatA 'H' (-0.38)
$plantStatB=New-UiTextGapStat;$plantStatB['n']=3;Add-UiTextGapValue $plantStatB 'W' 0.49;Add-UiTextGapValue $plantStatB 'H' 0.24
$plantStatC=New-UiTextGapStat;$plantStatC['n']=1;Add-UiTextGapValue $plantStatC 'W' (-0.7);Add-UiTextGapValue $plantStatC 'H' 0.1
$plantRecords=@(
    @{label='Plant.B light 1.25 2.0 640x480';scale=[double]1.25;textScale=[double]2.0;bound=[double]0.500001;liveScales=[string[]]@('1.0');nowrap=$plantStatC;wrap=(New-UiTextGapStat);over=0;under=1;offGrid=0;sized=0;accessKey=0;trimmed=0;remeasured=0;notes=[string[]]@('below the bound on W: PlantText')},
    @{label='Plant.A light 1.0 1.0 640x480';scale=[double]1.0;textScale=[double]1.0;bound=[double]0.500001;liveScales=[string[]]@('1.0');nowrap=$plantStatA;wrap=$plantStatB;over=1;under=0;offGrid=0;sized=2;accessKey=1;trimmed=1;remeasured=1;notes=[string[]]@()},
    @{label='Plant.A dark 1.0 1.0 640x480';scale=[double]1.0;textScale=[double]1.0;bound=[double]0.400001;liveScales=[string[]]@('1.25');nowrap=$plantStatA;wrap=(New-UiTextGapStat);over=0;under=0;offGrid=2;sized=0;accessKey=0;trimmed=0;remeasured=0;notes=[string[]]@('off the pixel grid: PlantText')})
$plantRows=@(Get-UiTextGapSummary $plantRecords)
Check ($plantRows.Count -eq 2 -and [double]$plantRows[0]['scale'] -eq 1.0 -and [double]$plantRows[1]['scale'] -eq 1.25) "the gap summary has one row per scale and text scale, lowest scale first (got $($plantRows.Count))"
if($plantRows.Count -eq 2){
    $pr=$plantRows[0]
    Check ([int]$pr['cases'] -eq 2 -and [int]$pr['nowrap']['n'] -eq 4 -and [int]$pr['wrap']['n'] -eq 3 -and [int]$pr['over'] -eq 1 -and [int]$pr['offGrid'] -eq 2 -and [int]$pr['sized'] -eq 2 -and [int]$pr['accessKey'] -eq 1 -and [int]$pr['trimmed'] -eq 1 -and [int]$pr['remeasured'] -eq 1) 'the gap summary adds the counts of the cases of one row'
    Check ((Test-UiNear ([double]$pr['bound']) 0.500001) -and (Test-UiNear ([double]$pr['nowrap']['minW']) (-0.31)) -and (Test-UiNear ([double]$pr['nowrap']['maxW']) 0.42) -and (Test-UiNear ([double]$pr['wrap']['maxW']) 0.49) -and [string]$pr['liveScales'] -ceq '1.0, 1.25') "the gap summary keeps the largest bound, the gap range and every live scale (live scales '$($pr['liveScales'])')"
    Check ([string]$pr['line'] -ceq 'scale 1.0 text 1.0: cases 2; live layout scale 1.0, 1.25; bound 0.500; NoWrap n=4 gap W [-0.310, 0.420] H [-0.380, -0.380]; Wrap n=3 gap W [0.490, 0.490] H [0.240, 0.240]; above the bound (reported clipped) 1; below the bound 0; off the pixel grid 2; below it by an explicit size 2; below it by an access key split 1; trimmed with a tooltip 1; wraps re-measured 1') "the gap summary line reads as pinned (got '$($pr['line'])')"
    Check ([int]$plantRows[1]['under'] -eq 1 -and @($plantRows[1]['notes']).Count -eq 1 -and [string]@($plantRows[1]['notes'])[0] -ceq 'Plant.B light 1.25 2.0 640x480: below the bound on W: PlantText' -and [string]$plantRows[1]['line'] -like '*Wrap n=0 gap W none H none; above the bound (reported clipped) 0; below the bound 1;*') "the gap summary carries a case's notes with its label and prints an empty range as none (line '$($plantRows[1]['line'])')"
}
# The Hyperlink negative pages (pure, any OS, from this file's own text): each is a TextBlock whose only content is a Hyperlink, the negative table and the case list
# name each page and its one expected problem, and the PNG count covers both, so the Windows run cannot drop them unnoticed.
$selfText=[IO.File]::ReadAllText((Join-Path $root 'tests/ui-render-tests.ps1'))
$linkExpect=[ordered]@{LinkClipped=@{Name='LinkClippedText';Problem='clipped:LinkClippedText'};LinkOutside=@{Name='LinkOutsideText';Problem='outside:LinkOutsideText'}}
foreach($ln in $linkExpect.Keys){
    $m=[regex]::Match($selfText,"(?s)\`$script:FastLlmUiXaml\['Test\.$ln'\]\s*=\s*@'\r?\n(.*?)\r?\n'@")
    Check $m.Success "the $ln markup was found in this file"
    if(-not $m.Success){continue}
    $linkDoc=New-Object System.Xml.XmlDocument
    $linkDoc.LoadXml($m.Groups[1].Value)
    $xamlNs='http://schemas.microsoft.com/winfx/2006/xaml'
    $tbs=@($linkDoc.GetElementsByTagName('TextBlock')|Where-Object{$_.GetAttribute('Name',$xamlNs) -ceq $linkExpect[$ln].Name})
    Check ($tbs.Count -eq 1) "the $ln page has one TextBlock named $($linkExpect[$ln].Name)"
    if($tbs.Count -ne 1){continue}
    $kids=@($tbs[0].ChildNodes|Where-Object{$_.NodeType -eq [System.Xml.XmlNodeType]::Element})
    Check ($kids.Count -eq 1 -and $kids[0].LocalName -ceq 'Hyperlink' -and $kids[0].InnerText.Length -ge 40 -and -not [string]::IsNullOrEmpty($kids[0].GetAttribute('Name',$xamlNs))) "the $ln TextBlock holds one named Hyperlink with a long text and nothing else"
    Check ($tbs[0].InnerText -ceq $kids[0].InnerText -and [string]::IsNullOrEmpty($tbs[0].GetAttribute('Text'))) "the $ln TextBlock text is the link's run alone"
    Check ($selfText.Contains("$ln='$($linkExpect[$ln].Problem)'")) "the negative table expects exactly '$($linkExpect[$ln].Problem)' from $ln"
}
Check ($selfText.Contains("'Nested','LinkClipped','LinkOutside'){")) 'the negative case list runs both Hyperlink pages'
Check ($selfText.Contains('-eq 54) ("the render folder holds 54 Test.* PNGs')) 'the Test.* PNG count includes the two Hyperlink pages'
# PR 4a CI round 1, the LinkClipped miss: a block whose only content is a Hyperlink has an empty Text on Windows, so its clone measured as nothing and the 60-wide NoWrap
# link was never reported clipped. The clone now takes the text of the inlines when Text is empty. Pure checks over the object shape (a Run has Text, a Hyperlink or Span has Inlines).
$planRun=[pscustomobject]@{Text='This link text is much too long'}
$planLink=[pscustomobject]@{Inlines=@($planRun)}
$planNested=[pscustomobject]@{Inlines=@([pscustomobject]@{Text='Read '},[pscustomobject]@{Inlines=@([pscustomobject]@{Text='the '},[pscustomobject]@{Text='notes'})})}
Check ((Get-UiInlineText @($planLink)) -ceq 'This link text is much too long') 'a Hyperlink inline gives the text of its run'
Check ((Get-UiInlineText @($planNested)) -ceq 'Read the notes') 'nested inlines give their text in order'
Check ((Get-UiInlineText @()) -ceq '') 'no inlines give an empty text'
Check ((Get-UiBlockText ([pscustomobject]@{Text='';Inlines=@($planLink)})) -ceq 'This link text is much too long') 'a block with an empty Text and a Hyperlink inline is measured with the link text (the LinkClipped miss)'
Check ((Get-UiBlockText ([pscustomobject]@{Text='Plain';Inlines=@($planLink)})) -ceq 'Plain') 'a block with a Text keeps its Text'
Check ((Get-UiBlockText ([pscustomobject]@{Text=''})) -ceq '') 'a block with neither Text nor inlines is empty'
Check ($selfText.Contains('$planLink') -and ([IO.File]::ReadAllText((Join-Path $root 'tests/helpers/UiRenderHarness.ps1'))).Contains('$clone.Text = Get-UiBlockText $Text')) 'the clone takes its text through Get-UiBlockText'
# Dialog reading order: the region comes first, so a stop below the body's fold (large Top) is still read before the footer.
$planRows=@([pscustomobject]@{Name='Footer';Region=1;Row=40.0;Left=300.0;Order=3},[pscustomobject]@{Name='BelowFold';Region=0;Row=90.0;Left=0.0;Order=2},[pscustomobject]@{Name='Device';Region=0;Row=5.0;Left=0.0;Order=0},[pscustomobject]@{Name='Close';Region=1;Row=40.0;Left=400.0;Order=4})
Check ((@(Sort-UiReadingRows $planRows|ForEach-Object{$_.Name}) -join ',') -ceq 'Device,BelowFold,Footer,Close') 'a stop below the body fold sorts before the footer: region, then row, then left'
Check ((@(Sort-UiReadingRows @($planRows[0]))|Measure-Object).Count -eq 1 -and @(Sort-UiReadingRows @()).Count -eq 0) 'the reading sort keeps one stop and none'
$dlgOrderText=[regex]::Match($selfText,'(?sm)^function Test-DialogReadingOrder.*?\r?\n}\r?\n').Value
Check ($dlgOrderText.Contains("Get-UiTabRegion `$el `$built.Content @('DlgBodyScroll')") -and $dlgOrderText.Contains('Sort-UiReadingRows')) 'the dialog reading order sorts by the body scroll region first'
Check ([regex]::Matches($selfText,"-TabRegions @\('DlgBodyScroll'\)").Count -eq 2) 'both dialog render calls name the body scroll as a tab region'
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}
$onWindows=($PSVersionTable.PSVersion.Major -le 5) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if(-not $onWindows){Write-Host 'SKIP: Windows only';exit 0}

# A non-STA host, or a WPF that does not load, fails loudly; it never skips.
Check ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') 'runs on an STA thread'
$interop=$false
try{$interop=[bool](Initialize-FastLlmUiWindowInterop -SourceRoot $root)}catch{Write-Host ('FAIL: interop threw: '+$_.Exception.Message)}
if(-not $interop){
    try{Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop}catch{Write-Host ('INFO: interop load error: '+$_.Exception.ToString())}
    try{Add-Type -Path (Join-Path $root 'src/WindowsFluentWindow.cs') -ErrorAction Stop}catch{Write-Host ('INFO: interop load error: '+$_.Exception.ToString())}
}
Check $interop 'WPF and the interop load'
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}

# Pin Remove-UiAccessKey against WPF's own rule, found by reflection (CI only; the log shows the real rule on a mismatch).
$wpfRule=@([System.Windows.Controls.AccessText].GetMethods('NonPublic,Static')|Where-Object{$_.Name -ceq 'RemoveAccessKeyMarker' -and @($_.GetParameters()).Count -eq 1 -and $_.GetParameters()[0].ParameterType -eq [string]})
if($wpfRule.Count -ne 1){
    $names=(@([System.Windows.Controls.AccessText].GetMethods('NonPublic,Static')|Where-Object{$_.Name -match 'Access'}|ForEach-Object{$_.Name}|Sort-Object -Unique) -join ', ')
    Check $false ("AccessText.RemoveAccessKeyMarker (one string parameter) found exactly once (found $($wpfRule.Count); NonPublic static AccessText methods with 'Access': $names)")
}else{
    foreach($t in '_Name','Na_me','a__b','__Name','Plain','a_b_c','_a__b','a__b_c','x_','_','__'){
        $want=[string]$wpfRule[0].Invoke($null,@([string]$t))
        $got=Remove-UiAccessKey $t
        Check ($got -ceq $want) "Remove-UiAccessKey matches WPF for '$t' (ours '$got', WPF '$want')"
    }
    # Product round trip: WinForms caption -> adapter conversion -> WPF access text -> the text WinForms shows.
    . (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
    $trips=@(
        @{text='Install && start';mn=$true;shown='Install & start'},
        @{text='&Save a_b';mn=$true;shown='Save a_b'},
        @{text='a_b &Save';mn=$true;shown='a_b Save'},
        @{text='model_a_b';mn=$false;shown='model_a_b'},
        @{text='a & b';mn=$false;shown='a & b'})
    foreach($trip in $trips){
        $conv=ConvertTo-FastLlmUiAccessText -Text $trip.text -UseMnemonic $trip.mn
        $shown=[string]$wpfRule[0].Invoke($null,@([string]$conv))
        Check ($shown -ceq $trip.shown) "access text round trip for '$($trip.text)' (UseMnemonic $($trip.mn)): converted '$conv', WPF shows '$shown', want '$($trip.shown)'"
    }
}
if($script:failures.Count -gt 0){throw ('FAIL: '+($script:failures -join '; '))}

$script:FastLlmUiXaml['Test.Sample']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16" UseLayoutRounding="True">
  <TextBlock x:Name="TitleText" Text="Fluent harness check" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.TitleSize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,8"/>
  <TextBlock x:Name="BodyText" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextSecondaryBrush}" Margin="0,0,0,12" Text="This sample page exists only to exercise the layout and accessibility checks. It holds a heading, a paragraph that wraps over several lines, a labelled text box, a check box and two buttons, one of them an icon button with a spoken name."/>
  <TextBlock x:Name="InheritedText" Text="Inherited example text" TextWrapping="Wrap" Margin="0,0,0,12"/>
  <TextBlock x:Name="NameLabel" Text="Example field" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="NameBox" AutomationProperties.Name="Example field" AutomationProperties.LabeledBy="{x:Reference NameLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.CardBrush}" BorderBrush="{DynamicResource FastLlm.ControlStrongStrokeBrush}" Margin="0,0,0,12"/>
  <CheckBox x:Name="OptionBox" Content="Example option" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,12"/>
  <StackPanel Orientation="Vertical">
    <Button x:Name="AccentButton" Content="Example action" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextOnAccentBrush}" Background="{DynamicResource FastLlm.AccentFillBrush}" HorizontalAlignment="Left" Padding="12,6,12,6" Margin="0,0,0,8"/>
    <Button x:Name="IconButton" Width="32" Height="32" HorizontalAlignment="Left" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="16" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Background="{DynamicResource FastLlm.CardBrush}" Content="&#xE8C8;" AutomationProperties.Name="Copy example" ToolTip="Copy example"/>
  </StackPanel>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.Overlap']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Button x:Name="BtnA" Content="First example" HorizontalAlignment="Left" VerticalAlignment="Top" Width="160" Height="32" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
  <Button x:Name="BtnB" Content="Second example" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="40,10,0,0" Width="160" Height="32" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.Clipped']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="ClippedText" Width="60" HorizontalAlignment="Left" VerticalAlignment="Top" TextWrapping="NoWrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Text="This text is much too long to fit in sixty device independent pixels."/>
</Grid>
'@

$script:FastLlmUiXaml['Test.ClippedButton']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Button x:Name="NarrowButton" Content="A label too long for this button" Width="60" HorizontalAlignment="Left" VerticalAlignment="Top" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.Unnamed']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Button x:Name="NoNameButton" Width="32" Height="32" HorizontalAlignment="Left" VerticalAlignment="Top" FontFamily="{DynamicResource FastLlm.IconFont}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Content="&#xE8C8;"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.TabOrder']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBox x:Name="UpperBox" TabIndex="1" AutomationProperties.Name="Upper example" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,8"/>
  <TextBox x:Name="LowerBox" TabIndex="0" AutomationProperties.Name="Lower example" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.Outside']=@'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Height="60">
  <Border x:Name="FarBox" Canvas.Left="2000" Canvas.Top="10" Width="50" Height="20" Background="{DynamicResource FastLlm.AccentFillBrush}"/>
</Canvas>
'@

# A Hyperlink inside a TextBlock: the clipped and outside rules judge the TextBlock, whose Text includes the link's run, so a link that overflows is reported.
# The link has no NavigateUri (an external reference is refused) and no Run of its own, so the overflow is the link's text alone.
$script:FastLlmUiXaml['Test.LinkClipped']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="LinkClippedText" Width="60" HorizontalAlignment="Left" VerticalAlignment="Top" TextWrapping="NoWrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"><Hyperlink x:Name="ClippedLink">This link text is much too long to fit in sixty device independent pixels.</Hyperlink></TextBlock>
</Grid>
'@

$script:FastLlmUiXaml['Test.LinkOutside']=@'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Height="60">
  <TextBlock x:Name="LinkOutsideText" Canvas.Left="560" Canvas.Top="10" TextWrapping="NoWrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"><Hyperlink x:Name="OutsideLink">This link text runs past the right edge of the page.</Hyperlink></TextBlock>
</Canvas>
'@

$script:FastLlmUiXaml['Test.UnnamedTextBox']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBox x:Name="BareBox" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.LabeledByOnly']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="OnlyLabel" Text="Only label" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="OnlyBox" AutomationProperties.LabeledBy="{x:Reference OnlyLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

$script:FastLlmUiXaml['Test.LabelMismatch']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <TextBlock x:Name="MisLabel" Text="Visible text" TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}" Margin="0,0,0,4"/>
  <TextBox x:Name="MisBox" AutomationProperties.Name="Other text" AutomationProperties.LabeledBy="{x:Reference MisLabel}" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</StackPanel>
'@

# A viewer inside the page: its content below the fold is scrolled, not outside or clipped (the rules measure against the nearest scroll content).
# Only the element beyond the viewer's own width is a problem.
$script:FastLlmUiXaml['Test.Nested']=@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <ScrollViewer x:Name="InnerScroll" Height="60" Focusable="False" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel>
      <TextBlock x:Name="UpperText" Text="Inside the inner viewer." TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Border Height="700"/>
      <TextBlock x:Name="DeepText" Text="Text far below the inner fold. It is scrolled, not clipped." TextWrapping="Wrap" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Button x:Name="DeepButton" Content="Deep action" HorizontalAlignment="Left" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
      <Canvas Height="20">
        <Border x:Name="InnerFar" Canvas.Left="2000" Canvas.Top="0" Width="50" Height="20" Background="{DynamicResource FastLlm.AccentFillBrush}"/>
      </Canvas>
    </StackPanel>
  </ScrollViewer>
</StackPanel>
'@

# Two-column tab order with the pane as a region: pane first is clean, a content stop before the pane is flagged.
$script:FastLlmUiXaml['Test.RegionGood']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <StackPanel x:Name="PaneRoot" Grid.Column="0"><Button x:Name="PaneButton" Content="Pane item" TabIndex="0" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/></StackPanel>
  <Button x:Name="ContentButton" Grid.Column="1" Content="Content item" TabIndex="1" HorizontalAlignment="Left" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$script:FastLlmUiXaml['Test.RegionBad']=@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="16">
  <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <StackPanel x:Name="PaneRoot" Grid.Column="0"><Button x:Name="PaneButton" Content="Pane item" TabIndex="1" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/></StackPanel>
  <Button x:Name="ContentButton" Grid.Column="1" Content="Content item" TabIndex="0" HorizontalAlignment="Left" FontSize="{DynamicResource FastLlm.BodySize}" Foreground="{DynamicResource FastLlm.TextPrimaryBrush}"/>
</Grid>
'@

$out=$env:FASTLLM_RENDER_DIR
if([string]::IsNullOrEmpty($out)){
    if(-not [string]::IsNullOrEmpty($env:RUNNER_TEMP)){$out=Join-Path $env:RUNNER_TEMP 'fastllm-fluent-render'}
    else{$out=[IO.Path]::GetTempPath()}
}
[void][IO.Directory]::CreateDirectory($out)

$matrix=@(Get-UiRenderMatrix)

# Each negative page shows exactly its own problem.
$neg=@{Overlap='overlap:BtnA:BtnB';Clipped='clipped:ClippedText';ClippedButton='clipped:TextBlock';Unnamed='unnamed:Button';TabOrder='tab-order';Outside='outside:FarBox';UnnamedTextBox='unnamed:TextBox';LabeledByOnly='unnamed:TextBox';LabelMismatch='label-mismatch:MisBox';Nested='outside:InnerFar';LinkClipped='clipped:LinkClippedText';LinkOutside='outside:LinkOutsideText'}
$base=@{theme='light';scale=[double]1.0;textScale=[double]1.0;width=640;height=480}
foreach($n in 'Overlap','Clipped','ClippedButton','Unnamed','TabOrder','Outside','UnnamedTextBox','LabeledByOnly','LabelMismatch','Nested','LinkClipped','LinkOutside'){
    $found=@()
    $diag=@()
    try{$res=Invoke-UiRenderCase -Name ('Test.'+$n) -Case $base -OutFolder $out;$found=@($res.problems);$diag=@($res.diagnostics)}catch{$found=@('threw: '+$_.Exception.Message)}
    if($n -ceq 'LabeledByOnly'){
        # The root cause of the cold-page failure, recorded on green runs too: whether the label already had an automation peer.
        $peerState='unknown'
        foreach($d in $diag){if($d -match 'labelPeer=(\w+)'){$peerState=$Matches[1];break}}
        Write-Host ('INFO: render LabeledByOnly labelPeer='+$peerState)
    }
    $diagText=''
    $ok=($found.Count -eq 1 -and $found[0] -ceq $neg[$n])
    if(-not $ok -and $diag.Count -gt 0){$diagText=' | diag: '+($diag -join '; ')}
    Check $ok ("the harness catches $n (expected '"+$neg[$n]+"', got '"+($found -join '; ')+"')"+$diagText)
}

# Regions: a pane on the left whose stops come first is a clean two-column order; a content stop before the pane is flagged.
$regionOk=@();$regionBad=@()
try{$regionOk=@((Invoke-UiRenderCase -Name 'Test.RegionGood' -Case $base -OutFolder $out -TabRegions @('PaneRoot')).problems)}catch{$regionOk=@('threw: '+$_.Exception.Message)}
try{$regionBad=@((Invoke-UiRenderCase -Name 'Test.RegionBad' -Case $base -OutFolder $out -TabRegions @('PaneRoot')).problems)}catch{$regionBad=@('threw: '+$_.Exception.Message)}
Check (@($regionOk|Where-Object{$_ -ceq 'tab-order'}).Count -eq 0 -and $regionOk.Count -eq 0) "a page whose tab order puts the pane region first is clean (got '$($regionOk -join '; ')')"
Check (@($regionBad|Where-Object{$_ -ceq 'tab-order'}).Count -eq 1) "a content stop before the pane is still flagged tab-order (got '$($regionBad -join '; ')')"

$sw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){
    $label="$($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'Test.Sample' -Case $case -OutFolder $out}catch{Check $false "sample page renders at ${label}: $($_.Exception.Message)";continue}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "sample page clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if(Test-Path -LiteralPath $r.png){
        $info=Get-UiPngInfo -Path $r.png
        $real=($info.width -eq [int][Math]::Ceiling($case.width*$case.scale)) -and ($info.height -eq [int][Math]::Ceiling($case.height*$case.scale)) -and $info.hasContent
    }
    Check $real "the render is real at $label"
    # Probes: the theme reached the page and every check had something to examine.
    $expTitle=28.0*[double]$case.textScale
    $expBody=14.0*[double]$case.textScale
    Check ($null -ne $r.titleFontSize -and [Math]::Abs([double]$r.titleFontSize-$expTitle) -le 0.01) "title font size follows the text scale at ${label} (got $($r.titleFontSize), want $expTitle)"
    Check ($null -ne $r.bodyFontSize -and [Math]::Abs([double]$r.bodyFontSize-$expBody) -le 0.01) "body font size follows the text scale at ${label} (got $($r.bodyFontSize), want $expBody)"
    # Body text with no size of its own is the host's: 14 at 1.0, 2.25 times that at 2.25 (the host takes FastLlm.BodySize the way the Window does).
    Check ($null -ne $r.inheritedFontSize -and [Math]::Abs([double]$r.inheritedFontSize-$expBody) -le 0.01) "inherited body text follows the text scale at ${label} (got $($r.inheritedFontSize), want $expBody)"
    $themeArgs=@{Theme=[string]$case.theme;AccentPair=(Get-FastLlmUiAccentPair -Palette $null);TextScale=[double]$case.textScale}
    if($case.theme -ceq 'high-contrast'){
        $expFg=([System.Windows.Media.ColorConverter]::ConvertFromString($hcPal.WindowText)).ToString()
        $darkText=(New-FastLlmUiThemeDictionary -Theme dark -AccentPair (Get-FastLlmUiAccentPair -Palette $null) -TextScale 1.0)['FastLlm.TextPrimaryBrush'].Color.ToString()
        Check ($expFg -cne $darkText) "the high-contrast probe colour differs from dark TextPrimary at ${label}"
    }else{$expFg=(New-FastLlmUiThemeDictionary @themeArgs)['FastLlm.TextPrimaryBrush'].Color.ToString()}
    Check ([string]$r.titleForeground -ceq $expFg) "title colour is the theme text colour at ${label} (got $($r.titleForeground), want $expFg)"
    $expFont=[string](New-FastLlmUiThemeDictionary -Theme dark -AccentPair (Get-FastLlmUiAccentPair -Palette $null) -TextScale 1.0)['FastLlm.TextFont'].Source
    Check ([string]$r.inheritedFontFamily -ceq $expFont) "inherited body text uses the theme text font at ${label} (got $($r.inheritedFontFamily), want $expFont)"
    Check ([string]$r.inheritedForeground -ceq $expFg) "inherited body text uses the theme text colour at ${label} (got $($r.inheritedForeground), want $expFg)"
    Check ($r.labeledInputs -ge 1) "the label-mismatch check saw at least 1 labelled input at ${label} (got $($r.labeledInputs))"
    Check ($r.textBlocks -ge 6) "the clipped check examined at least 6 text blocks at ${label} (got $($r.textBlocks))"
    # The clipped rule's evidence on the harness's own page, where every caption is plain text: wrapping and NoWrap blocks were both measured, each live size is on
    # its device-pixel grid, and each clone reproduces its live block to within the derived bound in BOTH directions (above the bound is reported as clipped).
    $tg=$r.textGap
    Check ([int]$tg['wrap']['n'] -ge 4 -and [int]$tg['nowrap']['n'] -ge 1) "the text gap was measured for wrapping and NoWrap text at ${label} (wrap $($tg['wrap']['n']), NoWrap $($tg['nowrap']['n']))"
    Check ([int]$tg['over'] -eq 0 -and [int]$tg['under'] -eq 0 -and [int]$tg['offGrid'] -eq 0 -and [double]$tg['bound'] -gt 0) "every sample text clone is within the derived bound of its live block at ${label} (bound $($tg['bound']), above $($tg['over']), below $($tg['under']), off the pixel grid $($tg['offGrid'])): $(@($tg['notes']) -join '; ')"
    Check ($r.namedControls -ge 4) "the unnamed check examined at least 4 controls at ${label} (got $($r.namedControls))"
    Check ($r.tabStops -eq 4) "the tab-order check saw 4 tab stops at ${label} (got $($r.tabStops))"
    Check ($r.unmappedRects -eq 0) "no authored element was left unmapped at ${label} (got $($r.unmappedRects))"
}
Write-Host ('INFO: render matrix of {0} cases took {1:N1} s' -f $matrix.Count,$sw.Elapsed.TotalSeconds)

# ---- The Home page of the Fluent window. The page is bound to the real adapters and shown in one card state per case.
# The prepare step does what the shell does for Home (Initialize-FastLlmUiFluentHome, the binding table, one refresh of the card); the orchestration
# the refresh reads (the snapshot, the background status) is a stub here.
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'tests/helpers/UiControlStatesMatrix.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentBindings.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentShell.ps1')
Initialize-FastLlmUiFluentAutomation -SourceRoot $root
$script:homeDir=Join-Path ([IO.Path]::GetTempPath()) ('fastllm-render-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:homeDir)
$script:InstallRoot=$script:homeDir
$script:installPath=$script:homeDir
$script:homeCatalog=Get-FastLlmCatalog (Join-Path $root 'config/catalog.json')
$script:homeSettings=Read-FastLlmUiSettings -InstallRoot $script:homeDir -AppRoot $root
$script:homeSnap=$null
$script:homeCaseTheme='light'
$script:homeState='not-running'
# What the pages read from the orchestration (fast-llm-ui.ps1): the snapshot, the background run status, the key store and the action availability.
# A Connect case sets the status and the store so the real Get-FastLlmConnectionInfo and Get-FastLlmUiApiKeyRow produce its facts.
$script:renderRunStatus=$null
$script:renderKeyStore=$null
$script:renderFail=''
$script:child=$null
$script:vcBroker=$null
$script:updateRun=$null
function GetUiStateSnapshot([bool]$Busy){return $script:homeSnap}
function GetUiBackgroundRunStatus{return $script:renderRunStatus}
function GetUiApiKeyStore{return $script:renderKeyStore}
function GetUiActionAvailabilityNow([bool]$Busy){return Get-FastLlmUiSnapshotAvailability -Snapshot $script:homeSnap}
function ShowFailure($Message){$script:renderFail=[string]$Message}
function New-HomeSnap([hashtable]$O=@{}){
    $d=@{Busy=$false;UpdateKind='';ChildActive=$false;Step='';RunReady=$false;SideChildActive=$false;VcBrokerActive=$false;PreviewReady=$false
        SwitchGap=$false;ChatUrlSet=$false;BackgroundStopRequested=$false;Background='absent';FlowPhase='';FailureHeld=$false}
    foreach($k in $O.Keys){$d[$k]=$O[$k]}
    $bg=$d.Background; if($bg -is [string]){$bg=Get-UiBackgroundFixture -Name $bg}
    return New-FastLlmUiStateSnapshot -Busy $d.Busy -UpdateKind $d.UpdateKind -ChildActive $d.ChildActive -Step $d.Step -RunReady $d.RunReady `
        -SideChildActive $d.SideChildActive -VcBrokerActive $d.VcBrokerActive -PreviewReady $d.PreviewReady -SwitchGap $d.SwitchGap `
        -ChatUrlSet $d.ChatUrlSet -BackgroundStopRequested $d.BackgroundStopRequested -Background $bg -FlowPhase $d.FlowPhase -FailureHeld $d.FailureHeld
}
# The card states the render covers, by the snapshot that produces each one.
$homeSnaps=[ordered]@{
    'not-running'=@{}
    'starting'=@{ChildActive=$true;Step='model download'}
    'running'=@{ChildActive=$true;Step='serving';RunReady=$true}
    'needs-attention'=@{FailureHeld=$true}
    'background-found'=@{Background='ready-attachable'}
    'waiting-microsoft'=@{VcBrokerActive=$true}
}
$homeStatusText=@{
    'not-running'='Not running. Install & start sets up and starts the best setup for your card.'
    'starting'='Downloading the model. This can take a while on a first start.'
    'running'='Running. Connect an app with the address below.'
    'needs-attention'='Action needs attention. Use Copy full output, then review Diagnostics.'
    'background-found'='A FastLLM run is already active in the background. Attach to use it.'
    'waiting-microsoft'='Microsoft setup is still running. Complete or cancel it in the Microsoft window.'
}
# The ONE binding loop of the render test. It mirrors the shell's loop in Initialize-FastLlmUiFluentShell (the same Mode, Event, Flags and Also handling),
# so a table row is bound here exactly as the window binds it.
function Connect-RenderBindingRows([object[]]$Rows,[hashtable]$Els){
    foreach($row in $Rows){
        $adapter=Get-Variable -Name ([string]$row.Name) -Scope Script -ValueOnly
        $also=($row.ContainsKey('Also') -and [bool]$row['Also'])
        Connect-FastLlmUiFluentControl -Adapter $adapter -Element $Els[[string]$row.Element] -Mode ([string]$row.Mode) -Event ([string]$row.Event) -Flags @($row.Flags) -Also:$also
    }
}
function Initialize-HomeRenderPage($Page){
    $els=@{}
    [void](Initialize-FastLlmUiFluentHome -Page $Page -Els $els)
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentHomeBindings) $els
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme}
    $script:statusLabel.Text=[string]$homeStatusText[$script:homeState]
    $script:homeSnap=New-HomeSnap $homeSnaps[$script:homeState]
    Update-FastLlmUiFluentHome
    $script:FastLlmUiFluent.Tick=2
}
$homePrepare={param($page) Initialize-HomeRenderPage $page}
function Test-HomeCase([string]$State,$case){
    $script:homeState=$State
    $script:homeCaseTheme=[string]$case.theme
    $label="Home $State $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Home' -Case $case -OutFolder $out -Prepare $homePrepare}catch{Check $false "Home renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Home clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Home render is real at $label"
}
$homeSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-HomeCase 'not-running' $case}
foreach($state in 'starting','running','needs-attention','background-found','waiting-microsoft'){
    foreach($theme in 'light','dark','high-contrast'){
        foreach($text in 1.0,2.25){
            $case=@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}
            Test-HomeCase $state $case
        }
    }
}
Write-Host ('INFO: Home render of {0} cases took {1:N1} s' -f ($matrix.Count+30),$homeSw.Elapsed.TotalSeconds)

# ---- Overlap pin: Home at text 1.0, 2.0 and 2.25 has no overlap, the Minimize to tray button is the first tab stop, and the whole tab sequence is the reading order.
foreach($text in 1.0,2.0,2.25){
    $case=@{theme='light';scale=[double]1.0;textScale=[double]$text;width=640;height=480}
    $script:homeState='not-running'
    $script:homeCaseTheme='light'
    $script:pinPage=$null
    $pinPrepare={param($page) $script:pinPage=$page; Initialize-HomeRenderPage $page}
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Home' -Case $case -OutFolder $out -Prepare $pinPrepare}catch{Check $false "Home overlap pin renders at text ${text}: $($_.Exception.Message)";continue}
    $overlaps=@(@($r.problems)|Where-Object{$_ -like 'overlap:*'})
    Check ($overlaps.Count -eq 0) "Home has no overlap at text ${text}: $($overlaps -join '; ')"
    $all=Get-UiVisualElements $script:pinPage
    $stops=New-Object System.Collections.ArrayList
    foreach($el in $all){
        if($el -is [System.Windows.Controls.Control] -and (Test-UiAuthored $el) -and $el.Focusable -and $el.IsTabStop -and $el.IsEnabled -and (Test-UiShown $el $script:pinPage)){[void]$stops.Add($el)}
    }
    $firstName=''
    if($stops.Count -gt 0){$firstName=[string]$stops[0].Name}
    Check ($firstName -ceq 'TrayButton') "TrayButton is the first tab stop in Home at text ${text} (first is '$firstName' of $($stops.Count) stops)"
    $rows=@()
    $order=0
    foreach($el in $stops){
        $rect=Get-UiRelativeRect $el $script:pinPage
        if($null -ne $rect){$rows+=[pscustomobject]@{Name=(Get-UiElementLabel $el);Row=[double][Math]::Round($rect.Top/8.0);Left=[double]$rect.Left;Order=$order}}
        $order++
    }
    $byRead=@($rows|Sort-Object -Property @{Expression='Row'},@{Expression='Left'},@{Expression='Order'})
    $treeNames=(@($rows|ForEach-Object{$_.Name}) -join ', ')
    $readNames=(@($byRead|ForEach-Object{$_.Name}) -join ', ')
    Write-Host "INFO: Home tab sequence at text ${text}: tree [$treeNames] reading [$readNames]"
    Check ($treeNames -ceq $readNames -and $rows.Count -eq $stops.Count) "the Home tab sequence is the reading order at text ${text}"
}

# ---- The Tools page: idle across the 40-case matrix, and busy (every disabled button with its reason) at 640x480 x 3 themes x text 1.0 and 2.25.
# The prepare step is what the shell does for the page: Initialize-FastLlmUiFluentTools, the page's rows of the binding table, then one reasons refresh.
$script:toolsBusy=$false
$script:toolsEls=$null
function Initialize-ToolsRenderPage($Page){
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentTools -Page $Page -Els $els)
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentToolsBindings) $els
    $els['ToolsStatusText'].Text='Not running. Install & start sets up and starts the best setup for your card.'
    if($script:toolsBusy){
        $script:homeSnap=New-HomeSnap @{Busy=$true;ChildActive=$true;Step='model download'}
        foreach($row in (Get-FastLlmUiFluentToolsReasonRows)){(Get-Variable -Name ([string]$row.Adapter) -Scope Script -ValueOnly).Enabled=$false}
        Update-FastLlmUiFluentTools
    }else{$script:homeSnap=New-HomeSnap @{}}
    $script:toolsEls=$els
}
$toolsPrepare={param($page) Initialize-ToolsRenderPage $page}
function Test-ToolsCase([bool]$Busy,$case){
    $script:toolsBusy=$Busy
    $script:homeCaseTheme=[string]$case.theme
    $kind='idle'
    $pngName='FastLlm.Tools'
    if($Busy){$kind='busy';$pngName='FastLlm.ToolsBusy'}
    $label="Tools $kind $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Tools' -Case $case -OutFolder $out -Prepare $toolsPrepare -PngName $pngName}catch{Check $false "Tools renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Tools clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Tools render is real at $label"
    $e=$script:toolsEls
    Check (@(@('ToolsDiagnosticsButton','ToolsDriverButton','ToolsBundleButton','ToolsLogsButton','ToolsRecheckButton','ToolsAttachButton')|Where-Object{[string]$e[$_].Content -eq ''}).Count -eq 0) "every Tools button has its adapter caption at $label"
    if($Busy){
        $noReason=@(Get-FastLlmUiFluentToolsReasonRows|Where-Object{-not $e[[string]$_.Element].IsEnabled -and [string]::IsNullOrEmpty([string]$e[[string]$_.Element].ToolTip)}|ForEach-Object{[string]$_.Element})
        Check ($noReason.Count -eq 0) "every disabled Tools button says why at ${label}: no reason on $($noReason -join ', ')"
    }
}
$toolsSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-ToolsCase $false $case}
foreach($theme in 'light','dark','high-contrast'){
    foreach($text in 1.0,2.25){Test-ToolsCase $true @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
}
Write-Host ('INFO: Tools render of {0} cases took {1:N1} s' -f ($matrix.Count+6),$toolsSw.Elapsed.TotalSeconds)

# ---- The Connect page. The facts come from the real Get-FastLlmConnectionInfo (a run status in) and the real Get-FastLlmUiApiKeyRow (the store state in).
# Running with the key on shows every client card, the agent warning (a 16K context) and the key row; "not running" has no key row; "key unreadable"
# is running with the key on and a store this user cannot read.
function New-ConnectRunStatus{
    return [pscustomobject]@{phase='ready';active=$true;runId='aabbccdd11223344aabbccdd11223344';modelId='render-model-q4';endpoint='http://127.0.0.1:8123/v1';apiKey='on';apiKeyId='0123abcd'
        recipe=[pscustomobject]@{catalogVersion='1';contextSize=16384;id=$null}}
}
function Set-ConnectRenderState([string]$State){
    switch -CaseSensitive ($State){
        'running'{
            $script:renderRunStatus=New-ConnectRunStatus
            $script:renderKeyStore=[pscustomobject]@{exists=$true;available=$true;apiKeyId='0123abcd'}
            $script:homeSnap=New-HomeSnap @{RunReady=$true;ChildActive=$true;Step='serving'}
        }
        'not-running'{
            $script:renderRunStatus=$null
            $script:renderKeyStore=[pscustomobject]@{exists=$false;available=$false;apiKeyId=$null}
            $script:homeSnap=New-HomeSnap @{}
        }
        'key-unreadable'{
            $script:renderRunStatus=New-ConnectRunStatus
            $script:renderKeyStore=[pscustomobject]@{exists=$true;available=$false;apiKeyId=$null}
            $script:homeSnap=New-HomeSnap @{RunReady=$true;ChildActive=$true;Step='serving'}
        }
        default{throw "unknown Connect render state $State"}
    }
}
$script:connectState='running'
$script:connectEls=$null
function Initialize-ConnectRenderPage($Page){
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentConnect -Page $Page -Els $els)
    Set-ConnectRenderState $script:connectState
    $els['ConnectStatusText'].Text='Running. Connect an app with the address below.'
    $script:renderFail=''
    Enter-FastLlmUiFluentConnect
    $script:connectEls=$els
}
$connectPrepare={param($page) Initialize-ConnectRenderPage $page}
function Test-ConnectCase([string]$State,$case){
    $script:connectState=$State
    $script:homeCaseTheme=[string]$case.theme
    $pngName='FastLlm.Connect'
    if($State -ceq 'not-running'){$pngName='FastLlm.ConnectNotRunning'}
    elseif($State -ceq 'key-unreadable'){$pngName='FastLlm.ConnectKeyUnreadable'}
    $label="Connect $State $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Connect' -Case $case -OutFolder $out -Prepare $connectPrepare -PngName $pngName}catch{Check $false "Connect renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Connect clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Connect render is real at $label"
    $e=$script:connectEls
    Check ($script:renderFail -ceq '') "the Connect page filled without a failure at ${label}: '$($script:renderFail)'"
    $running=($State -cne 'not-running')
    $keyRow=($e['ConnectKeyRow'].Visibility -eq [System.Windows.Visibility]::Visible)
    Check ($keyRow -eq $running) "the Connect key row is shown exactly when the key is on at $label"
    if($State -ceq 'key-unreadable'){Check (-not $e['ConnectKeyShow'].IsEnabled -and -not $e['ConnectKeyCopy'].IsEnabled) "an unreadable key disables Show and Copy at $label"}
    if($State -ceq 'running'){
        Check ([string]$e['ConnectBaseUrlBox'].Text -ceq 'http://127.0.0.1:8123/v1' -and $e['ConnectClients'].Children.Count -ge 2 -and $e['ConnectAgentWarning'].Visibility -eq [System.Windows.Visibility]::Visible) "a running Connect page shows its address, the client cards and the agent warning at $label"
    }
}
$connectSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-ConnectCase 'running' $case}
foreach($state in 'not-running','key-unreadable'){
    foreach($theme in 'light','dark','high-contrast'){
        foreach($text in 1.0,2.25){Test-ConnectCase $state @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
    }
}
Write-Host ('INFO: Connect render of {0} cases took {1:N1} s' -f ($matrix.Count+12),$connectSw.Elapsed.TotalSeconds)

# ---- The Models page. The store reads, the engine components and the switch picker are shadows over a fixture; the page, its lists, its reasons and the
# bindings are the product's. 'long' is the stress case (long names, in-use rows, leftovers, components, picker items with long verdicts, a long folder path,
# the Start options open and long messages); 'empty' has nothing installed, switching off with its reason line and the Start options closed.
$script:form=$null
$script:catalog=$script:homeCatalog
$script:modelsFx=$null
$script:modelsEls=$null
function Get-FastLlmInstalledModels{param([string]$InstallRoot,[string]$CatalogPath)return @($script:modelsFx.models)}
function Get-FastLlmModelLeftovers{param([string]$InstallRoot)return @($script:modelsFx.leftovers)}
function Get-FastLlmModelStoreFreeBytes{param([string]$InstallRoot)return [int64]123456789012}
function Get-FastLlmComponentInventory{param([string]$ComponentsPath,[string]$InstallRoot)return @()}
function Get-FastLlmInstalledComponentRows{param([object[]]$Inventory)return @($script:modelsFx.components)}
function Get-FastLlmStatus{param([string]$InstallRoot)return $null}
function Get-FastLlmUiSwitchPickerModel{param([string]$InstallRoot,[string]$CatalogPath,$Status,[scriptblock]$RowsProvider)return [pscustomobject]@{items=@($script:modelsFx.pickerItems);message=''}}
function New-ModelsRenderFixture([string]$Kind){
    if($Kind -ceq 'empty'){
        return @{kind='empty';catalog=$script:homeCatalog;models=@();leftovers=@();components=@();pickerItems=@();switchOn=$false;expanded=$false;folder=[string]$script:InstallRoot
            switchLine='Model switching is off. Turn it on in the settings to switch models while FastLLM runs.';longMessages=$false;models_n=0;components_n=0;picker_n=0}
    }
    $entries=New-Object System.Collections.ArrayList
    $installed=New-Object System.Collections.ArrayList
    $picker=New-Object System.Collections.ArrayList
    for($i=1;$i -le 10;$i++){
        $id=('render-model-{0:D2}' -f $i)
        [void]$entries.Add([pscustomobject]@{id=$id;upstreamModel=('example-org/Very-Long-Model-Name-For-Layout-Checks-{0:D2}-Instruct-Extended-Context' -f $i);quantization='Q4_K_M'})
        $reason='';if($i -le 2){$reason='FastLLM is serving this model right now, so it cannot be removed.'}
        [void]$installed.Add([pscustomobject]@{id=$id;sizeBytes=[int64](1500000000+$i*250000000);inUse=($i -le 2);inUseReason=$reason})
    }
    for($i=1;$i -le 8;$i++){
        [void]$picker.Add([pscustomobject]@{id=('render-model-{0:D2}' -f $i);text=('Very-Long-Model-Name-For-Layout-Checks-{0:D2}-Instruct Q4_K_M  -  fits with room for the context you picked, about 30 GB needed of 48 GB free' -f $i);canSwitch=(($i % 2) -eq 1)})
    }
    $components=@()
    for($i=1;$i -le 5;$i++){$components+=[pscustomobject]@{id=('render-engine-{0}' -f $i);label=('render-engine-{0} (engine, 1.{0}.0, {0}40 MB) - a long component label to wrap on a narrow window' -f $i)}}
    $leftovers=@([pscustomobject]@{name='a.part';sizeBytes=[int64]1073741824;locked=$false},[pscustomobject]@{name='b.part';sizeBytes=[int64]536870912;locked=$false})
    $catalog=[pscustomobject]@{models=@($entries.ToArray())}
    return @{kind='long';catalog=$catalog;models=@($installed.ToArray());leftovers=$leftovers;components=$components;pickerItems=@($picker.ToArray());switchOn=$true;expanded=$true
        folder='D:\Programs and Data With A Long Name\FastLLM\models and caches\a-very-long-folder-name-for-the-layout-checks-and-one-more-part-to-make-it-longer';switchLine='';longMessages=$true;models_n=10;components_n=5;picker_n=8}
}
function Set-ModelsRenderFixtureState($Fx,$Els){
    $script:pathBox.Text=[string]$Fx.folder
    $script:switchButton.Enabled=[bool]$Fx.switchOn
    if([string]$Fx.switchLine -ne ''){$script:switchLabel.Text=[string]$Fx.switchLine}
    $Els['ModelsStartOptions'].IsExpanded=[bool]$Fx.expanded
}
function Set-ModelsRenderMessages($Fx){
    if(-not [bool]$Fx.longMessages){return}
    $long='The model list could not be read because the folder is on a drive that is not ready, and this sentence is long on purpose so that it wraps at a narrow window width and at the largest text size. '
    $m=$script:FastLlmUiFluent['Models']
    $m['Message'].Text=$long.Substring(0,180)
    $m['ComponentsMessage'].Text=$long.Substring(0,180)
    $m['SwitchMessage'].Text=$long.Substring(0,180)
}
function Initialize-ModelsRenderPage($Page){
    $fx=$script:modelsFx
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentModels -Page $Page -Els $els)
    # The names the stand-in holds are exactly the page's x:Names (resolved through FindName by the product's own collection, checked against the markup here).
    $pageNames=Get-UiPageElementNames ([string]$script:FastLlmUiXaml['FastLlm.Models'])
    $absent=@($pageNames|Where-Object{-not $els.ContainsKey([string]$_)})
    if($absent.Count -gt 0){throw ('Models names missing from the element map: '+($absent -join ', '))}
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentModelsBindings) $els
    Set-ModelsRenderFixtureState $fx $els
    $script:catalog=$fx.catalog
    $script:homeSnap=New-HomeSnap @{}
    $script:renderFail=''
    Enter-FastLlmUiFluentModels
    Set-ModelsRenderMessages $fx
    $script:modelsEls=$els
}
$modelsPrepare={param($page) Initialize-ModelsRenderPage $page}
function Get-RenderRemoveButtons($Panel){
    $list=New-Object System.Collections.ArrayList
    foreach($row in $Panel.Children){
        if($row -is [System.Windows.Controls.Grid]){foreach($cell in $row.Children){if($cell -is [System.Windows.Controls.Button]){[void]$list.Add($cell)}}}
    }
    return $list.ToArray()
}
function Test-ModelsCase([string]$Kind,$case){
    $script:modelsFx=New-ModelsRenderFixture $Kind
    $script:homeCaseTheme=[string]$case.theme
    $pngName='FastLlm.Models'
    if($Kind -ceq 'empty'){$pngName='FastLlm.ModelsEmpty'}
    $label="Models $Kind $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Models' -Case $case -OutFolder $out -Prepare $modelsPrepare -PngName $pngName -ScrollOwners @('ModelsSwitchList')}catch{Check $false "Models renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Models clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Models render is real at $label"
    $e=$script:modelsEls
    $fx=$script:modelsFx
    Check ($script:renderFail -ceq '') "the Models page filled without a failure at ${label}: '$($script:renderFail)'"
    $modelButtons=@(Get-RenderRemoveButtons $e['ModelsModelRows'])
    $componentButtons=@(Get-RenderRemoveButtons $e['ModelsComponentRows'])
    $wantModelChildren=[Math]::Max(1,[int]$fx.models_n)
    $wantComponentChildren=[Math]::Max(1,[int]$fx.components_n)
    Check ($e['ModelsModelRows'].Children.Count -eq $wantModelChildren -and $modelButtons.Count -eq [int]$fx.models_n) "the Models list has its fixture rows at ${label} (children $($e['ModelsModelRows'].Children.Count) of $wantModelChildren, buttons $($modelButtons.Count) of $($fx.models_n))"
    Check ($e['ModelsComponentRows'].Children.Count -eq $wantComponentChildren -and $componentButtons.Count -eq [int]$fx.components_n) "the component list has its fixture rows at ${label} (children $($e['ModelsComponentRows'].Children.Count) of $wantComponentChildren, buttons $($componentButtons.Count) of $($fx.components_n))"
    $names=@($modelButtons+$componentButtons|ForEach-Object{[string][System.Windows.Automation.AutomationProperties]::GetName($_)})
    Check (@($names|Where-Object{$_ -notmatch '^Remove .'}).Count -eq 0 -and @($names|Sort-Object -Unique).Count -eq $names.Count) "every Remove button has its own name at ${label} (names: $($names -join ' | '))"
    Check ($e['ModelsSwitchList'].Items.Count -eq [int]$fx.picker_n) "the switch list has its fixture items at ${label} (got $($e['ModelsSwitchList'].Items.Count) of $($fx.picker_n))"
    Check ([bool]$e['ModelsStartOptions'].IsExpanded -eq [bool]$fx.expanded) "the Start options are $(if($fx.expanded){'open'}else{'closed'}) at $label"
    $disabledModels=@($modelButtons|Where-Object{-not $_.IsEnabled})
    if($Kind -ceq 'long'){
        Check ($disabledModels.Count -eq 2 -and @($disabledModels|Where-Object{[string]::IsNullOrEmpty([string]$_.ToolTip)}).Count -eq 0) "the two in-use models have a disabled Remove with a reason at $label"
        Check ($e['ModelsLeftoverButton'].IsEnabled) "the leftover button is enabled with leftovers at $label"
    }else{
        Check (-not $e['ModelsLeftoverButton'].IsEnabled -and [string]$e['ModelsLeftoverButton'].ToolTip -ceq [string]$script:FastLlmUiFluentStrings.WhyNoLeftovers) "the leftover button says why it is off at $label"
    }
}
$modelsSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-ModelsCase 'long' $case}
foreach($theme in 'light','dark','high-contrast'){
    foreach($text in 1.0,2.25){Test-ModelsCase 'empty' @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
}
Write-Host ('INFO: Models render of {0} cases took {1:N1} s' -f ($matrix.Count+6),$modelsSw.Elapsed.TotalSeconds)

# ---- Reading order of the Tools, Connect and Models pages at text 1.0, 2.0 and 2.25: no overlap, and the whole tab sequence is the reading order.
function Test-PageReadingOrder([string]$Label,[string]$XamlName,[string]$PngName,[scriptblock]$Prepare,[int]$MinStops,[string[]]$ScrollOwners=@(),[string[]]$TabRegions=@()){
    foreach($text in 1.0,2.0,2.25){
        $case=@{theme='light';scale=[double]1.0;textScale=[double]$text;width=640;height=480}
        $script:homeCaseTheme='light'
        $script:pinPage=$null
        # A plain scriptblock (not a closure), so $script: is this file's scope; the page's own prepare step is handed over in $script:pinInner.
        $script:pinInner=$Prepare
        $pinPrepare={param($page) $script:pinPage=$page; & $script:pinInner $page}
        $r=$null
        try{$r=Invoke-UiRenderCase -Name $XamlName -Case $case -OutFolder $out -Prepare $pinPrepare -PngName $PngName -ScrollOwners $ScrollOwners -TabRegions $TabRegions}catch{Check $false "$Label reading order renders at text ${text}: $($_.Exception.Message)";continue}
        $overlaps=@(@($r.problems)|Where-Object{$_ -like 'overlap:*'})
        Check ($overlaps.Count -eq 0) "$Label has no overlap at text ${text}: $($overlaps -join '; ')"
        $stops=New-Object System.Collections.ArrayList
        foreach($el in (Get-UiVisualElements $script:pinPage)){
            if($el -is [System.Windows.Controls.Control] -and (Test-UiAuthored $el) -and $el.Focusable -and $el.IsTabStop -and $el.IsEnabled -and (Test-UiShown $el $script:pinPage)){[void]$stops.Add($el)}
        }
        $rows=@()
        $order=0
        foreach($el in $stops){
            $rect=Get-UiRelativeRect $el $script:pinPage
            if($null -ne $rect){$rows+=[pscustomobject]@{Name=(Get-UiElementLabel $el);Region=(Get-UiTabRegion $el $script:pinPage $TabRegions);Row=[double][Math]::Round($rect.Top/8.0);Left=[double]$rect.Left;Order=$order}}
            $order++
        }
        $byRead=@($rows|Sort-Object -Property @{Expression='Region'},@{Expression='Row'},@{Expression='Left'},@{Expression='Order'})
        $treeNames=(@($rows|ForEach-Object{$_.Name}) -join ', ')
        $readNames=(@($byRead|ForEach-Object{$_.Name}) -join ', ')
        Write-Host "INFO: $Label tab sequence at text ${text}: tree [$treeNames] reading [$readNames]"
        Check ($treeNames -ceq $readNames -and $rows.Count -eq $stops.Count -and $stops.Count -ge $MinStops) "the $Label tab sequence is the reading order at text ${text} ($($stops.Count) stops, at least $MinStops)"
    }
}
$orderSw=[Diagnostics.Stopwatch]::StartNew()
$script:toolsBusy=$false
Test-PageReadingOrder 'Tools' 'FastLlm.Tools' 'FastLlm.ToolsReading' $toolsPrepare 6
$script:connectState='running'
Test-PageReadingOrder 'Connect' 'FastLlm.Connect' 'FastLlm.ConnectReading' $connectPrepare 10
# Models at the long fixture (the Start options open, so the whole page is in the tab sequence): the model box, the three start inputs, the switch list, the leftover
# button and the 13 Remove buttons, at least 12 stops
$script:modelsFx=New-ModelsRenderFixture 'long'
Test-PageReadingOrder 'Models' 'FastLlm.Models' 'FastLlm.ModelsReading' $modelsPrepare 12 @('ModelsSwitchList')
Write-Host ('INFO: Tools, Connect and Models reading order of 9 cases took {0:N1} s' -f $orderSw.Elapsed.TotalSeconds)

# ---- The Settings page (PR 3c): the fluent replacement for settings-dialog-render-tests (the table is in the PR body).
# The serving settings and the sign-in view are fixtures over the real functions; the page, its bindings, its reasons and its Enter are the product's.
# The harness wraps a page in a ScrollViewer with unlimited height, so a bounded page height (the window's) is set in the prepare step: row 0 (the page's own
# ScrollViewer) then fills what the footer leaves, and the footer is always in view, as in the app. Tab regions: the page's scroll content first, the footer last.
$script:settingsOverride=$null
$script:settingsKind='notset'
$script:settingsCaseHeight=[double]480
$script:settingsPageEl=$null
$script:settingsEls=$null
$script:uiSettings=$script:homeSettings
# The function's script block, not a FunctionInfo: a FunctionInfo is updated in place when the function is redefined below, so the wrapper would call itself.
$script:realGetServingSettings=${function:Get-FastLlmServingSettings}
function Get-FastLlmServingSettings{
    param([string]$InstallRoot)
    $real=& $script:realGetServingSettings -InstallRoot $InstallRoot
    if($null -ne $script:settingsOverride){foreach($k in @($script:settingsOverride.Keys)){$real.$k=$script:settingsOverride[$k]}}
    return $real
}
function Get-FastLlmSignInDefaultInstallRoot{return [string]$script:homeDir}
function Get-FastLlmSignInSettingsView{param([string]$AppRoot,[string]$InstallRoot)return [pscustomobject]@{checked=$false;stateText='Starting FastLLM when you sign in is off.';lastResultText='No sign-in start has run yet.'}}
# The fixtures: not set (the worst case: the long caption, the long thinking text, the biggest port), key on, key off, running (key on), unavailable (a launch is starting).
function Get-SettingsRenderFixture([string]$Kind){
    switch -CaseSensitive ($Kind){
        'notset'{return @{override=@{serverPort=65535;thinking='off';chatPage='on';idleStopMinutes=60;apiKey='off';apiKeyUndetermined=$true};snap=@{};unavailable=$false;keyChecked=$null}}
        'on'{return @{override=@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=15;apiKey='on';apiKeyUndetermined=$false};snap=@{};unavailable=$false;keyChecked=$true}}
        'off'{return @{override=@{serverPort=8080;thinking='off';chatPage='on';idleStopMinutes=0;apiKey='off';apiKeyUndetermined=$false};snap=@{};unavailable=$false;keyChecked=$false}}
        'running'{return @{override=@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=30;apiKey='on';apiKeyUndetermined=$false};snap=@{ChildActive=$true;Step='serving';RunReady=$true};unavailable=$false;keyChecked=$true}}
        'unavailable'{return @{override=@{serverPort=8080;thinking='auto';chatPage='off';idleStopMinutes=0;apiKey='off';apiKeyUndetermined=$false};snap=@{Busy=$true;ChildActive=$true;Step='model download'};unavailable=$true;keyChecked=$false}}
        default{throw "unknown Settings render state $Kind"}
    }
}
function Initialize-SettingsRenderPage($Page){
    $fx=Get-SettingsRenderFixture $script:settingsKind
    $els=@{}
    $script:FastLlmUiFluent=@{Window=$null;Els=$els;Keys=@{};Tick=1;Theme=[string]$script:homeCaseTheme;Pages=@{};Current=''}
    [void](Initialize-FastLlmUiFluentSettings -Page $Page -Els $els)
    $pageNames=Get-UiPageElementNames ([string]$script:FastLlmUiXaml['FastLlm.Settings'])
    $absent=@($pageNames|Where-Object{-not $els.ContainsKey([string]$_)})
    if($absent.Count -gt 0){throw ('Settings names missing from the element map: '+($absent -join ', '))}
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentSettingsBindings) $els
    $script:settingsOverride=$fx.override
    $script:homeSnap=New-HomeSnap $fx.snap
    $script:settingsButton.Enabled=(-not [bool]$fx.unavailable)
    $script:renderFail=''
    Enter-FastLlmUiFluentSettings
    $Page.Height=[double]$script:settingsCaseHeight
    $script:settingsPageEl=$Page
    $script:settingsEls=$els
}
$settingsPrepare={param($page) Initialize-SettingsRenderPage $page}
# Pixels of a box's text area that differ from the area's most common colour (the box background): 0 means the box is blank. -1: the area is outside the bitmap.
function Get-UiRegionInk([string]$PngPath,$Rect,[double]$Scale){
    $stream=[System.IO.File]::OpenRead($PngPath)
    try{
        $decoder=New-Object System.Windows.Media.Imaging.PngBitmapDecoder($stream,[System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $conv=New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($decoder.Frames[0],[System.Windows.Media.PixelFormats]::Pbgra32,$null,0)
        $x0=[int][Math]::Ceiling(($Rect.Left+6)*$Scale);$y0=[int][Math]::Ceiling(($Rect.Top+5)*$Scale)
        $w=[int][Math]::Floor(($Rect.Width*0.5)*$Scale);$h=[int][Math]::Floor(($Rect.Height-10)*$Scale)
        if($w -le 0 -or $h -le 0 -or $x0 -lt 0 -or $y0 -lt 0 -or ($x0+$w) -gt $conv.PixelWidth -or ($y0+$h) -gt $conv.PixelHeight){return -1}
        $stride=$w*4
        $pixels=New-Object byte[] ($stride*$h)
        $conv.CopyPixels((New-Object System.Windows.Int32Rect($x0,$y0,$w,$h)),$pixels,$stride,0)
        $counts=@{}
        for($i=0;$i -lt $pixels.Length;$i+=4){$v=[BitConverter]::ToInt32($pixels,$i);if($counts.ContainsKey($v)){$counts[$v]++}else{$counts[$v]=1}}
        $mode=0;foreach($c in $counts.Values){if($c -gt $mode){$mode=$c}}
        return [int]($w*$h-$mode)
    }finally{$stream.Dispose()}
}
# PR 3c CI round 1 (F6): a selection box shows its selection when a non-empty selected string reaches the box's own presenter (a TextBlock or the ContentPresenter that
# holds the string), whichever template draws it. An empty or missing selection is never drawn. The ink check below still judges the pixels of the box's own rectangle.
function Test-UiSelectionDrawn($Box){
    $selected=[string]$Box.SelectedItem
    if([string]::IsNullOrEmpty($selected)){return $false}
    foreach($v in (Get-UiVisualElements $Box)){
        if($v -is [System.Windows.Controls.TextBlock] -and [string]$v.Text -ceq $selected){return $true}
        if($v -is [System.Windows.Controls.ContentPresenter] -and $v.Content -is [string] -and [string]$v.Content -ceq $selected){return $true}
    }
    return $false
}
$plantedBox=New-Object System.Windows.Controls.ComboBox
$plantedBox.Items.Add('') | Out-Null
$plantedBox.SelectedIndex=0
Check (-not (Test-UiSelectionDrawn $plantedBox)) 'planted: a box whose selected text is empty is not drawn'
$plantedBox.SelectedIndex=-1
Check (-not (Test-UiSelectionDrawn $plantedBox)) 'planted: a box with no selection is not drawn'
function Test-SettingsCase([string]$Kind,$case){
    $script:settingsKind=$Kind
    $script:settingsCaseHeight=[double]$case.height
    $script:homeCaseTheme=[string]$case.theme
    $pngName='FastLlm.Settings'
    switch -CaseSensitive ($Kind){'on'{$pngName='FastLlm.SettingsKeyOn'}'off'{$pngName='FastLlm.SettingsKeyOff'}'running'{$pngName='FastLlm.SettingsRunning'}'unavailable'{$pngName='FastLlm.SettingsUnavailable'}}
    $label="Settings $Kind $($case.theme) $($case.scale) $($case.textScale) $($case.width)x$($case.height)"
    $r=$null
    try{$r=Invoke-UiRenderCase -Name 'FastLlm.Settings' -Case $case -OutFolder $out -Prepare $settingsPrepare -PngName $pngName -TabRegions @('SettingsScroll')}catch{Check $false "Settings renders at ${label}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "Settings clean at ${label}: $(@($r.problems) -join '; ')$diagText"
    $real=$false
    if($r.png -and (Test-Path -LiteralPath $r.png)){$info=Get-UiPngInfo -Path $r.png;$real=$info.hasContent}
    Check $real "the Settings render is real at $label"
    $e=$script:settingsEls
    $page=$script:settingsPageEl
    $fx=Get-SettingsRenderFixture $Kind
    $t=$script:FastLlmUiFluentSettingsText
    Check ($script:renderFail -ceq '') "the Settings page filled without a failure at ${label}: '$($script:renderFail)'"
    # every authored element is shown, apart from the unavailable line (shown only while unavailable)
    $hidden=@((Get-UiPageElementNames ([string]$script:FastLlmUiXaml['FastLlm.Settings']))|Where-Object{[string]$_ -cne 'SettingsUnavailableText' -and -not (Test-UiShown $e[[string]$_] $page)})
    Check ($hidden.Count -eq 0) "no Settings control is hidden at ${label}: $($hidden -join ', ')"
    $line=($e['SettingsUnavailableText'].Visibility -eq [System.Windows.Visibility]::Visible)
    Check ($line -eq [bool]$fx.unavailable -and (-not $line -or [string]$e['SettingsUnavailableText'].Text -ceq [string]$script:FastLlmUiFluentStrings.WhyBusy)) "the unavailable line is shown exactly while unavailable, with WhyBusy, at $label (shown=$line text='$($e['SettingsUnavailableText'].Text)')"
    # the footer: Save and Discard inside the client area, never inside the scroll viewer; the scroll viewer fills what the footer leaves
    $scroll=$e['SettingsScroll']
    $badFooter=@()
    foreach($n in 'SettingsSaveButton','SettingsDiscardButton'){
        $rect=Get-UiRelativeRect $e[$n] $page
        if($null -eq $rect -or $rect.Top -lt -0.5 -or $rect.Bottom -gt ([double]$case.height+0.5) -or $rect.Right -gt ([double]$case.width+0.5) -or $scroll.IsAncestorOf($e[$n])){$badFooter+="$n rect=$rect inScroll=$($scroll.IsAncestorOf($e[$n]))"}
    }
    Check ($badFooter.Count -eq 0) "Save and Discard are in the footer, inside the client area and outside the scroll viewer at ${label}: $($badFooter -join '; ')"
    Check ([Math]::Abs([double]$scroll.ActualHeight+[double]$e['SettingsFooter'].ActualHeight-[double]$case.height) -le 1.0) "the Settings scroll viewer fills the page above the footer at ${label} (scroll $($scroll.ActualHeight) + footer $($e['SettingsFooter'].ActualHeight) of $($case.height))"
    $outside=@('SettingsServerGroup','SettingsStartingGroup','SettingsComponentsGroup'|Where-Object{-not $scroll.IsAncestorOf($e[[string]$_])})
    Check ($outside.Count -eq 0) "every Settings group is inside the scroll content at ${label}: $($outside -join ', ')"
    if([double]$case.textScale -ge 2.25 -and [int]$case.width -eq 640){
        Check ([double]$scroll.ExtentHeight -gt [double]$scroll.ViewportHeight) "at text 2.25 the Settings content needs scrolling at ${label} (extent $($scroll.ExtentHeight), viewport $($scroll.ViewportHeight))"
    }
    # The PR 3c plan, Task 4, Layout: "Row 1 is the **footer**, outside the scroll, so Save and Discard are always in view (today's docked button row)".
    # That is the requirement, so it is checked in EVERY Settings case: the whole footer is shown, inside the window and outside the scroll viewer. The plan does
    # not ask for the Server group to fit the viewport (with the Fluent control styles it is 585 DIP tall and starts 98 DIP down a 623 DIP viewport at 1000x680,
    # so it scrolls), so the earlier check of that, which a test builder added for the three 1000x680 cases only, is replaced by this one.
    $footer=$e['SettingsFooter']
    $footerRect=Get-UiRelativeRect $footer $page
    $footerIn=($null -ne $footerRect -and (Test-UiShown $footer $page) -and $footerRect.Width -gt 0 -and $footerRect.Height -gt 0 -and $footerRect.Left -ge -0.5 -and $footerRect.Top -ge -0.5 -and $footerRect.Right -le ([double]$case.width+0.5) -and $footerRect.Bottom -le ([double]$case.height+0.5))
    Check ($footerIn -and -not $scroll.IsAncestorOf($footer)) "the Settings footer is fully inside the window and outside the scroll viewer at ${label} (footer $footerRect, window $($case.width)x$($case.height), inScroll=$($scroll.IsAncestorOf($footer)))"
    # the texts: each label is on its element; the three help lines are shown; the key box has its caption and state
    Check ([string]$e['SettingsPortLabel'].Text -ceq [string]$t.Port -and [string]$e['SettingsThinkingLabel'].Text -ceq [string]$t.Thinking -and [string]$e['SettingsIdleLabel'].Text -ceq [string]$t.Idle -and [string]$e['SettingsServerHeading'].Text -ceq [string]$script:FastLlmUiFluentStrings.SettingsServer) "the Settings labels and headings carry their text-table strings at $label"
    $helpBad=@('SettingsChatHelp','SettingsIdleHelp','SettingsKeyHelp','SettingsSwitchHelp'|Where-Object{[string]::IsNullOrEmpty([string]$e[[string]$_].Text) -or $e[[string]$_].Visibility -ne [System.Windows.Visibility]::Visible})
    Check ($helpBad.Count -eq 0) "the Settings help lines are shown with their text at ${label}: $($helpBad -join ', ')"
    $wantKeyName=[string]$t.Key
    if($Kind -ceq 'notset'){$wantKeyName=[string]$t.KeyNotSet}
    $keyChecked=$e['SettingsKeyBox'].IsChecked
    $keyOk=([string][System.Windows.Automation.AutomationProperties]::GetName($e['SettingsKeyBox']) -ceq $wantKeyName)
    if($Kind -ceq 'notset'){$keyOk=($keyOk -and $null -eq $keyChecked -and [bool]$e['SettingsKeyBox'].IsThreeState)}else{$keyOk=($keyOk -and $null -ne $keyChecked -and $keyChecked -eq [bool]$fx.keyChecked)}
    Check $keyOk "the key box shows the right caption and state for the $Kind fixture at ${label} (name='$([System.Windows.Automation.AutomationProperties]::GetName($e['SettingsKeyBox']))' checked=$keyChecked)"
    # the three value boxes hold the saved values and a selection
    Check ([string]$e['SettingsPortBox'].Text -ceq ([int]$fx.override.serverPort).ToString() -and [int]$e['SettingsThinkingBox'].SelectedIndex -ge 0 -and [int]$e['SettingsIdleBox'].SelectedIndex -ge 0) "Port shows the saved port and Thinking and the idle stop have a selection at $label (port='$($e['SettingsPortBox'].Text)' thinking=$($e['SettingsThinkingBox'].SelectedIndex) idle=$($e['SettingsIdleBox'].SelectedIndex))"
    foreach($n in 'SettingsThinkingBox','SettingsIdleBox'){
        $selected=[string]$e[$n].SelectedItem
        Check (Test-UiSelectionDrawn $e[$n]) "the $n selection text is drawn at ${label} ('$selected')"
    }
    $toggleBad=@('SettingsUpdateToggle','SettingsExperimentalToggle','SettingsLicenseToggle'|Where-Object{-not $e[[string]$_].IsEnabled -or [string]::IsNullOrWhiteSpace([string][System.Windows.Automation.AutomationProperties]::GetName($e[[string]$_]))})
    Check ($toggleBad.Count -eq 0) "the three Components toggles are enabled and named (also while unavailable) at ${label}: $($toggleBad -join ', ')"
    if($Kind -ceq 'unavailable'){
        Check (-not $e['SettingsServerGroup'].IsEnabled -and -not $e['SettingsStartingGroup'].IsEnabled -and -not $e['SettingsFooter'].IsEnabled) "the Server group, the Starting group and the footer are disabled while unavailable at $label"
    }else{
        Check ($e['SettingsServerGroup'].IsEnabled -and $e['SettingsStartingGroup'].IsEnabled -and $e['SettingsFooter'].IsEnabled) "the Settings groups are enabled while available at $label"
    }
    # ink: the value boxes are painted (the classic blank-list regression). Only boxes inside the viewport can be seen in the picture.
    if($r.png -and (Test-Path -LiteralPath $r.png)){
        $seen=0
        foreach($n in 'SettingsPortBox','SettingsThinkingBox','SettingsIdleBox'){
            $br=Get-UiRelativeRect $e[$n] $scroll
            if($null -eq $br -or $br.Top -lt 0 -or $br.Bottom -gt [double]$scroll.ViewportHeight){continue}
            $pr=Get-UiRelativeRect $e[$n] $page
            $ink=Get-UiRegionInk $r.png $pr ([double]$case.scale)
            $seen++
            Check ($ink -gt 0) "the $n is painted (ink pixels $ink) at $label"
        }
        if([int]$case.width -eq 1000 -and [double]$case.textScale -eq 1.0 -and [double]$case.scale -eq 1.0){Check ($seen -eq 3) "all three value boxes are inside the viewport and inked at 1000x680 (seen $seen) at $label"}
    }
}
$settingsSw=[Diagnostics.Stopwatch]::StartNew()
foreach($case in $matrix){Test-SettingsCase 'notset' $case}
foreach($kind in 'on','off','running','unavailable'){
    foreach($theme in 'light','dark','high-contrast'){
        foreach($text in 1.0,2.25){Test-SettingsCase $kind @{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}}
    }
}
Write-Host ('INFO: Settings render of {0} cases took {1:N1} s' -f ($matrix.Count+24),$settingsSw.Elapsed.TotalSeconds)
$script:settingsKind='notset'
$script:settingsCaseHeight=[double]480
Test-PageReadingOrder 'Settings' 'FastLlm.Settings' 'FastLlm.SettingsReading' $settingsPrepare 13 @() @('SettingsScroll')
$script:settingsOverride=$null

# ---- PR 4a: the dialogs (message box kinds and icons, the side result, the driver guidance). Each dialog is built by the product's own functions with
# Show-FastLlmUiFluentDialog shadowed to capture it (nothing is shown); its body and footer Grid is taken off the dialog Window and rendered like a page, at the dialog's
# own width capped at the case width. The shell Window's style resources are merged in the prepare step (as for the shell render), so these cases do not depend on the
# harness carrying them. This block runs before the shell block, which leaves a stand-in window in $script:FastLlmUiFluent.
if($null -eq (Get-Command -Name Get-FastLlmUiDialogKeyPlan -ErrorAction SilentlyContinue)){. (Join-Path $root 'src/FastLlm.UiState.ps1')}
$script:FastLlmUiFluent=$null
function RevealUiForAction{}
function SetTrayMenuAvailable([bool]$Available){}
# The message box answers as [System.Windows.Forms.DialogResult] (the window loads WinForms; this process does not until asked).
try{Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop}catch{Write-Host ('INFO: WinForms load error: '+$_.Exception.ToString())}
$script:dlgCaptured=$null
$script:dlgStyleHost=New-FastLlmUiXamlElement -Name 'FastLlm.Shell'
$script:dlgRealShow=${function:Show-FastLlmUiFluentDialog}
function Show-FastLlmUiFluentDialog{param([Parameter(Mandatory=$true)]$Dialog) $script:dlgCaptured=$Dialog; return ''}
$dlgCases=@()
foreach($theme in 'light','dark','high-contrast'){foreach($size in @(@(640,480),@(1000,680))){foreach($text in 1.0,2.25){$dlgCases+=,@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=[int]$size[0];height=[int]$size[1]}}}}
Check ($dlgCases.Count -eq 12) 'the dialog grid is 3 themes x 2 window sizes x 2 text sizes (12 cases)'
$dlgShort='Remove the model? It is deleted from this PC.'
$dlgLong=((1..40|ForEach-Object{"Line $_ of a long box body that is long enough to wrap at large text sizes and to scroll inside the dialog."}) -join "`n")
# Builds the dialog for a spec and returns its content Grid (detached from the dialog Window) and the dialog's own width.
function New-DialogRenderContent($Spec,$Case){
    $themeArgs=@{Theme=[string]$Case.theme;AccentPair=(Get-FastLlmUiAccentPair -Palette $null);TextScale=[double]$Case.textScale}
    if($Case.theme -ceq 'high-contrast'){$themeArgs['HighContrastPalette']=Get-UiRenderHighContrastPalette}
    $owner=New-Object System.Windows.Window
    $owner.Resources=New-FastLlmUiThemeDictionary @themeArgs
    $script:form=$owner
    $script:dlgCaptured=$null
    switch([string]$Spec.Kind){
        'box'{$null=Show-FastLlmUiFluentMessageBox -Owner $owner -Text ([string]$Spec.Text) -Caption 'FastLLM dialog render' -Buttons ([string]$Spec.Buttons) -Icon ([string]$Spec.Icon) -DefaultButton ([string]$Spec.Default)}
        'side'{Show-FastLlmUiFluentSideResult -Title 'FastLLM dialog render result' -Text ([string]$Spec.Text)}
        'guidance'{Show-FastLlmUiFluentDriverGuidance -Diagnostic $Spec.Diagnostic}
        default{throw "unknown dialog kind '$($Spec.Kind)'"}
    }
    if($null -eq $script:dlgCaptured){throw 'the dialog function did not build a dialog'}
    $win=$script:dlgCaptured['Window']
    $grid=$win.Content
    $win.Content=$null
    $grid.Width=[Math]::Min([double]$win.Width,[double]$Case.width)
    # The real dialog Window is capped at 95% of the work area and its star row shrinks the body, which scrolls. The case stands for that work area: the Grid is capped at the
    # case height, so the body scrolls inside the Grid and the harness page never needs a scroll bar of its own (which narrows the viewport below the Grid's fixed width).
    $grid.MaxHeight=[double]$Case.height
    return @{Content=$grid;Dialog=$script:dlgCaptured;Width=[double]$win.Width}
}
$dlgPrepare={
    param($page)
    foreach($k in @($script:dlgStyleHost.Resources.Keys)){if(-not $page.Resources.Contains($k)){$page.Resources[$k]=([object]$script:dlgStyleHost.Resources[$k]).psobject.BaseObject}}
}
$dlgGuidance=[pscustomobject]@{windows=$true;driverGuidance=@([pscustomobject]@{schemaVersion=1;qualification=$false;automaticDriverInstall=$false;hasOwnTrustedMapping=$false
    asOf='2026-01-01';inputGpuName='Probe display device';reportedPnpDriverVersion='1.0';knownFocusModel=$false;note=((1..12|ForEach-Object{"Guidance note line $_ that is long enough to wrap."}) -join ' ')})}
function Test-DialogCase([string]$Label,$Spec,$Case,[string]$PngName,[int]$WantButtons){
    $caseLabel="$($Case.theme) $($Case.scale) $($Case.textScale) $($Case.width)x$($Case.height)"
    $r=$null;$built=$null
    try{
        $built=New-DialogRenderContent $Spec $Case
        $r=Invoke-UiRenderCase -Name 'FastLlm.Dialog' -Case $Case -OutFolder $out -Element $built.Content -Prepare $dlgPrepare -PngName $PngName -TabRegions @('DlgBodyScroll')
    }catch{Check $false "$Label renders at ${caseLabel}: $($_.Exception.Message)";return}
    $diagText=''
    if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
    Check (@($r.problems).Count -eq 0) "$Label clean at ${caseLabel}: $(@($r.problems) -join '; ')$diagText"
    # the visual list is one array object on the pipeline (the function returns it with a leading comma), so it is taken into a variable and piped from there
    $dlgVisuals=Get-UiVisualElements $built.Content
    $buttons=@($dlgVisuals|Where-Object{$_ -is [System.Windows.Controls.Button] -and (Test-UiAuthored $_) -and (Test-UiShown $_ $built.Content)})
    Check ($buttons.Count -eq $WantButtons) "$Label shows $WantButtons footer button(s) at ${caseLabel} (got $($buttons.Count))"
    Check ($r.unmappedRects -eq 0) "$Label left no authored element unmapped at ${caseLabel} (got $($r.unmappedRects))"
}
$dlgSw=[Diagnostics.Stopwatch]::StartNew()
# every box kind with a short and a long body, over the 12-case grid
foreach($kind in @(@('OK','Button1',1),@('OKCancel','Button1',2),@('YesNo','Button2',2))){
    foreach($body in 'short','long'){
        $text=$dlgShort;if($body -ceq 'long'){$text=$dlgLong}
        foreach($case in $dlgCases){
            Test-DialogCase "Box $($kind[0]) $body" @{Kind='box';Buttons=$kind[0];Default=$kind[1];Icon='Question';Text=$text} $case ('FastLlm.Dialog'+$kind[0]+$body) ([int]$kind[2])
        }
    }
}
# every icon over the 3 themes at text 1.0 and 2.25 (640x480)
foreach($icon in 'None','Information','Warning','Question','Error'){
    foreach($theme in 'light','dark','high-contrast'){
        foreach($text in 1.0,2.25){
            $case=@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=640;height=480}
            Test-DialogCase "Box icon $icon" @{Kind='box';Buttons='OK';Default='Button1';Icon=$icon;Text=$dlgShort} $case ('FastLlm.DialogIcon'+$icon) 1
        }
    }
}
# the side result (long text) and the driver guidance over the 12-case grid
foreach($case in $dlgCases){Test-DialogCase 'Side result' @{Kind='side';Text=((1..60|ForEach-Object{"Probe line $_ of a long side result that wraps at large text."}) -join "`n")} $case 'FastLlm.DialogSide' 1}
foreach($case in $dlgCases){Test-DialogCase 'Driver guidance' @{Kind='guidance';Diagnostic=$dlgGuidance} $case 'FastLlm.DialogGuidance' 2}
Write-Host ('INFO: dialog render of {0} cases took {1:N1} s' -f (12*6+30+24),$dlgSw.Elapsed.TotalSeconds)
# reading order: no overlap, and the tab sequence is the reading order, at text 1.0, 2.0 and 2.25 (a YesNo box and the driver guidance, the one with a list, a text box and two buttons)
function Test-DialogReadingOrder([string]$Label,$Spec,[string]$PngName,[int]$MinStops){
    foreach($text in 1.0,2.0,2.25){
        $case=@{theme='light';scale=[double]1.0;textScale=[double]$text;width=640;height=480}
        $r=$null;$built=$null
        try{
            $built=New-DialogRenderContent $Spec $case
            $r=Invoke-UiRenderCase -Name 'FastLlm.Dialog' -Case $case -OutFolder $out -Element $built.Content -Prepare $dlgPrepare -PngName $PngName -TabRegions @('DlgBodyScroll')
        }catch{Check $false "$Label reading order renders at text ${text}: $($_.Exception.Message)";continue}
        $overlaps=@(@($r.problems)|Where-Object{$_ -like 'overlap:*'})
        Check ($overlaps.Count -eq 0) "$Label has no overlap at text ${text}: $($overlaps -join '; ')"
        $rows=@();$order=0
        foreach($el in (Get-UiVisualElements $built.Content)){
            if($el -is [System.Windows.Controls.Control] -and (Test-UiAuthored $el) -and $el.Focusable -and $el.IsTabStop -and $el.IsEnabled -and (Test-UiShown $el $built.Content)){
                $rect=Get-UiRelativeRect $el $built.Content
                # the body scroll first, the footer after it: a stop below the body's fold sorts by its unclipped Top, so the region comes first (as Test-PageReadingOrder does)
                if($null -ne $rect){$rows+=[pscustomobject]@{Name=(Get-UiElementLabel $el);Region=(Get-UiTabRegion $el $built.Content @('DlgBodyScroll'));Row=[double][Math]::Round($rect.Top/8.0);Left=[double]$rect.Left;Order=$order}}
            }
            $order++
        }
        $byRead=@(Sort-UiReadingRows $rows)
        $treeNames=(@($rows|ForEach-Object{$_.Name}) -join ', ')
        $readNames=(@($byRead|ForEach-Object{$_.Name}) -join ', ')
        Write-Host "INFO: $Label tab sequence at text ${text}: tree [$treeNames] reading [$readNames]"
        Check ($treeNames -ceq $readNames -and @($rows).Count -ge $MinStops) "the $Label tab sequence is the reading order at text ${text} ($(@($rows).Count) stops, at least $MinStops)"
    }
}
Test-DialogReadingOrder 'YesNo box' @{Kind='box';Buttons='YesNo';Default='Button2';Icon='Question';Text=$dlgShort} 'FastLlm.DialogReadingYesNo' 2
Test-DialogReadingOrder 'Driver guidance' @{Kind='guidance';Diagnostic=$dlgGuidance} 'FastLlm.DialogReadingGuidance' 4
Set-Item -Path Function:\Show-FastLlmUiFluentDialog -Value $script:dlgRealShow
$script:form=$null

# ---- The shell and Home together: the window content (navigation pane, message area, page host with Home) is rendered like a page.
# The Window element cannot be measured inside the harness, so its content is taken off it and its styles are merged into the theme dictionary.
# The update bar is visible and the failure bar holds 400 characters in every case.
$script:shellRp=$null
function New-ShellRenderPage($Case,[string]$PageId='Home'){
    $sw=New-FastLlmUiXamlElement -Name 'FastLlm.Shell'
    $homePage=New-FastLlmUiXamlElement -Name 'FastLlm.Home'
    $els=@{}
    # Every x:Name in the registered shell markup, resolved through the XAML namescope (FindName), so ColumnDefinitions and other non-visuals resolve too.
    $missing=@()
    foreach($n in (Get-UiPageElementNames ([string]$script:FastLlmUiXaml['FastLlm.Shell']))){
        $found=$sw.FindName($n)
        if($null -eq $found){$missing+=$n}else{$els[$n]=$found}
    }
    if($missing.Count -gt 0){throw ('shell names that did not resolve: '+($missing -join ', '))}
    [void](Initialize-FastLlmUiFluentHome -Page $homePage -Els $els)
    $els.PageHost.Child=$homePage
    $script:FastLlmUiFluent=@{Window=[pscustomobject]@{ActualWidth=[double]$Case.width;ActualHeight=[double]$Case.height};Els=$els;Keys=@{};Timer=$null;Tick=1;Theme=[string]$Case.theme;ThemeKey='';Interop=$false;Hooks=$null
        NavItems=@();LastException=$null;InUnhandled=$false;TickError='';Pages=@{};Current=''}
    # The binding table includes the Tools rows, so the Tools page is parsed, initialised and registered as the shell does (before the pane).
    $toolsPage=New-FastLlmUiXamlElement -Name 'FastLlm.Tools'
    [void](Initialize-FastLlmUiFluentTools -Page $toolsPage -Els $els)
    $connectPage=New-FastLlmUiXamlElement -Name 'FastLlm.Connect'
    [void](Initialize-FastLlmUiFluentConnect -Page $connectPage -Els $els)
    # PR 3b: Models is registered the same way (the binding table includes its rows, bound by the same loop below as Tools and Connect).
    $modelsPage=New-FastLlmUiXamlElement -Name 'FastLlm.Models'
    [void](Initialize-FastLlmUiFluentModels -Page $modelsPage -Els $els)
    # PR 3c (named test change): Settings is registered the same way (the binding table includes its rows), so every pane item has a page, as in the window.
    $settingsPage=New-FastLlmUiXamlElement -Name 'FastLlm.Settings'
    [void](Initialize-FastLlmUiFluentSettings -Page $settingsPage -Els $els)
    Register-FastLlmUiFluentHomePage -Page $homePage -Els $els
    Register-FastLlmUiFluentToolsPage -Page $toolsPage -Els $els
    Register-FastLlmUiFluentConnectPage -Page $connectPage -Els $els
    Register-FastLlmUiFluentModelsPage -Page $modelsPage -Els $els
    Register-FastLlmUiFluentSettingsPage -Page $settingsPage -Els $els
    Initialize-FastLlmUiFluentPane
    $null=Initialize-FastLlmUiFluentBindings -InstallRoot $script:InstallRoot -Catalog $script:homeCatalog -UiSettings $script:homeSettings
    Connect-RenderBindingRows @(Get-FastLlmUiFluentBindingTable) $els
    $long=('Engine start failed while loading the model. '*10).Substring(0,400)
    $script:bannerLabel.Text='An update to FastLLM is available.'
    $script:bannerLabel.Visible=$true
    $script:bannerButton.Visible=$true
    $script:bannerNotes.Visible=$true
    $script:failureHeld=$true
    $script:failureViewText=$long
    $script:output.Text=$long
    $script:failureCopyLink.Visible=$true
    $script:homeSnap=New-HomeSnap @{FailureHeld=$true}
    Update-FastLlmUiFluentHome
    Update-FastLlmUiFluentMessages
    Update-FastLlmUiFluentPane
    # The page under test is hosted the way the window hosts it (Leave, host, nav selection, Enter). Models is hosted with the long fixture.
    if($PageId -ceq 'Models'){
        $script:modelsFx=New-ModelsRenderFixture 'long'
        Set-ModelsRenderFixtureState $script:modelsFx $els
        $script:catalog=$script:modelsFx.catalog
    }
    if($PageId -ceq 'Settings'){$script:settingsOverride=$null;$script:settingsButton.Enabled=$true}
    if($PageId -cne 'Home'){
        $script:renderFail=''
        $hosted=Set-FastLlmUiFluentPage -Id $PageId
        if(-not [bool]$hosted -or $script:renderFail -cne ''){throw ("the shell could not host $PageId (hosted=$hosted, failure='$($script:renderFail)')")}
        if($PageId -ceq 'Models'){Set-ModelsRenderMessages $script:modelsFx}
    }
    $res=$sw.Resources
    $content=$sw.Content
    $sw.Content=$null
    return @{Content=$content;Resources=$res;Els=$els}
}
$shellPrepare={
    param($page)
    foreach($k in @($script:shellRp.Resources.Keys)){$page.Resources[$k]=([object]$script:shellRp.Resources[$k]).psobject.BaseObject}
}
$shellSw=[Diagnostics.Stopwatch]::StartNew()
foreach($pageId in 'Home','Tools','Connect','Models','Settings'){
    $pageSw=[Diagnostics.Stopwatch]::StartNew()
    $shellPng='FastLlm.Shell'
    if($pageId -cne 'Home'){$shellPng='FastLlm.Shell'+$pageId}
    foreach($theme in 'light','dark','high-contrast'){
        foreach($size in @(@(640,480),@(1000,680))){
            foreach($text in 1.0,2.25){
                $case=@{theme=$theme;scale=[double]1.0;textScale=[double]$text;width=[int]$size[0];height=[int]$size[1]}
                $label="Shell $pageId $theme $($case.scale) $text $($case.width)x$($case.height)"
                $script:homeCaseTheme=$theme
                Set-ConnectRenderState 'running'
                $r=$null
                try{
                    $script:shellRp=New-ShellRenderPage $case $pageId
                    $r=Invoke-UiRenderCase -Name 'FastLlm.Shell' -Case $case -OutFolder $out -Element $script:shellRp.Content -Prepare $shellPrepare -PngName $shellPng -TabRegions @('NavList','NavSettingsList') -ScrollOwners @('ModelsSwitchList')
                }catch{Check $false "Shell renders at ${label}: $($_.Exception.Message)";continue}
                $diagText=''
                if(@($r.diagnostics).Count -gt 0){$diagText=' | diag: '+(@($r.diagnostics) -join '; ')}
                Check (@($r.problems).Count -eq 0) "Shell clean at ${label}: $(@($r.problems) -join '; ')$diagText"
                $badBars=@()
                foreach($ln in 'NavList','NavSettingsList'){
                    $lb=$script:shellRp.Els[$ln]
                    $mode=[System.Windows.Controls.ScrollViewer]::GetHorizontalScrollBarVisibility($lb)
                    if($mode -ne [System.Windows.Controls.ScrollBarVisibility]::Disabled){$badBars+="$ln mode=$mode"}
                    foreach($v in (Get-UiVisualElements $lb)){
                        if($v -is [System.Windows.Controls.Primitives.ScrollBar] -and $v.Orientation -eq [System.Windows.Controls.Orientation]::Horizontal -and $v.Visibility -eq [System.Windows.Visibility]::Visible){$badBars+="$ln horizontal bar visible"}
                    }
                }
                Check ($badBars.Count -eq 0) "the navigation lists have no horizontal scrolling at ${label}: $($badBars -join '; ')"
                $hostedChild=$script:shellRp.Els['PageHost'].Child
                $hostedOk=$false
                if($null -ne $hostedChild){$hostedOk=[object]::ReferenceEquals($hostedChild,$script:FastLlmUiFluent['Pages'][$pageId]['Element'])}
                Check $hostedOk "the shell hosts the $pageId page at $label"
            }
        }
    }
    Write-Host ('INFO: Shell with {0} render of 12 cases took {1:N1} s' -f $pageId,$pageSw.Elapsed.TotalSeconds)
}
Write-Host ('INFO: Shell render of 60 cases took {0:N1} s' -f $shellSw.Elapsed.TotalSeconds)

# ---- The clipped rule's evidence, per device scale and text scale, over EVERY render case of this run (the harness records each case; the derivation of the
# bound is above Get-UiTextGapBound). For each examined text block the gap is: the unrounded clone's size minus the live block's desired size without margin.
# A gap above the bound is the clipped problem itself, so it fails the clean check of its case (the two planted pages, Test.Clipped and Test.ClippedButton,
# show one each by design). The checks here fail the run when the bound's own premise does not hold: a layout-rounded live size off its device-pixel grid, or
# a block that is above the bound and was not reported. A clone below the bound cannot cause a false clipped report; it is printed with its numbers, and it
# fails the run on the sample page (above), where every caption is plain text.
$gapRows=@(Get-UiTextGapSummary $script:UiRenderTextGapLog)
foreach($row in $gapRows){
    Write-Host ('INFO: text gap '+[string]$row['line'])
    foreach($note in @($row['notes'])){Write-Host ('INFO: text gap note '+[string]$note)}
    $at="device scale $($row['scale']) and text scale $($row['textScale'])"
    $seen=[int]$row['nowrap']['n']+[int]$row['wrap']['n']
    Check ($seen -gt 0 -and [double]$row['bound'] -gt 0) "the text gap was measured at $at (blocks $seen, bound $($row['bound']))"
    Check ([int]$row['offGrid'] -eq 0) "every layout-rounded live text size is on its own device-pixel grid at $at (off the grid: $($row['offGrid']))"
    $highest=[double]0
    foreach($kind in 'nowrap','wrap'){foreach($axis in 'maxW','maxH'){if($null -ne $row[$kind][$axis] -and [double]$row[$kind][$axis] -gt $highest){$highest=[double]$row[$kind][$axis]}}}
    Check ($highest -le [double]$row['bound']) "no text block is above the derived bound without being reported clipped at $at (highest gap $highest, bound $($row['bound']))"
}
$gapPairs=@($matrix|ForEach-Object{"$([double]$_.scale)|$([double]$_.textScale)"}|Sort-Object -Unique)
Check ($gapRows.Count -eq $gapPairs.Count -and $gapRows.Count -eq 13) "the text gap summary covers the 13 device scale and text scale pairs of the matrix (rows $($gapRows.Count), pairs $($gapPairs.Count))"

# PNGs per run, counted by prefix: Test.* is 40 sample cases plus 12 negative pages plus 2 region pages. Only files written during this run count, so leftovers cannot inflate a number.
function Get-RenderPngCount([string]$Prefix){
    return @(Get-ChildItem -LiteralPath $out -Filter ($Prefix+'-*.png') -File | Where-Object { $_.LastWriteTimeUtc -ge $runStart }).Count
}
Check ((Get-RenderPngCount 'Test.*') -eq 54) ("the render folder holds 54 Test.* PNGs written by this run (got $(Get-RenderPngCount 'Test.*'))")
$pngExpect=[ordered]@{'FastLlm.Tools'=40;'FastLlm.ToolsBusy'=6;'FastLlm.ToolsReading'=3;'FastLlm.Connect'=40;'FastLlm.ConnectNotRunning'=6;'FastLlm.ConnectKeyUnreadable'=6;'FastLlm.ConnectReading'=3
    'FastLlm.Models'=40;'FastLlm.ModelsEmpty'=6;'FastLlm.ModelsReading'=3
    'FastLlm.Settings'=40;'FastLlm.SettingsKeyOn'=6;'FastLlm.SettingsKeyOff'=6;'FastLlm.SettingsRunning'=6;'FastLlm.SettingsUnavailable'=6;'FastLlm.SettingsReading'=3
    'FastLlm.DialogOKshort'=12;'FastLlm.DialogOKlong'=12;'FastLlm.DialogOKCancelshort'=12;'FastLlm.DialogOKCancellong'=12;'FastLlm.DialogYesNoshort'=12;'FastLlm.DialogYesNolong'=12
    'FastLlm.DialogIconNone'=6;'FastLlm.DialogIconInformation'=6;'FastLlm.DialogIconWarning'=6;'FastLlm.DialogIconQuestion'=6;'FastLlm.DialogIconError'=6;'FastLlm.DialogSide'=12;'FastLlm.DialogGuidance'=12;'FastLlm.DialogReadingYesNo'=3;'FastLlm.DialogReadingGuidance'=3
    'FastLlm.Shell'=12;'FastLlm.ShellTools'=12;'FastLlm.ShellConnect'=12;'FastLlm.ShellModels'=12;'FastLlm.ShellSettings'=12}
foreach($prefix in $pngExpect.Keys){
    $got=Get-RenderPngCount $prefix
    Check ($got -eq $pngExpect[$prefix]) ("the render folder holds $($pngExpect[$prefix]) $prefix PNGs written by this run (got $got)")
}
Write-Host ('INFO: render PNG counts: Test.* {0}; {1}' -f (Get-RenderPngCount 'Test.*'),((@($pngExpect.Keys|ForEach-Object{$_+' '+(Get-RenderPngCount $_)})) -join '; '))

if($script:failures.Count -gt 0){throw ("FAIL: $($script:failures.Count) check(s) failed: "+($script:failures -join ' | '))}
Write-Host "PASS: ui render tests ($($script:checks) checks)"
exit 0
