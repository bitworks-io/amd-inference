# Shared by the task-quality tests: reduce a report to a stable text so two runs compare equal.
# Only values that differ between any two runs are masked: the record time, the on-disk source digests
# (they change whenever a source file does) and the collector clock readings. Property order is kept
# as written, except for the three blocks the tool builds from a hashtable: .NET randomizes hashtable order
# per process, so those are compared by sorted key.
function Get-TaskQualityMaskedReportText([string]$Text){
    $report=ConvertFrom-Json $Text
    $report.recordedAt='<masked>'
    foreach($name in @($report.sourceProvenance.sha256.PSObject.Properties.Name)){$report.sourceProvenance.sha256.$name='<masked>'}
    foreach($level in @($report.summary)){
        foreach($name in @('wholeSuiteWallMs','suiteStartCollectorMs','suiteFinishCollectorMs','usefulTasksPerSecond')){
            if($null -ne $level.$name){$level.$name='<masked>'}
        }
    }
    foreach($block in @('methodology','sourceProvenance','qualification')){
        $sorted=[ordered]@{}
        foreach($name in @($report.$block.PSObject.Properties.Name|Sort-Object {$_} -CaseSensitive)){$sorted[$name]=$report.$block.$name}
        $report.$block=[pscustomobject]$sorted
    }
    return (ConvertTo-Json -InputObject $report -Depth 30 -Compress)
}
