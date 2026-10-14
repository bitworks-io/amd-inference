# Atomic same-folder file replacement shared by the module (Runtime.ps1) and the standalone background host.
# Dot-sourced; defines no top-level behaviour beyond two test seams.
Set-StrictMode -Version 2.0

# Test seams: when set, a scriptblock param($Source,$Destination) replaces the real call. Default $null = real call.
$script:FastLlmFileReplaceInvoker = $null
$script:FastLlmFileMoveInvoker = $null

function Invoke-FastLlmFileReplaceCall {
    param([string]$Source,[string]$Destination)
    if ($null -ne $script:FastLlmFileReplaceInvoker) { & $script:FastLlmFileReplaceInvoker $Source $Destination; return }
    # [NullString]::Value is a true null (no backup); a plain $null becomes "" in Windows PowerShell 5.1 and breaks Replace.
    [IO.File]::Replace($Source,$Destination,[NullString]::Value)
}

function Invoke-FastLlmFileMoveCall {
    param([string]$Source,[string]$Destination)
    if ($null -ne $script:FastLlmFileMoveInvoker) { & $script:FastLlmFileMoveInvoker $Source $Destination; return }
    [IO.File]::Move($Source,$Destination)
}

function Get-FastLlmUnwrappedException {
    param($Exception)
    if ($Exception -is [Management.Automation.MethodInvocationException] -and $Exception.InnerException) { return $Exception.InnerException }
    return $Exception
}

# Replaces $Destination with $Source (same folder, so the operation is atomic) and never deletes the destination first.
# Windows: Replace when the destination exists, else Move; bounded retry (12 attempts, <= ~1.4 s). ReplaceFile can fail
# with 1176 after the original is already gone; the temp file then still exists and is moved into place.
# Failure throws 'state-replace-failed: <leaf> (HResult 0x........)'; the source is NOT deleted here.
function Move-FastLlmFileReplacing {
    param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$Destination)
    if ($env:OS -cne 'Windows_NT') {
        Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        return
    }
    $sleeps = @(10,20,40,80,100,100,100,100,100,100,100)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastHResult = 0
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        if (-not [IO.File]::Exists($Source)) { $lastHResult = -2147024894; break }
        $failure = $null
        try {
            if ([IO.File]::Exists($Destination)) {
                try { Invoke-FastLlmFileReplaceCall -Source $Source -Destination $Destination }
                catch {
                    $inner = Get-FastLlmUnwrappedException $_.Exception
                    $win32 = [int]$inner.HResult -band 0xFFFF
                    # 1176: the original may already be gone while the replacement still sits in $Source. FileNotFound: destination vanished.
                    if (($inner -is [IO.FileNotFoundException] -or $win32 -eq 1176) -and [IO.File]::Exists($Source) -and -not [IO.File]::Exists($Destination)) {
                        Invoke-FastLlmFileMoveCall -Source $Source -Destination $Destination
                    } else { throw }
                }
            } else {
                try { Invoke-FastLlmFileMoveCall -Source $Source -Destination $Destination }
                catch {
                    $inner = Get-FastLlmUnwrappedException $_.Exception
                    if ($inner -is [IO.IOException] -and [IO.File]::Exists($Source) -and [IO.File]::Exists($Destination)) {
                        Invoke-FastLlmFileReplaceCall -Source $Source -Destination $Destination
                    } else { throw }
                }
            }
            return
        } catch {
            $failure = Get-FastLlmUnwrappedException $_.Exception
        }
        $lastHResult = [int]$failure.HResult
        if (-not ($failure -is [IO.IOException] -or $failure -is [UnauthorizedAccessException])) { break }
        if ($failure -is [IO.DirectoryNotFoundException]) { break }
        if ($attempt -ge 11 -or $clock.ElapsedMilliseconds -ge 1400) { break }
        Start-Sleep -Milliseconds $sleeps[$attempt]
    }
    throw ('state-replace-failed: {0} (HResult 0x{1:X8})' -f [IO.Path]::GetFileName($Destination),$lastHResult)
}

# Best-effort sweep of stale temp files left by failed replaces in one folder. A failed replace always KEEPS its temp (it
# can be the only copy, and File.Exists on the destination cannot tell a delete-pending file from a live one on .NET
# Framework), so garbage is collected here instead, after the next SUCCESSFUL write to the same folder. Only leaf names
# matching the writer's own GUID pattern (-NamePattern, case-sensitive regex) and only files whose LastWriteTimeUtc is older
# than -MinAgeMinutes (default 10) are removed, so a concurrent writer's in-flight temp is never touched. Never throws.
function Remove-FastLlmStaleTemporaries {
    param([string]$Folder,[string]$NamePattern,[int]$MinAgeMinutes = 10)
    try {
        if ([string]::IsNullOrEmpty($Folder) -or [string]::IsNullOrEmpty($NamePattern)) { return }
        if (-not [IO.Directory]::Exists($Folder)) { return }
        $cutoff = [DateTime]::UtcNow.AddMinutes(-$MinAgeMinutes)
        foreach ($file in [IO.Directory]::GetFiles($Folder)) {
            try {
                if ([IO.Path]::GetFileName($file) -cnotmatch $NamePattern) { continue }
                $attributes = [int][IO.File]::GetAttributes($file)
                if ($attributes -eq -1 -or ($attributes -band [int][IO.FileAttributes]::ReparsePoint)) { continue }
                if ([IO.File]::GetLastWriteTimeUtc($file) -ge $cutoff) { continue }
                [IO.File]::Delete($file)
            } catch { }
        }
    } catch { }
}
