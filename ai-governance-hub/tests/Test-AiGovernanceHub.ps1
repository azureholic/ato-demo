#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$adapter = Join-Path $root 'Invoke-AiGovernanceHub.ps1'
$originalConfig = Get-Content (Join-Path $root 'config\deployment.json') -Raw | ConvertFrom-Json
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "ai-governance-hub-tests-$([guid]::NewGuid())"
$configPath = Join-Path $testRoot 'config'
New-Item $configPath -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $root 'config\main.bicepparam') $configPath
$state = @{ Failure = ''; Calls = [Collections.Generic.List[string]]::new() }
$previousLocation = Get-Location
$previousExitCode = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$previousExitCodeValue = if ($previousExitCode) { $previousExitCode.Value } else { $null }

function git {
    $state.Calls.Add("git $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'clone') {
        $path = $args[-1]
        foreach ($file in 'azure.yaml', 'bicep\infra\main.bicep', 'src\usage-ingestion-logicapp\package.json') {
            $destination = Join-Path $path $file
            New-Item (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
            Set-Content $destination '{}'
        }
    } elseif ($args[2] -eq 'rev-parse') {
        if ($state.Failure -eq 'wrong-revision') { '0' * 40 } else { $originalConfig.upstreamRevision }
    } elseif ($state.Failure -eq 'checkout') {
        $global:LASTEXITCODE = 23
    }
}
function az {
    $state.Calls.Add("az $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($state.Failure -eq 'compile') {
        $global:LASTEXITCODE = 17
        return
    }
    if ($args[1] -eq 'build-params') {
        Set-Content $args[-1] '{"parameters":{}}'
    } else {
        $template = @{ resources = @() }
        if ($state.Failure -eq 'oversized') { $template.metadata = @{ padding = 'x' * (4MB) } }
        $template | ConvertTo-Json -Compress | Set-Content $args[-1]
    }
}
function azd {
    $state.Calls.Add("azd $($args -join ' ')")
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'env') {
        if ($args[4] -ne $originalConfig.subscriptionId -or $args[6] -ne $originalConfig.location) {
            throw 'azd must use the configured subscription and region.'
        }
    }
    if ($state.Failure -eq $args[0]) { $global:LASTEXITCODE = 29 }
}
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-Case {
    param([string]$Name, [string]$Failure = '', [string]$ExpectedError = '', [string]$Mode = 'Deploy')
    $state.Calls.Clear()
    $state.Failure = $Failure
    $originalConfig | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $configPath 'deployment.json')
    $path = Join-Path $testRoot $Name
    if ($Name -eq 'existing') { New-Item $path -ItemType Directory | Out-Null }
    if ($Name -eq 'unpinned') {
        $changed = $originalConfig | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $changed.upstreamRevision = 'main'
        $changed | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $configPath 'deployment.json')
    }
    $caught = $null
    try {
        & $adapter -OutputPath $path -ConfigPath $configPath -Mode $Mode
    } catch {
        $caught = $_.Exception.Message
    }
    if ($ExpectedError) {
        Assert ($null -ne $caught -and $caught.Contains($ExpectedError)) "$Name should fail with '$ExpectedError', got '$caught'."
    } elseif ($caught) {
        throw "$Name failed: $caught"
    }
    Assert ((Get-Location).Path -eq $previousLocation.Path) "$Name did not restore the caller's directory."
    Write-Host "PASS: $Name"
}

try {
    Invoke-Case -Name 'validate' -Mode Validate
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Validation must not authenticate or provision/deploy.'
    $overlay = Get-Content (Join-Path $testRoot 'validate\bicep\infra\main.bicepparam') -Raw
    Assert ($overlay -ceq (Get-Content (Join-Path $configPath 'main.bicepparam') -Raw)) 'The exact scenario parameters must replace upstream defaults.'
    $copied = Get-Content (Join-Path $testRoot 'validate\bicep\infra\deployment.json') -Raw | ConvertFrom-Json
    Assert ($copied.model.name -eq $originalConfig.model.name) 'The model configuration must accompany the parameter overlay.'

    Invoke-Case -Name 'deploy'
    $azdCalls = @($state.Calls | Where-Object { $_ -like 'azd *' })
    Assert ($azdCalls.Count -eq 3 -and $azdCalls[1] -like 'azd provision *' -and $azdCalls[2] -like 'azd deploy *') 'Provisioning must precede deployment of upstream application code.'

    Invoke-Case -Name 'provision-failure' -Failure provision -ExpectedError 'exit code 29'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd deploy *' }).Count -eq 0) 'Failed provisioning must stop application deployment.'
    Invoke-Case -Name 'deploy-failure' -Failure deploy -ExpectedError 'exit code 29'
    Invoke-Case -Name 'compile-failure' -Failure compile -ExpectedError 'exit code 17'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Invalid parameters must stop before provisioning.'
    Invoke-Case -Name 'oversized' -Failure oversized -ExpectedError '4 MB limit'
    Assert (@($state.Calls | Where-Object { $_ -like 'azd *' }).Count -eq 0) 'Oversized deployments must stop before provisioning.'
    Invoke-Case -Name 'checkout-failure' -Failure checkout -ExpectedError 'exit code 23'
    Invoke-Case -Name 'wrong-revision' -Failure wrong-revision -ExpectedError 'does not match'
    Invoke-Case -Name 'unpinned' -ExpectedError 'full lowercase Git commit SHA'
    Assert ($state.Calls.Count -eq 0) 'An unpinned revision must fail before cloning.'
    Invoke-Case -Name 'existing' -ExpectedError 'fresh output directory'
    Assert ($state.Calls.Count -eq 0) 'Existing output must not be overwritten.'
} finally {
    Set-Location $previousLocation
    if ($previousExitCode) {
        $global:LASTEXITCODE = $previousExitCodeValue
    } else {
        Remove-Variable LASTEXITCODE -Scope Global
    }
    Remove-Item $testRoot -Recurse -Force
}
Write-Host 'All AI governance hub adapter tests passed.'
