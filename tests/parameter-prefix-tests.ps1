#requires -Version 5.1
# Parameter-prefix compatibility: PowerShell binds a unique parameter-name prefix, so a new parameter name must not make any prefix that
# identified exactly one parameter before (for example -Context for -ContextSize) ambiguous. The old names are embedded as data (the parameter
# names of each command before the serving profile options were added); the current names are read from the source with the PowerShell parser.
# Pure parsing and command metadata; no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
$old=[ordered]@{
    'fast-llm.ps1'='Action,Profile,InstallRoot,ModelId,Recipe,ContextSize,AllowExperimentalModel,EngineOnly,LoadTimeoutSeconds,HardwareFile,AcceptModelLicense,ExpectedModelProvenanceSha256,Unattended,DryRun,AsJson,VulkanBarMitigation,ProbeVulkanMemory,Compact,SupportBundle,ListOnly,ApiCheck,ThroughputCanary,SkipSelfTest,DeviceBinding,NoDownload,Yes,Channel,List,Install,Remove,Installed,RemoveQuarantined,AcceptLicense,ComponentLicenses,ServerPort,Thinking,ChatPage,IdleStopMinutes,Port,IgnoreUserSettings,PlannedRecipe,UseFallback,FallbackReason,AcceptExperimental,Detail,Preload,PreloadStatus,Next,ApprovedModelsPath,MinFreeGB,OutputPath'
    'Get-FastLlmPlan'='Hardware,CatalogPath,Profile,InstallRoot,ModelId,ContextSize,AllowExperimentalModel,RecipesPath,GpuVariantsPath,RecipeId,ServerPort,Thinking,ChatPage,Recovered,NoEngineExecution,ResolveFallback,FallbackFromRecipe,FallbackReason,PreferInstalledModels'
    'Test-FastLlmApiCanary'='BaseUrl,ModelId,ContextSize'
    'Set-FastLlmServingSettings'='InstallRoot,ServerPort,Thinking,ChatPage,IdleStopMinutes'
    # The parameter names of the background start before the model switch option was added.
    'Start-FastLlmBackgroundHost'='SourceRoot,InstallRoot,Profile,ModelId,ContextSize,AllowExperimentalModel,LoadTimeoutSeconds,ReadyTimeoutSeconds,VulkanBarMitigation,ServerPort,Thinking,ChatPage,IdleStopMinutes,NoWait'
}
function Get-ParameterNames([string]$Command) {
    if ($Command -ceq 'fast-llm.ps1') {
        $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'fast-llm.ps1'),[ref]$null,[ref]$null)
        return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
    $files=Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps*1'
    foreach ($file in $files) {
        $ast=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$null)
        $fn=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Command},$true))
        if ($fn.Count -eq 1) {
            $list=if ($fn[0].Body.ParamBlock) { $fn[0].Body.ParamBlock.Parameters } else { $fn[0].Parameters }
            return @($list | ForEach-Object { $_.Name.VariablePath.UserPath })
        }
    }
    throw "FAIL: $Command not found"
}
foreach ($command in $old.Keys) {
    $before=@($old[$command] -split ',')
    $after=Get-ParameterNames $command
    Check (@($before | Where-Object { $after -notcontains $_ }).Count -eq 0) "$command keeps every existing parameter"
    $broken=@()
    foreach ($name in $before) {
        for ($length=1; $length -lt $name.Length; $length++) {
            $prefix=$name.Substring(0,$length)
            $wasUnique=@($before | Where-Object { $_.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) }).Count -eq 1
            if (-not $wasUnique) { continue }
            $now=@($after | Where-Object { $_.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) })
            if ($now.Count -ne 1 -or $now[0] -cne $name) {
                # The one exception: the parameter itself declares this prefix as an exact alias. The binder resolves an exact alias before any
                # prefix, so the abbreviation still binds the same parameter (fast-llm.ps1 -V for -VulkanBarMitigation, beside -Vision). Any other
                # prefix that stops being unique stays broken.
                $declaresAlias=$false
                try {
                    $info=if ($command -ceq 'fast-llm.ps1') { Get-Command -Name (Join-Path $root 'fast-llm.ps1') } else { Get-Command -Name $command }
                    $declaresAlias=($info.Parameters.ContainsKey($name) -and @($info.Parameters[$name].Aliases) -contains $prefix -and $info.ResolveParameter($prefix).Name -ceq $name)
                } catch { $declaresAlias=$false }
                if (-not $declaresAlias) { $broken+="-$prefix ($name)" }
            }
        }
    }
    Check ($broken.Count -eq 0) "${command}: every prefix that was unique stays unique (broken: $($broken -join ' '))"
}
# The binder itself: ResolveParameter applies the same prefix rules and throws when a prefix is ambiguous.
$script=Get-Command (Join-Path $root 'fast-llm.ps1')
Check ($script.ResolveParameter('Context').Name -ceq 'ContextSize') 'fast-llm.ps1 plan -Context 8192 binds ContextSize'
Check ($script.ResolveParameter('ContextS').Name -ceq 'ContextSize') 'fast-llm.ps1 -ContextS binds ContextSize'
Check ($script.ResolveParameter('Se').Name -ceq 'ServerPort') 'fast-llm.ps1 -Se binds ServerPort'
# The model switch options: -Allow still means -AllowExperimentalModel and -F still means -FallbackReason, so the new switches are named
# -SwitchAllowed and -SwitchForce (not -AllowSwitch and -Force) on the command line and on the background start.
Check ($script.ResolveParameter('Allow').Name -ceq 'AllowExperimentalModel') 'fast-llm.ps1 -Allow binds AllowExperimentalModel'
Check ($script.ResolveParameter('F').Name -ceq 'FallbackReason') 'fast-llm.ps1 -F binds FallbackReason'
Check ($script.ResolveParameter('SwitchA').Name -ceq 'SwitchAllowed' -and $script.ResolveParameter('SwitchF').Name -ceq 'SwitchForce') 'fast-llm.ps1 has -SwitchAllowed and -SwitchForce'
Check ((Get-ParameterNames 'Start-FastLlmBackgroundHost') -ccontains 'SwitchAllowed' -and (Get-ParameterNames 'Start-FastLlmBackgroundHost') -cnotcontains 'AllowSwitch') 'Start-FastLlmBackgroundHost takes -SwitchAllowed, so -Allow stays -AllowExperimentalModel there too'
# The API key setting is written -ApiKey. A parameter of that name would make -Api (until now unique for -ApiCheck) ambiguous, so the
# parameter is named KeyAction with the alias ApiKey, and ApiCheck has the alias Api: an exact alias wins over a prefix. The binder is asked
# directly, for every prefix that was unique before the key existed.
$oldCli=@($old['fast-llm.ps1'] -split ',')
$rebound=@()
foreach ($name in $oldCli) {
    for ($length=1; $length -le $name.Length; $length++) {
        $prefix=$name.Substring(0,$length)
        if (@($oldCli | Where-Object { $_.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { continue }
        $resolved=$null
        try { $resolved=$script.ResolveParameter($prefix).Name } catch { $resolved='<'+$_.Exception.GetType().Name+'>' }
        if ($resolved -cne $name) { $rebound+="-$prefix ($name -> $resolved)" }
    }
}
Check ($rebound.Count -eq 0) "fast-llm.ps1: the binder still binds every prefix that was unique to the same parameter (changed: $($rebound -join ' '))"
Check ($script.ResolveParameter('Api').Name -ceq 'ApiCheck') 'fast-llm.ps1 doctor -Api still binds ApiCheck'
Check ($script.ResolveParameter('ApiKey').Name -ceq 'KeyAction') 'fast-llm.ps1 settings -ApiKey binds the key action'
Check ($script.ResolveParameter('ApiK').Name -ceq 'KeyAction') 'fast-llm.ps1 -ApiK binds the key action'
$plan=Get-Command Get-FastLlmPlan
Check ($plan.ResolveParameter('Context').Name -ceq 'ContextSize') 'Get-FastLlmPlan -Context 8192 binds ContextSize'
Check ($plan.ResolveParameter('S').Name -ceq 'ServerPort') 'Get-FastLlmPlan -S binds ServerPort'
Check ($plan.ResolveParameter('Serv').Name -ceq 'ServerPort') 'Get-FastLlmPlan -Serv binds ServerPort'
$settings=Get-Command Set-FastLlmServingSettings
Check ($settings.ResolveParameter('S').Name -ceq 'ServerPort') 'Set-FastLlmServingSettings -S binds ServerPort'
# The embedding options. -E was already ambiguous (EngineOnly, ExpectedModelProvenanceSha256) and -En still means -EngineOnly; the new names
# are told apart from -Embeddi on (-Embeddings and -EmbeddingP).
Check ($script.ResolveParameter('En').Name -ceq 'EngineOnly' -and $script.ResolveParameter('Ex').Name -ceq 'ExpectedModelProvenanceSha256') 'fast-llm.ps1 -En still binds EngineOnly and -Ex still binds ExpectedModelProvenanceSha256'
Check ($script.ResolveParameter('Embeddings').Name -ceq 'Embeddings' -and $script.ResolveParameter('EmbeddingPort').Name -ceq 'EmbeddingPort' -and $script.ResolveParameter('EmbeddingP').Name -ceq 'EmbeddingPort') 'fast-llm.ps1 has -Embeddings and -EmbeddingPort'
$start=Get-Command Start-FastLlmServer
$oldStart='Plan,CatalogPath,InstallRoot,LoadTimeoutSeconds,VulkanBarMitigation,ThroughputCanary,SelfTest,DeviceBinding,IdleStopMinutes,AllowSwitch,SwitchContext,SwitchObserver,ApiKey' -split ','
$startRebound=@()
foreach ($name in $oldStart) {
    for ($length=1; $length -le $name.Length; $length++) {
        $prefix=$name.Substring(0,$length)
        if (@($oldStart | Where-Object { $_.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) { continue }
        $resolved=$null
        try { $resolved=$start.ResolveParameter($prefix).Name } catch { $resolved='<'+$_.Exception.GetType().Name+'>' }
        if ($resolved -cne $name) { $startRebound+="-$prefix ($name -> $resolved)" }
    }
}
Check ($startRebound.Count -eq 0 -and $start.Parameters.ContainsKey('Embeddings') -and $start.Parameters.ContainsKey('EmbeddingPort')) "Start-FastLlmServer: the embedding parameters leave every prefix that was unique bound to the same parameter (changed: $($startRebound -join ' '))"
$setSettings=Get-Command Set-FastLlmServingSettings
Check ($setSettings.ResolveParameter('S').Name -ceq 'ServerPort' -and $setSettings.ResolveParameter('T').Name -ceq 'Thinking' -and $setSettings.ResolveParameter('C').Name -ceq 'ChatPage' -and $setSettings.Parameters.ContainsKey('Embeddings') -and $setSettings.Parameters.ContainsKey('EmbeddingPort')) 'Set-FastLlmServingSettings takes the embedding settings, and -S, -T and -C still bind ServerPort, Thinking and ChatPage'
# The vision option is the parameter -Vision, so what users type matches Get-Help. A second parameter starting with V would make -V (until now
# unique for -VulkanBarMitigation) ambiguous, so VulkanBarMitigation has the exact alias V: an exact alias wins over a prefix.
Check ($script.ResolveParameter('Vision').Name -ceq 'Vision') 'fast-llm.ps1 plan -Vision binds the vision option'
Check ($script.ResolveParameter('Vi').Name -ceq 'Vision') 'fast-llm.ps1 -Vi binds Vision'
Check ($script.ResolveParameter('V').Name -ceq 'VulkanBarMitigation' -and $script.ResolveParameter('Vu').Name -ceq 'VulkanBarMitigation') 'fast-llm.ps1 -V and -Vu still bind VulkanBarMitigation'
Check ((Get-ParameterNames 'fast-llm.ps1') -ccontains 'Vision' -and (Get-ParameterNames 'fast-llm.ps1') -cnotcontains 'ImageMode') 'fast-llm.ps1 has a parameter named Vision (and none named ImageMode)'
Check ((Get-ParameterNames 'Get-FastLlmPlan') -ccontains 'Vision') 'Get-FastLlmPlan takes -Vision (the planner has no -V abbreviation to protect)'
Write-Host "parameter-prefix-tests: $script:count checks passed"
