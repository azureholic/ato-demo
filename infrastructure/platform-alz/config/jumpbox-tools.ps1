# Runs on the jumpbox through an Azure run command (Windows PowerShell 5.1). Idempotent.
# __TARGETS__ is replaced by Invoke-PlatformJumpbox.ps1 with the endpoints from jumpbox.json.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = 'C:\ProgramData\jumpbox'
New-Item $dir -ItemType Directory -Force | Out-Null

@'
# Shows whether the private gateway and Foundry endpoints resolve to private addresses and answer over HTTPS.
param([string[]]$Hosts = @(__TARGETS__))
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($h in $Hosts) {
    $ip = (Resolve-DnsName $h -Type A -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1).IPAddress
    try { $code = [int](Invoke-WebRequest "https://$h/" -UseBasicParsing -TimeoutSec 20).StatusCode }
    catch { $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
    $scope = if (-not $ip) { 'unresolved' } elseif ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { 'private' } else { 'PUBLIC' }
    '{0} -> {1} [{2}] HTTPS GET / => {3:000}' -f $h, $(if ($ip) { $ip } else { 'none' }), $scope, $code
}
'@ | Set-Content -Path (Join-Path $dir 'hub-check.ps1') -Encoding UTF8

# Desktop shortcut so the check is one double-click away.
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut('C:\Users\Public\Desktop\Hub connectivity check.lnk')
$link.TargetPath = 'powershell.exe'
$link.Arguments = "-NoExit -ExecutionPolicy Bypass -File `"$dir\hub-check.ps1`""
$link.Save()

$cli = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
if (-not (Test-Path $cli)) {
    $msi = Join-Path $env:TEMP 'azure-cli.msi'
    Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindowsx64' -OutFile $msi -UseBasicParsing
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "The Azure CLI installer failed with exit code $($process.ExitCode)." }
    Remove-Item $msi -Force
}
$version = (& $cli version --output json | ConvertFrom-Json).'azure-cli'
"azure-cli installed: $version"
