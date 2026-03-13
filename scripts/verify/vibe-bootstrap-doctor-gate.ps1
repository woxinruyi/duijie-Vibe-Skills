param(
    [string]$TargetRoot = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$WriteArtifacts,
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\vibe-governance-helpers.ps1')

function Test-PlaceholderValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return (($Value.Trim().StartsWith('<')) -and ($Value.Trim().EndsWith('>')))
}

function Get-SettingValue {
    param(
        [AllowNull()]$Settings,
        [string]$Name
    )

    if ($null -eq $Settings) {
        return $null
    }
    if ($Settings.PSObject.Properties.Name -notcontains 'env') {
        return $null
    }
    if ($null -eq $Settings.env) {
        return $null
    }
    if ($Settings.env.PSObject.Properties.Name -notcontains $Name) {
        return $null
    }

    return [string]$Settings.env.$Name
}

function Get-SettingState {
    param(
        [AllowNull()]$Settings,
        [string]$Name
    )

    $value = Get-SettingValue -Settings $Settings -Name $Name
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'missing'
    }
    if (Test-PlaceholderValue -Value $value) {
        return 'placeholder'
    }
    return 'configured'
}

function Test-CommandPresent {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function Get-EnvironmentVariableValue {
    param([Parameter(Mandatory)] [string]$Name)

    $item = Get-Item -Path ("env:{0}" -f $Name) -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    return [string]$item.Value
}

function Write-DoctorArtifacts {
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [psobject]$Artifact,
        [string]$DestinationRoot
    )

    $outputRoot = if ([string]::IsNullOrWhiteSpace($DestinationRoot)) {
        Join-Path $RepoRoot 'outputs\verify'
    } else {
        $DestinationRoot
    }

    New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null

    $jsonPath = Join-Path $outputRoot 'vibe-bootstrap-doctor-gate.json'
    $mdPath = Join-Path $outputRoot 'vibe-bootstrap-doctor-gate.md'

    Write-VgoUtf8NoBomText -Path $jsonPath -Content (($Artifact | ConvertTo-Json -Depth 100) + "`r`n")

    $lines = @(
        '# VCO Bootstrap Doctor Gate',
        '',
        ('- Gate Result: **{0}**' -f $Artifact.gate_result),
        ('- Readiness State: **{0}**' -f $Artifact.summary.readiness_state),
        ('- Blocking Issues: `{0}`' -f $Artifact.summary.blocking_issue_count),
        ('- Manual Actions Pending: `{0}`' -f $Artifact.summary.manual_action_count),
        ('- Warnings: `{0}`' -f $Artifact.summary.warning_count),
        ('- Target Root: `{0}`' -f $Artifact.target_root),
        ('- MCP Profile: `{0}`' -f $Artifact.mcp.profile),
        ('- MCP Active File Exists: `{0}`' -f $Artifact.mcp.active_file_exists),
        ''
    )

    $lines += '## Settings'
    $lines += ''
    $lines += ('- `OPENAI_API_KEY`: `{0}`' -f $Artifact.settings.openai_api_key_state)
    $lines += ('- `ARK_API_KEY`: `{0}`' -f $Artifact.settings.ark_api_key_state)
    $lines += ''

    if ($Artifact.plugins.Count -gt 0) {
        $lines += '## Plugin Readiness'
        $lines += ''
        foreach ($plugin in $Artifact.plugins) {
            $lines += ('- `{0}`: status=`{1}` install_mode=`{2}` next_step=`{3}`' -f $plugin.name, $plugin.status, $plugin.install_mode, $plugin.next_step)
        }
        $lines += ''
    }

    if ($Artifact.external_tools.Count -gt 0) {
        $lines += '## External Tools'
        $lines += ''
        foreach ($tool in $Artifact.external_tools) {
            $lines += ('- `{0}`: present=`{1}` required_for=`{2}`' -f $tool.name, $tool.present, ($tool.required_for -join ', '))
        }
        $lines += ''
    }

    if ($Artifact.mcp.servers.Count -gt 0) {
        $lines += '## MCP Servers'
        $lines += ''
        foreach ($server in $Artifact.mcp.servers) {
            $lines += ('- `{0}`: mode=`{1}` status=`{2}` next_step=`{3}`' -f $server.name, $server.mode, $server.status, $server.next_step)
        }
        $lines += ''
    }

    if ($Artifact.secret_surfaces.Count -gt 0) {
        $lines += '## Secret Surfaces'
        $lines += ''
        foreach ($secret in $Artifact.secret_surfaces) {
            $lines += ('- `{0}`: status=`{1}` storage=`{2}`' -f $secret.name, $secret.status, ($secret.storage -join ', '))
        }
        $lines += ''
    }

    Write-VgoUtf8NoBomText -Path $mdPath -Content (($lines -join "`r`n") + "`r`n")
}

$context = Get-VgoGovernanceContext -ScriptPath $PSCommandPath -EnforceExecutionContext
$repoRoot = $context.repoRoot

$settingsPath = Join-Path $TargetRoot 'settings.json'
$pluginsManifestPath = Join-Path $repoRoot 'config\plugins-manifest.codex.json'
$serversTemplatePath = Join-Path $repoRoot 'mcp\servers.template.json'
$secretsPolicyPath = Join-Path $repoRoot 'config\secrets-policy.json'

$settings = $null
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw ("Failed to parse target settings.json: " + $_.Exception.Message)
    }
}

$profile = 'full'
if ($null -ne $settings -and $settings.PSObject.Properties.Name -contains 'vco' -and $null -ne $settings.vco) {
    if ($settings.vco.PSObject.Properties.Name -contains 'mcp_profile' -and -not [string]::IsNullOrWhiteSpace([string]$settings.vco.mcp_profile)) {
        $profile = [string]$settings.vco.mcp_profile
    }
}

$activeMcpPath = Join-Path $TargetRoot 'mcp\servers.active.json'
$pluginsManifest = Get-Content -LiteralPath $pluginsManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$serversTemplate = Get-Content -LiteralPath $serversTemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$profilePath = Join-Path $repoRoot ("mcp\profiles\{0}.json" -f $profile)
$profileObject = if (Test-Path -LiteralPath $profilePath) {
    Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
} else {
    [pscustomobject]@{
        profile = $profile
        enabled_servers = @()
    }
}
$secretsPolicy = Get-Content -LiteralPath $secretsPolicyPath -Raw -Encoding UTF8 | ConvertFrom-Json

$pluginResults = @()
foreach ($plugin in @($pluginsManifest.core) + @($pluginsManifest.optional)) {
    if ($null -eq $plugin) { continue }

    $installMode = if ($plugin.PSObject.Properties.Name -contains 'install_mode') { [string]$plugin.install_mode } else { 'unknown' }
    $status = switch ($installMode) {
        'manual-codex' { 'platform_plugin_required' }
        'scripted' {
            if ($plugin.PSObject.Properties.Name -contains 'install' -and ([string]$plugin.install) -match 'claude-flow') {
                if (Test-CommandPresent -Name 'claude-flow') { 'ready' } else { 'auto_installable_missing' }
            } else {
                'scripted_unknown_probe'
            }
        }
        default { 'unknown' }
    }

    $nextStep = if ($status -eq 'platform_plugin_required') {
        if ($plugin.PSObject.Properties.Name -contains 'install_hint') { [string]$plugin.install_hint } else { 'Provision in Codex host runtime.' }
    } elseif ($status -eq 'auto_installable_missing') {
        if ($plugin.PSObject.Properties.Name -contains 'install') { [string]$plugin.install } else { 'Install via documented package manager.' }
    } else {
        'none'
    }

    $pluginResults += [pscustomobject]@{
        name = [string]$plugin.name
        install_mode = $installMode
        status = $status
        required = [bool]($plugin.PSObject.Properties.Name -contains 'required' -and $plugin.required)
        next_step = $nextStep
    }
}

$externalTools = @(
    [pscustomobject]@{ name = 'git'; present = [bool](Test-CommandPresent -Name 'git'); required_for = @('bootstrap') },
    [pscustomobject]@{ name = 'npm'; present = [bool](Test-CommandPresent -Name 'npm'); required_for = @('claude-flow', 'ralph-wiggum') },
    [pscustomobject]@{ name = 'python'; present = [bool](Test-CommandPresent -Name 'python'); required_for = @('scrapling', 'ivy') },
    [pscustomobject]@{ name = 'claude-flow'; present = [bool](Test-CommandPresent -Name 'claude-flow'); required_for = @('mcp:claude-flow') },
    [pscustomobject]@{ name = 'scrapling'; present = [bool](Test-CommandPresent -Name 'scrapling'); required_for = @('mcp:scrapling') },
    [pscustomobject]@{ name = 'xan'; present = [bool](Test-CommandPresent -Name 'xan'); required_for = @('csv-acceleration') }
)

$mcpServers = @()
foreach ($serverName in @($profileObject.enabled_servers)) {
    $serverConfig = if ($serversTemplate.servers.PSObject.Properties.Name -contains $serverName) {
        $serversTemplate.servers.$serverName
    } else {
        $null
    }

    if ($null -eq $serverConfig) {
        $mcpServers += [pscustomobject]@{
            name = [string]$serverName
            mode = 'unknown'
            status = 'missing_from_template'
            next_step = 'Fix mcp/profile definition mismatch.'
        }
        continue
    }

    $mode = [string]$serverConfig.mode
    $status = 'ready'
    $nextStep = 'none'

    if ($mode -eq 'plugin') {
        $status = 'platform_plugin_required'
        $nextStep = 'Provision the corresponding Codex plugin in the host runtime.'
    } elseif ($mode -eq 'stdio') {
        $commandName = [string]$serverConfig.command
        if (-not (Test-CommandPresent -Name $commandName)) {
            $status = 'manual_action_required'
            $nextStep = if ($serverConfig.PSObject.Properties.Name -contains 'note' -and -not [string]::IsNullOrWhiteSpace([string]$serverConfig.note)) {
                [string]$serverConfig.note
            } else {
                ("Install command '{0}' and register the MCP server in the host." -f $commandName)
            }
        }
    }

    $mcpServers += [pscustomobject]@{
        name = [string]$serverName
        mode = $mode
        status = $status
        next_step = $nextStep
    }
}

$secretSurfaces = @()
foreach ($secret in @($secretsPolicy.allowed_secret_refs)) {
    $state = if ([string]$secret.name -eq 'COMPOSIO_SESSION_MCP_URL') {
        if ([string]::IsNullOrWhiteSpace([string]$env:COMPOSIO_SESSION_MCP_URL)) { 'runtime_not_set' } else { 'runtime_present' }
    } else {
        $secretValue = Get-EnvironmentVariableValue -Name ([string]$secret.name)
        if ([string]::IsNullOrWhiteSpace($secretValue)) { 'not_configured' } else { 'configured_in_env' }
    }

    $secretSurfaces += [pscustomobject]@{
        name = [string]$secret.name
        scope = [string]$secret.scope
        storage = @($secret.storage)
        status = $state
    }
}

$blockingIssues = New-Object System.Collections.Generic.List[string]
$manualActions = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if (-not (Test-Path -LiteralPath $settingsPath)) {
    $blockingIssues.Add('settings.json is missing in target root.') | Out-Null
}
if ((Get-SettingState -Settings $settings -Name 'OPENAI_API_KEY') -ne 'configured') {
    $manualActions.Add('OPENAI_API_KEY must be configured for full online Codex usage.') | Out-Null
}
if (-not (Test-Path -LiteralPath $activeMcpPath)) {
    $manualActions.Add('MCP active profile has not been materialized yet (servers.active.json missing).') | Out-Null
}
foreach ($plugin in $pluginResults | Where-Object { $_.status -eq 'platform_plugin_required' -and $_.required }) {
    $manualActions.Add(("Required host plugin pending: {0}" -f $plugin.name)) | Out-Null
}
foreach ($server in $mcpServers | Where-Object { $_.status -in @('platform_plugin_required', 'manual_action_required', 'missing_from_template') }) {
    $manualActions.Add(("MCP server pending: {0}" -f $server.name)) | Out-Null
}
foreach ($tool in $externalTools | Where-Object { -not $_.present -and $_.name -in @('npm', 'claude-flow') }) {
    $warnings.Add(("Optional external tool missing: {0}" -f $tool.name)) | Out-Null
}

$readinessState = if ($blockingIssues.Count -gt 0) {
    'core_install_incomplete'
} elseif ($manualActions.Count -gt 0) {
    'manual_actions_pending'
} else {
    'fully_ready'
}

$artifact = [ordered]@{
    gate = 'vibe-bootstrap-doctor-gate'
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    repo_root = $repoRoot
    target_root = [System.IO.Path]::GetFullPath($TargetRoot)
    gate_result = if ($blockingIssues.Count -eq 0) { 'PASS' } else { 'FAIL' }
    settings = [ordered]@{
        path = $settingsPath
        exists = [bool](Test-Path -LiteralPath $settingsPath)
        openai_api_key_state = (Get-SettingState -Settings $settings -Name 'OPENAI_API_KEY')
        ark_api_key_state = (Get-SettingState -Settings $settings -Name 'ARK_API_KEY')
        openai_base_url_state = (Get-SettingState -Settings $settings -Name 'OPENAI_BASE_URL')
        ark_base_url_state = (Get-SettingState -Settings $settings -Name 'ARK_BASE_URL')
    }
    plugins = @($pluginResults)
    external_tools = @($externalTools)
    mcp = [ordered]@{
        profile = $profile
        profile_path = if (Test-Path -LiteralPath $profilePath) { (Get-VgoRelativePathPortable -BasePath $repoRoot -TargetPath $profilePath) } else { $null }
        active_file_path = $activeMcpPath
        active_file_exists = [bool](Test-Path -LiteralPath $activeMcpPath)
        servers = @($mcpServers)
    }
    secret_surfaces = @($secretSurfaces)
    summary = [ordered]@{
        readiness_state = $readinessState
        blocking_issue_count = $blockingIssues.Count
        manual_action_count = $manualActions.Count
        warning_count = $warnings.Count
        blocking_issues = @($blockingIssues)
        manual_actions = @($manualActions)
        warnings = @($warnings)
    }
}

if ($WriteArtifacts) {
    Write-DoctorArtifacts -RepoRoot $repoRoot -Artifact ([pscustomobject]$artifact) -DestinationRoot $OutputDirectory
}

Write-Host '=== VCO Bootstrap Doctor Gate ===' -ForegroundColor Cyan
Write-Host ("Target root      : {0}" -f $artifact.target_root)
Write-Host ("Readiness state  : {0}" -f $artifact.summary.readiness_state)
Write-Host ("Blocking issues  : {0}" -f $artifact.summary.blocking_issue_count)
Write-Host ("Manual actions   : {0}" -f $artifact.summary.manual_action_count)
Write-Host ("Warnings         : {0}" -f $artifact.summary.warning_count)

if ($blockingIssues.Count -gt 0) {
    exit 1
}

exit 0
