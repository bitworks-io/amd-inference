#requires -Version 5.1
# Writes the golden table of the window's enable rules from a given window script (the released one).
param([Parameter(Mandatory=$true)][string]$SourceFile, [Parameter(Mandatory=$true)][string]$OutFile)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'UiControlStatesMatrix.ps1')
$sourceText = [IO.File]::ReadAllText($SourceFile)
$rows = @{}
foreach ($row in (Get-UiControlStatesMatrix)) { $rows[$row.key] = Invoke-UiWindowEnableRules -SourceText $sourceText -Row $row }
$tray = @{}
foreach ($row in (Get-UiTrayMatrix)) { $tray[$row.key] = Invoke-UiWindowTrayRule -SourceText $sourceText -Row $row }
function Format-Block($Table) {
    $keys = [string[]]@($Table.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    return (($keys | ForEach-Object { '"' + $_ + '":"' + $Table[$_] + '"' }) -join ",`n")
}
$columns = (Get-UiControlStatesColumns | ForEach-Object { '"' + $_ + '"' }) -join ','
$json = '{"schema":"fastllm.ui-control-states-golden/v1","source":"fast-llm-ui.ps1@646ccb05","columns":[' + $columns + '],' + "`n" +
    '"rows":{' + "`n" + (Format-Block $rows) + "`n" + '},' + "`n" +
    '"tray":{' + "`n" + (Format-Block $tray) + "`n" + '}}' + "`n"
[IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('golden rows: ' + $rows.Count + ', tray rows: ' + $tray.Count)
