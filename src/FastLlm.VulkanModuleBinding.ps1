#requires -Version 5.1
# Pure checks for the private loaded-module collector; also exercised with mock runs.
function Assert-FastLlmVulkanModuleState {
    param($State,[string]$RunId,[int]$ExpectedPid=0,[long]$ExpectedTicks=0,[string]$ExpectedEngineHash='')
    if(-not $State -or -not $State.active -or $State.phase -cne 'ready' -or
        $State.runId -cne $RunId -or $State.engineVersion -cne 'b10698' -or
        -not $State.recipe -or $State.recipe.backend -cne 'Vulkan' -or
        $State.recipe.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $State.recipe.catalogSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $State.modelSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        -not $State.processIdentity -or [int]$State.processIdentity.pid -le 0 -or
        [long]$State.processIdentity.startUtcTicks -le 0){
        throw 'An exact active, Ready, supervised b10698 Vulkan run is required.'
    }
    $endpoint=[uri]$State.endpoint
    if($endpoint.Scheme -cne 'http' -or $endpoint.Host -cne '127.0.0.1' -or
        $endpoint.AbsolutePath -cne '/v1' -or $endpoint.Port -ne 8080){
        throw 'The normal loopback endpoint is required.'
    }
    if(($ExpectedPid -gt 0 -and [int]$State.processIdentity.pid -ne $ExpectedPid) -or
        ($ExpectedTicks -gt 0 -and [long]$State.processIdentity.startUtcTicks -ne $ExpectedTicks) -or
        ($ExpectedEngineHash -and $State.recipe.engineSha256 -cne $ExpectedEngineHash)){
        throw 'The supervised run binding changed.'
    }
}

function Assert-FastLlmVulkanModuleOutputSyntax {
    param([string]$Path)
    if($Path -cnotmatch '^[A-Za-z]:\\[^<>:"|?*\x00-\x1f\x7f]+\.json$' -or
        $Path -match '[\\/]\.\.?([\\/]|$)' -or $Path -match '/'){
        throw 'OutputPath must be an absolute local-drive .json file.'
    }
}

function Assert-FastLlmVulkanModuleOutputComponents {
    param([string]$FullPath,[string]$Root)
    $parent=[IO.Path]::GetDirectoryName($FullPath)
    $cursor=$Root
    foreach($segment in @('') + $parent.Substring($Root.Length).Split([IO.Path]::DirectorySeparatorChar)){
        if($segment.Length -gt 0){$cursor=Join-Path $cursor $segment}
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
            throw 'OutputPath traverses an unsafe directory.'
        }
    }
    if([IO.File]::Exists($FullPath) -or [IO.Directory]::Exists($FullPath)){
        throw 'OutputPath already exists; use a new report filename.'
    }
}

function Assert-FastLlmVulkanModuleProcess {
    param($State,[int[]]$ListenerOwners,[string]$ProcessName,[long]$ProcessTicks,
        [string]$ActualExe,[string]$ExpectedExe,[string]$ActualExeSha256)
    if(@($ListenerOwners).Count -ne 1 -or [int]$ListenerOwners[0] -ne [int]$State.processIdentity.pid){
        throw 'The loopback listener owner changed.'
    }
    if($ProcessName -cne 'llama-server' -or $ProcessTicks -ne [long]$State.processIdentity.startUtcTicks){
        throw 'The server PID/start identity changed.'
    }
    if(-not [string]::Equals([IO.Path]::GetFullPath($ActualExe),[IO.Path]::GetFullPath($ExpectedExe),
            [StringComparison]::OrdinalIgnoreCase) -or
        $ActualExeSha256 -cne [string]$State.recipe.engineSha256){
        throw 'The active server executable does not match the pinned installation and run recipe.'
    }
}

function Select-FastLlmVulkanModulePaths {
    param([object[]]$Modules)
    if($Modules.Count -lt 1 -or $Modules.Count -gt 512){throw 'The loaded module count is outside the diagnostic limit.'}
    $paths=New-Object System.Collections.Generic.List[string]
    foreach($module in $Modules){
        $name=[string]$module.ModuleName
        if($name -match '^(?i:(?:amd|ati|vulkan|vk)[a-z0-9_.-]*|ggml-vulkan)\.dll$'){
            $path=[string]$module.FileName
            if(-not [IO.Path]::IsPathRooted($path) -or $path.Length -gt 1024){
                throw 'A selected module has no bounded absolute path.'
            }
            $paths.Add($path)
        }
    }
    if($paths.Count -lt 1 -or $paths.Count -gt 32){throw 'The selected Vulkan/AMD module count is outside the diagnostic limit.'}
    if(-not @($paths | Where-Object {[IO.Path]::GetFileName($_) -ieq 'vulkan-1.dll'}).Count){
        throw 'The serving process snapshot has no Vulkan loader.'
    }
    return @($paths.ToArray() | Sort-Object -Unique)
}

function Assert-FastLlmVulkanModuleReportRows {
    param($Report)
    $rows=@($Report.selectedModules)
    if($rows.Count -lt 1 -or $rows.Count -gt 32){throw 'Module report has an invalid selected-module count.'}
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($row in $rows){
        $path=[string]$row.path
        if(-not [IO.Path]::IsPathRooted($path) -or $path.Length -gt 1024 -or
            [IO.Path]::GetFileName($path) -cne [string]$row.name -or -not $seen.Add($path) -or
            [long]$row.sizeBytes -lt 1 -or [long]$row.sizeBytes -gt 268435456 -or
            [string]$row.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            [string]$row.signatureStatus -cnotmatch '^[A-Za-z]{1,64}$' -or
            [string]$row.fileVersion -match '[\x00-\x1f\x7f]' -or
            [string]$row.productVersion -match '[\x00-\x1f\x7f]' -or
            ([string]$row.fileVersion).Length -gt 128 -or ([string]$row.productVersion).Length -gt 128 -or
            ([string]$row.signer).Length -gt 512){
            throw 'Module report has a malformed or incomplete file observation.'
        }
    }
}
