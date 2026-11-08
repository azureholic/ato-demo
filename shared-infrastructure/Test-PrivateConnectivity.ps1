#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string[]]$HostNames)
$ErrorActionPreference = 'Stop'
foreach ($hostName in $HostNames) {
    $addresses = [Net.Dns]::GetHostAddresses($hostName)
    if (-not $addresses.Count) { throw "$hostName returned no DNS addresses." }
    foreach ($address in $addresses) {
        $bytes = $address.GetAddressBytes()
        $private = $bytes.Length -eq 4 -and ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168))
        if (-not $private) { throw "$hostName resolves outside RFC1918: $address." }
        $client = [Net.Sockets.TcpClient]::new()
        $stream = $null
        try {
            if (-not $client.ConnectAsync($address, 443).Wait(10000)) { throw "$hostName private TCP connection timed out." }
            $stream = [Net.Security.SslStream]::new($client.GetStream(), $false)
            if (-not $stream.AuthenticateAsClientAsync($hostName).Wait(10000)) { throw "$hostName TLS verification timed out." }
        } finally {
            if ($stream) { $stream.Dispose() }
            $client.Dispose()
        }
    }
    Write-Host "$hostName resolves privately and passes TCP/TLS verification."
}
