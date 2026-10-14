param(
    [Parameter(Mandatory=$true)][string]$PlanPath,
    [Parameter(Mandatory=$true)][string]$LabRunRoot,
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$ModulePath,
    [Parameter(Mandatory=$true)][int]$Port,
    [ValidateSet('stub','fail')][string]$OwnerMode='stub'
)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$plan=Get-Content -LiteralPath $PlanPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
# The mock listens through HttpListener (owned by the OS, not by the child), so the real owner check is stubbed.
$ownerCheck=if($OwnerMode -ceq 'fail'){{param($ChildPid,$LabPort) throw 'The supervised CPU reference child does not own the loopback listener.'}}else{{param($ChildPid,$LabPort)}}
$result=& (Get-Module FastLlm) {
    param($Source,$Plan,$Root,$LabPort,$Owner)
    . $Source
    Invoke-FastLlmCpuReferenceLabSupervisor -Plan $Plan -LabRunRoot $Root -LoadTimeoutSeconds 20 -Port $LabPort -OwnerCheck $Owner
} $SourcePath $plan $LabRunRoot $Port $ownerCheck
if($result -ne 0){throw 'CPU reference lab supervisor returned a nonzero result.'}
exit 0
