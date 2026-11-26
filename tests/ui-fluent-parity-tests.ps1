#requires -Version 5.1
# Initial-state parity of the Fluent window's adapters with the classic controls. Windows only (WinForms); elsewhere it skips cleanly.
# The classic creation block of fast-llm-ui.ps1 (from the form to the reinstall button) is cut out of the file by its syntax tree and run with
# real WinForms, then Initialize-FastLlmUiFluentBindings runs with the same inputs. Per control name, the start state must match:
# Text, Enabled, the control's own visible flag, Checked, Items, SelectedIndex, Value (with Maximum and Increment) and UseMnemonic.
# A difference fails with the control name and the property. Two cases: default settings, and saved settings (BAR off, experimental on, updates off, licences accepted automatically) that move each
# saved-setting control away from its default.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:OS -ne 'Windows_NT') {
    Write-Host 'SKIP: ui-fluent-parity-tests need Windows (WinForms); nothing was compared.'
    exit 0
}
$root = Split-Path -Parent $PSScriptRoot
$script:checks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentBindings.ps1')

# A control's own visible flag (WinForms keeps it as the state bit 0x2 behind the non-public Control.GetState); the effective Visible is false on a form never shown.
# The parameter is an int on .NET Framework and the private Control.States enum on .NET 8 (pwsh 7), so the method is found by name and one parameter,
# and the argument is built from the parameter's own type (STATE_VISIBLE = 2 in both).
$getStateMethods = @([Windows.Forms.Control].GetMethods([Reflection.BindingFlags]'NonPublic, Instance') | Where-Object { $_.Name -ceq 'GetState' -and $_.GetParameters().Count -eq 1 })
Check ($getStateMethods.Count -eq 1) "WinForms has exactly one non-public one-parameter Control.GetState, which this test reads for a control's own visible flag (found $($getStateMethods.Count))"
$script:controlGetState = $getStateMethods[0]
$stateType = $script:controlGetState.GetParameters()[0].ParameterType
$script:visibleStateArg = if ($stateType.IsEnum) { [Enum]::ToObject($stateType, 2) } else { [int]2 }
function Test-OwnVisible($Control) { return [bool]$script:controlGetState.Invoke($Control, @($script:visibleStateArg)) }
# Sanity: the probe reads a hidden control as false and a visible one as true.
$probeHidden = New-Object Windows.Forms.Button; $probeHidden.Visible = $false
$probeShown = New-Object Windows.Forms.Button; $probeShown.Visible = $true
Check ((-not (Test-OwnVisible $probeHidden)) -and (Test-OwnVisible $probeShown)) 'the own-visible probe reads Visible=false as false and Visible=true as true'
$probeHidden.Dispose(); $probeShown.Dispose()

# The creation block, cut from the real script.
$path = Join-Path $root 'fast-llm-ui.ps1'
$fileText = [IO.File]::ReadAllText($path)
$parseErrors = $null
$tree = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$parseErrors)
Check ($parseErrors.Count -eq 0) 'fast-llm-ui.ps1 parses'
$starts = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$form' -and $n.Right.Extent.Text -ceq 'New-Object Windows.Forms.Form' }, $true))
Check ($starts.Count -eq 1) 'the script creates the main form once'
$ends = @($tree.FindAll({ param($n) $n -is [System.Management.Automation.Language.StatementAst] -and $n.Extent.Text -ceq '$form.Controls.Add($reinstallButton)' }, $true))
Check ($ends.Count -ge 1) 'the script adds the reinstall button to the form'
# Each match comes twice: the PipelineAst and its CommandExpressionAst are the two matches for one statement (there is no update-handler pair);
# the smallest end after the form is the creation line's.
$startOffset = $starts[0].Extent.StartOffset
$endOffset = ($ends | Where-Object { $_.Extent.StartOffset -gt $startOffset } | ForEach-Object { $_.Extent.EndOffset } | Measure-Object -Minimum).Minimum
Check ($endOffset -gt $startOffset) 'the creation block runs from the form to the reinstall button'
$block = $fileText.Substring($startOffset, $endOffset - $startOffset).Replace('$PSScriptRoot', '$script:parityAppRoot')
Check ($block -notmatch '\$Window\b') 'the creation block has no window-mode branch'
$script:parityAppRoot = $root
$catalog = Get-FastLlmCatalog (Join-Path $root 'config/catalog.json')
$names = @(Get-FastLlmUiFluentControlTable | ForEach-Object { [string]$_[0] })
$kinds = @{}
foreach ($row in (Get-FastLlmUiFluentControlTable)) { $kinds[[string]$row[0]] = [string]$row[1] }

# Runs the classic block in a function scope (its LabelAt and ButtonAt helpers see $form there) and returns the controls by name.
function Invoke-ClassicCreation([string]$InstallRoot) {
    $script:settingsRoot = $InstallRoot
    Invoke-Expression $block
    $found = @{}
    foreach ($n in $names) {
        $v = Get-Variable -Name $n -ValueOnly -ErrorAction Stop
        $found[$n] = $v
    }
    $found['__form'] = $form
    return $found
}

function Compare-Name([string]$Name, $Classic, $Adapter, [string]$Case) {
    $kind = $kinds[$Name]
    $problems = New-Object System.Collections.ArrayList
    function Same([string]$Property, $a, $b) { if (-not ($a -ceq $b)) { [void]$problems.Add("$Case $Name.${Property}: classic='$a' fluent='$b'") } }
    if ($kind -in 'Label', 'Button', 'LinkLabel', 'CheckBox', 'TextBox') { Same 'Text' ([string]$Classic.Text) ([string]$Adapter.Text) }
    if ($kind -ne 'ToolTip') {
        Same 'Enabled' ([string][bool]$Classic.Enabled) ([string][bool]$Adapter.Enabled)
        Same 'Visible(own)' ([string](Test-OwnVisible $Classic)) ([string][bool]$Adapter.Visible)
    }
    if ($kind -ceq 'CheckBox') { Same 'Checked' ([string][bool]$Classic.Checked) ([string][bool]$Adapter.Checked) }
    if ($kind -ceq 'ComboBox') {
        Same 'Items' (@($Classic.Items | ForEach-Object { [string]$_ }) -join '|') (@($Adapter.Items | ForEach-Object { [string]$_ }) -join '|')
        Same 'SelectedIndex' ([string][int]$Classic.SelectedIndex) ([string][int]$Adapter.SelectedIndex)
    }
    if ($kind -ceq 'NumericUpDown') {
        Same 'Value' ([string][decimal]$Classic.Value) ([string][decimal]$Adapter.Value)
        Same 'Maximum' ([string][decimal]$Classic.Maximum) ([string][decimal]$Adapter.Maximum)
        Same 'Increment' ([string][decimal]$Classic.Increment) ([string][decimal]$Adapter.Increment)
    }
    if ($kind -in 'Label', 'Button', 'LinkLabel', 'CheckBox') { Same 'UseMnemonic' ([string][bool]$Classic.UseMnemonic) ([string][bool]$Adapter.UseMnemonic) }
    return , $problems.ToArray()
}

function Test-Case([string]$Case, [scriptblock]$Prepare, [scriptblock]$Verify) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-parity-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $dir)
    try {
        & $Prepare $dir
        $classic = Invoke-ClassicCreation -InstallRoot $dir
        if ($null -ne $Verify) { & $Verify $classic }
        $made = Initialize-FastLlmUiFluentBindings -InstallRoot $dir -Catalog $catalog -UiSettings $script:uiSettings
        Check ($made.Count -eq $names.Count) "$Case : one adapter per control name ($($names.Count))"
        $all = New-Object System.Collections.ArrayList
        foreach ($n in $names) {
            Check ($made.Contains($n)) "$Case : the bindings made an adapter for $n"
            foreach ($p in (Compare-Name -Name $n -Classic $classic[$n] -Adapter $made[$n] -Case $Case)) { [void]$all.Add($p) }
        }
        foreach ($p in $all) { Write-Host "DIFF: $p" }
        Check ($all.Count -eq 0) "$Case : every control starts in the classic state ($($all.Count) difference(s))"
        $classic['__form'].Dispose()
        foreach ($n in $names) { try { $classic[$n].Dispose() } catch { } }
    }
    finally {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
        Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'default settings' { param($dir) }
Test-Case 'saved settings' {
    param($dir)
    # The licence block in the shape Get-FastLlmComponentLicenseSettings reads: mode, acceptedAt and a non-empty accepted list of title and host.
    $saved = [pscustomobject]@{
        vulkanBarMitigation = 'off'; experimentalComponents = 'on'; updateCheck = 'off'
        componentLicenses = [pscustomobject]@{ mode = 'accept-automatically'; acceptedAt = '2026-01-02T03:04:05Z'; accepted = @([pscustomobject]@{ title = 'Example engine component'; host = 'example.invalid' }) }
    }
    [IO.File]::WriteAllText((Join-Path $dir 'settings.json'), ($saved | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
} {
    param($classic)
    # The classic controls took the saved values, so the comparison below runs the Checked=true paths (not only the defaults).
    Check ([bool]$classic['licenseBox'].Checked) 'saved settings case: the classic licence box is checked (accept-automatically was read)'
    Check ([bool]$classic['experimentalBox'].Checked -and -not [bool]$classic['updateBox'].Checked) 'saved settings case: the classic experimental box is checked and the update box is not'
    Check ([int]$classic['barBox'].SelectedIndex -eq 2) 'saved settings case: the classic BAR box shows Off'
}
Check ([string]$script:uiSettings.vulkanBarMitigation -ceq 'off') 'the second case read the saved BAR setting'
Check ([string]$script:uiSettings.experimentalComponents -ceq 'on') 'the second case read the saved experimental setting'
Check ([string]$script:uiSettings.updateCheck -ceq 'off') 'the second case read the saved update setting'


# A real NumericUpDown (Maximum 32768, Increment 1024, as the context box) takes each typed string, commits it with ValidateEditText, and its Value
# must equal the pure clamp (the clamp that the Fluent number box runs). The same under the current culture, so grouping and decimals agree.
$nud = New-Object Windows.Forms.NumericUpDown
$nud.Minimum = 0; $nud.Maximum = 32768; $nud.Increment = 1024; $nud.DecimalPlaces = 0
foreach ($typed in @('', 'abc', '-5', '40000', '2048', ' 4096 ', '1,024', '1500.7', '0x10', '32768', '0')) {
    $nud.Value = 7
    $nud.Text = $typed
    $nud.ValidateEditText()
    $pure = ConvertTo-FastLlmUiNumericValue -Text $typed -Current 7 -Minimum 0 -Maximum 32768
    Check ([decimal]$nud.Value -eq $pure) "number clamp parity for '$typed': WinForms Value $($nud.Value), pure $pure"
}
$nud.Dispose()
# Port: 1024..65535, step 1.
$port = New-Object Windows.Forms.NumericUpDown
$port.Minimum = 1024; $port.Maximum = 65535; $port.Increment = 1
foreach ($typed in @('80', '70000', '8080', 'x')) {
    $port.Value = 5000
    $port.Text = $typed
    $port.ValidateEditText()
    $pure = ConvertTo-FastLlmUiNumericValue -Text $typed -Current 5000 -Minimum 1024 -Maximum 65535
    Check ([decimal]$port.Value -eq $pure) "port clamp parity for '$typed': WinForms Value $($port.Value), pure $pure"
}
$port.Dispose()

Write-Host "UI fluent parity tests passed: $($script:checks)"
