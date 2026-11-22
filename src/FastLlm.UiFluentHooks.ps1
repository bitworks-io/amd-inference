#requires -Version 5.1
# Window-message hooks for the fluent window: theme changes (settings, system colors, DWM colorization) and session end.
# The hook body is the C# class Bitworks.FastLlm.FluentWindowHook (a scriptblock delegate cannot write back the ref bool handled),
# so PowerShell runs only for session-end queries and theme messages. Both callbacks are built here, in this function's own scope.
# No WPF type is resolved at dot-source time, only inside function bodies.
Set-StrictMode -Version 2.0

# Entries: @{ Window; Source; Hook }. Matched by Window reference, because the handle reads zero after WM_DESTROY.
$script:FastLlmUiHookEntries = New-Object System.Collections.ArrayList

function Register-FastLlmUiWindowHooks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Window,
        [Parameter(Mandatory = $true)] $Form,
        [Parameter(Mandatory = $true)] [scriptblock] $OnThemeChanged
    )
    $result = @{ hooked = $false; error = '' }
    try {
        Unregister-FastLlmUiWindowHooks -Window $Window
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
        $hwnd = $helper.EnsureHandle()
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
        if ($null -eq $source) { throw 'No HwndSource for the window handle.' }
        $closing = ${function:Invoke-FastLlmUiFormClosing}
        $disp = $Window.Dispatcher
        $theme = $OnThemeChanged
        $formRef = $Form

        # Exactly one [bool] out: $true refuses the session end.
        $refuseBlock = {
            try {
                if ($formRef.FastLlmFormState['Closing'] -eq $true) { return $true }
                $cancel = & $closing -Form $formRef -CloseReason ([System.Windows.Forms.CloseReason]::WindowsShutDown)
                return [bool] $cancel
            }
            catch {
                $ex = $_
                $rethrow = { throw $ex }.GetNewClosure()
                $null = $disp.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [Action] $rethrow)
                return $true
            }
        }.GetNewClosure()

        # Only queues; the theme work runs on the dispatcher and is not wrapped, so a failure reaches Dispatcher.UnhandledException.
        $themeBlock = {
            $null = $disp.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [Action] $theme)
        }.GetNewClosure()

        $hookObj = New-Object Bitworks.FastLlm.FluentWindowHook(([Func[bool]] $refuseBlock), ([Action] $themeBlock))
        $hook = $hookObj.CreateHook([System.Windows.Interop.HwndSourceHook])
        $source.AddHook($hook)
        $null = $script:FastLlmUiHookEntries.Add(@{ Window = $Window; Source = $source; Hook = $hook; Obj = $hookObj })
        $result.hooked = $true
    }
    catch {
        $result.hooked = $false
        $result.error = [string] $_.Exception.Message
    }
    return $result
}

function Unregister-FastLlmUiWindowHooks {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Window)
    foreach ($entry in @($script:FastLlmUiHookEntries)) {
        if ([object]::ReferenceEquals($entry.Window, $Window)) {
            try { $entry.Source.RemoveHook($entry.Hook) } catch { $null = $_ }
            $script:FastLlmUiHookEntries.Remove($entry)
        }
    }
}
