#requires -Version 5.1
# The initial state of every control the Fluent window's bindings make, pinned against literals (cross-platform: no WPF, no WinForms).
# Initialize-FastLlmUiFluentBindings runs with a fixture catalog and with the real one, with default settings and with saved settings
# (BAR off, experimental on, updates off, licences accepted automatically). Every adapter's initial Text, Enabled, Visible, Checked, Items, SelectedIndex,
# Value, Maximum, Increment, UseMnemonic, AutoEllipsis, Style, Multiline and ReadOnly must equal the literal row of its control name. The picker ids and the
# five labels that keep no access key (title, notice, backgroundLabel, statusLabel, switchLabel; every other Button, CheckBox, LinkLabel and Label keeps its
# access key) are pinned too.
# The literals were generated from the classic creation block of fast-llm-ui.ps1 (the block run against minimal WinForms-shaped stand-ins), never copied from the
# bindings. tests/ui-fluent-parity-tests.ps1 (Windows) runs the real block with real WinForms and requires it to equal the same literals; that suite is deleted
# with the classic window, and these literals then stand alone.
# Mutants: a changed copy of the bindings source is run and must fail; the unchanged source is the control.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force
. (Join-Path $root 'src/FastLlm.UiFlow.ps1')
. (Join-Path $root 'src/FastLlm.Update.ps1')
. (Join-Path $root 'src/FastLlm.Components.ps1')
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentAdapter.ps1')
. (Join-Path $root 'src/FastLlm.UiFluentBindings.ps1')
# The bindings set one script variable per control name (title, notice, output, progress, vc, amd, ...): this file uses none of those names for its own variables.
$script:bindChecks = 0
function Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:bindChecks++ }

# The catalog of the frozen picker list: four models, one never auto-picked, one superseded. The picker offers 'Recommended for installed GPU', fixture-a and fixture-new.
function Get-BindingsInitialFixtureCatalog {
    return [pscustomobject]@{ models = @([pscustomobject]@{ id = 'fixture-a' }, [pscustomobject]@{ id = 'fixture-hidden'; autoEligible = $false }, [pscustomobject]@{ id = 'fixture-old'; supersededBy = 'fixture-new' }, [pscustomobject]@{ id = 'fixture-new' }) }
}

# One row per control name, in the bindings table's order: the frozen initial state. TextIsInstallRoot: the text is the install root the bindings were given.
# The Items of a combo box are joined with a vertical bar. The rows are added one statement per line.
function Get-BindingsInitialRows {
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add(@{ Name = 'title'; Kind = 'Label'; Text = 'Local AMD inference, managed on this PC'; Enabled = $true; Visible = $true; UseMnemonic = $false; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'notice'; Kind = 'Label'; Text = 'Preview. Windows + AMD Radeon. Vulkan or HIP engine. Text-only models.'; Enabled = $true; Visible = $true; UseMnemonic = $false; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'backgroundLabel'; Kind = 'Label'; Text = 'Checking background host ownership.'; Enabled = $true; Visible = $true; UseMnemonic = $false; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'statusLabel'; Kind = 'Label'; Text = 'Not running. Install & start sets up and starts the best setup for your card.'; Enabled = $true; Visible = $true; UseMnemonic = $false; AutoEllipsis = $true })
    [void]$rows.Add(@{ Name = 'switchLabel'; Kind = 'Label'; Text = ''; Enabled = $true; Visible = $true; UseMnemonic = $false; AutoEllipsis = $true })
    [void]$rows.Add(@{ Name = 'notesLabel'; Kind = 'Label'; Text = ''; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'bannerLabel'; Kind = 'Label'; Text = ''; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'installButton'; Kind = 'Button'; Text = 'Install && start'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'startButton'; Kind = 'Button'; Text = 'Start / download'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'stopButton'; Kind = 'Button'; Text = 'Stop'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'doctorButton'; Kind = 'Button'; Text = 'Diagnostics'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'copyButton'; Kind = 'Button'; Text = 'Copy API URL'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'backgroundStartButton'; Kind = 'Button'; Text = 'Start in background'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'backgroundAttachButton'; Kind = 'Button'; Text = 'Attach running'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'backgroundCheckButton'; Kind = 'Button'; Text = 'Recheck background'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'componentsButton'; Kind = 'Button'; Text = 'Components'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'chooseButton'; Kind = 'Button'; Text = 'Choose another setup'; Enabled = $false; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'settingsButton'; Kind = 'Button'; Text = ('Settings' + [string][char]0x2026); Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'connectButton'; Kind = 'Button'; Text = 'Connect an app'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'openChatButton'; Kind = 'Button'; Text = 'Open chat'; Enabled = $false; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'modelsButton'; Kind = 'Button'; Text = 'Downloaded models'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'bundleButton'; Kind = 'Button'; Text = ('Save support bundle' + [string][char]0x2026); Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'logsButton'; Kind = 'Button'; Text = 'Open logs'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'switchButton'; Kind = 'Button'; Text = ('Switch model' + [string][char]0x2026); Enabled = $false; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'trayButton'; Kind = 'Button'; Text = 'Minimize to tray'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'driverButton'; Kind = 'Button'; Text = 'Driver guidance'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'bannerButton'; Kind = 'Button'; Text = 'Update'; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'reinstallButton'; Kind = 'Button'; Text = 'Reinstall previous version'; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'resultsLink'; Kind = 'LinkLabel'; Text = 'See results'; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'failureCopyLink'; Kind = 'LinkLabel'; Text = 'Copy full output'; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'barLink'; Kind = 'LinkLabel'; Text = 'How to turn it on'; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'vc'; Kind = 'LinkLabel'; Text = 'Microsoft VC++ prerequisite'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'amd'; Kind = 'LinkLabel'; Text = 'AMD Windows drivers'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'bannerNotes'; Kind = 'LinkLabel'; Text = 'Release notes'; Enabled = $true; Visible = $false; UseMnemonic = $true; AutoEllipsis = $false })
    [void]$rows.Add(@{ Name = 'updateBox'; Kind = 'CheckBox'; Text = 'Check for updates'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false; Checked = $true })
    [void]$rows.Add(@{ Name = 'experimentalBox'; Kind = 'CheckBox'; Text = 'Experimental community components'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false; Checked = $false })
    [void]$rows.Add(@{ Name = 'licenseBox'; Kind = 'CheckBox'; Text = 'Install engine components automatically (accept their licenses for me)'; Enabled = $true; Visible = $true; UseMnemonic = $true; AutoEllipsis = $false; Checked = $false })
    [void]$rows.Add(@{ Name = 'modelBox'; Kind = 'ComboBox'; Items = 'Recommended for installed GPU|fixture-a|fixture-new'; SelectedIndex = 0; Enabled = $true; Visible = $true })
    [void]$rows.Add(@{ Name = 'barBox'; Kind = 'ComboBox'; Items = 'Auto (recommended)|On|Off'; SelectedIndex = 0; Enabled = $true; Visible = $true })
    [void]$rows.Add(@{ Name = 'contextBox'; Kind = 'NumericUpDown'; Value = '0'; Maximum = '32768'; Increment = '1024'; Enabled = $true; Visible = $true })
    [void]$rows.Add(@{ Name = 'pathBox'; Kind = 'TextBox'; TextIsInstallRoot = $true; Enabled = $true; Visible = $true })
    [void]$rows.Add(@{ Name = 'output'; Kind = 'TextBox'; Text = ''; Enabled = $true; Visible = $true; Multiline = $true; ReadOnly = $true })
    [void]$rows.Add(@{ Name = 'progress'; Kind = 'ProgressBar'; Style = 'Marquee'; Enabled = $true; Visible = $false })
    # 5b-delete-begin
    [void]$rows.Add(@{ Name = 'statusTip'; Kind = 'ToolTip' })
    # 5b-delete-end
    return $rows.ToArray()
}

# What the saved-settings case moves away from the default (BAR off, experimental on, updates off, licences accepted automatically): name -> the changed fields.
function Get-BindingsInitialSavedOverrides {
    return @{
        updateBox       = @{ Checked = $false }
        experimentalBox = @{ Checked = $true }
        licenseBox      = @{ Checked = $true }
        barBox          = @{ SelectedIndex = 2 }
    }
}

# Runs the bindings from a source text in a scope of its own (so a mutant never replaces the real functions) and returns the adapters by name.
function Invoke-BindingsInitialRun([string]$BindingsSource, [string]$InstallRoot, $Catalog, $UiSettings) {
    & {
        param($bindSource, $bindRoot, $bindCatalog, $bindSettings)
        . ([scriptblock]::Create($bindSource))
        return Initialize-FastLlmUiFluentBindings -InstallRoot $bindRoot -Catalog $bindCatalog -UiSettings $bindSettings
    } $BindingsSource $InstallRoot $Catalog $UiSettings
}

# The differences between the adapters and the literal rows, as a list of sentences naming the control and the property (empty when equal). Overrides move fields of rows.
function Get-BindingsInitialProblems($Made, $Rows, [string]$InstallRoot, $Overrides) {
    $problems = New-Object System.Collections.ArrayList
    $madeNames = @($Made.Keys | ForEach-Object { [string]$_ })
    $rowNames = @($Rows | ForEach-Object { [string]$_.Name })
    if ($madeNames.Count -ne $rowNames.Count) { [void]$problems.Add("the bindings made $($madeNames.Count) adapters, the literal table has $($rowNames.Count) rows") }
    foreach ($n in $rowNames) { if ($madeNames -cnotcontains $n) { [void]$problems.Add("no adapter for $n") } }
    foreach ($n in $madeNames) { if ($rowNames -cnotcontains $n) { [void]$problems.Add("an adapter for $n has no literal row") } }
    foreach ($row in $Rows) {
        $n = [string]$row.Name
        if (-not $Made.Contains($n)) { continue }
        $a = $Made[$n]
        $want = @{}; foreach ($k in @($row.Keys)) { $want[$k] = $row[$k] }
        if ($null -ne $Overrides -and $Overrides.ContainsKey($n)) { foreach ($k in @($Overrides[$n].Keys)) { $want[$k] = $Overrides[$n][$k] } }
        if ([string]$a.__kind -cne [string]$want['Kind']) { [void]$problems.Add("$n kind is '$($a.__kind)', expected '$($want['Kind'])'") }
        if ($want.ContainsKey('Text') -and [string]$a.Text -cne [string]$want['Text']) { [void]$problems.Add("$n Text is '$($a.Text)', expected '$($want['Text'])'") }
        if ($want.ContainsKey('TextIsInstallRoot') -and [string]$a.Text -cne $InstallRoot) { [void]$problems.Add("$n Text is '$($a.Text)', expected the install root '$InstallRoot'") }
        foreach ($prop in 'Enabled', 'Visible', 'Checked', 'UseMnemonic', 'AutoEllipsis', 'Multiline', 'ReadOnly') {
            if ($want.ContainsKey($prop) -and [bool]$a.$prop -ne [bool]$want[$prop]) { [void]$problems.Add("$n $prop is $([bool]$a.$prop), expected $([bool]$want[$prop])") }
        }
        if ($want.ContainsKey('Items')) {
            $got = (@($a.Items | ForEach-Object { [string]$_ }) -join '|')
            if ($got -cne [string]$want['Items']) { [void]$problems.Add("$n Items are '$got', expected '$($want['Items'])'") }
        }
        if ($want.ContainsKey('SelectedIndex') -and [int]$a.SelectedIndex -ne [int]$want['SelectedIndex']) { [void]$problems.Add("$n SelectedIndex is $($a.SelectedIndex), expected $($want['SelectedIndex'])") }
        foreach ($prop in 'Value', 'Maximum', 'Increment') {
            if ($want.ContainsKey($prop) -and [string][decimal]$a.$prop -cne [string][decimal][string]$want[$prop]) { [void]$problems.Add("$n $prop is $($a.$prop), expected $($want[$prop])") }
        }
        if ($want.ContainsKey('Style') -and [string]$a.Style -cne [string]$want['Style']) { [void]$problems.Add("$n Style is '$($a.Style)', expected '$($want['Style'])'") }
    }
    return $problems.ToArray()
}

# D3, access keys: UseMnemonic is false for exactly these five labels and true for every other Button, CheckBox, LinkLabel and Label adapter.
function Get-BindingsUseMnemonicProblems($Made) {
    $problems = New-Object System.Collections.ArrayList
    $noMnemonic = @('title', 'notice', 'backgroundLabel', 'statusLabel', 'switchLabel')
    foreach ($n in @($Made.Keys)) {
        $a = $Made[$n]
        if ([string]$a.__kind -cnotin 'Button', 'CheckBox', 'LinkLabel', 'Label') { continue }
        $wantMnemonic = ($noMnemonic -cnotcontains [string]$n)
        if ([bool]$a.UseMnemonic -ne $wantMnemonic) { [void]$problems.Add("$n UseMnemonic is $([bool]$a.UseMnemonic), expected $wantMnemonic") }
    }
    foreach ($n in $noMnemonic) { if (-not $Made.Contains($n)) { [void]$problems.Add("the label $n has no adapter") } }
    return $problems.ToArray()
}

# Only run when this file is the suite (tests/ui-fluent-parity-tests.ps1 reads the literal functions above by their syntax tree and never runs this part).
$rows = Get-BindingsInitialRows
$overrides = Get-BindingsInitialSavedOverrides
$fixture = Get-BindingsInitialFixtureCatalog
$realSource = [System.IO.File]::ReadAllText((Join-Path $root 'src/FastLlm.UiFluentBindings.ps1'))
$defaultSettings = [pscustomobject]@{ vulkanBarMitigation = 'auto'; experimentalComponents = 'off'; updateCheck = 'on' }
$savedSettings = [pscustomobject]@{ vulkanBarMitigation = 'off'; experimentalComponents = 'on'; updateCheck = 'off' }

$bindWork = Join-Path ([IO.Path]::GetTempPath()) ('fastllm-bindings-initial-' + [guid]::NewGuid().ToString('N'))
$bindDefaultRoot = Join-Path $bindWork 'default'
$bindSavedRoot = Join-Path $bindWork 'saved'
[void](New-Item -ItemType Directory -Path $bindDefaultRoot)
[void](New-Item -ItemType Directory -Path $bindSavedRoot)
try {
    # The licence block in the shape Get-FastLlmComponentLicenseSettings reads: mode, acceptedAt and a non-empty accepted list of title and host.
    $bindLicense = [pscustomobject]@{ componentLicenses = [pscustomobject]@{ mode = 'accept-automatically'; acceptedAt = '2026-01-02T03:04:05Z'; accepted = @([pscustomobject]@{ title = 'Example engine component'; host = 'example.invalid' }) } }
    [IO.File]::WriteAllText((Join-Path $bindSavedRoot 'settings.json'), ($bindLicense | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

    # the literal table itself
    Check ($rows.Count -ge 43) "the literal table has a row for every control name ($($rows.Count))"
    $bindNames = @($rows | ForEach-Object { [string]$_.Name })
    Check (@($bindNames | Select-Object -Unique).Count -eq $bindNames.Count) 'every literal row has its own control name'
    $bindOrder = ($bindNames -join ',')

    # default settings and saved settings, on the real source
    $madeDefault = Invoke-BindingsInitialRun $realSource $bindDefaultRoot $fixture $defaultSettings
    $problemsDefault = @(Get-BindingsInitialProblems $madeDefault $rows $bindDefaultRoot $null)
    foreach ($p in $problemsDefault) { Write-Host "DIFF: default settings $p" }
    Check ($problemsDefault.Count -eq 0) "default settings: every adapter starts in the literal state ($($problemsDefault.Count) difference(s) in $($rows.Count) controls)"
    Check ((@($madeDefault.Keys) -join ',') -ceq $bindOrder) 'default settings: the adapters are made in the literal table order'
    $madeSaved = Invoke-BindingsInitialRun $realSource $bindSavedRoot $fixture $savedSettings
    $problemsSaved = @(Get-BindingsInitialProblems $madeSaved $rows $bindSavedRoot $overrides)
    foreach ($p in $problemsSaved) { Write-Host "DIFF: saved settings $p" }
    Check ($problemsSaved.Count -eq 0) "saved settings: every adapter starts in the literal state with the saved-settings overrides ($($problemsSaved.Count) difference(s))"
    Check ($madeSaved['licenseBox'].Checked -eq $true -and $madeSaved['experimentalBox'].Checked -eq $true -and $madeSaved['updateBox'].Checked -eq $false -and $madeSaved['barBox'].SelectedIndex -eq 2) 'saved settings: the licence box and the experimental box are checked, the update box is not, and the BAR box shows Off'
    Check ($madeDefault['licenseBox'].Checked -eq $false -and $madeDefault['experimentalBox'].Checked -eq $false -and $madeDefault['updateBox'].Checked -eq $true -and $madeDefault['barBox'].SelectedIndex -eq 0) 'default settings: the licence box and the experimental box are unchecked, the update box is checked, and the BAR box shows Auto'

    # the picker ids: the fixture list as a literal, and the real catalog through the shared picker helper
    Check ((@($madeDefault['modelBox'].Items) -join '|') -ceq 'Recommended for installed GPU|fixture-a|fixture-new') 'the picker offers Recommended for installed GPU, then the auto-eligible models that are not superseded, in catalog order (fixture catalog)'
    $bindRealCatalog = Get-FastLlmCatalog (Join-Path $root 'config/catalog.json')
    $madeReal = Invoke-BindingsInitialRun $realSource $bindDefaultRoot $bindRealCatalog $defaultSettings
    $bindPickerIds = @(Get-FastLlmUiPickerModelIds -Catalog $bindRealCatalog)
    Check ($bindPickerIds.Count -ge 1 -and (@($madeReal['modelBox'].Items) -join '|') -ceq ('Recommended for installed GPU|' + ($bindPickerIds -join '|')) -and [int]$madeReal['modelBox'].SelectedIndex -eq 0) 'the picker of the real catalog is the Recommended entry followed by every picker id, with the first selected'

    # D3 access keys
    $mnemonicProblems = @(Get-BindingsUseMnemonicProblems $madeDefault)
    Check ($mnemonicProblems.Count -eq 0) "UseMnemonic is false for exactly title, notice, backgroundLabel, statusLabel and switchLabel, and true for every other Button, CheckBox, LinkLabel and Label ($($mnemonicProblems -join '; '))"

    # mutants: a changed copy of the bindings source must fail the literals; each is a one-statement regression
    $bindMutants = @(
        @{ Name = 'a button text changed'; Old = "@('logsButton','Button','Open logs')"; New = "@('logsButton','Button','Open log')" },
        @{ Name = 'a label that loses its access-key switch (notice)'; Old = "foreach(`$n in 'title','notice','backgroundLabel','statusLabel','switchLabel')"; New = "foreach(`$n in 'title','backgroundLabel','statusLabel','switchLabel')" },
        @{ Name = 'a label that loses its access-key switch (switchLabel)'; Old = "'statusLabel','switchLabel'){`$made[`$n].UseMnemonic=`$false}"; New = "'statusLabel'){`$made[`$n].UseMnemonic=`$false}" },
        @{ Name = 'the status label stops ellipsising'; Old = "`$made['statusLabel'].AutoEllipsis=`$true"; New = "`$made['statusLabel'].AutoEllipsis=`$false" },
        @{ Name = 'the switch label stops ellipsising'; Old = "`$made['switchLabel'].AutoEllipsis=`$true"; New = "`$made['switchLabel'].AutoEllipsis=`$false" },
        @{ Name = 'a button that starts enabled (chooseButton)'; Old = "foreach(`$n in 'openChatButton','chooseButton','switchButton')"; New = "foreach(`$n in 'openChatButton','switchButton')" },
        @{ Name = 'a link that starts visible (barLink)'; Old = "'resultsLink','failureCopyLink','barLink','bannerLabel'"; New = "'resultsLink','failureCopyLink','bannerLabel'" },
        @{ Name = 'the banner button starts visible'; Old = "'bannerNotes','bannerButton','reinstallButton'"; New = "'bannerNotes','reinstallButton'" },
        @{ Name = 'the Recommended entry renamed'; Old = "[void]`$modelBox.Items.Add('Recommended for installed GPU')"; New = "[void]`$modelBox.Items.Add('Recommended for this GPU')" },
        @{ Name = 'the model box selects its second entry'; Old = '$modelBox.SelectedIndex=0'; New = '$modelBox.SelectedIndex=1' },
        @{ Name = 'a BAR item renamed'; Old = "@('Auto (recommended)','On','Off')"; New = "@('Auto (recommended)','ON','Off')" },
        @{ Name = 'the BAR box ignores the saved setting'; Old = '$made[''barBox''].SelectedIndex=[Array]::IndexOf($barValues,[string]$UiSettings.vulkanBarMitigation)'; New = '$made[''barBox''].SelectedIndex=0' },
        @{ Name = 'the context maximum changed'; Old = '$made[''contextBox''].Maximum=32768'; New = '$made[''contextBox''].Maximum=32767' },
        @{ Name = 'the context increment changed'; Old = '$made[''contextBox''].Increment=1024'; New = '$made[''contextBox''].Increment=1000' },
        @{ Name = 'the path box forgets the install root'; Old = '$made[''pathBox''].Text=$InstallRoot'; New = '$made[''pathBox''].Text=''''' },
        @{ Name = 'the update box ignores the saved setting'; Old = "`$made['updateBox'].Checked=([string]`$UiSettings.updateCheck -ceq 'on')"; New = "`$made['updateBox'].Checked=`$true" },
        @{ Name = 'the experimental box ignores the saved setting'; Old = "`$made['experimentalBox'].Checked=([string]`$UiSettings.experimentalComponents -ceq 'on')"; New = "`$made['experimentalBox'].Checked=`$false" },
        @{ Name = 'the licence box ignores the saved mode'; Old = "-ceq 'accept-automatically')"; New = "-cne 'accept-automatically')" },
        @{ Name = 'the progress bar loses its marquee style'; Old = "`$made['progress'].Style='Marquee'"; New = "`$made['progress'].Style='Continuous'" },
        @{ Name = 'the output box is not read-only'; Old = '$made[''output''].ReadOnly=$true'; New = '$made[''output''].ReadOnly=$false' }
    )
    $bindControl = @(Get-BindingsInitialProblems (Invoke-BindingsInitialRun $realSource $bindSavedRoot $fixture $savedSettings) $rows $bindSavedRoot $overrides)
    Check ($bindControl.Count -eq 0 -and @(Get-BindingsUseMnemonicProblems (Invoke-BindingsInitialRun $realSource $bindSavedRoot $fixture $savedSettings)).Count -eq 0) 'mutation control: the unchanged bindings source passes the literals and the access-key rule'
    foreach ($m in $bindMutants) {
        $changed = $realSource.Replace([string]$m.Old, [string]$m.New)
        Check ($changed -cne $realSource) "mutation check setup: the text to change was found ($($m.Name))"
        $caught = $false
        foreach ($case in @(@{ Root = $bindDefaultRoot; Settings = $defaultSettings; Over = $null }, @{ Root = $bindSavedRoot; Settings = $savedSettings; Over = $overrides })) {
            $made = Invoke-BindingsInitialRun $changed $case.Root $fixture $case.Settings
            if (@(Get-BindingsInitialProblems $made $rows $case.Root $case.Over).Count -ge 1 -or @(Get-BindingsUseMnemonicProblems $made).Count -ge 1) { $caught = $true }
        }
        Check $caught "mutation check: $($m.Name) is flagged"
    }
    # the access-key rule alone also flags the two label mutants
    foreach ($m in @($bindMutants | Select-Object -First 3 | Select-Object -Skip 1)) {
        $made = Invoke-BindingsInitialRun ($realSource.Replace([string]$m.Old, [string]$m.New)) $bindDefaultRoot $fixture $defaultSettings
        Check (@(Get-BindingsUseMnemonicProblems $made).Count -ge 1) "mutation check: the access-key rule alone flags $($m.Name)"
    }
}
finally {
    foreach ($f in @(Get-ChildItem -LiteralPath $bindWork -Recurse -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $f.FullName -Force }
    foreach ($d in @($bindSavedRoot, $bindDefaultRoot, $bindWork)) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
}
Write-Host "UI fluent bindings initial-state tests passed: $($script:bindChecks)"
