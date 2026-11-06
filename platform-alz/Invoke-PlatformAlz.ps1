#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputPath,
    [switch]$RefreshGitHubOidc
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-StrictMode -Version Latest

foreach ($name in 'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
        throw "Missing environment variable: $name."
    }
}
Get-Command az, bicep, Deploy-Accelerator -ErrorAction Stop | Out-Null
Import-Module powershell-yaml -RequiredVersion 0.4.12
$inputsPath = Join-Path $PSScriptRoot 'config\inputs.yaml'
$config = Get-Content $inputsPath -Raw | ConvertFrom-Yaml
$platformConfig = Get-Content (Join-Path $PSScriptRoot 'config\platform-landing-zone.yaml') -Raw | ConvertFrom-Yaml
$settings = Get-Content (Join-Path $PSScriptRoot 'config\templates\smb.json') -Raw | ConvertFrom-Json
if ($config.iac_type -ne 'bicep' -or $config.create_bootstrap_resources_in_azure -ne $false -or
    $settings.tenantId -ne $config.root_parent_management_group_id -or
    $settings.subscriptionId -ne $config.bootstrap_subscription_id -or
    $settings.subscriptionId -ne $config.subscription_ids.management -or
    $settings.subscriptionId -ne $config.subscription_ids.connectivity -or
    $platformConfig.network_type -ne 'hubNetworking' -or
    $platformConfig.management_group_id_prefix -ne '' -or
    $platformConfig.management_group_id_postfix -ne '' -or
    $platformConfig.starter_locations.Count -ne 1 -or
    $settings.location -ne $platformConfig.starter_locations[0] -or
    $settings.location -ne $config.bootstrap_location -or
    $settings.intermediateRootManagementGroupId -ne $platformConfig.management_group_int_root_id) {
    throw 'Bicep bootstrap, platform inputs and SMB parameters must describe the same single-subscription environment without Azure bootstrap creation.'
}
$account = (& az account show --output json) | ConvertFrom-Json
if ($account.tenantId -ne $env:ARM_TENANT_ID -or $account.id -ne $env:ARM_SUBSCRIPTION_ID -or
    $account.tenantId -ne $config.root_parent_management_group_id -or
    $account.id -ne $config.bootstrap_subscription_id) {
    throw 'Azure login and environment must match the repository tenant and subscription configuration.'
}

$outputDirectory = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path $outputDirectory) {
    throw 'Use a fresh output directory. Generated bootstrap files must not reuse the preserved bootstrap state.'
}
$previousTarget = $env:TF_VAR_target_directory
$previousInitArguments = $env:TF_CLI_ARGS_init
try {
    $env:TF_VAR_target_directory = Join-Path $outputDirectory 'platform'
    $env:TF_CLI_ARGS_init = $null
    Deploy-Accelerator -inputConfigFilePaths @(
        $inputsPath
        (Join-Path $PSScriptRoot 'config\platform-landing-zone.yaml')
    ) -starter_additional_files @(
        (Join-Path $PSScriptRoot 'config\templates')
    ) -output $outputDirectory -autoApprove

    $platformDirectory = $env:TF_VAR_target_directory
    $deployScript = Join-Path $platformDirectory 'scripts\deploy-local.ps1'
    if (-not (Test-Path $deployScript -PathType Leaf)) {
        throw "The Accelerator did not generate the expected official local deployment script at '$deployScript'."
    }

    if ($RefreshGitHubOidc) {
        $stackScriptPath = Join-Path $platformDirectory 'scripts\bicep-deploy.ps1'
        $stackScript = Get-Content -LiteralPath $stackScriptPath -Raw
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($stackScript, [ref]$null, [ref]$parseErrors)
        $retryLoops = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.WhileStatementAst] -and
                $node.Condition.Extent.Text -eq '$retryCount -lt $retryMax'
        }, $true))
        $retryHooks = @($retryLoops | ForEach-Object { $_.Body.Statements } | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left.Extent.Text -eq '$result' -and $_.Right.Extent.Text -eq '$null'
        })
        if ($parseErrors -or $retryLoops.Count -ne 1 -or $retryHooks.Count -ne 1) {
            throw 'Expected the pinned deployment retry loop and authentication hook exactly once. Review the upstream script before deployment.'
        }
        # Renew outside the retry catch so authentication failures cannot be swallowed.
        $stackScript = $stackScript.Insert($retryHooks[0].Extent.StartOffset,
            "& (Join-Path `$PSScriptRoot 'Connect-GitHubOidc.ps1')`n`n    ")
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Connect-GitHubOidc.ps1') `
            -Destination (Join-Path $platformDirectory 'scripts\Connect-GitHubOidc.ps1')
        $stackScript | Set-Content -LiteralPath $stackScriptPath -Encoding utf8
    }

    # These three upstream names have no parameter override in the pinned release.
    $hubTemplatePath = Join-Path $platformDirectory 'templates\networking\hubnetworking\main.bicep'
    $hubTemplate = Get-Content $hubTemplatePath -Raw
    foreach ($prefix in 'rt-hub-fw', 'rt-hub-std', 'afwp-alz') {
        $original = "name: '$prefix-" + '${hub.location}' + "'"
        $replacement = "name: '$prefix-" + '${substring(hub.location, 0, 3)}' + "'"
        if ([regex]::Matches($hubTemplate, [regex]::Escape($original)).Count -ne 1) {
            throw "Expected exactly one upstream name expression for $prefix. Review the pinned hub template before deployment."
        }
        $hubTemplate = $hubTemplate.Replace($original, $replacement)
    }
    $hubTemplate | Set-Content -LiteralPath $hubTemplatePath -Encoding utf8

    $parameterRoot = Join-Path $PSScriptRoot 'config\templates'
    foreach ($file in Get-ChildItem $parameterRoot -Filter '*.bicepparam' -Recurse) {
        $relativePath = [IO.Path]::GetRelativePath($parameterRoot, $file.FullName)
        $generatedPath = Join-Path $platformDirectory "templates\$relativePath"
        $build = ((& bicep build-params $generatedPath --stdout) -join [Environment]::NewLine) | ConvertFrom-Json
        foreach ($property in 'templateJson', 'parametersJson') {
            if ([string]::IsNullOrWhiteSpace($build.$property) -or
                [Text.Encoding]::UTF8.GetByteCount($build.$property) -gt 4MB) {
                throw "Invalid or oversized Bicep $property for $relativePath."
            }
        }
    }

    Push-Location $platformDirectory
    try {
        # The pinned Bicep script uses Read-Host, not Terraform's auto_approve switch.
        'yes' | & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -InputFormat Text -OutputFormat Text -Command '
            $ErrorActionPreference = "Stop"
            $PSNativeCommandUseErrorActionPreference = $true
            $global:LASTEXITCODE = 0
            & (Join-Path $env:TF_VAR_target_directory "scripts\deploy-local.ps1") -Verbose:$false
            exit $LASTEXITCODE
        '
    } finally {
        Pop-Location
    }
} finally {
    $env:TF_CLI_ARGS_init = $previousInitArguments
    $env:TF_VAR_target_directory = $previousTarget
}
