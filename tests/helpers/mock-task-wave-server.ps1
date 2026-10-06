#requires -Version 5.1
param([Parameter(Mandatory=$true)][int]$Port,[Parameter(Mandatory=$true)][string]$LogPath,
      [string]$AcceptPath,[string]$DisconnectPath)
$ErrorActionPreference='Stop'
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
$listener.Start()
try {
    while($true){
        $client=$listener.AcceptTcpClient()
        try {
            if($AcceptPath){[IO.File]::AppendAllText($AcceptPath,"accepted`n")}
            $client.ReceiveTimeout=5000
            $stream=$client.GetStream()
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$false,1024,$true)
            try {$first=$reader.ReadLine()}
            catch [IO.IOException] {continue}
            catch [Net.Sockets.SocketException] {continue}
            if(-not $first){continue}
            $length=0
            $peerReadFailed=$false
            while($true){
                try {$line=$reader.ReadLine()}
                catch [IO.IOException] {$peerReadFailed=$true;break}
                catch [Net.Sockets.SocketException] {$peerReadFailed=$true;break}
                if(-not $line){break}
                if($line -match '^Content-Length:\s*(\d+)'){$length=[int]$Matches[1]}
            }
            if($peerReadFailed){continue}
            if($length -lt 0 -or $length -gt 4096){throw 'Unexpected mock body length.'}
            $chars=New-Object char[] $length
            $read=0
            $peerDisconnectReason=$null
            while($read -lt $length){
                try {$n=$reader.Read($chars,$read,$length-$read)}
                catch [IO.IOException] {$peerReadFailed=$true;$peerDisconnectReason='body-read-io';break}
                catch [Net.Sockets.SocketException] {$peerReadFailed=$true;$peerDisconnectReason='body-read-socket';break}
                if($n -le 0){$peerReadFailed=$true;$peerDisconnectReason='body-eof';break}
                $read+=$n
            }
            if($peerReadFailed){
                # A client can abort after sending a valid bounded length but
                # before the body arrives (including during startup retries).
                # Discard only this incomplete peer; never log or answer it.
                if($DisconnectPath){[IO.File]::AppendAllText($DisconnectPath,($peerDisconnectReason+"`n"))}
                continue
            }
            $body=-join $chars
            [IO.File]::AppendAllText($LogPath,($body+"`n"),[Text.Encoding]::UTF8)
            if($body -eq 'stall') {Start-Sleep -Milliseconds 1500}
            elseif($body -eq 'slow-fail') {Start-Sleep -Milliseconds 300}
            else {Start-Sleep -Milliseconds 60}
            $status=if($body -eq 'slow-fail'){'503 Unavailable'}else{'200 OK'}
            $payload=[Text.Encoding]::UTF8.GetBytes('{"body":"'+$body+'"}')
            $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: $($payload.Length)`r`nContent-Type: application/json`r`nConnection: close`r`n`r`n")
            try {
                $stream.Write($header,0,$header.Length)
                $stream.Write($payload,0,$payload.Length)
            }catch [IO.IOException] {
                # A timed-out test client may close its connection; keep the
                # fixture alive for the next health request.
            }catch [Net.Sockets.SocketException] {}
        }finally{$client.Dispose()}
    }
}finally{$listener.Stop()}
