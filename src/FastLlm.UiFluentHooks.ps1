#requires -Version 5.1
# Window-message hooks for the fluent window: theme changes (settings, system colors, DWM colorization) and session end.
# The hook delegate is a scriptblock converted to HwndSourceHook, so it captures what it calls as scriptblocks, never by function name.
# No WPF type is resolved at dot-source time, only inside function bodies.
Set-StrictMode -Version 2.0

$script:FastLlmUiHookState = @{}

function Register-FastLlmUiWindowHooks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Window,
        [Parameter(Mandatory = $true)] $Form,
        [Parameter(Mandatory = $true)] [scriptblock] $OnThemeChanged
    )
    $result = @{ hooked = $false; error = '' }
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
        $hwnd = $helper.EnsureHandle()
        $source = [System.Windows.Interop.HwndSource]::FromHwnd($hwnd)
        if ($null -eq $source) { throw 'No HwndSource for the window handle.' }
        $key = [string] $hwnd.ToInt64()
        if ($script:FastLlmUiHookState.ContainsKey($key)) {
            $old = $script:FastLlmUiHookState[$key]
            try { $old.Source.RemoveHook($old.Hook) } catch { $null = $_ }
            $script:FastLlmUiHookState.Remove($key)
        }
        $closing = ${function:Invoke-FastLlmUiFormClosing}
        $dispatcher = $Window.Dispatcher
        $hookBody = {
            param([IntPtr] $hwndArg, [int] $msg, [IntPtr] $wParam, [IntPtr] $lParam, $handled)
            try {
                if ($msg -eq 0x001A -or $msg -eq 0x0015 -or $msg -eq 0x0320) {
                    $run = { try { & $OnThemeChanged } catch { $null = $_ } }.GetNewClosure()
                    [void] $dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [Action] $run)
                }
                elseif ($msg -eq 0x0011) {
                    $cancel = & $closing -Form $Form -CloseReason ([System.Windows.Forms.CloseReason]::WindowsShutDown)
                    if ([bool] $cancel) {
                        if ($handled -is [ref]) { $handled.Value = $true } else { $handled = $true }
                    }
                }
            }
            catch { $null = $_ }
            return [IntPtr]::Zero
        }.GetNewClosure()
        $hook = [System.Windows.Interop.HwndSourceHook] $hookBody
        $source.AddHook($hook)
        $script:FastLlmUiHookState[$key] = @{ Source = $source; Hook = $hook }
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
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($Window)
        $key = [string] $helper.Handle.ToInt64()
    }
    catch { return }
    if (-not $script:FastLlmUiHookState.ContainsKey($key)) { return }
    $state = $script:FastLlmUiHookState[$key]
    try { $state.Source.RemoveHook($state.Hook) } catch { $null = $_ }
    $script:FastLlmUiHookState.Remove($key)
}
