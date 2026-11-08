#requires -Version 5.1
# Connection info, client cards and the user-run API-format check. Mock request only: no engine, GPU or network.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/FastLlm.psm1') -Force -ErrorAction Stop
. (Join-Path $root 'src/FastLlm.ServingSettings.ps1')
. (Join-Path $root 'src/FastLlm.ConnectInfo.ps1')
$script:count=0
function Check($Condition,[string]$Message){if(-not $Condition){throw "FAIL: $Message"};$script:count++;Write-Host "PASS: $Message"}
function New-Status([int]$Port,[int]$Context,[string]$Model='fastllm-test-model'){
    [pscustomobject]@{ phase='ready'; active=$true; runId='aabbccdd11223344aabbccdd11223344'; modelId=$Model; endpoint="http://127.0.0.1:$Port/v1"
        recipe=[pscustomobject]@{ catalogVersion='1'; contextSize=$Context; id=$null } }
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('connect-info-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    # agent-warning-below-32k
    $small=Get-FastLlmConnectionInfo -Status (New-Status 8080 16384)
    Check ($small.contextTokens -eq 16384) 'agent-warning-below-32k: context read from recipe.contextSize'
    Check ($small.agentWarning -and $small.agentWarning.Contains('16,384') -and $small.agentWarning.Contains('refused')) 'agent-warning-below-32k: 16384 warns with 16,384 and refused'
    Check ($small.agentWarning -ceq "This setup's context is 16,384 tokens. Coding agents such as Claude Code, Codex, Cline and Roo Code often send longer requests; those requests are refused with an error.") 'agent-warning-below-32k: exact text'
    $edge=Get-FastLlmConnectionInfo -Status (New-Status 8080 32768)
    Check ($null -eq $edge.agentWarning) 'agent-warning-below-32k: 32768 gives no warning'
    Check ($null -ne (Get-FastLlmConnectionInfo -Status (New-Status 8080 32767)).agentWarning) 'agent-warning-below-32k: 32767 warns'
    foreach($client in $small.clients){ Check ($client.snippet.Contains('Requests longer than 16,384 tokens are refused.')) "limit line in the $($client.id) snippet" }

    # no-claim-of-agent-support
    $agents='Claude Code|Codex|Cline|Roo Code|Continue|Open WebUI'
    foreach($client in $small.clients){
        Check ($client.snippet -notmatch '(?i)works? with' -and $client.snippet -notmatch '(?i)supported') "no-claim-of-agent-support: $($client.id) snippet"
    }
    $allText=(@($small.clients|ForEach-Object{$_.title+' '+$_.snippet}) -join ' ')+' '+$small.agentWarning+' '+(@($small.endpoints|ForEach-Object{$_.label}) -join ' ')
    Check ($allText -notmatch "(?i)(works with|supported by|compatible with|supports|certified)\W+(\w+\W+){0,2}($agents)") 'no-claim-of-agent-support: no agent name follows a support phrase'
    $claude=@($small.clients|Where-Object id -ceq 'claude-code')[0]
    Check ($claude.snippet.Contains("Claude Code is designed for Anthropic's Claude models; results with a local model may vary.")) 'claude-code card carries the exact designed-for note'
    Check ($claude.snippet -notmatch '(?i)does not support|doesn''t support|not support') 'claude-code card does not contain "does not support"'
    Check ($claude.snippet.Contains('ANTHROPIC_BASE_URL = "http://127.0.0.1:8080"')) 'claude-code card base URL has no /v1'

    Check ($claude.snippet -notmatch 'documentation describes') 'claude-code card attributes no instruction to the docs'
    Check ($claude.snippet.Contains('FastLLM serves the model as fastllm-test-model.')) 'claude-code card states only the served name'

    # responses-labelled-partial
    $responses=@($small.endpoints|Where-Object path -ceq '/v1/responses')[0]
    Check ($responses.label -ceq '/v1/responses: partial at this engine version') 'responses-labelled-partial: endpoint label'
    $codex=@($small.clients|Where-Object id -ceq 'codex')[0]
    Check ($codex.snippet.Contains('wire_api = "responses"') -and $codex.snippet.Contains('/v1/responses: partial at this engine version')) 'responses-labelled-partial: codex card'
    Check (@($small.endpoints|ForEach-Object{$_.path}) -join ',' -ceq '/v1/chat/completions,/v1/completions,/v1/models,/v1/messages,/v1/responses') 'endpoint list is the fixed five'
    Check (@($small.endpoints|Where-Object path -ceq '/v1/messages')[0].label -ceq 'Anthropic-compatible') 'messages endpoint labelled Anthropic-compatible'

    # every-card-has-doc-url
    Check (@($small.clients|ForEach-Object{$_.id}) -join ',' -ceq 'openai-compatible,open-webui,continue,cline-roo,claude-code,codex') 'client ids and order'
    foreach($client in $small.clients){
        Check (-not [string]::IsNullOrWhiteSpace($client.docUrl) -and $client.docUrl.StartsWith('https://')) "every-card-has-doc-url: $($client.id)"
    }
    foreach($constant in $script:FastLlmConnectClients){
        Check (-not [string]::IsNullOrWhiteSpace([string]$constant.docUrl) -and ([string]$constant.docUrl).StartsWith('https://')) "every-card-has-doc-url: constant $($constant.id)"
        $text=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.ConnectInfo.ps1') -Raw
        Check ($text -match ('(?m)^\s*#.*'+[regex]::Escape([string]$constant.docUrl))) "every-card-has-doc-url: $($constant.id) URL also sits in a comment"
    }

    Check ($codex.snippet.Contains("base_url ends in /v1 because FastLLM serves the Responses API at /v1/responses; the Codex documentation's example has no path.")) 'codex card labels the /v1 as FastLLM''s own reasoning'
    Check ($codex.snippet.Contains("FastLLM's own fact: it sets no key")) 'codex card labels the any-text key as FastLLM''s own fact'

    # connection-follows-port
    $moved=Get-FastLlmConnectionInfo -Status (New-Status 18181 16384)
    Check ($moved.baseUrl -ceq 'http://127.0.0.1:18181/v1' -and $moved.anthropicBaseUrl -ceq 'http://127.0.0.1:18181') 'connection-follows-port: base URLs'
    foreach($client in $moved.clients){
        Check ($client.snippet.Contains('127.0.0.1:18181')) "connection-follows-port: $($client.id) mentions 18181"
        Check ($client.snippet -notmatch '8080') "connection-follows-port: $($client.id) has no 8080"
    }
    Check ($moved.modelName -ceq 'fastllm-test-model') 'modelName is status.modelId'

    # not running: the configured port, no context
    $r=Join-Path $work 'cfg'; New-Item -ItemType Directory -Path $r | Out-Null
    Set-FastLlmServingSettings -InstallRoot $r -ServerPort 19191
    $idle=Get-FastLlmConnectionInfo -Status ([pscustomobject]@{ phase='stopped'; active=$false }) -InstallRoot $r
    Check ($idle.state -ceq 'not running' -and $idle.baseUrl -ceq 'http://127.0.0.1:19191/v1' -and $null -eq $idle.contextTokens -and $null -eq $idle.modelName) 'not running: configured endpoint, no context, no model'
    $unknownNotice='FastLLM is not running, so the context limit is not known yet. Coding agents often send requests longer than 32,768 tokens; check the limit after FastLLM starts.'
    Check ($idle.agentWarning -ceq $unknownNotice) 'unknown-context-notice: not running shows the fixed line'
    Check ((ConvertTo-Json $idle -Depth 5).Contains('check the limit after FastLLM starts.')) 'unknown-context-notice: it is in the status JSON'
    Check ($null -eq (Get-FastLlmConnectionInfo -Status (New-Status 8080 65536)).agentWarning -and $small.agentWarning -cne $unknownNotice) 'unknown-context-notice: known context never shows it'
    Check (@($idle.clients).Count -eq 6) 'not running: all cards still built'

    # estimated-setup-has-context
    $estimated=[pscustomobject]@{ phase='ready'; active=$true; modelId='est-model'; endpoint='http://127.0.0.1:8080/v1'
        recipe=[pscustomobject]@{ catalogVersion='3'; contextSize=16384; id='estimated-8gb'; origin='estimated' } }
    $est=Get-FastLlmConnectionInfo -Status $estimated
    Check ($est.contextTokens -eq 16384 -and $est.agentWarning) 'estimated-setup-has-context: context and warning from an estimated 8 GB plan'

    # connection-info-old-status
    $old=[pscustomobject]@{ schemaVersion=1; runId='abc'; phase='ready'; active=$true; modelId='old-model'; endpoint='http://127.0.0.1:8080/v1' }
    $oldInfo=$null; $threw=$false
    try{ $oldInfo=Get-FastLlmConnectionInfo -Status $old }catch{ $threw=$true }
    Check (-not $threw -and $oldInfo.modelName -ceq 'old-model' -and $null -eq $oldInfo.contextTokens -and $oldInfo.agentWarning -ceq $unknownNotice) 'connection-info-old-status: no exception, no context'
    foreach($bad in @($null,[pscustomobject]@{},[pscustomobject]@{active='yes';endpoint=5;modelId=7;recipe='x'},[pscustomobject]@{active=$true;endpoint='http://evil.example/v1';recipe=[pscustomobject]@{contextSize='many'}})){
        $threw=$false; $badInfo=$null
        try{ $badInfo=Get-FastLlmConnectionInfo -Status $bad }catch{ $threw=$true }
        Check (-not $threw -and $badInfo.baseUrl.StartsWith('http://127.0.0.1:')) 'connection-info-old-status: odd status shapes are tolerated and stay on loopback'
    }

    # apicheck-records-no-text
    $marker='MARKER-ZEBRA-7731'
    $script:seen=@()
    $mock={
        param($Root,$Path,$Body,$TimeoutMs)
        $script:seen+=,@($Root,$Path,$Body)
        $reply=switch($Path){
            '/v1/chat/completions'{@{choices=@(@{message=@{role='assistant';content=$marker}});usage=@{prompt_tokens=11;completion_tokens=3}}}
            '/v1/messages'{@{content=@(@{type='text';text=$marker});usage=@{input_tokens=12;output_tokens=4}}}
            '/v1/responses'{@{output=@(@{type='message';content=@(@{type='output_text';text=$marker})});usage=@{input_tokens=13;output_tokens=5}}}
        }
        [pscustomobject]@{ Status=200; Body=(ConvertTo-Json $reply -Depth 8 -Compress); ElapsedMs=7.5 }
    }
    $result=Invoke-FastLlmApiCheck -BaseUrl 'http://127.0.0.1:8080/v1' -ModelName 'm' -Request $mock
    $json=ConvertTo-Json $result -Depth 6
    Check (-not $json.Contains($marker)) 'apicheck-records-no-text: marker absent from the result'
    Check (@($result.checks).Count -eq 3 -and (@($result.checks|Where-Object status -ceq 'pass').Count -eq 3)) 'api check: three passes'
    Check ($result.checks[0].promptTokens -eq 11 -and $result.checks[0].completionTokens -eq 3 -and $result.checks[1].promptTokens -eq 12 -and $result.checks[2].completionTokens -eq 5) 'api check: usage read per API shape'
    Check ((@($result.checks[0].PSObject.Properties.Name) -join ',') -ceq 'endpoint,status,httpStatus,promptTokens,completionTokens,elapsedMs') 'api check: only the six recorded fields'
    Check ((@($script:seen|ForEach-Object{$_[1]}) -join ',') -ceq '/v1/chat/completions,/v1/messages,/v1/responses' -and $script:seen[0][0] -ceq 'http://127.0.0.1:8080') 'api check: three formats in order against the host without /v1'
    Check (@($script:seen|Where-Object{ $b=$_[2]; $cap=$(if($b.ContainsKey('max_tokens')){$b['max_tokens']}else{$b['max_output_tokens']}); $b['stream'] -ne $false -or $cap -ne 16 }).Count -eq 0) 'api check: non-streaming with 16 tokens'
    $logRoot=Join-Path $work 'logs'; New-Item -ItemType Directory -Path $logRoot | Out-Null
    $runId='aabbccdd11223344aabbccdd11223344'
    Write-FastLlmApiCheckRunLog -InstallRoot $logRoot -RunId $runId -Result $result
    $logFiles=@(Get-ChildItem -LiteralPath $logRoot -Recurse -Filter '*.jsonl')
    Check ($logFiles.Count -eq 1) 'apicheck-records-no-text: a run log file was written'
    $logText=Get-Content -LiteralPath $logFiles[0].FullName -Raw
    $logLines=@($logText -split "`n"|Where-Object{$_.Trim()})
    Check (-not $logText.Contains($marker) -and $logLines.Count -eq 3 -and $logText.Contains('"event":"api-check"') -and $logText.Contains('/v1/responses')) 'apicheck-records-no-text: marker absent from the run log; one event per endpoint'

    # failures are recorded as fail without text
    $failMock={ param($Root,$Path,$Body,$TimeoutMs)
        if($Path -ceq '/v1/messages'){ throw "boom $marker" }
        if($Path -ceq '/v1/responses'){ return [pscustomobject]@{Status=400;Body="{""error"":""$marker""}";ElapsedMs=2} }
        [pscustomobject]@{Status=200;Body='{"choices":[]}';ElapsedMs=1} }
    $bad=Invoke-FastLlmApiCheck -BaseUrl 'http://127.0.0.1:8080' -ModelName 'm' -Request $failMock
    Check ((@($bad.checks|ForEach-Object{$_.status}) -join ',') -ceq 'fail,fail,fail' -and $bad.checks[1].httpStatus -eq $null -and $bad.checks[2].httpStatus -eq 400 -and -not (ConvertTo-Json $bad -Depth 6).Contains($marker)) 'api check: empty choices, thrown error and HTTP 400 are fails and keep no text'

    # structural pass criterion
    foreach($case in @(
        @{ body='{"choices":5}' },@{ body='{"choices":{}}' },@{ body='{"choices":[{}]}' },@{ body='{"choices":[]}' },@{ body='{"choices":["x"]}' },
        @{ body='{"content":[{}]}' },@{ body='{"content":"x"}' },@{ body='{"output":[{}]}' },@{ body='{"output":7}' },@{ body='not json' })){
        $script:caseBody=$case.body
        $oneBad={ param($Root,$Path,$Body,$TimeoutMs) [pscustomobject]@{Status=200;Body=$script:caseBody;ElapsedMs=1} }
        $r=Invoke-FastLlmApiCheck -BaseUrl 'http://127.0.0.1:8080' -ModelName 'm' -Request $oneBad
        Check (@($r.checks|Where-Object status -ceq 'pass').Count -eq 0) "structural check: $($case.body) fails every format"
    }
    $partialOk={ param($Root,$Path,$Body,$TimeoutMs)
        $b=switch($Path){ '/v1/chat/completions'{'{"choices":[{"message":{}}]}'} '/v1/messages'{'{"content":[{"type":"text"}]}'} '/v1/responses'{'{"output":[{"type":"message"}]}'} }
        [pscustomobject]@{Status=200;Body=$b;ElapsedMs=1} }
    $okResult=Invoke-FastLlmApiCheck -BaseUrl 'http://127.0.0.1:8080' -ModelName 'm' -Request $partialOk
    Check (@($okResult.checks|Where-Object status -ceq 'pass').Count -eq 3) 'structural check: object with the expected key passes without any text'
    Check (@($script:seen|Where-Object{$_[1] -ceq '/v1/responses'}|Where-Object{$_[2].ContainsKey('max_tokens')}).Count -eq 0 -and $script:seen[2][2].max_output_tokens -eq 16) 'responses body sends max_output_tokens only'

    # apicheck-refuses-when-not-ready
    $script:called=$false
    $never={ param($Root,$Path,$Body,$TimeoutMs) $script:called=$true; [pscustomobject]@{Status=200;Body='{}';ElapsedMs=1} }
    foreach($notReady in @([pscustomobject]@{phase='stopped';active=$false},[pscustomobject]@{phase='loading';active=$true;modelId='m';endpoint='http://127.0.0.1:8080/v1'},[pscustomobject]@{phase='checking';active=$true})){
        $run=Invoke-FastLlmDoctorApiCheck -InstallRoot $work -Status $notReady -Request $never
        Check ($run.exitCode -ne 0 -and $run.message -ceq 'Start FastLLM and wait for Ready before running the API check.') "apicheck-refuses-when-not-ready: phase $($notReady.phase)"
    }
    Check (-not $script:called) 'apicheck-refuses-when-not-ready: no request was sent'
    $doctorRoot=Join-Path $work 'doctor'; New-Item -ItemType Directory -Path $doctorRoot | Out-Null
    $ready=Invoke-FastLlmDoctorApiCheck -InstallRoot $doctorRoot -Status (New-Status 8080 16384) -Request $mock
    Check ($ready.exitCode -eq 0 -and $null -eq $ready.message -and @($ready.result.checks).Count -eq 3) 'doctor -ApiCheck flow: Ready server runs the check'
    Check (@(Get-ChildItem -LiteralPath $doctorRoot -Recurse -Filter '*.jsonl').Count -eq 1) 'doctor -ApiCheck flow: writes the api-check event'

    # apicheck-not-in-start
    $files=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File)+@(Get-Item (Join-Path $root 'fast-llm.ps1'),(Join-Path $root 'fast-llm-ui.ps1'),(Join-Path $root 'src/FastLlm.psm1'))
    $users=@($files|Where-Object{ (Get-Content -LiteralPath $_.FullName -Raw) -match 'Invoke-FastLlm(Doctor)?ApiCheck' }|ForEach-Object{$_.Name}|Sort-Object -Unique)
    Check (($users -join ',') -ceq 'fast-llm.ps1,FastLlm.ConnectInfo.ps1') "apicheck-not-in-start: only the definitions and the doctor branch name it ($($users -join ','))"
    $entry=Get-Content -LiteralPath (Join-Path $root 'fast-llm.ps1') -Raw
    $doctorAt=$entry.IndexOf("        'doctor' {")
    $guardAt=$entry.IndexOf('if ($ApiCheck) {')
    $callAt=$entry.IndexOf('Invoke-FastLlmDoctorApiCheck')
    Check ($doctorAt -gt 0 -and $guardAt -gt $doctorAt -and $callAt -gt $guardAt -and $entry.IndexOf('Invoke-FastLlmDoctorApiCheck',$callAt+1) -lt 0) 'apicheck-not-in-start: the single call sits behind the -ApiCheck guard in the doctor branch'
    $startAt=$entry.IndexOf("        'start' {")
    Check ($startAt -lt 0 -or $callAt -lt $startAt -or $startAt -lt $doctorAt) 'apicheck-not-in-start: not inside the start branch'
    $ui=Get-Content -LiteralPath (Join-Path $root 'fast-llm-ui.ps1') -Raw
    Check ($ui.Contains("LaunchStep 'api check' (@('doctor','-ApiCheck')") -and $ui.Contains('$connectButton=ButtonAt ''Connect an app'' $rowSlotX[1] $rowY $rowWidth')) 'window runs doctor -ApiCheck as a step; button sits in slot 1'
    $runtime=Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.Runtime.ps1') -Raw
    Check ($runtime -notmatch 'Invoke-FastLlm(Doctor)?ApiCheck' -and (Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw) -notmatch 'Invoke-FastLlm(Doctor)?ApiCheck') 'apicheck-not-in-start: neither the module nor the runtime mention it'

    # entry layer: not in the module
    Check ((Get-Content -LiteralPath (Join-Path $root 'src/FastLlm.psm1') -Raw) -notmatch 'ConnectInfo') 'ConnectInfo is not part of the module'
    Check ($entry.Contains("'FastLlm.ConnectInfo.ps1'") -and $ui.Contains("src/FastLlm.ConnectInfo.ps1")) 'ConnectInfo is dot-sourced by fast-llm.ps1 and fast-llm-ui.ps1'

    # table for the window
    $table=Format-FastLlmApiCheckTable -Result $bad
    Check ($table.Contains('FAIL') -and $table.Contains('no reply') -and -not $table.Contains($marker)) 'window table shows fails and no text'
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "connect-info-tests: $script:count checks passed"
