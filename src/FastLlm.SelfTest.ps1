# Post-load self-test (public-release spec §4.3, Amendment 3): one discarded warm-up and two measured runs of a 512-token prompt
# with 128 generated tokens. Server-reported timings only. Never stores prompt or completion text.
Set-StrictMode -Version 2
$script:FastLlmSelfTestPromptTokens = 512
$script:FastLlmSelfTestGenerationTokens = 128
$script:FastLlmSelfTestRequestTimeoutMs = 120000

function Get-FastLlmMedian {
    param([double[]] $Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    if ($sorted.Count % 2 -eq 1) { return [double] $sorted[[int](($sorted.Count - 1) / 2)] }
    return ([double] $sorted[$sorted.Count / 2 - 1] + [double] $sorted[$sorted.Count / 2]) / 2
}

function Get-FastLlmSelfTestVerdict {
    param([object[]] $Samples, [int] $GenerationTokens = 128, $Expected, [string] $EngineBuild, [int] $ContextSize, [string] $MitigationEffective)
    $result = [ordered]@{ status = 'pass'; reasons = @(); generationTokS = $null; promptTokS = $null; firstTextMs = $null; expectedGenerationTokS = $null; comparable = $false }
    $all = @($Samples | Where-Object { $null -ne $_ })
    $valid = @($all | Where-Object { [int] $_.outputTokens -ge $GenerationTokens -and [double] $_.generationTokensPerSecond -gt 0 -and [double] $_.promptTokensPerSecond -gt 0 })
    if ($all.Count -lt 2 -or $valid.Count -lt $all.Count) { $result.status = 'fail'; $result.reasons = @('incomplete-generation'); return [pscustomobject] $result }
    $result.generationTokS = [Math]::Round((Get-FastLlmMedian @($valid | ForEach-Object { [double] $_.generationTokensPerSecond })), 2)
    $result.promptTokS = [Math]::Round((Get-FastLlmMedian @($valid | ForEach-Object { [double] $_.promptTokensPerSecond })), 1)
    $first = @($valid | Where-Object { $_.PSObject.Properties['timeToFirstTextMs'] -and $null -ne $_.timeToFirstTextMs } | ForEach-Object { [double] $_.timeToFirstTextMs })
    if ($first.Count) { $result.firstTextMs = [Math]::Round((Get-FastLlmMedian $first), 0) }
    if ($Expected) {
        $mitigation = 'off'
        if ($Expected.PSObject.Properties['mitigation'] -and $Expected.mitigation) { $mitigation = [string] $Expected.mitigation }
        $result.expectedGenerationTokS = [double] $Expected.generationTokS
        $result.comparable = ([string] $Expected.engineBuild -eq $EngineBuild) -and ([int] $Expected.contextTokens -ge $ContextSize) -and ($mitigation -eq $MitigationEffective)
        if ($result.comparable -and $result.generationTokS -lt 0.70 * [double] $Expected.generationTokS) {
            $result.status = 'below-expected'
            $result.reasons = @('driver-version', 'resizable-bar', 'other-apps-using-vram', 'power-or-thermal-limits')
        }
    }
    return [pscustomobject] $result
}

function Invoke-FastLlmSelfTest {
    param([string] $BaseUrl, [int] $ContextSize, $Expected, [string] $EngineBuild, [string] $MitigationEffective, [scriptblock] $Request)
    $fail = { param($reason) [pscustomobject] [ordered]@{ status = 'fail'; reasons = @($reason); generationTokS = $null; promptTokS = $null; firstTextMs = $null
            expectedGenerationTokS = $null; comparable = $false; promptArtifactSha256 = $null; measuredAt = (Get-Date).ToUniversalTime().ToString('o') } }
    $promptTokens = $script:FastLlmSelfTestPromptTokens
    $generation = $script:FastLlmSelfTestGenerationTokens
    # A context too small for the workload (512 prompt + 128 generated + 8 overhead = 648) is not a failure: a valid small-context start is not stopped.
    if ($ContextSize -gt 0 -and $promptTokens + $generation + 8 -gt $ContextSize) {
        $skipped = & $fail 'context-too-small'
        $skipped.status = 'skipped'
        return $skipped
    }
    $send = { param($Path, $Body, $TimeoutMs)
        if ($Request) { return (& $Request $Path $Body $TimeoutMs) }
        return (Invoke-FastLlmHttp -BaseUrl $BaseUrl -Path $Path -Body $Body -TimeoutMs $TimeoutMs) }
    try {
        # Same fixed corpus as the throughput canary and the benchmark producer (fastllm-repeated-prose-v1).
        $corpus = ('A local inference system should produce accurate useful answers. Measure speed consistently while preserving model quality. ' + [Environment]::NewLine) * ([int][Math]::Ceiling($promptTokens / 16) + 2)
        $tokenized = & $send '/tokenize' @{ content = $corpus; add_special = $false } 20000
        if ($tokenized.Status -ne 200) { return (& $fail 'tokenize-failed') }
        $tokens = @((ConvertFrom-Json $tokenized.Body).tokens)
        if ($tokens.Count -lt $promptTokens) { return (& $fail 'corpus-too-short') }
        $prompt = @($tokens[0..($promptTokens - 1)])
        $completion = @{ prompt = $prompt; n_predict = $generation; temperature = 0; seed = 42; cache_prompt = $false; ignore_eos = $true; stream = $true }
        $samples = @()
        foreach ($round in 0..2) {
            try {
                $response = & $send '/completion' $completion $script:FastLlmSelfTestRequestTimeoutMs
                $sample = ConvertFrom-FastLlmBenchmarkResponse $response $generation
            }
            catch {
                if (Test-FastLlmCanaryTimeout $_) { return (& $fail 'timeout') }
                return (& $fail 'request-failed')
            }
            if ($round -gt 0) { $samples += $sample }   # round 0 is the discarded warm-up
        }
        $verdict = Get-FastLlmSelfTestVerdict -Samples $samples -GenerationTokens $generation -Expected $Expected -EngineBuild $EngineBuild -ContextSize $ContextSize -MitigationEffective $MitigationEffective
        $verdict | Add-Member -NotePropertyName promptArtifactSha256 -NotePropertyValue (Get-FastLlmPromptArtifactSha256 $prompt)
        $verdict | Add-Member -NotePropertyName measuredAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o'))
        return $verdict
    }
    catch { return (& $fail 'self-test-error') }
}
