param(
  [string]$Operation,
  [switch]$RestartAuthorized,
  [switch]$ForceAuthorized,
  [switch]$DeleteUserThemes,
  [switch]$Deep
)

$ErrorActionPreference = 'Stop'
$UnknownArguments = @($args)

function Write-InvalidRequest {
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $envelope = [pscustomobject][ordered]@{
    schemaVersion = 1
    ok = $false
    operation = $Operation
    state = [pscustomobject][ordered]@{
      install = 'not-installed'; codex = 'not-installed'; session = 'official'; operation = 'idle'
      themeName = $null; requiresRestart = $false; availableActions = @(); verified = $null
    }
    error = [pscustomobject][ordered]@{
      code = 'INVALID_REQUEST'; message = 'The Studio operation is invalid.'; recoveryActions = @('cancel')
    }
  }
  [Console]::Out.WriteLine(($envelope | ConvertTo-Json -Compress -Depth 8))
  exit 2
}

$operations = @('preflight', 'install', 'apply', 'status', 'pause', 'resume', 'restore', 'verify', 'uninstall')
if (-not $Operation -or $Operation -notin $operations) {
  $Operation = 'status'
  Write-InvalidRequest
}
if ($UnknownArguments.Count -gt 0) { Write-InvalidRequest }
if ($ForceAuthorized -and -not $RestartAuthorized) { Write-InvalidRequest }
if ($DeleteUserThemes -and $Operation -ne 'uninstall') { Write-InvalidRequest }
if ($Deep -and $Operation -notin @('preflight', 'status')) { Write-InvalidRequest }
if ($Operation -in @('preflight', 'status') -and ($RestartAuthorized -or $ForceAuthorized -or $DeleteUserThemes)) {
  Write-InvalidRequest
}
if ($Operation -in @('pause', 'verify') -and ($RestartAuthorized -or $ForceAuthorized)) { Write-InvalidRequest }

if ($Operation -in @('preflight', 'status')) {
  & (Join-Path $PSScriptRoot 'status-dream-skin.ps1') -Operation $Operation -Deep:$Deep
  exit $LASTEXITCODE
}

$EngineRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$PrivateNodePath = Join-Path $EngineRoot 'runtime\node.exe'
. (Join-Path $PSScriptRoot 'studio-windows.ps1')

function Copy-DreamSkinStudioState {
  param([Parameter(Mandatory = $true)][object]$State, [bool]$RequiresRestart = $State.requiresRestart)
  return New-DreamSkinStudioState -Install "$($State.install)" -Codex "$($State.codex)" `
    -Session "$($State.session)" -Operation 'idle' -ThemeName $State.themeName `
    -RequiresRestart $RequiresRestart -Verified $State.verified -AvailableActions @($State.availableActions)
}

function Exit-DreamSkinStudioError {
  param(
    [Parameter(Mandatory = $true)][string]$Code,
    [Parameter(Mandatory = $true)][string]$Message,
    [Parameter(Mandatory = $true)][string[]]$RecoveryActions,
    [AllowNull()][object]$State,
    [switch]$RequiresRestart
  )
  if ($null -eq $State) {
    $State = New-DreamSkinStudioState -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
      -ThemeName $null -Verified $null -AvailableActions @()
  } else {
    $State = Copy-DreamSkinStudioState -State $State `
      -RequiresRestart ([bool]($RequiresRestart -or $State.requiresRestart))
  }
  $error = [pscustomobject][ordered]@{
    code = $Code
    message = $Message
    recoveryActions = @($RecoveryActions)
  }
  Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $false -State $State -Error $error
  exit 1
}

function Get-DreamSkinLifecycleStatus {
  return Get-DreamSkinStudioStatus -Deep
}

function Test-DreamSkinResumeHotPath {
  try {
    $state = Read-DreamSkinState -Path (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\state.json')
    if ($null -eq $state -or -not $state.browserId -or -not $state.port) { return $false }
    $installs = @(Get-DreamSkinRegisteredCodexInstalls)
    $codex = Resolve-DreamSkinCodexInstallFromState -State $state -RegisteredInstalls $installs
    if ($null -eq $codex) { return $false }
    $identity = Get-DreamSkinVerifiedCdpIdentity -Port ([int]$state.port) -Codex $codex
    return $null -ne $identity -and $identity.BrowserId -ceq "$($state.browserId)"
  } catch {
    return $false
  }
}

function Remove-DreamSkinUserThemeData {
  param([Parameter(Mandatory = $true)][string]$StateRoot)
  $deletePaths = @('themes', 'images', 'active-theme') | ForEach-Object { Join-Path $StateRoot $_ }
  foreach ($path in $deletePaths) {
    if ((Test-Path -LiteralPath $path) -and -not (Test-DreamSkinThemePathWithin -Path $path -Root $StateRoot)) {
      throw 'A user theme directory is unsafe to remove.'
    }
  }
  foreach ($path in $deletePaths) {
    if (Test-Path -LiteralPath $path) {
      if (-not (Test-DreamSkinThemePathWithin -Path $path -Root $StateRoot)) {
        throw 'A user theme directory changed before removal.'
      }
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    }
  }
}

function Invoke-DreamSkinLifecycleChild {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogPath
  )
  $powershellPath = Join-Path $PSHOME 'powershell.exe'
  if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
    throw 'The fixed Windows PowerShell runtime is unavailable.'
  }
  $tokens = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
  $argumentLine = (@($tokens | ForEach-Object { ConvertTo-DreamSkinProcessArgument -Value "$_" })) -join ' '
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $powershellPath
  $startInfo.Arguments = $argumentLine
  $startInfo.WorkingDirectory = $EngineRoot
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  $startInfo.EnvironmentVariables['DREAM_SKIN_ADAPTER_LOCK_OWNER_PID'] = "$PID"
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw 'The lifecycle child process could not be started.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    [IO.File]::WriteAllText($LogPath, $stdout + $stderr, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout + "`n" + $stderr }
  } finally {
    $process.Dispose()
  }
}

function Exit-DreamSkinChildFailure {
  param([Parameter(Mandatory = $true)][object]$Child, [Parameter(Mandatory = $true)][object]$State)
  $output = "$($Child.Output)"
  if ($output -match 'Codex did not close within 15 seconds') {
    Exit-DreamSkinStudioError -Code 'FORCE_STOP_REQUIRED' -Message 'Codex must close before the operation can continue.' `
      -RecoveryActions @('authorize-force-stop', 'cancel') -State $State
  }
  if ($output -match 'private Node\.js runtime|Node\.js runtime.*(?:invalid|required|validated|unavailable)') {
    Exit-DreamSkinStudioError -Code 'RUNTIME_INVALID' -Message 'The Studio runtime is unavailable.' `
      -RecoveryActions @('diagnostics', 'cancel') -State $State
  }
  if ($Operation -eq 'install' -and $output -match 'Close Codex before installing Dream Skin') {
    Exit-DreamSkinStudioError -Code 'CODEX_CLOSE_REQUIRED' -Message 'Codex must close before Studio can be installed.' `
      -RecoveryActions @('authorize-restart', 'cancel') -State $State -RequiresRestart
  }
  if ($output -match 'open without a verified Dream Skin CDP endpoint|explicitly use -CloseRunning') {
    Exit-DreamSkinStudioError -Code 'RESTART_REQUIRED' -Message 'Codex must restart once to apply the theme.' `
      -RecoveryActions @('authorize-restart', 'cancel') -State $State -RequiresRestart
  }
  if ($output -match 'STATE_UNSAFE|state is unreadable|state is damaged|identity does not match|state was preserved') {
    Exit-DreamSkinStudioError -Code 'STATE_UNSAFE' -Message 'Theme state needs recovery before it can be used.' `
      -RecoveryActions @('restore', 'diagnostics', 'cancel') -State $State
  }
  if ($output -match 'LIVE_REMOVE_FAILED') {
    Exit-DreamSkinStudioError -Code 'LIVE_REMOVE_FAILED' -Message 'The live theme could not be removed safely.' `
      -RecoveryActions @('restore', 'diagnostics', 'cancel') -State $State
  }
  if ($Operation -eq 'verify' -or $output -match 'verification failed|verify failed') {
    Exit-DreamSkinStudioError -Code 'VERIFY_FAILED' -Message 'Theme verification failed.' `
      -RecoveryActions @('retry', 'restore', 'diagnostics', 'cancel') -State $State
  }
  Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'The Studio operation failed.' `
    -RecoveryActions @('retry', 'diagnostics', 'cancel') -State $State
}

$status = $null
$operationLock = $null
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
try {
  try {
    $operationLock = Enter-DreamSkinOperationLock
  } catch {
    $busyState = New-DreamSkinStudioState -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
      -Operation 'busy' -ThemeName $null -Verified $null -AvailableActions @()
    Exit-DreamSkinStudioError -Code 'OPERATION_BUSY' -Message 'Another Studio operation is already running.' `
      -RecoveryActions @('retry', 'cancel') -State $busyState
  }
  if ($Operation -in @('install', 'apply', 'pause', 'resume', 'verify')) {
    try { $null = Get-DreamSkinNodeRuntime -NodePath $PrivateNodePath -ExpectedVersion '22.23.1' } catch {
      Exit-DreamSkinStudioError -Code 'RUNTIME_INVALID' -Message 'The Studio runtime is unavailable.' `
        -RecoveryActions @('diagnostics', 'cancel') -State $null
    }
  }

  $status = Get-DreamSkinLifecycleStatus
  $recovery = Get-DreamSkinStudioRecoveryState -StateRoot $stateRoot
  $restoreRecoveryAvailable = $recovery.LiveBackup -or $recovery.Completed
  $uninstallRecoveryAvailable = $restoreRecoveryAvailable -or $recovery.NeverApplied
  $recoveringStatusError = $null -ne $status.Error -and (
    ($Operation -eq 'restore' -and $restoreRecoveryAvailable -and
      $status.Error.code -in @('STATE_UNSAFE', 'RUNTIME_INVALID', 'CODEX_NOT_INSTALLED', 'CODEX_FIRST_RUN_REQUIRED')) -or
    ($Operation -eq 'uninstall' -and $uninstallRecoveryAvailable -and
      $status.Error.code -in @('STATE_UNSAFE', 'RUNTIME_INVALID', 'CODEX_NOT_INSTALLED', 'CODEX_FIRST_RUN_REQUIRED'))
  )
  if (-not $status.Ok -and -not $recoveringStatusError) {
    Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $false -State $status.State -Error $status.Error
    exit 1
  }
  $canSkipCompletedUninstall = $Operation -eq 'uninstall' -and
    $status.State.install -eq 'not-installed' -and $status.State.session -eq 'official' -and
    -not $status.State.requiresRestart -and ($recovery.Completed -or $recovery.NeverApplied)
  if ($canSkipCompletedUninstall) {
    [Console]::Error.WriteLine('DREAM_SKIN_PROGRESS=uninstalling')
    Remove-DreamSkinManagedLegacyShortcuts
    if ($DeleteUserThemes) { Remove-DreamSkinUserThemeData -StateRoot $stateRoot }
    $uninstalledState = New-DreamSkinStudioState -Install 'not-installed' -Codex 'stopped' -Session 'official' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @('install')
    Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $true -State $uninstalledState -Error $null
    exit 0
  }
  if (($Operation -eq 'restore' -and -not $restoreRecoveryAvailable) -or
    ($Operation -eq 'uninstall' -and -not $uninstallRecoveryAvailable)) {
    Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'Safe restore evidence is unavailable.' `
      -RecoveryActions @('diagnostics', 'cancel') -State $status.State
  }
  if ($Operation -eq 'install' -and $status.State.codex -eq 'running' -and -not $RestartAuthorized) {
    Exit-DreamSkinStudioError -Code 'CODEX_CLOSE_REQUIRED' -Message 'Codex must close before Studio can be installed.' `
      -RecoveryActions @('authorize-restart', 'cancel') -State $status.State -RequiresRestart
  }
  if ($Operation -in @('apply', 'resume') -and $status.State.requiresRestart -and -not $RestartAuthorized) {
    Exit-DreamSkinStudioError -Code 'RESTART_REQUIRED' -Message 'Codex must restart once to apply the theme.' `
      -RecoveryActions @('authorize-restart', 'cancel') -State $status.State -RequiresRestart
  }
  if ($Operation -eq 'resume' -and $status.State.codex -eq 'running' -and
    $status.State.session -eq 'paused' -and -not $RestartAuthorized -and
    -not (Test-DreamSkinResumeHotPath)) {
    Exit-DreamSkinStudioError -Code 'RESTART_REQUIRED' -Message 'Codex must restart once to resume the theme.' `
      -RecoveryActions @('authorize-restart', 'cancel') -State $status.State -RequiresRestart
  }
  if ($Operation -in @('restore', 'uninstall') -and
    $status.State.requiresRestart -and -not $RestartAuthorized) {
    Exit-DreamSkinStudioError -Code 'RESTART_REQUIRED' -Message 'Codex must restart once to restore the official session.' `
      -RecoveryActions @('authorize-restart', 'cancel') -State $status.State -RequiresRestart
  }

  switch ($Operation) {
    'install' {
      $progress = 'installing'; $scriptPath = Join-Path $PSScriptRoot 'install-dream-skin.ps1'
      $childArguments = @('-NoShortcuts', '-NodePath', $PrivateNodePath)
    }
    'apply' {
      $progress = 'applying'; $scriptPath = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
      $childArguments = @('-NodePath', $PrivateNodePath)
    }
    'pause' {
      $progress = 'pausing'; $scriptPath = Join-Path $PSScriptRoot 'pause-dream-skin.ps1'
      $childArguments = @('-NodePath', $PrivateNodePath)
    }
    'resume' {
      $progress = 'applying'; $scriptPath = Join-Path $PSScriptRoot 'start-dream-skin.ps1'
      $childArguments = @('-NodePath', $PrivateNodePath)
    }
    'restore' {
      $progress = 'restoring'; $scriptPath = Join-Path $PSScriptRoot 'restore-dream-skin.ps1'
      $childArguments = @('-RestoreBaseTheme')
    }
    'verify' {
      $progress = 'verifying'; $scriptPath = Join-Path $PSScriptRoot 'verify-dream-skin.ps1'
      $childArguments = @('-NodePath', $PrivateNodePath)
    }
    'uninstall' {
      $progress = 'uninstalling'; $scriptPath = Join-Path $PSScriptRoot 'restore-dream-skin.ps1'
      $childArguments = @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
    }
  }
  if ($RestartAuthorized) {
    switch ($Operation) {
      'install' { $childArguments += '-CloseRunning' }
      'apply' { $childArguments += '-RestartExisting' }
      'resume' { $childArguments += '-RestartExisting' }
      'restore' { $childArguments += '-CloseRunning' }
      'uninstall' { $childArguments += '-CloseRunning' }
    }
  }
  if ($ForceAuthorized) { $childArguments += '-ForceRestart' }
  $childArguments += '-AdapterLockHeld'

  Ensure-DreamSkinManagedDirectory -Path $stateRoot -Root $stateRoot
  $logPath = Join-Path $stateRoot 'studio-operation.log'
  Assert-DreamSkinNoReparseComponents -Path $logPath
  [IO.File]::WriteAllText($logPath, '', [Text.UTF8Encoding]::new($false))
  [Console]::Error.WriteLine("DREAM_SKIN_PROGRESS=$progress")
  $child = Invoke-DreamSkinLifecycleChild -ScriptPath $scriptPath -Arguments $childArguments -LogPath $logPath
  if ($child.ExitCode -ne 0) { Exit-DreamSkinChildFailure -Child $child -State $status.State }

  $postStatus = Get-DreamSkinLifecycleStatus
  $unavailableCodexAfterRestore = $Operation -eq 'restore' -and -not $postStatus.Ok -and
    $null -ne $postStatus.Error -and
    $postStatus.Error.code -in @('CODEX_NOT_INSTALLED', 'CODEX_FIRST_RUN_REQUIRED') -and
    $postStatus.State.install -eq 'not-installed' -and $postStatus.State.session -eq 'official' -and
    -not $postStatus.State.requiresRestart
  $unavailableCodexAfterUninstall = $Operation -eq 'uninstall' -and -not $postStatus.Ok -and
    $null -ne $postStatus.Error -and
    $postStatus.Error.code -in @('CODEX_NOT_INSTALLED', 'CODEX_FIRST_RUN_REQUIRED') -and
    $postStatus.State.install -eq 'not-installed' -and $postStatus.State.session -eq 'official' -and
    -not $postStatus.State.requiresRestart
  if (-not $postStatus.Ok -and -not $unavailableCodexAfterRestore -and -not $unavailableCodexAfterUninstall) {
    if ($null -ne $postStatus.Error -and $postStatus.Error.code -eq 'STATE_UNSAFE') {
      Exit-DreamSkinStudioError -Code 'STATE_UNSAFE' -Message 'Theme state needs recovery before it can be used.' `
        -RecoveryActions @('restore', 'diagnostics', 'cancel') -State $postStatus.State
    }
    Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'The Studio operation could not be verified.' `
      -RecoveryActions @('retry', 'diagnostics', 'cancel') -State $postStatus.State
  }
  if ($Operation -eq 'install' -and $postStatus.State.install -ne 'ready') {
    Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'The Studio installation could not be verified.' `
      -RecoveryActions @('retry', 'diagnostics', 'cancel') -State $postStatus.State
  }
  if ($Operation -in @('apply', 'resume', 'verify') -and $postStatus.State.verified -ne $true) {
    Exit-DreamSkinStudioError -Code 'VERIFY_FAILED' -Message 'Theme verification failed.' `
      -RecoveryActions @('retry', 'restore', 'diagnostics', 'cancel') -State $postStatus.State
  }
  if ($Operation -eq 'pause' -and $postStatus.State.session -ne 'paused') {
    Exit-DreamSkinStudioError -Code 'LIVE_REMOVE_FAILED' -Message 'The live theme could not be removed safely.' `
      -RecoveryActions @('restore', 'diagnostics', 'cancel') -State $postStatus.State
  }
  if ($Operation -in @('restore', 'uninstall') -and $postStatus.State.session -ne 'official') {
    Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'The official Codex session could not be verified.' `
      -RecoveryActions @('retry', 'restore', 'diagnostics', 'cancel') -State $postStatus.State
  }
  if ($Operation -eq 'uninstall' -and $postStatus.State.install -ne 'not-installed') {
    Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'The Studio uninstall could not be verified.' `
      -RecoveryActions @('retry', 'diagnostics', 'cancel') -State $postStatus.State
  }
  if ($Operation -eq 'uninstall' -and $postStatus.State.requiresRestart) {
    Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'Codex did not remain stopped after uninstall.' `
      -RecoveryActions @('retry', 'diagnostics', 'cancel') -State $postStatus.State
  }

  if ($Operation -eq 'uninstall' -and $DeleteUserThemes) {
    Remove-DreamSkinUserThemeData -StateRoot $stateRoot
  }

  if ($Operation -eq 'uninstall') {
    $postStatus.State = New-DreamSkinStudioState -Install 'not-installed' -Codex 'stopped' -Session 'official' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @('install')
  }

  Write-DreamSkinStudioEnvelope -Operation $Operation -Ok $true -State $postStatus.State -Error $null
  exit 0
} catch {
  if ($logPath -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    try {
      [IO.File]::AppendAllText($logPath, "`r`n$($_.Exception.ToString())`r`n", [Text.UTF8Encoding]::new($false))
    } catch {}
  }
  if ($null -ne $status) { $errorState = $status.State } else { $errorState = $null }
  Exit-DreamSkinStudioError -Code 'OPERATION_FAILED' -Message 'The Studio operation failed.' `
    -RecoveryActions @('retry', 'diagnostics', 'cancel') -State $errorState
} finally {
  if ($null -ne $operationLock) { Exit-DreamSkinOperationLock -Mutex $operationLock }
}
