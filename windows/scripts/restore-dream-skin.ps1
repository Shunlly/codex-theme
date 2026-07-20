[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$Uninstall,
  [switch]$RestoreBaseTheme,
  [switch]$RecoverConfigBackup,
  [switch]$PromptRestart,
  [switch]$CloseRunning,
  [switch]$ForceRestart,
  [switch]$NoRelaunch,
  [switch]$AdapterLockHeld
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

function Stop-DreamSkinTrayProcess {
  $trayScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tray-dream-skin.ps1'))
  try {
    $processes = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" `
      -ErrorAction Stop
    foreach ($process in $processes) {
      if ($process.ProcessId -eq $PID -or -not $process.CommandLine) { continue }
      if ($process.CommandLine.IndexOf($trayScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
      }
    }
  } catch {
    Write-Warning "Could not close the Dream Skin tray automatically: $($_.Exception.Message)"
  }
}

function Remove-DreamSkinRecoveryArtifact {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
  if (Test-Path -LiteralPath $Path) { throw "Recovery artifact could not be removed: $Path" }
}

function Get-DreamSkinRecoveryArtifactSnapshot {
  param([Parameter(Mandatory = $true)][string]$Path)
  Assert-DreamSkinNoReparseComponents -Path $Path
  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ Path = $Path; Exists = $false; Bytes = $null }
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Recovery artifact is not a safe file: $Path"
  }
  return [pscustomobject]@{ Path = $Path; Exists = $true; Bytes = [IO.File]::ReadAllBytes($Path) }
}

function Restore-DreamSkinRecoveryArtifactSnapshot {
  param([Parameter(Mandatory = $true)][object]$Snapshot)
  Assert-DreamSkinNoReparseComponents -Path $Snapshot.Path
  if ($Snapshot.Exists) {
    $currentBytes = if (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf) {
      [IO.File]::ReadAllBytes($Snapshot.Path)
    } else { $null }
    Write-DreamSkinBytesAtomically -Path $Snapshot.Path -Bytes $Snapshot.Bytes -ExpectedBytes $currentBytes
  } else {
    Remove-DreamSkinRecoveryArtifact -Path $Snapshot.Path
  }
}

$operationLock = $null
if (-not (Test-DreamSkinAdapterOperationLockOwner -AdapterLockHeld:$AdapterLockHeld)) {
  $operationLock = Enter-DreamSkinOperationLock
}
try {
  if ($RestoreBaseTheme -and $RecoverConfigBackup) {
    throw 'Choose either -RestoreBaseTheme or -RecoverConfigBackup, not both.'
  }
  if ($ForceRestart -and -not $CloseRunning) {
    throw '-ForceRestart requires -CloseRunning.'
  }
  Assert-DreamSkinPort -Port $Port

  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $themePaths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  $StatePath = Join-Path $StateRoot 'state.json'
  $state = Read-DreamSkinState -Path $StatePath
  if (-not $PortExplicit -and $null -ne $state -and $state.port) {
    $Port = [int]$state.port
    Assert-DreamSkinPort -Port $Port
  }

  $currentCodex = $null
  try { $currentCodex = Get-DreamSkinCodexInstall } catch { Write-Warning $_.Exception.Message }
  $savedPathCandidate = Get-DreamSkinCodexStatePathCandidate -State $state
  $savedCodex = Get-DreamSkinCodexInstallFromState -State $state
  $candidateMatchesCurrent = [bool]($null -ne $savedPathCandidate -and $null -ne $currentCodex -and
    (Test-DreamSkinPathEqual -Left $savedPathCandidate.PackageRoot -Right $currentCodex.PackageRoot) -and
    (Test-DreamSkinPathEqual -Left $savedPathCandidate.Executable -Right $currentCodex.Executable))
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and -not $candidateMatchesCurrent) {
    $unverifiedSavedRunning = (Get-DreamSkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0
    $unverifiedSavedOwnsPort = Test-DreamSkinCodexPortOwner -Port $Port -Codex $savedPathCandidate
    if ($unverifiedSavedRunning -or $unverifiedSavedOwnsPort) {
      throw 'The saved Codex path is still active but no longer matches a registered OpenAI.Codex package. Close it manually; state and configuration were preserved.'
    }
  }
  $savedIsDifferent = [bool]($null -ne $savedCodex -and $null -ne $currentCodex -and
    -not (Test-DreamSkinPathEqual -Left $savedCodex.Executable -Right $currentCodex.Executable))
  $currentRunning = $null -ne $currentCodex -and (Get-DreamSkinCodexProcesses -Codex $currentCodex).Count -gt 0
  $savedRunning = $null -ne $savedCodex -and (Get-DreamSkinCodexProcesses -Codex $savedCodex).Count -gt 0
  $savedOwnsPort = $null -ne $savedCodex -and (Test-DreamSkinCodexPortOwner -Port $Port -Codex $savedCodex)
  if ($savedIsDifferent -and $currentRunning -and ($savedRunning -or $savedOwnsPort)) {
    throw 'Multiple Codex package versions are active. Close them manually before restore; state and configuration were preserved.'
  }

  $codex = $currentCodex
  if ($savedRunning -or $savedOwnsPort -or $null -eq $currentCodex) {
    $codex = $savedCodex
    if ($null -ne $codex -and $savedIsDifferent) {
      Write-Warning 'Using the saved Codex package identity to close its older active CDP session.'
    } elseif ($null -ne $codex -and $null -eq $currentCodex) {
      Write-Warning 'Using the saved Codex identity after revalidating it against the registered Store package.'
    }
  }
  $relaunchCodex = if ($null -ne $currentCodex) { $currentCodex } else { $codex }
  $codexRunning = $null -ne $codex -and (Get-DreamSkinCodexProcesses -Codex $codex).Count -gt 0
  $portOwnedByCodex = $null -ne $codex -and (Test-DreamSkinCodexPortOwner -Port $Port -Codex $codex)
  if ($portOwnedByCodex -and -not $codexRunning) {
    throw 'A Codex-owned listener exists without a manageable Codex process; state was preserved.'
  }
  if ($null -ne $state -and $null -eq $codex -and -not (Test-DreamSkinPortAvailable -Port $Port)) {
    throw "Port $Port is still active, but Codex ownership cannot be verified. State and configuration were preserved."
  }

  $shouldCloseCodex = $codexRunning
  $restartAuthorized = [bool]$CloseRunning
  if ($shouldCloseCodex -and $PromptRestart) {
    $restartMessage = if ($NoRelaunch) {
      'Restore will close Codex and remove Dream Skin plus its CDP session. Continue?'
    } else {
      'Restore will close Codex, remove Dream Skin and its CDP session, then reopen the official app. Continue?'
    }
    $restartAuthorized = Confirm-DreamSkinRestart -Message $restartMessage
    if (-not $restartAuthorized) {
      Write-Host 'Restore was cancelled; no state or configuration was changed.'
      exit 0
    }
  }
  if ($shouldCloseCodex -and -not $restartAuthorized) {
    throw 'Codex is running. Close it first or explicitly use -CloseRunning.'
  }

  $backup = Join-Path $StateRoot 'config.before-dream-skin.toml'
  $archivePath = Join-Path $StateRoot 'config.restored.toml'
  $pausedPath = Join-Path $StateRoot 'paused'
  $backupMarkerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $backup
  $archiveMarkerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $archivePath
  $config = Join-Path $HOME '.codex\config.toml'
  $restoreRequested = $RecoverConfigBackup -or $RestoreBaseTheme
  $completionEvidence = Test-DreamSkinConfigCompletionEvidence -ArchivePath $archivePath
  $restoreAlreadyCommitted = $restoreRequested -and (Test-DreamSkinRestoreCompleted `
    -StateRoot $StateRoot -CompletionEvidence $completionEvidence -BackupPath $backup)
  $artifactSnapshots = @(
    (Get-DreamSkinRecoveryArtifactSnapshot -Path $StatePath),
    (Get-DreamSkinRecoveryArtifactSnapshot -Path $pausedPath),
    (Get-DreamSkinRecoveryArtifactSnapshot -Path $backup),
    (Get-DreamSkinRecoveryArtifactSnapshot -Path $backupMarkerPath),
    (Get-DreamSkinRecoveryArtifactSnapshot -Path $archivePath),
    (Get-DreamSkinRecoveryArtifactSnapshot -Path $archiveMarkerPath)
  )
  $configBeforeRestoreBytes = $null
  if ($RecoverConfigBackup -and -not $restoreAlreadyCommitted) {
    if (-not (Test-DreamSkinLiveConfigBackup -BackupPath $backup)) {
      throw 'No pre-install config backup is available.'
    }
    $configBeforeRestoreBytes = [IO.File]::ReadAllBytes($config)
    $null = ConvertFrom-DreamSkinUtf8Bytes -Bytes $configBeforeRestoreBytes -Path $config
  } elseif ($RestoreBaseTheme -and -not $restoreAlreadyCommitted) {
    if (-not (Test-DreamSkinLiveConfigBackup -BackupPath $backup)) {
      throw 'No pre-install config backup is available.'
    }
    $null = Read-DreamSkinUtf8File -Path $config
    $configBeforeRestoreBytes = [IO.File]::ReadAllBytes($config)
  }

  $restoreError = $null
  $configChanged = $false
  $transactionCommitted = $false
  try {
    if ($shouldCloseCodex) {
      Stop-DreamSkinCodex -Codex $codex -AllowForce:$ForceRestart
      if ($portOwnedByCodex -and -not (Wait-DreamSkinPortAvailable -Port $Port -TimeoutSeconds 5)) {
        throw "Port $Port is still listening after Codex closed; state was preserved for inspection."
      }
    }

    Ensure-DreamSkinManagedDirectory -Path $themePaths.Root -Root $themePaths.Root
    Stop-DreamSkinTrayProcess
    $recordedInjectorStopped = Stop-DreamSkinRecordedInjector -State $state
    if (-not $recordedInjectorStopped) {
      Write-Warning 'The recorded injector identity was stale; lifecycle state will be removed only if restore commits.'
    }

    if ($RecoverConfigBackup -and -not $restoreAlreadyCommitted) {
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N')
      $recoveryBackup = Join-Path $StateRoot "config.before-recovery-$stamp.toml"
      Restore-DreamSkinConfigBackup -ConfigPath $config -BackupPath $backup -RecoveryBackupPath $recoveryBackup
      $configChanged = $true
      Write-Host "Recovered the exact pre-install config; previous current config saved at $recoveryBackup"
    } elseif ($RestoreBaseTheme -and -not $restoreAlreadyCommitted) {
      Restore-DreamSkinBaseTheme -ConfigPath $config -BackupPath $backup
      $configChanged = $true
    }

    if ($restoreRequested -and -not $restoreAlreadyCommitted) {
      Publish-DreamSkinConfigBackupArchive -BackupPath $backup -ArchivePath $archivePath
    }
    Remove-DreamSkinRecoveryArtifact -Path $StatePath
    Remove-DreamSkinRecoveryArtifact -Path (Join-Path $StateRoot 'paused')
    Remove-DreamSkinRecoveryArtifact -Path $backupMarkerPath
    if ($restoreRequested -and -not $restoreAlreadyCommitted) {
      Remove-DreamSkinRecoveryArtifact -Path $backup
    }
    $transactionCommitted = $true
    if ($restoreRequested) { Write-Host "Archived the completed pre-install backup at $archivePath" }
    if ($Uninstall) {
      $desktop = [Environment]::GetFolderPath('Desktop')
      $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
      @(
        (Join-Path $desktop 'Codex Dream Skin.lnk'),
        (Join-Path $desktop 'Codex Dream Skin - Restore.lnk'),
        (Join-Path $desktop 'Codex Dream Skin - Tray.lnk'),
        (Join-Path $startMenu 'Codex Dream Skin.lnk'),
        (Join-Path $startMenu 'Codex Dream Skin - Tray.lnk')
      ) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
    }
  } catch {
    $restoreError = $_
    if (-not $transactionCommitted -and $configChanged -and $null -ne $configBeforeRestoreBytes) {
      try {
        $currentConfigBytes = [IO.File]::ReadAllBytes($config)
        Write-DreamSkinBytesAtomically -Path $config -Bytes $configBeforeRestoreBytes -ExpectedBytes $currentConfigBytes
      } catch {
        Write-Warning 'Restore failed and the original config could not be rolled back automatically.'
      }
    }
    if (-not $transactionCommitted) {
      foreach ($snapshot in $artifactSnapshots) {
        try { Restore-DreamSkinRecoveryArtifactSnapshot -Snapshot $snapshot } catch {
          Write-Warning "Restore failed and a recovery artifact could not be rolled back: $($snapshot.Path)"
        }
      }
    }
    throw $restoreError
  }

  if ($shouldCloseCodex -and -not $NoRelaunch) {
    try {
      if ($null -eq $relaunchCodex -or -not (Test-Path -LiteralPath $relaunchCodex.Executable)) {
        throw 'The Codex executable is unavailable.'
      }
      Start-Process -FilePath $relaunchCodex.Executable | Out-Null
    } catch {
      Write-Warning 'Codex could not be reopened automatically. The restore is complete; open Codex normally when you are ready.'
    }
  }

  Write-Host 'Dream Skin restore actions completed; any saved CDP session was closed.'
} finally {
  if ($null -ne $operationLock) { Exit-DreamSkinOperationLock -Mutex $operationLock }
}
