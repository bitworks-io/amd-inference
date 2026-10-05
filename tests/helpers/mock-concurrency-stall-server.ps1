#requires -Version 5.1
param([Parameter(Mandatory=$true)][int]$Port)
$ErrorActionPreference='Stop'
$listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,$Port)
$listener.Start()
try {
    while($true){
        $client=$listener.AcceptTcpClient()
        try {Start-Sleep -Seconds 30} finally {$client.Dispose()}
    }
} finally {$listener.Stop()}
