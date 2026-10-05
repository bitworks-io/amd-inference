#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-FastLlmPortableSourceZip {
    param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$ArchivePath)
    $prefix=[IO.Path]::GetFullPath($SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $zip=[IO.Compression.ZipFile]::Open($ArchivePath,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach($item in Get-ChildItem -LiteralPath $prefix -Recurse -File | Sort-Object FullName){
            # .NET Framework's CreateFromDirectory writes Windows backslashes in ZIP member names.
            # Explicit entry names must use ZIP's portable '/' separator on every host.
            $entryName=$item.FullName.Substring($prefix.Length+1).Replace('\','/')
            if($entryName.Contains('\')){throw 'ZIP member name is not portable.'}
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,$item.FullName,$entryName,[IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {$zip.Dispose()}
}
$root=Split-Path $PSScriptRoot -Parent
$output=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force|Out-Null
$id=[Guid]::NewGuid().ToString('N')
$stage=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-package-'+$id)
$archive=Join-Path $output ('FastLLM-lab-'+$id+'.zip')
$setupStage=Join-Path ([IO.Path]::GetTempPath()) ('fast-llm-setup-package-'+$id)
$setupArchive=Join-Path $output ('FastLLM-lab-'+$id+'-setup.zip')
New-Item -ItemType Directory -Path $stage|Out-Null
try {
    $files=@(
        'FastLLM.cmd','Install-FastLLM-Lab.cmd','fast-llm-ui.ps1','fast-llm.ps1','README.md','SECURITY.md','THIRD_PARTY_NOTICES.md',
        'config/catalog.json','config/catalog.sha256','config/driver-guidance.json','config/windows-prerequisites.json',
        'config/experiments/lemonade-hip-b1339-gfx110x.json',
        'tools/benchmark.ps1','tools/soak.ps1','tools/offload-lab.ps1','tools/offload-benchmark.ps1',
        'tools/semantic-smoke.ps1','tools/collect-prerequisite-inventory.ps1','tools/collect-smbios-memory.ps1','tools/prepare-vc-runtime.ps1','tools/install-vc-runtime.ps1','tools/install-lab-app.ps1',
        'tools/collect-ggml-vulkan-identity.ps1','tools/collect-ggml-vulkan-capabilities.ps1','tools/collect-pci-identity-join.ps1',
        'tools/collect-windows-vulkan-pnp-bridge.ps1','tools/collect-vulkan-driver-modules.ps1','tools/vulkan-coopmat-screen.ps1',
        'tools/probe-lemonade-hip-b1339.ps1','tools/hip-candidate-native-worker.ps1',
        'tools/hip-model-trial.ps1','tools/hip-benchmark.ps1','tools/hip-semantic-smoke.ps1','tools/hip-soak.ps1',
        'tools/vulkan-fit-trial.ps1','tools/vulkan-fit-benchmark.ps1'
    )
    foreach($directory in @('src','docs')){
        $extensions=if($directory -eq 'src'){@('.ps1','.psm1','.cs')}else{@('.md')}
        foreach($item in Get-ChildItem (Join-Path $root $directory) -Recurse -File | Where-Object Extension -in $extensions){$files+=$item.FullName.Substring($root.Length+1).Replace('\','/')}
    }
    $manifest=@()
    foreach($relative in $files){
        $source=Join-Path $root $relative;$item=Get-Item -LiteralPath $source -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Cannot package reparse-point sources.'}
        $target=Join-Path $stage $relative
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $target
        $manifest+=[ordered]@{path=$relative;sizeBytes=$item.Length;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    [ordered]@{
        schemaVersion=1;kind='unsigned-private-windows-lab-package';physicalQualification=$false;publicReleaseApproved=$false
        generatedAt=(Get-Date).ToUniversalTime().ToString('o');sourceLicenseDecision='pending-bitworks';files=$manifest
    }|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $stage 'PACKAGE-MANIFEST.json') -Encoding UTF8
    New-FastLlmPortableSourceZip -SourceRoot $stage -ArchivePath $archive
    $digest=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$digest  $([IO.Path]::GetFileName($archive))"|Set-Content -LiteralPath ($archive+'.sha256') -Encoding ASCII
    Write-Host "Created unsigned lab package: $archive"
    Write-Host 'No engine/model binaries, credentials, telemetry, or public-release approval are bundled.'

    # This small companion is obtained/reviewed independently of the full ZIP.
    # Its own manifest/sidecar cannot authenticate a publisher or the app ZIP.
    $setupSources=@(
        [ordered]@{source='Install-FastLLM-Lab.cmd';path='Install-FastLLM-Lab.cmd'},
        [ordered]@{source='tools/install-lab-app.ps1';path='tools/install-lab-app.ps1'},
        [ordered]@{source='src/FastLlm.LabApp.ps1';path='src/FastLlm.LabApp.ps1'},
        [ordered]@{source='tools/lab-setup-README.md';path='README-SETUP.md'}
    )
    if(Test-Path -LiteralPath (Join-Path $root 'src/LabPackage.cs') -PathType Leaf){
        $setupSources+=([ordered]@{source='src/LabPackage.cs';path='src/LabPackage.cs'})
    }
    New-Item -ItemType Directory -Path $setupStage|Out-Null
    $setupManifest=@()
    foreach($entry in $setupSources){
        $source=Join-Path $root $entry.source
        $item=Get-Item -LiteralPath $source -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Cannot package reparse-point setup sources.'}
        $target=Join-Path $setupStage $entry.path
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force|Out-Null
        Copy-Item -LiteralPath $source -Destination $target
        $setupManifest+=[ordered]@{path=$entry.path;sizeBytes=$item.Length;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    [ordered]@{
        schemaVersion=1;kind='unsigned-private-windows-lab-setup';physicalQualification=$false;publicReleaseApproved=$false
        publisherAuthenticated=$false;generatedAt=(Get-Date).ToUniversalTime().ToString('o')
        sourceLicenseDecision='pending-bitworks';appZipDigestIncluded=$false;files=$setupManifest
    }|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $setupStage 'SETUP-MANIFEST.json') -Encoding UTF8
    New-FastLlmPortableSourceZip -SourceRoot $setupStage -ArchivePath $setupArchive
    $setupDigest=(Get-FileHash -LiteralPath $setupArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$setupDigest  $([IO.Path]::GetFileName($setupArchive))"|Set-Content -LiteralPath ($setupArchive+'.sha256') -Encoding ASCII
    Write-Host "Created unsigned setup source bundle: $setupArchive"
    Write-Host 'Trust setup source independently; neither ZIP sidecar authenticates a publisher.'
}finally{
    if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
    if(Test-Path -LiteralPath $setupStage){Remove-Item -LiteralPath $setupStage -Recurse -Force}
}
