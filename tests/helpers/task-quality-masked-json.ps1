# Shared by the task-quality tests: reduce a report to a stable text so two runs compare equal.
# The text is built here from the parsed report, never from the serialised layout, so Windows PowerShell 5.1 and PowerShell 7
# (different indent, spacing, escaping and number text in ConvertTo-Json) give the same text for the same report.
# Only values that differ between any two runs are masked: the record time, the on-disk source digests (they change whenever a
# source file does) and the collector clock readings. Property order is kept as written, except for the three blocks the tool
# builds from a hashtable: .NET randomizes hashtable order per process, so those are compared by sorted key.
# Every key, its order and every value still count.
function ConvertTo-TaskQualityCanonicalText($Value){
    if($null -eq $Value){return 'null'}
    if($Value -is [string]){return '"'+($Value.Replace('\','\\').Replace('"','\"'))+'"'}
    if($Value -is [bool]){return $(if($Value){'true'}else{'false'})}
    if($Value -is [ValueType]){return [Convert]::ToDouble($Value,[Globalization.CultureInfo]::InvariantCulture).ToString('R',[Globalization.CultureInfo]::InvariantCulture)}
    if($Value -is [System.Collections.IEnumerable] -and $Value -isnot [System.Collections.IDictionary]){
        $items=@();foreach($item in $Value){$items+=ConvertTo-TaskQualityCanonicalText $item}
        return '['+($items -join ',')+']'
    }
    $members=@()
    foreach($property in $Value.PSObject.Properties){$members+=('"'+$property.Name+'":'+(ConvertTo-TaskQualityCanonicalText $property.Value))}
    return '{'+($members -join ',')+'}'
}

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
    return (ConvertTo-TaskQualityCanonicalText $report)
}
