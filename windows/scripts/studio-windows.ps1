$ErrorActionPreference = 'Stop'
$EngineRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

function New-DreamSkinStudioState {
  param(
    [string]$Install,
    [string]$Codex,
    [string]$Session,
    [string]$Operation = 'idle',
    [AllowNull()][string]$ThemeName,
    [bool]$RequiresRestart = $false,
    [AllowNull()][Nullable[bool]]$Verified,
    [string[]]$AvailableActions = @()
  )
  return [pscustomobject][ordered]@{
    install = $Install
    codex = $Codex
    session = $Session
    operation = $Operation
    themeName = $ThemeName
    requiresRestart = $RequiresRestart
    availableActions = @($AvailableActions)
    verified = $Verified
  }
}

function Write-DreamSkinStudioEnvelope {
  param(
    [string]$Operation,
    [bool]$Ok,
    [object]$State,
    [AllowNull()][object]$Error
  )
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $envelope = [pscustomobject][ordered]@{
    schemaVersion = 1
    ok = $Ok
    operation = $Operation
    state = $State
    error = $Error
  }
  [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Compress -Depth 8))
}

function script:Test-DreamSkinStudioReadableFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $stream.Dispose()
    return $true
  } catch {
    return $false
  }
}

function script:Test-DreamSkinStudioVersion {
  $versionPath = Join-Path $EngineRoot 'VERSION'
  if (-not (Test-DreamSkinStudioReadableFile -Path $versionPath)) { return $false }
  try {
    $bytes = [IO.File]::ReadAllBytes($versionPath)
    $value = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    if ($value.Length -gt 0 -and $value[0] -eq [char]0xFEFF) { $value = $value.Substring(1) }
    return [regex]::IsMatch($value, '\A1\.3\.0(?:\r\n|\n)?\z')
  } catch {
    return $false
  }
}

function script:Test-DreamSkinStudioInstalled {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  if (-not (Test-DreamSkinStudioVersion)) { return $false }
  foreach ($path in @(
    (Join-Path $EngineRoot 'runtime\node.exe'),
    (Join-Path $PSScriptRoot 'studio-adapter.ps1'),
    (Join-Path $PSScriptRoot 'start-dream-skin.ps1'),
    (Join-Path $PSScriptRoot 'restore-dream-skin.ps1'),
    (Join-Path $StateRoot 'config.before-dream-skin.toml'),
    (Join-Path $StateRoot 'active-theme\theme.json')
  )) {
    if (-not (Test-DreamSkinStudioReadableFile -Path $path)) { return $false }
  }
  return $true
}

function script:Test-DreamSkinStudioInjectorIdentity {
  param(
    [Parameter(Mandatory = $true)][object]$State,
    [Parameter(Mandatory = $true)][object]$Codex
  )
  foreach ($field in @('injectorPid', 'injectorStartedAt', 'injectorPath', 'nodePath', 'port', 'browserId')) {
    if (-not $State.$field) { return $false }
  }
  if (-not (Test-DreamSkinPathEqual -Left "$($State.injectorPath)" -Right (Join-Path $PSScriptRoot 'injector.mjs')) -or
    -not (Test-DreamSkinPathEqual -Left "$($State.nodePath)" -Right (Join-Path $EngineRoot 'runtime\node.exe')) -or
    -not (Test-DreamSkinPathEqual -Left "$($State.codexExe)" -Right "$($Codex.Executable)")) {
    return $false
  }
  if ($State.codexPackageRoot -and -not (Test-DreamSkinPathEqual -Left "$($State.codexPackageRoot)" -Right "$($Codex.PackageRoot)")) {
    return $false
  }
  if (($State.codexPackageFullName -and "$($State.codexPackageFullName)" -ine "$($Codex.PackageFullName)") -or
    ($State.codexPackageFamilyName -and "$($State.codexPackageFamilyName)" -ine "$($Codex.PackageFamilyName)")) {
    return $false
  }

  $processId = 0
  $port = 0
  if (-not [int]::TryParse("$($State.injectorPid)", [ref]$processId) -or $processId -le 0 -or
    -not [int]::TryParse("$($State.port)", [ref]$port) -or $port -lt 1024 -or $port -gt 65535 -or
    -not (Test-DreamSkinBrowserId -Value "$($State.browserId)")) {
    return $false
  }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
  if ($null -eq $process) { return $false }
  $processPath = Get-DreamSkinProcessExecutablePath -ProcessInfo $process
  $commandLine = "$($process.CommandLine)"
  if (-not (Test-DreamSkinPathEqual -Left $processPath -Right "$($State.nodePath)") -or
    -not (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token "$($State.nodePath)") -or
    -not (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token "$($State.injectorPath)") -or
    -not (Test-DreamSkinCommandLineToken -CommandLine $commandLine -Token '--watch')) {
    return $false
  }
  $portPattern = '(?i)(?:^|\s)--port(?:=|\s+)' + [regex]::Escape("$port") + '(?=$|\s)'
  $browserPattern = '(?i)(?:^|\s)--browser-id(?:=|\s+)' + [regex]::Escape("$($State.browserId)") + '(?=$|\s)'
  return [regex]::IsMatch($commandLine, $portPattern) -and
    [regex]::IsMatch($commandLine, $browserPattern) -and
    (Get-DreamSkinProcessStartedAt -ProcessId $processId) -ceq "$($State.injectorStartedAt)"
}

function script:New-DreamSkinStudioError {
  param([string]$Code, [string]$Message, [string[]]$RecoveryActions)
  return [pscustomobject][ordered]@{
    code = $Code
    message = $Message
    recoveryActions = @($RecoveryActions)
  }
}

function Get-DreamSkinStudioStatus {
  param([switch]$Deep)

  $stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $install = if (Test-DreamSkinStudioInstalled -StateRoot $stateRoot) { 'ready' } else { 'not-installed' }
  $statePath = Join-Path $stateRoot 'state.json'
  $savedState = $null
  $stateDamaged = $false
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
      $savedState = Read-DreamSkinState -Path $statePath
      if ($null -eq $savedState) { $stateDamaged = $true }
    } catch {
      $stateDamaged = $true
    }
  }

  $codexState = 'not-installed'
  $codex = $null
  $codexProcesses = @()
  $installs = @(Get-DreamSkinRegisteredCodexInstalls)
  if ($installs.Count -gt 0) {
    $savedCodex = $null
    if ($null -ne $savedState) {
      $savedCodex = Resolve-DreamSkinCodexInstallFromState -State $savedState -RegisteredInstalls $installs
    }
    $savedProcesses = @()
    $newestProcesses = @()
    $runningCodex = $null
    $runningProcesses = @()
    foreach ($candidate in $installs) {
      $candidateProcesses = @(Get-DreamSkinCodexProcesses -Codex $candidate)
      if (Test-DreamSkinPathEqual -Left $candidate.Executable -Right $installs[0].Executable) {
        $newestProcesses = $candidateProcesses
      }
      if ($null -ne $savedCodex -and
        (Test-DreamSkinPathEqual -Left $candidate.Executable -Right $savedCodex.Executable)) {
        $savedProcesses = $candidateProcesses
      }
      if ($null -eq $runningCodex -and $candidateProcesses.Count -gt 0) {
        $runningCodex = $candidate
        $runningProcesses = $candidateProcesses
      }
    }
    if ($null -ne $savedCodex) {
      $codex = $savedCodex
      $codexProcesses = $savedProcesses
    } elseif ($null -ne $runningCodex) {
      $codex = $runningCodex
      $codexProcesses = $runningProcesses
    } else {
      $codex = $installs[0]
      $codexProcesses = $newestProcesses
    }
    $configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $codexState = if ($null -ne $runningCodex) { 'running' } else { 'stopped' }
    } else {
      $codexState = 'needs-first-run'
    }
  }

  $session = 'official'
  $themeName = $null
  $verified = $null
  try { $pausedMarker = Test-DreamSkinPaused -StateRoot $stateRoot } catch { $pausedMarker = $false }
  if ($stateDamaged) {
    $session = 'stale'
  } elseif ($null -ne $savedState) {
    if ($pausedMarker) {
      $session = 'paused'
    } elseif ($codexState -eq 'running' -and $codexProcesses.Count -gt 0 -and $null -ne $codex -and
      (Test-DreamSkinStudioInjectorIdentity -State $savedState -Codex $codex)) {
      $session = 'active'
    } else {
      $session = 'stale'
    }
  } elseif ($pausedMarker) {
    $session = 'paused'
  }

  try {
    $theme = Read-DreamSkinTheme -ThemeDirectory (Join-Path $stateRoot 'active-theme') -SkipImageMetadata
    $themeName = if ($theme.Theme.name) { "$($theme.Theme.name)" } elseif ($theme.Theme.id) { "$($theme.Theme.id)" } else { $null }
  } catch {}

  if ($Deep -and $session -eq 'active') {
    $verified = $false
    try {
      $port = [int]$savedState.port
      $cdpIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $port -Codex $codex
      if ($null -ne $cdpIdentity -and $cdpIdentity.BrowserId -is [string] -and
        "$($cdpIdentity.BrowserId)" -ceq "$($savedState.browserId)") {
        $node = Get-DreamSkinNodeRuntime -NodePath (Join-Path $EngineRoot 'runtime\node.exe')
        & $node.Path (Join-Path $PSScriptRoot 'injector.mjs') --verify --port "$port" `
          --browser-id "$($cdpIdentity.BrowserId)" --timeout-ms 5000 *> $null
        $verified = $LASTEXITCODE -eq 0
      }
    } catch {}
  } elseif ($Deep -and $session -eq 'paused') {
    $verified = $false
  }

  $requiresRestart = $codexState -eq 'running' -and $session -eq 'official'
  $availableActions = @('install')
  if ($install -eq 'ready') {
    switch ($session) {
      'active' { $availableActions = @('pause', 'resume', 'restore', 'verify', 'uninstall') }
      'paused' { $availableActions = @('apply', 'resume', 'restore', 'verify', 'uninstall') }
      'stale' { $availableActions = @('apply', 'restore', 'verify', 'uninstall') }
      default {
        $availableActions = if ($codexState -eq 'running') {
          @('apply', 'restore', 'verify', 'uninstall')
        } else {
          @('apply', 'restore', 'uninstall')
        }
      }
    }
  }

  $error = $null
  if ($codexState -eq 'not-installed') {
    $error = New-DreamSkinStudioError -Code 'CODEX_NOT_INSTALLED' -Message 'Codex is not installed.' -RecoveryActions @('cancel')
  } elseif ($codexState -eq 'needs-first-run') {
    $error = New-DreamSkinStudioError -Code 'CODEX_FIRST_RUN_REQUIRED' -Message 'Open Codex and complete first-run setup.' -RecoveryActions @('open-codex', 'retry', 'cancel')
  }
  if ($session -eq 'stale') {
    $error = New-DreamSkinStudioError -Code 'STATE_UNSAFE' -Message 'Theme state needs recovery before it can be used.' -RecoveryActions @('restore', 'diagnostics', 'cancel')
  }

  $studioState = New-DreamSkinStudioState -Install $install -Codex $codexState -Session $session `
    -ThemeName $themeName -RequiresRestart $requiresRestart -Verified $verified -AvailableActions $availableActions
  return [pscustomobject]@{
    Ok = $null -eq $error
    State = $studioState
    Error = $error
  }
}
