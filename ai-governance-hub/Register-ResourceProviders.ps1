#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string[]]$Namespaces = @('Microsoft.AlertsManagement', 'Microsoft.Web'),

    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 900,

    [ValidateRange(1, 60)]
    [int]$PollIntervalSeconds = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($SubscriptionId -eq [guid]::Empty) { throw 'SubscriptionId must not be empty.' }

function Get-RegistrationState {
    param([string]$Namespace)
    $registrationState = & az provider show --subscription $SubscriptionId --namespace $Namespace --query registrationState --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Unable to read registration state for $Namespace." }
    if ($registrationState -notin 'Registered', 'Registering', 'NotRegistered', 'Unregistering') {
        throw "Unexpected registration state for ${Namespace}: '$registrationState'."
    }
    return $registrationState
}

$pending = [Collections.Generic.List[string]]::new()
foreach ($namespace in ($Namespaces | Select-Object -Unique)) {
    if ($namespace -notmatch '^Microsoft\.[A-Za-z0-9]+$') { throw "Invalid provider namespace: $namespace." }
    $registrationState = Get-RegistrationState $namespace
    Write-Host "${namespace}: $registrationState"
    if ($registrationState -eq 'Registered') { continue }
    if ($registrationState -eq 'Unregistering') { throw "$namespace is unregistering; resolve this before deployment." }
    if ($registrationState -eq 'NotRegistered') {
        & az provider register --subscription $SubscriptionId --namespace $namespace --output none
        if ($LASTEXITCODE -ne 0) { throw "Registration request failed for $namespace." }
    }
    $pending.Add($namespace)
}

$timer = [Diagnostics.Stopwatch]::StartNew()
while ($pending.Count -gt 0) {
    foreach ($namespace in @($pending.ToArray())) {
        $registrationState = Get-RegistrationState $namespace
        Write-Host "${namespace}: $registrationState"
        if ($registrationState -eq 'Registered') {
            $pending.Remove($namespace) | Out-Null
        } elseif ($registrationState -eq 'Unregistering') {
            throw "$namespace began unregistering while waiting for registration."
        }
    }
    if ($pending.Count -eq 0) { break }
    if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        throw "Provider registration timed out after $TimeoutSeconds seconds: $($pending -join ', ')."
    }
    Start-Sleep -Seconds $PollIntervalSeconds
}
Write-Host 'Required resource providers are registered.'
