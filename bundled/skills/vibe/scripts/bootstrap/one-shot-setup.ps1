param(
    [ValidateSet('minimal', 'full')]
    [string]$Profile = 'full',
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$SkipExternalInstall,
    [switch]$StrictOffline,
    [switch]$SyncUserEnv,
    [string]$OpenAIBaseUrl = '',
    [string]$OpenAIApiKey = '',
    [string]$ArkBaseUrl = '',
    [string]$ArkApiKey = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\vibe-governance-helpers.ps1')

function Test-NonEmptyString {
    param([AllowNull()][string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value))
}

$repoRoot = Resolve-VgoRepoRoot -StartPath $PSCommandPath
$installPath = Join-Path $repoRoot 'install.ps1'
$checkPath = Join-Path $repoRoot 'check.ps1'
$materializePath = Join-Path $repoRoot 'scripts\setup\materialize-codex-mcp-profile.ps1'
$persistOpenAiPath = Join-Path $repoRoot 'scripts\setup\persist-codex-openai-env.ps1'
$persistArkPath = Join-Path $repoRoot 'scripts\setup\persist-codex-ark-env.ps1'
$syncEnvPath = Join-Path $repoRoot 'scripts\setup\sync-codex-settings-to-user-env.ps1'

Write-Host '=== VCO One-Shot Setup ===' -ForegroundColor Cyan
Write-Host ("Repo root           : {0}" -f $repoRoot)
Write-Host ("Target root         : {0}" -f $TargetRoot)
Write-Host ("Profile             : {0}" -f $Profile)
Write-Host ("StrictOffline       : {0}" -f ([bool]$StrictOffline))
Write-Host ("SkipExternalInstall : {0}" -f ([bool]$SkipExternalInstall))
Write-Host ("SyncUserEnv         : {0}" -f ([bool]$SyncUserEnv))

$installArgs = @{
    Profile = $Profile
    TargetRoot = $TargetRoot
}
if (-not $SkipExternalInstall) {
    $installArgs.InstallExternal = $true
}
if ($StrictOffline) {
    $installArgs.StrictOffline = $true
}

Write-Host ''
Write-Host '[1/5] Installing governed runtime payload...' -ForegroundColor Yellow
& $installPath @installArgs

$hasOpenAiSeed = (Test-NonEmptyString -Value $OpenAIApiKey) -or (Test-NonEmptyString -Value $env:OPENAI_API_KEY)
if ($hasOpenAiSeed) {
    Write-Host '[2/5] Seeding OPENAI settings into target settings.json...' -ForegroundColor Yellow
    $openAiArgs = @{
        CodexRoot = $TargetRoot
    }
    if (Test-NonEmptyString -Value $OpenAIBaseUrl) {
        $openAiArgs.BaseUrl = $OpenAIBaseUrl
    }
    if (Test-NonEmptyString -Value $OpenAIApiKey) {
        $openAiArgs.ApiKey = $OpenAIApiKey
    }
    & $persistOpenAiPath @openAiArgs
} else {
    Write-Warning 'OPENAI_API_KEY not provided and not present in the current environment. Full online readiness will remain pending.'
}

$hasArkSeed = (Test-NonEmptyString -Value $ArkApiKey) -or (Test-NonEmptyString -Value $env:ARK_API_KEY)
if ($hasArkSeed) {
    Write-Host '[3/5] Seeding ARK settings into target settings.json...' -ForegroundColor Yellow
    $arkArgs = @{
        CodexRoot = $TargetRoot
    }
    if (Test-NonEmptyString -Value $ArkBaseUrl) {
        $arkArgs.BaseUrl = $ArkBaseUrl
    }
    if (Test-NonEmptyString -Value $ArkApiKey) {
        $arkArgs.ApiKey = $ArkApiKey
    }
    & $persistArkPath @arkArgs
} else {
    Write-Host '[3/5] ARK settings not provided; skipping optional ARK seeding.' -ForegroundColor DarkGray
}

if ($SyncUserEnv) {
    Write-Host '[4/5] Syncing configured settings.json env values into the user environment...' -ForegroundColor Yellow
    & $syncEnvPath -CodexRoot $TargetRoot -Target All -Scope User
} else {
    Write-Host '[4/5] User environment sync skipped (pass -SyncUserEnv if you want registry env sync).' -ForegroundColor DarkGray
}

Write-Host '[5/5] Materializing MCP profile and running deep health check...' -ForegroundColor Yellow
& $materializePath -TargetRoot $TargetRoot -Force | Out-Null
& $checkPath -Profile $Profile -TargetRoot $TargetRoot -Deep

Write-Host ''
Write-Host 'One-shot setup completed.' -ForegroundColor Green
Write-Host ('- Re-run deep doctor anytime with: pwsh -File "{0}" -Profile {1} -TargetRoot "{2}" -Deep' -f $checkPath, $Profile, $TargetRoot)
Write-Host ('- MCP active file: {0}' -f (Join-Path $TargetRoot 'mcp\servers.active.json'))
Write-Host ('- Doctor artifacts: {0}' -f (Join-Path $repoRoot 'outputs\verify'))
