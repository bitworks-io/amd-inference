#requires -Version 5.1
# The four consent-family dialogs of the Fluent window (licence setting, component consent, exact model consent, VC++ review), built on the dialog host in
# FastLlm.UiFluentDialogs.ps1. Dot-sourced by FastLlm.UiFluentShell.ps1 right after it. No WPF or WinForms type is resolved at dot-source time.
# Each function takes the parameters of its classic function in fast-llm-ui.ps1 (the shell's view table calls it with them by name) and returns exactly what
# the classic function returns. Enter and Escape are the classic AcceptButton and CancelButton (all four: the cancel button), so accepting needs a click.
Set-StrictMode -Version 2.0

# The words of these dialogs, copied byte-identical from ShowLicenseSettingConfirm, ShowComponentConsent, ShowExactModelConsent and ShowVcInstallReview in
# fast-llm-ui.ps1; the one rule is that the WinForms escape && in a caption is shown as & (ModelAccept). A members pin compares every value with the classic
# constants. ComponentSource, ComponentRedirect and ComponentJoin are the constant parts of the classic source line. Merged into the shared dialog table.
$script:FastLlmUiFluentConsentText = [ordered]@{
    LicenseTitle      = 'Install engine components automatically'
    LicenseIntro      = 'With this on, FastLLM installs engine components without asking again, and counts that as accepting the licenses below. Open each link and read it first. You can turn this off at any time.'
    LicensePlain      = '{0} (this link cannot be opened from here)'
    LicenseLinkError  = 'Unable to open the license page. Check your default browser. Nothing was changed.'
    LinkErrorCaption  = 'Open license page'
    LicenseAccept     = 'I accept these licenses'
    ConsentCancel     = 'Cancel'
    ComponentTitle    = 'Install engine components'
    ComponentNameFmt  = '{0} ({1}) - {2}'
    ComponentSource   = 'Source: '
    ComponentRedirect = '; the download may be redirected via '
    ComponentJoin     = ', '
    ComponentPlain    = '{0} (this link cannot be opened from here, so this component cannot be accepted)'
    ComponentLinkError = 'Unable to open the license page. Check your default browser. Nothing was downloaded.'
    ComponentInstall  = 'Install'
    ModelTitle        = 'Review exact model license and artifact'
    ModelAccept       = 'Accept license & download'
    VcTitle           = 'Review Microsoft VC++ package and installation'
    VcInstall         = 'Install Microsoft runtime'
    VcLater           = 'Do later'
}
foreach ($consentKey in @($script:FastLlmUiFluentConsentText.Keys)) { $script:FastLlmUiFluentDialogText[$consentKey] = $script:FastLlmUiFluentConsentText[$consentKey] }

# One licence link of a consent dialog: a link button (named by its text) when the licence has a url, else plain wrapping text. A link opens through
# Get-FastLlmUiSafeLicenseUrl only; when it cannot be opened the warning box is owned by the dialog (Context['Dialog'], set once the dialog exists).
function New-FastLlmUiFluentConsentLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $LicenseLink,
        [Parameter(Mandatory = $true)][string] $PlainFormat,
        [Parameter(Mandatory = $true)][string] $ErrorText,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Context,
        [double] $Indent = 8
    )
    $t = $script:FastLlmUiFluentDialogText
    $errorCaption = [string] $t.LinkErrorCaption
    $safeUrl = ${function:Get-FastLlmUiSafeLicenseUrl}
    $messageBox = ${function:Show-FastLlmUiFluentMessageBox}
    if ($LicenseLink.url) {
        $link = New-Object System.Windows.Controls.Button
        $link.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.LinkButtonStyle')
        $link.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        $link.Margin = New-Object System.Windows.Thickness($Indent, 4, 0, 0)
        $linkText = [string] $LicenseLink.linkText
        # The caption is access text that wraps (a long licence name wraps inside the dialog); a Button with such content has no automation name of its own.
        $access = New-Object System.Windows.Controls.AccessText
        $access.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $access.Text = ConvertTo-FastLlmUiAccessText -Text $linkText -UseMnemonic $false
        $link.Content = $access
        $link.Tag = [string] $LicenseLink.url
        [System.Windows.Automation.AutomationProperties]::SetName($link, $linkText)
        $link.Add_Click({
            param($sender, $routed)
            try {
                $target = & $safeUrl -Url ([string] $sender.Tag)
                if ($target) { Start-Process $target }
            }
            catch { $null = & $messageBox -Owner $Context['Dialog'] -Text $ErrorText -Caption $errorCaption -Buttons 'OK' -Icon 'Warning' }
        }.GetNewClosure())
        return $link
    }
    $plain = New-Object System.Windows.Controls.TextBlock
    $plain.Text = ($PlainFormat -f [string] $LicenseLink.title)
    $plain.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $plain.Margin = New-Object System.Windows.Thickness($Indent, 4, 0, 0)
    return $plain
}

# The licence setting confirm: the intro, one link per licence, "I accept these licenses" (enabled when the disclosure can be accepted) and Cancel.
# Enter and Escape cancel, as the classic AcceptButton and CancelButton. Returns one [bool]: true only when the accept button was clicked.
function Show-FastLlmUiFluentLicenseSettingConfirm {
    [CmdletBinding()]
    param($Disclosure)
    $t = $script:FastLlmUiFluentDialogText
    $scale = Get-FastLlmUiFluentDialogScale -Owner $script:form
    $context = @{ Dialog = $null }
    $panel = New-Object System.Windows.Controls.StackPanel
    $intro = New-Object System.Windows.Controls.TextBlock
    $intro.Text = [string] $t.LicenseIntro
    $intro.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $intro.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
    $null = $panel.Children.Add($intro)
    foreach ($licenseLink in @($Disclosure.links)) {
        $null = $panel.Children.Add((New-FastLlmUiFluentConsentLink -LicenseLink $licenseLink -PlainFormat ([string] $t.LicensePlain) -ErrorText ([string] $t.LicenseLinkError) -Context $context -Indent 10))
    }
    $buttons = [ordered] @{ Accept = [string] $t.LicenseAccept; Cancel = [string] $t.ConsentCancel }
    $dialog = New-FastLlmUiFluentDialog -Title ([string] $t.LicenseTitle) -Body $panel -Buttons $buttons -Enter 'Cancel' -Escape 'Cancel' -Owner $script:form
    $context['Dialog'] = $dialog
    $dialog['Buttons']['Accept'].IsEnabled = [bool] $Disclosure.canAccept
    $work = [System.Windows.SystemParameters]::WorkArea
    $dialog['Window'].Width = [Math]::Min($work.Width * 0.9, 640.0 * $scale)
    SetTrayMenuAvailable $false
    try { $answer = Show-FastLlmUiFluentDialog -Dialog $dialog }
    finally { SetTrayMenuAvailable $true }
    return [bool] ($answer -ceq 'Accept')
}

# The component consent: the intro, then per component its name, version and status, its source, its licence links and (for a missing one) an accept box.
# Install is enabled only while every box is ticked (Test-FastLlmUiConsentComplete, as the classic dialog); Enter and Escape cancel. Returns today's object:
# confirmed (true only when Install was clicked) and ticked (the state of every box, in row order).
function Show-FastLlmUiFluentComponentConsent {
    [CmdletBinding()]
    param($Row, [object[]] $ConsentRows, [bool] $Chosen = $true)
    RevealUiForAction
    $t = $script:FastLlmUiFluentDialogText
    $scale = Get-FastLlmUiFluentDialogScale -Owner $script:form
    $context = @{ Dialog = $null }
    $panel = New-Object System.Windows.Controls.StackPanel
    $intro = New-Object System.Windows.Controls.TextBlock
    $introModel = @($catalog.models | Where-Object { [string] $_.id -ceq [string] $Row.model }) | Select-Object -First 1
    $introName = [string] (Get-FastLlmModelDisplayName -Model $introModel)
    if (-not $introName) { $introName = [string] $Row.model }
    $intro.Text = Get-FastLlmUiComponentIntro -Model $introName -ContextText ([string] $Row.contextText) -Chosen $Chosen
    $intro.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $intro.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)
    $null = $panel.Children.Add($intro)
    $boxes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($consentRow in $ConsentRows) {
        $nameLabel = New-Object System.Windows.Controls.TextBlock
        $nameLabel.Text = ([string] $t.ComponentNameFmt -f [string] $consentRow.name, [string] $consentRow.version, [string] $consentRow.statusText)
        $nameLabel.FontWeight = [System.Windows.FontWeights]::Bold
        $nameLabel.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $nameLabel.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0)
        $sourceText = [string] $t.ComponentSource + [string] $consentRow.sourceText
        if (@($consentRow.redirectHosts).Count -gt 0) { $sourceText += [string] $t.ComponentRedirect + (@($consentRow.redirectHosts) -join [string] $t.ComponentJoin) }
        $sourceLabel = New-Object System.Windows.Controls.TextBlock
        $sourceLabel.Text = $sourceText
        $sourceLabel.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $sourceLabel.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        $null = $panel.Children.Add($nameLabel)
        $null = $panel.Children.Add($sourceLabel)
        foreach ($licenseLink in @($consentRow.links)) {
            $null = $panel.Children.Add((New-FastLlmUiFluentConsentLink -LicenseLink $licenseLink -PlainFormat ([string] $t.ComponentPlain) -ErrorText ([string] $t.ComponentLinkError) -Context $context -Indent 14))
        }
        # An installed or built-in component is a read-only row; only a missing one has a box, and a blocked one cannot be ticked.
        if ($consentRow.needsAccept) {
            $box = New-Object System.Windows.Controls.CheckBox
            $box.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'FastLlm.CheckBoxStyle')
            $box.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $acceptText = [string] $consentRow.acceptText
            # The caption wraps (the check box template's access text and text blocks wrap) and the box is named by its own caption, one string for both
            # (as the Settings check boxes are).
            $box.Content = ConvertTo-FastLlmUiAccessText -Text $acceptText -UseMnemonic $false
            [System.Windows.Automation.AutomationProperties]::SetName($box, $acceptText)
            $box.Tag = [string] $consentRow.id
            $box.IsEnabled = (-not $consentRow.blocked)
            $null = $panel.Children.Add($box)
            $boxes.Add($box)
        }
    }
    $buttons = [ordered] @{ Install = [string] $t.ComponentInstall; Cancel = [string] $t.ConsentCancel }
    $dialog = New-FastLlmUiFluentDialog -Title ([string] $t.ComponentTitle) -Body $panel -Buttons $buttons -Enter 'Cancel' -Escape 'Cancel' -Owner $script:form
    $context['Dialog'] = $dialog
    $install = $dialog['Buttons']['Install']
    $install.IsEnabled = $false
    # Install is enabled only when every box is ticked: the classic rule, the same function, over the state of every box.
    $complete = ${function:Test-FastLlmUiConsentComplete}
    $update = {
        $ticked = @($boxes | ForEach-Object { [bool] ($_.IsChecked -eq $true) })
        $install.IsEnabled = [bool] (& $complete -RowCount $boxes.Count -Ticked $ticked)
    }.GetNewClosure()
    foreach ($box in $boxes) { $box.Add_Checked($update); $box.Add_Unchecked($update) }
    $work = [System.Windows.SystemParameters]::WorkArea
    $dialog['Window'].Width = [Math]::Min($work.Width * 0.9, 720.0 * $scale)
    $confirmed = $false
    $ticked = @()
    SetTrayMenuAvailable $false
    try {
        $answer = Show-FastLlmUiFluentDialog -Dialog $dialog
        $confirmed = [bool] ($answer -ceq 'Install')
        $ticked = @($boxes | ForEach-Object { [bool] ($_.IsChecked -eq $true) })
    }
    finally { SetTrayMenuAvailable $true }
    return [pscustomobject] @{ confirmed = $confirmed; ticked = $ticked }
}

# The exact model consent: the review text in a read-only box (caret at the start), "Accept license & download" and Cancel. Enter and Escape cancel.
# Returns one [bool]: true only when the accept button was clicked.
function Show-FastLlmUiFluentExactModelConsent {
    [CmdletBinding()]
    param($Plan)
    RevealUiForAction
    $t = $script:FastLlmUiFluentDialogText
    $reviewText = Format-FastLlmUiModelConsent -Plan $Plan
    $scale = Get-FastLlmUiFluentDialogScale -Owner $script:form
    $details = New-FastLlmUiFluentDialogReadBox -Text $reviewText -MinHeight (320 * $scale) -MaxHeight (480 * $scale)
    $details.Name = 'ModelConsentText'
    [System.Windows.Automation.AutomationProperties]::SetName($details, [string] $t.ModelTitle)
    # The read-only box would open with everything selected: the caret goes to the start.
    $details.SelectionStart = 0
    $details.SelectionLength = 0
    $buttons = [ordered] @{ Accept = [string] $t.ModelAccept; Cancel = [string] $t.ConsentCancel }
    $dialog = New-FastLlmUiFluentDialog -Title ([string] $t.ModelTitle) -Body $details -Buttons $buttons -Enter 'Cancel' -Escape 'Cancel' -Owner $script:form
    $dialog['Window'].Add_Loaded({ $details.SelectionStart = 0; $details.SelectionLength = 0 }.GetNewClosure())
    $work = [System.Windows.SystemParameters]::WorkArea
    $dialog['Window'].Width = [Math]::Min($work.Width * 0.9, 760.0 * $scale)
    SetTrayMenuAvailable $false
    try { $answer = Show-FastLlmUiFluentDialog -Dialog $dialog }
    finally { SetTrayMenuAvailable $true }
    return [bool] ($answer -ceq 'Accept')
}

# The VC++ install review: the review text in a read-only box, "Install Microsoft runtime" and "Do later". Enter and Escape answer Do later.
# Returns one [bool]: true only when the install button was clicked.
function Show-FastLlmUiFluentVcInstallReview {
    [CmdletBinding()]
    param($Receipt, $Candidate)
    RevealUiForAction
    $t = $script:FastLlmUiFluentDialogText
    $review = Format-FastLlmUiVcReview -Receipt $Receipt -Candidate $Candidate -CacheRoot $script:vcCacheRoot
    $scale = Get-FastLlmUiFluentDialogScale -Owner $script:form
    $details = New-FastLlmUiFluentDialogReadBox -Text $review -MinHeight (320 * $scale) -MaxHeight (480 * $scale)
    $details.Name = 'VcReviewText'
    [System.Windows.Automation.AutomationProperties]::SetName($details, [string] $t.VcTitle)
    $buttons = [ordered] @{ Install = [string] $t.VcInstall; Later = [string] $t.VcLater }
    $dialog = New-FastLlmUiFluentDialog -Title ([string] $t.VcTitle) -Body $details -Buttons $buttons -Enter 'Later' -Escape 'Later' -Owner $script:form
    $work = [System.Windows.SystemParameters]::WorkArea
    $dialog['Window'].Width = [Math]::Min($work.Width * 0.9, 760.0 * $scale)
    SetTrayMenuAvailable $false
    try { $answer = Show-FastLlmUiFluentDialog -Dialog $dialog }
    finally { SetTrayMenuAvailable $true }
    return [bool] ($answer -ceq 'Install')
}
