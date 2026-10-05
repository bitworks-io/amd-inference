param(
    [Parameter(Mandatory=$true)][string]$PlanPath,
    [Parameter(Mandatory=$true)][string]$LabRunRoot,
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$ModulePath
)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$plan=Get-Content -LiteralPath $PlanPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$result=& (Get-Module FastLlm) {
    param($Source,$Plan,$Root)
    . $Source
    Invoke-FastLlmOffloadLabSupervisor -Plan $Plan -LabRunRoot $Root -LoadTimeoutSeconds 15
} $SourcePath $plan $LabRunRoot
if($result -ne 0){throw 'Offload-lab supervisor returned a nonzero result.'}
exit 0
