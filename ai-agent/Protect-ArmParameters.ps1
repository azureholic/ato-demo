#Requires -Version 7.4
param([Parameter(Mandatory)][string]$Path)

$parameters = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
$settings = $parameters.parameters.additionalAppConfigurationSettings.value
if ($settings -isnot [array]) { throw 'Expected composed additionalAppConfigurationSettings array.' }
foreach ($setting in $settings) {
    if ($setting.value -isnot [string]) { throw 'Expected an App Configuration string value.' }
    if ($setting.value.StartsWith('[')) { $setting.value = '[' + $setting.value }
}
$parameters | ConvertTo-Json -Depth 100 -WarningAction Stop | Set-Content -LiteralPath $Path
