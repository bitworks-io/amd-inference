#requires -Version 5.1
param([int]$Port,[string]$Mode,[string]$LogPath,[string]$StatusPath,[string]$OriginalRunId,
      [string]$TransportProbePath)
$ErrorActionPreference='Stop'
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
$listener.Start()
$completionCountBySize=@{}
try {
    while ($true) {
        $client=$listener.AcceptTcpClient()
        try {
            if($TransportProbePath){[IO.File]::AppendAllText($TransportProbePath,"accepted`n")}
            $client.ReceiveTimeout=3000
            $stream=$client.GetStream()
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$false,1024,$true)
            try { $first=$reader.ReadLine() }
            catch [IO.IOException] { continue }
            catch [Net.Sockets.SocketException] { continue }
            if (-not $first) { continue }
            $path=($first -split ' ')[1]
            $length=0
            $peerReadFailed=$false
            while ($true) {
                try { $line=$reader.ReadLine() }
                catch [IO.IOException] { $peerReadFailed=$true;break }
                catch [Net.Sockets.SocketException] { $peerReadFailed=$true;break }
                if (-not $line) { break }
                if ($line -match '^Content-Length:\s*(\d+)') { $length=[int]$Matches[1] }
            }
            if($peerReadFailed){continue}
            if ($length -gt 32768) { throw 'Oversize mock request.' }
            $chars=New-Object char[] $length
            $read=0
            while ($read -lt $length) {
                try { $n=$reader.Read($chars,$read,$length-$read) }
                catch [IO.IOException] { $peerReadFailed=$true;break }
                catch [Net.Sockets.SocketException] { $peerReadFailed=$true;break }
                if ($n -le 0) { throw 'Truncated mock request.' }
                $read+=$n
            }
            if($peerReadFailed){continue}
            $bodyText=-join $chars
            $status=200
            $contentType='application/json'
            if ($path -eq '/disconnect-probe') {
                if (-not $LogPath) { throw 'Mock disconnect probe requires a signal path.' }
                [IO.File]::WriteAllText($LogPath,'ready')
                Start-Sleep -Milliseconds 300
                # Large enough that an RST peer cannot just absorb a buffered write.
                $response='x'*1048576
            }
            elseif ($path -eq '/health') { $response='{"status":"ok"}' }
            elseif ($path -eq '/tokenize') {
                $request=$bodyText|ConvertFrom-Json
                if ($request.add_special -ne $false -or [string]$request.content -notmatch 'A local inference system') { throw 'Unexpected tokenize request.' }
                Add-Content -LiteralPath $LogPath -Value 'TOKENIZE' -Encoding ASCII
                if ($Mode -eq 'invalid-token') { $response='{"tokens":['+(('1.5,'*63)+'1.5')+']}' }
                else { $response='{"tokens":['+((1..64) -join ',')+']}' }
            }
            elseif ($path -eq '/completion') {
                $request=$bodyText|ConvertFrom-Json
                $ids=@($request.prompt)
                if ($ids.Count -notin @(16,32) -or $request.n_predict -ne 8 -or $request.temperature -ne 0 -or $request.seed -ne 42 -or $request.cache_prompt -ne $false -or $request.ignore_eos -ne $true -or $request.stream -ne $true) { throw 'Unexpected completion workload.' }
                for ($i=0;$i -lt $ids.Count;$i++) {
                    if (($ids[$i] -isnot [int] -and $ids[$i] -isnot [long]) -or [long]$ids[$i] -ne $i+1) { throw 'Completion prompt numeric token array changed.' }
                }
                Add-Content -LiteralPath $LogPath -Value ($ids.Count.ToString()+':'+($ids -join ',')) -Encoding ASCII
                if(-not $completionCountBySize.ContainsKey($ids.Count)){$completionCountBySize[$ids.Count]=0}
                $completionCountBySize[$ids.Count]++
                if ($Mode -eq 'change-run') {
                    $state=[IO.File]::ReadAllText($StatusPath)
                    if ($state.Contains($OriginalRunId)) { [IO.File]::WriteAllText($StatusPath,$state.Replace($OriginalRunId,('f'*32))) }
                }
                $contentType='text/event-stream'
                $reportedPrompt=[string]$ids.Count
                $reportedPredicted='8'
                $reportedDuration='200'
                if($Mode -eq 'fractional-prompt'){$reportedPrompt="$($ids.Count).5"}
                if($Mode -eq 'fractional-predicted'){$reportedPredicted='8.5'}
                if($Mode -eq 'string-duration'){$reportedDuration='"200"'}
                if($Mode -eq 'mixed-evaluated' -and $completionCountBySize[$ids.Count] -ge 2){$reportedPrompt=[string]($ids.Count+1)}
                $final="data: {`"content`":`"`",`"stop`":true,`"timings`":{`"prompt_n`":$reportedPrompt,`"prompt_ms`":100,`"predicted_n`":$reportedPredicted,`"predicted_ms`":$reportedDuration}}`n`n"
                if($Mode -eq 'string-stop'){$final=$final.Replace('"stop":true','"stop":"false"')}
                $response="data: {`"content`":`"synthetic-completion-text-SECRET`",`"stop`":false}`n`n"+$final
                if($Mode -eq 'duplicate-final'){$response+=$final}
                $response+="data: [DONE]`n`n"
            }
            else { $status=404; $response='{}' }
            $bytes=[Text.Encoding]::UTF8.GetBytes($response)
            $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status OK`r`nContent-Length: $($bytes.Length)`r`nContent-Type: $contentType`r`nConnection: close`r`n`r`n")
            try {
                $stream.Write($header,0,$header.Length)
                $stream.Write($bytes,0,$bytes.Length)
            } catch [IO.IOException] {
                # A probe or timed-out client may close its socket after a valid
                # request. This peer's failed response must not kill the fixture.
            } catch [Net.Sockets.SocketException] {
                # Some runtimes surface the same peer reset directly.
            }
        } finally { $client.Dispose() }
    }
} finally { $listener.Stop() }
