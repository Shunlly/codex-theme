[CmdletBinding()]
param(
  [int]$Port = 9335,
  [switch]$RestartExisting,
  [switch]$PromptRestart,
  [string]$ProfilePath,
  [switch]$ForegroundInjector,
  [string]$NodePath,
  [switch]$ForceRestart,
  [switch]$AdapterLockHeld
)

$ErrorActionPreference = 'Stop'
$PortExplicit = $PSBoundParameters.ContainsKey('Port')
$Injector = Join-Path $PSScriptRoot 'injector.mjs'
. (Join-Path $PSScriptRoot 'common-windows.ps1')
. (Join-Path $PSScriptRoot 'theme-windows.ps1')

function Invoke-DreamSkinStartupCleanup {
  param(
    [Parameter(Mandatory = $true)][object]$Codex,
    [AllowNull()][object]$ClosedCodex,
    [AllowNull()][Nullable[int]]$ClosedCodexPort,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$Injector,
    [Parameter(Mandatory = $true)][object]$Node,
    [AllowNull()][object]$State,
    [AllowNull()][object]$Daemon,
    [AllowNull()][object]$CdpIdentity,
    [bool]$PriorInjectorCleanupProven,
    [bool]$NewManagedCdp,
    [AllowNull()][object]$PublishedStateSnapshot
  )
  $injectorStopped = $PriorInjectorCleanupProven
  $cleanupProven = $false
  if ($null -ne $State -and $State.injectorPid) {
    try {
      $currentInjectorStopped = Stop-DreamSkinRecordedInjector -State $State
      $injectorStopped = $injectorStopped -and $currentInjectorStopped
    } catch {
      $injectorStopped = $false
      Write-Warning $_.Exception.Message
    }
  } elseif ($null -ne $Daemon -and -not $Daemon.HasExited) {
    try {
      Stop-Process -InputObject $Daemon -Force -ErrorAction Stop
      [void]$Daemon.WaitForExit(5000)
      $injectorStopped = $injectorStopped -and $Daemon.HasExited
    } catch {
      $injectorStopped = $false
      Write-Warning 'The newly created injector could not be stopped during startup rollback.'
    }
  }

  if ($injectorStopped -and -not $NewManagedCdp -and $null -ne $CdpIdentity) {
    try {
      $rollbackIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $Codex
      if ($null -eq $rollbackIdentity -or $rollbackIdentity.BrowserId -cne $CdpIdentity.BrowserId) {
        throw 'The rollback Browser ID could not be verified.'
      }
      & $Node.Path $Injector --remove --port $Port --browser-id $CdpIdentity.BrowserId `
        --timeout-ms 5000 *> $null
      if ($LASTEXITCODE -ne 0) { throw 'Injector removal returned a failure status.' }
      $cleanupProven = $true
    } catch {
      Write-Warning 'Startup rollback could not remove the partially applied live skin; reload or close Codex to clear it.'
    }
  }
  if ($NewManagedCdp) {
    try {
      Stop-DreamSkinCodex -Codex $Codex -AllowForce
      if (@(Get-DreamSkinCodexProcessesStrict -Codex $Codex).Count -ne 0) {
        throw 'Codex processes remain after startup rollback.'
      }
      if (@(Get-DreamSkinPortListenersStrict -Port $Port).Count -ne 0) {
        throw "The rollback CDP listener on port $Port did not close."
      }
      $cleanupProven = $true
    } catch {
      Write-Warning 'Startup rollback could not fully close Codex; recovery state was preserved.'
    }
  }
  if ($null -ne $ClosedCodex) {
    $closedCleanupProven = $false
    if (-not $NewManagedCdp -or $cleanupProven) {
      try {
        if ($null -eq $ClosedCodexPort) { throw 'The closed Codex port was not retained.' }
        $closedMatchesCurrentCandidate = Test-DreamSkinPathEqual `
          -Left $ClosedCodex.Executable -Right $Codex.Executable
        if (-not ($NewManagedCdp -and $closedMatchesCurrentCandidate) -and
          @(Get-DreamSkinCodexProcessesStrict -Codex $ClosedCodex).Count -ne 0) {
          throw 'The pre-launch closed Codex process appeared or remained during startup rollback.'
        }
        $closedMatchesCurrent = Test-DreamSkinPathEqual -Left $ClosedCodex.Executable -Right $Codex.Executable
        if (-not $NewManagedCdp -and -not $closedMatchesCurrent -and
          @(Get-DreamSkinCodexProcessesStrict -Codex $Codex).Count -ne 0) {
          throw 'The current Codex process appeared during pre-launch startup rollback.'
        }
        $closedPortMatchesCurrent = [int]$ClosedCodexPort -eq $Port
        if (-not ($NewManagedCdp -and $closedPortMatchesCurrent) -and
          @(Get-DreamSkinPortListenersStrict -Port ([int]$ClosedCodexPort)).Count -ne 0) {
          throw "The pre-launch closed CDP listener on port $ClosedCodexPort appeared or remained."
        }
        $closedCleanupProven = $true
      } catch {
        Write-Warning 'Startup rollback could not prove the pre-launch closed Codex session remained absent.'
      }
    }
    if ($NewManagedCdp) {
      $cleanupProven = $cleanupProven -and $closedCleanupProven
    } elseif ($closedCleanupProven) {
      $cleanupProven = $true
    } else {
      $cleanupProven = $false
    }
  }
  $cleanupComplete = $injectorStopped -and $cleanupProven
  if ($cleanupComplete -and $null -ne $PublishedStateSnapshot -and
    ($NewManagedCdp -or $null -eq $ClosedCodex)) {
    try {
      [DreamSkinConfigNative]::DeleteExpectedFile(
        $StatePath, $PublishedStateSnapshot.Identity, $PublishedStateSnapshot.Bytes)
    } catch {
      $cleanupComplete = $false
      Write-Warning 'Startup rollback closed the live session but could not consume its exact recovery state.'
    }
  }
  return $cleanupComplete
}

$operationLock = $null
if (-not (Test-DreamSkinAdapterOperationLockOwner -AdapterLockHeld:$AdapterLockHeld)) {
  $operationLock = Enter-DreamSkinOperationLock
}
try {
  Assert-DreamSkinPort -Port $Port
  if ($ProfilePath) { $ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath) }
  $node = Get-DreamSkinNodeRuntime -NodePath $NodePath
  $currentCodex = Get-DreamSkinCodexInstall
  $codex = $currentCodex
  $StateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
  $themePaths = Get-DreamSkinThemePaths -StateRoot $StateRoot
  $StatePath = Join-Path $StateRoot 'state.json'
  $StdoutPath = Join-Path $StateRoot 'injector.log'
  $StderrPath = Join-Path $StateRoot 'injector-error.log'
  $VerifyPath = Join-Path $StateRoot 'verify.log'
  $pauseWasSet = Test-DreamSkinPaused -StateRoot $StateRoot

  $previousState = Read-DreamSkinState -Path $StatePath
  if (-not $PortExplicit -and $null -ne $previousState -and $previousState.port) {
    $savedPort = [int]$previousState.port
    Assert-DreamSkinPort -Port $savedPort
    $Port = $savedPort
  }
  if ($null -ne $previousState -and $previousState.schemaVersion -eq 4 -and
    "$($previousState.recoveryKind)" -ceq 'managed-cdp') {
    throw 'A previous managed CDP startup still needs cleanup. Run Restore before starting Dream Skin again; state was preserved.'
  }
  $savedPathCandidate = Get-DreamSkinCodexStatePathCandidate -State $previousState
  $savedCodex = Get-DreamSkinCodexInstallFromState -State $previousState
  $candidateMatchesCurrent = [bool]($null -ne $savedPathCandidate -and
    (Test-DreamSkinPathEqual -Left $savedPathCandidate.PackageRoot -Right $currentCodex.PackageRoot) -and
    (Test-DreamSkinPathEqual -Left $savedPathCandidate.Executable -Right $currentCodex.Executable))
  if ($null -ne $savedPathCandidate -and $null -eq $savedCodex -and -not $candidateMatchesCurrent) {
    $unverifiedSavedRunning = @(Get-DreamSkinCodexProcesses -Codex $savedPathCandidate).Count -gt 0
    $unverifiedSavedOwnsPort = Test-DreamSkinCodexPortOwner -Port $Port -Codex $savedPathCandidate
    if ($unverifiedSavedRunning -or $unverifiedSavedOwnsPort) {
      throw 'The saved Codex path is still active but no longer matches a registered OpenAI.Codex package. Close it manually; state was preserved.'
    }
  }

  $currentProcesses = @(Get-DreamSkinCodexProcesses -Codex $currentCodex)
  $codexToStop = $currentCodex
  $closedCodex = $null
  $closedCodexPort = $null
  $cdpIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $currentCodex
  $savedIsDifferent = [bool]($null -ne $savedCodex -and
    -not (Test-DreamSkinPathEqual -Left $savedCodex.Executable -Right $currentCodex.Executable))
  if ($savedIsDifferent) {
    $savedProcesses = @(Get-DreamSkinCodexProcesses -Codex $savedCodex)
    $savedOwnsPort = Test-DreamSkinCodexPortOwner -Port $Port -Codex $savedCodex
    if ($currentProcesses.Count -gt 0 -and ($savedProcesses.Count -gt 0 -or $savedOwnsPort)) {
      throw 'Multiple registered Codex package versions are active. Close them manually before starting Dream Skin.'
    }
    if ($savedProcesses.Count -gt 0 -or $savedOwnsPort) {
      if ($savedOwnsPort -and $savedProcesses.Count -eq 0) {
        throw 'The saved Codex listener is active but its process cannot be managed safely; state was preserved.'
      }
      $savedIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $savedCodex
      if ($null -ne $savedIdentity) {
        $codex = $savedCodex
        $codexToStop = $savedCodex
        $cdpIdentity = $savedIdentity
        Write-Warning 'Reapplying Dream Skin to the still-running registered Codex version; the current Store version will be used after that app exits.'
      } else {
        $codexToStop = $savedCodex
        $currentProcesses = $savedProcesses
      }
    }
  }
  $debugReady = $null -ne $cdpIdentity
  $codexProcesses = @(if (Test-DreamSkinPathEqual -Left $codexToStop.Executable -Right $currentCodex.Executable) {
    $currentProcesses
  } else {
    Get-DreamSkinCodexProcesses -Codex $codexToStop
  })
  if (-not $debugReady -and $codexProcesses.Count -gt 0) {
    $restartAuthorized = [bool]$RestartExisting
    if (-not $restartAuthorized -and $PromptRestart) {
      $restartAuthorized = Confirm-DreamSkinRestart -Message 'Codex must restart once to enable Dream Skin. Unsaved input may be lost. Restart now?'
      if (-not $restartAuthorized) {
        Write-Host 'Dream Skin launch was cancelled; Codex was not changed.'
        exit 0
      }
    }
    if (-not $restartAuthorized) {
      throw 'Codex is open without a verified Dream Skin CDP endpoint. Close it first or explicitly use -RestartExisting.'
    }
    Stop-DreamSkinCodex -Codex $codexToStop -AllowForce:$ForceRestart
    $closedCodex = $codexToStop
    $closedCodexPort = $Port
    $codex = $currentCodex
  }

  $newManagedCdp = $false
  $publishedStateSnapshot = $null
  $pauseCleared = $false
  $state = $null
  $daemon = $null
  $priorInjectorCleanupProven = $null -eq $previousState -or -not $previousState.injectorPid
  try {
    Ensure-DreamSkinManagedDirectory -Path $themePaths.Root -Root $themePaths.Root
    $themePaths = Initialize-DreamSkinThemeStore -SkillRoot (Split-Path -Parent $PSScriptRoot) `
      -StateRoot $StateRoot -NodePath $node.Path

    $recordedInjectorStopped = Stop-DreamSkinRecordedInjector -State $previousState
    $priorInjectorCleanupProven = [bool]$recordedInjectorStopped
    if (-not $recordedInjectorStopped) {
      $staleStatePath = Archive-DreamSkinStateFile -Path $StatePath
      Write-Warning "Archived stale Dream Skin state at $staleStatePath"
    }

    if ($null -eq (Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codex)) {
      if (-not (Test-DreamSkinPortAvailable -Port $Port)) {
        if ($PortExplicit) { throw "Port $Port is already occupied by an unverified listener. Choose another port." }
        $Port = Select-DreamSkinPort -PreferredPort $Port
      }
      $arguments = @('--remote-debugging-address=127.0.0.1', "--remote-debugging-port=$Port")
      if ($ProfilePath) {
        New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
        $arguments += ConvertTo-DreamSkinProcessArgument -Value "--user-data-dir=$ProfilePath"
      }
      $state = [pscustomobject]@{
        schemaVersion = 4
        platform = 'windows'
        recoveryKind = 'managed-cdp'
        port = $Port
        codexExe = $codex.Executable
        codexPackageRoot = $codex.PackageRoot
        codexPackageFullName = $codex.PackageFullName
        codexPackageFamilyName = $codex.PackageFamilyName
        codexVersion = $codex.Version
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
      }
      Write-DreamSkinState -Path $StatePath -State $state
      $publishedStateSnapshot = Get-DreamSkinStableFileSnapshot -Path $StatePath
      $newManagedCdp = $true
      Start-Process -FilePath $codex.Executable -ArgumentList $arguments | Out-Null
    }

    $deadline = (Get-Date).AddSeconds(45)
    $cdpIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codex
    while ($null -eq $cdpIdentity) {
      if ((Get-Date) -ge $deadline) {
        throw "Codex did not expose a verified loopback CDP endpoint on port $Port within 45 seconds."
      }
      Start-Sleep -Milliseconds 400
      $cdpIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codex
    }

  # Keep a paused, already-running watcher paused until all state checks and any
  # restart consent have succeeded.  A cancelled prompt must be side-effect free.
  Set-DreamSkinPaused -Paused $false -StateRoot $StateRoot | Out-Null
  $pauseCleared = $true

  if ($ForegroundInjector) {
    $foregroundCleanupNewManagedCdp = $newManagedCdp
    $foregroundCleanupCdpIdentity = $cdpIdentity
    $foregroundCleanupSnapshot = $publishedStateSnapshot
    $foregroundCleanupClosedCodex = $closedCodex
    $foregroundCleanupClosedCodexPort = $closedCodexPort
    $foregroundCleanupPauseWasSet = $pauseWasSet
    $foregroundCleanupPauseCleared = $pauseCleared
    $newManagedCdp = $false
    $cdpIdentity = $null
    $publishedStateSnapshot = $null
    $closedCodex = $null
    $closedCodexPort = $null
    $pauseWasSet = $false
    $pauseCleared = $false
    Exit-DreamSkinOperationLock -Mutex $operationLock
    $operationLock = $null
    & $node.Path $Injector --watch --port $Port --browser-id $foregroundCleanupCdpIdentity.BrowserId `
      --theme-dir $themePaths.Active --pause-file $themePaths.PauseFile
    if ($LASTEXITCODE -ne 0) {
      try {
        $operationLock = Enter-DreamSkinOperationLock
        if ($foregroundCleanupNewManagedCdp) {
          if ($null -eq $foregroundCleanupSnapshot) {
            throw 'Foreground cleanup has no exact published recovery snapshot.'
          }
          Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $foregroundCleanupSnapshot
          $foregroundCurrentProcesses = @(Get-DreamSkinCodexProcessesStrict -Codex $codex)
          if ($foregroundCurrentProcesses.Count -eq 0) {
            throw 'Foreground cleanup could not prove the managed Codex process remained present.'
          }
          $foregroundCurrentListeners = @(Get-DreamSkinPortListenersStrict -Port $Port)
          if ($foregroundCurrentListeners.Count -eq 0) {
            throw 'Foreground cleanup could not prove the managed CDP listener remained present.'
          }
        }
        if ($null -eq $foregroundCleanupCdpIdentity) {
          throw 'Foreground cleanup has no captured Browser identity.'
        }
        $foregroundIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $codex
        if ($null -eq $foregroundIdentity -or
          $foregroundIdentity.BrowserId -cne $foregroundCleanupCdpIdentity.BrowserId) {
          throw 'Foreground cleanup Browser identity changed while the operation lock was released.'
        }
        if ($null -ne $foregroundCleanupClosedCodex) {
          if ($null -eq $foregroundCleanupClosedCodexPort) {
            throw 'Foreground cleanup has no captured closed-session port.'
          }
          $foregroundClosedMatchesCurrent = Test-DreamSkinPathEqual `
            -Left $foregroundCleanupClosedCodex.Executable -Right $codex.Executable
          if (-not ($foregroundCleanupNewManagedCdp -and $foregroundClosedMatchesCurrent) -and
            @(Get-DreamSkinCodexProcessesStrict -Codex $foregroundCleanupClosedCodex).Count -ne 0) {
            throw 'Foreground cleanup closed-session identity changed while the operation lock was released.'
          }
          $foregroundClosedPortMatchesCurrent = [int]$foregroundCleanupClosedCodexPort -eq $Port
          if (-not ($foregroundCleanupNewManagedCdp -and $foregroundClosedPortMatchesCurrent) -and
            @(Get-DreamSkinPortListenersStrict -Port ([int]$foregroundCleanupClosedCodexPort)).Count -ne 0) {
            throw 'Foreground cleanup closed-session port changed while the operation lock was released.'
          }
        }
        $newManagedCdp = $foregroundCleanupNewManagedCdp
        $cdpIdentity = $foregroundCleanupCdpIdentity
        $publishedStateSnapshot = $foregroundCleanupSnapshot
        $closedCodex = $foregroundCleanupClosedCodex
        $closedCodexPort = $foregroundCleanupClosedCodexPort
        $pauseWasSet = $foregroundCleanupPauseWasSet
        $pauseCleared = $foregroundCleanupPauseCleared
      } catch {
        Write-Warning 'Foreground cleanup authority changed while the operation lock was released; the newer transaction was preserved.'
      }
      throw 'The foreground injector exited during startup.'
    }
    exit 0
  }

    $injectorArgs = @((ConvertTo-DreamSkinProcessArgument -Value $Injector), '--watch', '--port', "$Port",
      '--browser-id', $cdpIdentity.BrowserId, '--theme-dir',
      (ConvertTo-DreamSkinProcessArgument -Value $themePaths.Active), '--pause-file',
      (ConvertTo-DreamSkinProcessArgument -Value $themePaths.PauseFile))
    $daemon = Start-Process -FilePath $node.Path -ArgumentList $injectorArgs -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    Start-Sleep -Milliseconds 500
    if ($daemon.HasExited) { throw "The injector exited during startup. See $StderrPath" }

    $injectorStartedAt = Get-DreamSkinProcessStartedAt -ProcessId $daemon.Id
    if (-not $injectorStartedAt) { throw 'The injector process identity could not be recorded safely.' }
    $state = [pscustomobject]@{
      schemaVersion = 3
      platform = 'windows'
      port = $Port
      injectorPid = $daemon.Id
      injectorStartedAt = $injectorStartedAt
      injectorPath = $Injector
      nodePath = $node.Path
      nodeVersion = $node.Version
      codexExe = $codex.Executable
      codexPackageRoot = $codex.PackageRoot
      codexPackageFullName = $codex.PackageFullName
      codexPackageFamilyName = $codex.PackageFamilyName
      codexVersion = $codex.Version
      browserId = $cdpIdentity.BrowserId
      profilePath = $ProfilePath
      themeDir = $themePaths.Active
      pauseFile = $themePaths.PauseFile
      createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-DreamSkinState -Path $StatePath -State $state
    $publishedStateSnapshot = Get-DreamSkinStableFileSnapshot -Path $StatePath

    $verifyOutput = @(& $node.Path $Injector --verify --port $Port --browser-id $cdpIdentity.BrowserId `
      --timeout-ms 30000 2>&1)
    $verifyExitCode = $LASTEXITCODE
    Write-DreamSkinUtf8FileAtomically -Path $VerifyPath -Content (($verifyOutput -join "`r`n") + "`r`n")
    if ($verifyExitCode -ne 0) { throw "Dream Skin verification failed. See $VerifyPath" }
  } catch {
    $startupError = $_
    $cleanupProven = Invoke-DreamSkinStartupCleanup -Codex $codex -Port $Port -StatePath $StatePath `
      -ClosedCodex $closedCodex -ClosedCodexPort $closedCodexPort -Injector $Injector -Node $node `
      -State $state -Daemon $daemon -CdpIdentity $cdpIdentity `
      -PriorInjectorCleanupProven $priorInjectorCleanupProven -NewManagedCdp $newManagedCdp `
      -PublishedStateSnapshot $publishedStateSnapshot
    if (($newManagedCdp -or $null -ne $closedCodex) -and $cleanupProven) {
      try { Start-Process -FilePath $codex.Executable | Out-Null } catch {
        Write-Warning 'Startup rollback closed the CDP session but could not reopen Codex automatically.'
      }
    }
    if ($pauseWasSet -and $pauseCleared) {
      try {
        Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot | Out-Null
      } catch {
        Write-Warning 'Startup rollback could not restore the existing paused state.'
      }
    }
    throw $startupError
  }

  Write-Host "Codex Dream Skin is active on verified loopback port $Port."
} finally {
  if ($null -ne $operationLock) { Exit-DreamSkinOperationLock -Mutex $operationLock }
}
