$ErrorActionPreference = 'Stop'
$EngineRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

function Get-DreamSkinSafeThemeDisplayName {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  $name = "$Value"
  if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOfAny([char[]]@('/', '\')) -ge 0) { return $null }
  foreach ($character in $name.ToCharArray()) {
    $code = [int]$character
    if ($code -lt 0x20 -or ($code -ge 0x7f -and $code -le 0x9f) -or
      $character -eq [char]0x2028 -or $character -eq [char]0x2029) {
      return $null
    }
  }
  return $name
}

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
    themeName = Get-DreamSkinSafeThemeDisplayName -Value $ThemeName
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

function script:Test-DreamSkinStudioPathEntry {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $null = [IO.File]::GetAttributes([IO.Path]::GetFullPath($Path))
    return $true
  } catch [IO.FileNotFoundException] {
    return $false
  } catch [IO.DirectoryNotFoundException] {
    return $false
  }
}

function Get-DreamSkinStudioRecoveryState {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  Assert-DreamSkinNoReparseComponents -Path $StateRoot
  if ((Test-DreamSkinStudioPathEntry -Path $StateRoot) -and
    -not (Test-Path -LiteralPath $StateRoot -PathType Container)) {
    throw 'The Dream Skin state root is not a safe directory.'
  }
  $backup = Join-Path $StateRoot 'config.before-dream-skin.toml'
  $backupMarker = Get-DreamSkinAppearanceMarkerPath -BackupPath $backup
  $archive = Join-Path $StateRoot 'config.restored.toml'
  $archiveMarker = Get-DreamSkinAppearanceMarkerPath -BackupPath $archive
  $state = Join-Path $StateRoot 'state.json'
  $paused = Join-Path $StateRoot 'paused'
  $activeThemeRoot = Join-Path $StateRoot 'active-theme'
  $activeTheme = Join-Path $activeThemeRoot 'theme.json'
  foreach ($path in @($backup, $backupMarker, $archive, $archiveMarker, $state, $paused, $activeTheme)) {
    Assert-DreamSkinNoReparseComponents -Path $path
    if ((Test-DreamSkinStudioPathEntry -Path $path) -and
      -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "A Dream Skin lifecycle artifact is not a safe file: $path"
    }
  }
  Assert-DreamSkinNoReparseComponents -Path $activeThemeRoot
  if ((Test-DreamSkinStudioPathEntry -Path $activeThemeRoot) -and
    -not (Test-Path -LiteralPath $activeThemeRoot -PathType Container)) {
    throw 'The Dream Skin active theme is not a safe directory.'
  }

  $liveBackup = Test-Path -LiteralPath $backup -PathType Leaf
  $backupMarkerPresent = Test-Path -LiteralPath $backupMarker -PathType Leaf
  $statePresent = Test-Path -LiteralPath $state -PathType Leaf
  $pausedPresent = Test-Path -LiteralPath $paused -PathType Leaf
  $activeThemePresent = Test-DreamSkinStudioPathEntry -Path $activeThemeRoot
  $completionEvidence = Test-DreamSkinConfigCompletionEvidence -ArchivePath $archive
  $completed = $completionEvidence -and -not $liveBackup -and -not $backupMarkerPresent -and
    -not $statePresent -and -not $pausedPresent

  $configManaged = $false
  if (-not $liveBackup -and -not $completed -and -not $statePresent -and -not $pausedPresent) {
    $configManaged = Test-DreamSkinBaseThemeManaged -ConfigPath (Join-Path $env:USERPROFILE '.codex\config.toml')
  }
  $neverApplied = -not $liveBackup -and -not $backupMarkerPresent -and -not $completionEvidence -and
    -not $statePresent -and -not $pausedPresent -and -not $activeThemePresent -and -not $configManaged
  $unsafe = -not $liveBackup -and -not $completed -and -not $neverApplied
  return [pscustomobject]@{
    LiveBackup = $liveBackup
    BackupMarkerPresent = $backupMarkerPresent
    CompletionEvidence = $completionEvidence
    StatePresent = $statePresent
    PausedPresent = $pausedPresent
    ActiveThemePresent = $activeThemePresent
    ConfigManaged = $configManaged
    Completed = $completed
    NeverApplied = $neverApplied
    Unsafe = $unsafe
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
  $recovery = Get-DreamSkinStudioRecoveryState -StateRoot $stateRoot
  $install = if (Test-DreamSkinStudioInstalled -StateRoot $stateRoot) { 'ready' } else { 'not-installed' }
  $statePath = Join-Path $stateRoot 'state.json'
  $savedState = $null
  $stateDamaged = $false
  if ($recovery.StatePresent) {
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
  $runtimeInvalid = $false
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
  if ($session -eq 'active' -and $install -ne 'ready') { $session = 'stale' }
  if ($recovery.Unsafe) { $session = 'stale' }

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
        try {
          $node = Get-DreamSkinNodeRuntime -NodePath (Join-Path $EngineRoot 'runtime\node.exe') -ExpectedVersion '22.23.1'
        } catch {
          $runtimeInvalid = $true
        }
        if (-not $runtimeInvalid) {
          & $node.Path (Join-Path $PSScriptRoot 'injector.mjs') --verify --port "$port" `
            --browser-id "$($cdpIdentity.BrowserId)" --timeout-ms 5000 *> $null
          $verified = $LASTEXITCODE -eq 0
        }
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
      'stale' { $availableActions = @('restore', 'uninstall') }
      default {
        $availableActions = if ($codexState -eq 'running') {
          @('apply', 'restore', 'verify', 'uninstall')
        } else {
          @('apply', 'restore', 'uninstall')
        }
      }
    }
  } elseif ($recovery.Completed -or $recovery.NeverApplied) {
    $availableActions = @('install', 'uninstall')
  } elseif ($session -eq 'stale' -and $recovery.LiveBackup) {
    $availableActions = @('restore', 'uninstall')
  } elseif ($recovery.Unsafe) {
    $availableActions = @()
  }

  $error = $null
  if ($codexState -eq 'not-installed') {
    $error = New-DreamSkinStudioError -Code 'CODEX_NOT_INSTALLED' -Message 'Codex is not installed.' -RecoveryActions @('cancel')
  } elseif ($codexState -eq 'needs-first-run') {
    $error = New-DreamSkinStudioError -Code 'CODEX_FIRST_RUN_REQUIRED' -Message 'Open Codex and complete first-run setup.' -RecoveryActions @('open-codex', 'retry', 'cancel')
  }
  if ($session -eq 'stale') {
    $recoveryActions = if ($recovery.LiveBackup) { @('restore', 'diagnostics', 'cancel') } else { @('diagnostics', 'cancel') }
    $error = New-DreamSkinStudioError -Code 'STATE_UNSAFE' -Message 'Theme state needs recovery before it can be used.' -RecoveryActions $recoveryActions
  }
  if ($runtimeInvalid) {
    $error = New-DreamSkinStudioError -Code 'RUNTIME_INVALID' -Message 'The Studio runtime is unavailable.' -RecoveryActions @('diagnostics', 'cancel')
  }

  $studioState = New-DreamSkinStudioState -Install $install -Codex $codexState -Session $session `
    -ThemeName $themeName -RequiresRestart $requiresRestart -Verified $verified -AvailableActions $availableActions
  return [pscustomobject]@{
    Ok = $null -eq $error
    State = $studioState
    Error = $error
  }
}
