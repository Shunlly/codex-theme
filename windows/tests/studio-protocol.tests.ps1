[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex dream skin studio tests $PID $([guid]::NewGuid().ToString('N'))"
$versionRoot = Join-Path $temporaryRoot 'release\1.3.0'
$engineRoot = Join-Path $versionRoot 'engine'
$scriptsRoot = Join-Path $engineRoot 'scripts'
$adapterPath = Join-Path $scriptsRoot 'studio-adapter.ps1'
$nodePath = Join-Path $engineRoot 'runtime\node.exe'
$injectorPath = Join-Path $scriptsRoot 'injector.mjs'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Get-StateSnapshot {
  param([Parameter(Mandatory = $true)][string]$Root)
  if (-not (Test-Path -LiteralPath $Root)) { return @() }
  return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
    "$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
  })
}

function Assert-Equal {
  param([object]$Actual, [object]$Expected, [string]$Message)
  if ((ConvertTo-Json -InputObject @($Actual) -Compress -Depth 8) -cne
    (ConvertTo-Json -InputObject @($Expected) -Compress -Depth 8)) {
    throw $Message
  }
}

function Assert-NoPrivateStudioData {
  param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$UserProfile)
  if ($null -eq $Value) { return }
  if ($Value -is [string]) {
    if ($Value.Contains($UserProfile) -or $Value -match '(?i)[A-Z]:\\Users\\' -or
      $Value -match '(?i)powershell(?:\.exe)?') {
      throw 'Studio envelope leaks a user path or PowerShell executable detail.'
    }
    return
  }
  if ($Value -is [Collections.IDictionary]) {
    foreach ($key in $Value.Keys) {
      if ("$key" -match '(?i)(?:port|pid|path|cdp|powershell)') { throw "Studio envelope leaks internal key: $key" }
      Assert-NoPrivateStudioData -Value $Value[$key] -UserProfile $UserProfile
    }
    return
  }
  if ($Value -is [Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
    foreach ($item in $Value) { Assert-NoPrivateStudioData -Value $item -UserProfile $UserProfile }
    return
  }
  if ($Value -is [pscustomobject]) {
    foreach ($property in $Value.PSObject.Properties) {
      if ($property.Name -match '(?i)(?:port|pid|path|cdp|powershell)') {
        throw "Studio envelope leaks internal key: $($property.Name)"
      }
      Assert-NoPrivateStudioData -Value $property.Value -UserProfile $UserProfile
    }
  }
}

function New-CaseRoot {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$NoConfig,
    [switch]$NoState,
    [switch]$DamagedState,
    [switch]$SecondaryState
  )
  $caseRoot = Join-Path $temporaryRoot "cases\$Name"
  $localAppData = Join-Path $caseRoot 'local app data'
  $userProfile = Join-Path $caseRoot 'user profile'
  $stateRoot = Join-Path $localAppData 'CodexDreamSkin'
  New-Item -ItemType Directory -Path (Join-Path $stateRoot 'active-theme') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $userProfile '.codex') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $stateRoot 'config.before-dream-skin.toml'), "model = `"gpt-5`"`r`n", $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'active-theme\theme.json'), '{"name":"午夜极光","image":"theme.jpg"}', $utf8NoBom)
  [IO.File]::WriteAllBytes((Join-Path $stateRoot 'active-theme\theme.jpg'), [byte[]](1, 2, 3))
  if (-not $NoConfig) {
    [IO.File]::WriteAllText((Join-Path $userProfile '.codex\config.toml'), "model = `"gpt-5`"`r`n", $utf8NoBom)
  }
  if (-not $NoState) {
    $statePath = Join-Path $stateRoot 'state.json'
    if ($DamagedState) {
      [IO.File]::WriteAllText($statePath, '{broken', $utf8NoBom)
    } else {
      $packageRoot = if ($SecondaryState) { 'C:\Program Files\WindowsApps\OpenAI.Codex.Secondary' } else { 'C:\Program Files\WindowsApps\OpenAI.Codex.Primary' }
      $packageName = if ($SecondaryState) { 'OpenAI.Codex_1.0.0.0_x64__test' } else { 'OpenAI.Codex_2.0.0.0_x64__test' }
      $state = [ordered]@{
        schemaVersion = 3
        platform = 'windows'
        port = 9335
        injectorPid = 4242
        injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
        injectorPath = $injectorPath
        nodePath = $nodePath
        codexExe = Join-Path $packageRoot 'app\ChatGPT.exe'
        codexPackageRoot = $packageRoot
        codexPackageFullName = $packageName
        codexPackageFamilyName = 'OpenAI.Codex_test'
        browserId = 'browser-123'
      }
      [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Compress), $utf8NoBom)
    }
  }
  $stateTemplate = Join-Path $caseRoot 'valid-state.json'
  $templateState = [ordered]@{
    schemaVersion = 3
    platform = 'windows'
    port = 9335
    injectorPid = 4242
    injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
    injectorPath = $injectorPath
    nodePath = $nodePath
    codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex.Primary\app\ChatGPT.exe'
    codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex.Primary'
    codexPackageFullName = 'OpenAI.Codex_2.0.0.0_x64__test'
    codexPackageFamilyName = 'OpenAI.Codex_test'
    browserId = 'browser-123'
  }
  [IO.File]::WriteAllText($stateTemplate, ($templateState | ConvertTo-Json -Compress), $utf8NoBom)
  return [pscustomobject]@{
    Root = $caseRoot
    LocalAppData = $localAppData
    UserProfile = $userProfile
    StateRoot = $stateRoot
    StateTemplate = $stateTemplate
    ArgvPath = Join-Path $caseRoot 'child-argv.txt'
  }
}

function Start-StudioProcess {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$Operation = 'status',
    [string[]]$ExtraArguments = @(),
    [switch]$OmitOperation
  )
  $stdoutPath = Join-Path $Case.Root "stdout-$([guid]::NewGuid().ToString('N')).txt"
  $stderrPath = Join-Path $Case.Root "stderr-$([guid]::NewGuid().ToString('N')).txt"
  $savedLocalAppData = $env:LOCALAPPDATA
  $savedUserProfile = $env:USERPROFILE
  $savedScenario = $env:DREAM_SKIN_TEST_SCENARIO
  $savedInjector = $env:DREAM_SKIN_TEST_INJECTOR
  $savedSignal = $env:DREAM_SKIN_TEST_SIGNAL
  $savedArgv = $env:DREAM_SKIN_TEST_ARGV
  $savedStateTemplate = $env:DREAM_SKIN_TEST_STATE_TEMPLATE
  $savedRendererTrace = $env:DREAM_SKIN_TEST_RENDERER_TRACE
  try {
    $env:LOCALAPPDATA = $Case.LocalAppData
    $env:USERPROFILE = $Case.UserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $Scenario
    $env:DREAM_SKIN_TEST_INJECTOR = $injectorPath
    $env:DREAM_SKIN_TEST_SIGNAL = Join-Path $Case.Root 'probe-entered'
    $env:DREAM_SKIN_TEST_ARGV = $Case.ArgvPath
    $env:DREAM_SKIN_TEST_STATE_TEMPLATE = $Case.StateTemplate
    $env:DREAM_SKIN_TEST_RENDERER_TRACE = Join-Path $Case.Root 'renderer-trace.txt'
    $argumentLine = "-NoProfile -File `"$adapterPath`""
    if (-not $OmitOperation) { $argumentLine += " -Operation $Operation" }
    if ($ExtraArguments.Count -gt 0) { $argumentLine += ' ' + ($ExtraArguments -join ' ') }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  } finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:USERPROFILE = $savedUserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $savedScenario
    $env:DREAM_SKIN_TEST_INJECTOR = $savedInjector
    $env:DREAM_SKIN_TEST_SIGNAL = $savedSignal
    $env:DREAM_SKIN_TEST_ARGV = $savedArgv
    $env:DREAM_SKIN_TEST_STATE_TEMPLATE = $savedStateTemplate
    $env:DREAM_SKIN_TEST_RENDERER_TRACE = $savedRendererTrace
  }
  return [pscustomobject]@{ Process = $process; StdoutPath = $stdoutPath; StderrPath = $stderrPath; Case = $Case }
}

function Complete-StudioProcess {
  param([Parameter(Mandatory = $true)][object]$Invocation)
  $Invocation.Process.WaitForExit()
  $stdoutBytes = [IO.File]::ReadAllBytes($Invocation.StdoutPath)
  if ($stdoutBytes.Length -ge 3 -and $stdoutBytes[0] -eq 0xEF -and $stdoutBytes[1] -eq 0xBB -and $stdoutBytes[2] -eq 0xBF) {
    throw 'Studio stdout contains a UTF-8 BOM.'
  }
  $stdout = [Text.Encoding]::UTF8.GetString($stdoutBytes).TrimEnd([char[]]@("`r", "`n"))
  if (-not $stdout -or ($stdout -split "`r?`n").Count -ne 1) { throw 'Studio stdout is not exactly one JSON line.' }
  try { $envelope = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Studio stdout is not valid JSON.' }
  $reencoded = $envelope | ConvertTo-Json -Compress -Depth 8
  if ($reencoded -cne $stdout) { throw 'Studio stdout is not the canonical compact JSON envelope.' }
  Assert-NoPrivateStudioData -Value $envelope -UserProfile $Invocation.Case.UserProfile
  $stderr = [IO.File]::ReadAllText($Invocation.StderrPath).TrimEnd([char[]]@("`r", "`n"))
  $progressByOperation = @{
    preflight = 'checking'; status = 'checking'; install = 'installing'; apply = 'applying'
    pause = 'pausing'; resume = 'applying'; restore = 'restoring'; verify = 'verifying'; uninstall = 'uninstalling'
  }
  $progress = $progressByOperation["$($envelope.operation)"]
  if ($stderr -and $stderr -cne "DREAM_SKIN_PROGRESS=$progress") { throw "Unexpected Studio stderr: $stderr" }
  $preflightError = $null -ne $envelope.error -and $envelope.error.code -in @(
    'INVALID_REQUEST', 'CODEX_CLOSE_REQUIRED', 'RESTART_REQUIRED', 'STATE_UNSAFE',
    'CODEX_NOT_INSTALLED', 'CODEX_FIRST_RUN_REQUIRED', 'RUNTIME_INVALID', 'OPERATION_BUSY'
  )
  if ($null -ne $envelope.error -and $envelope.error.code -eq 'OPERATION_FAILED' -and
    -not (Test-Path -LiteralPath $Invocation.Case.ArgvPath)) {
    $preflightError = $true
  }
  if (-not $stderr -and -not $preflightError) {
    throw 'Studio operation omitted its progress marker.'
  }
  return [pscustomobject]@{ ExitCode = $Invocation.Process.ExitCode; Envelope = $envelope; Raw = $stdout; Stderr = $stderr }
}

function Invoke-Studio {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$Operation = 'status',
    [string[]]$ExtraArguments = @(),
    [switch]$OmitOperation
  )
  $invocation = Start-StudioProcess -Case $Case -Scenario $Scenario -Operation $Operation `
    -ExtraArguments $ExtraArguments -OmitOperation:$OmitOperation
  return Complete-StudioProcess -Invocation $invocation
}

function Assert-StudioResult {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [string]$Operation = 'status',
    [int]$ExitCode,
    [bool]$Ok,
    [string]$Install,
    [string]$Codex,
    [string]$Session,
    [string]$OperationState = 'idle',
    [AllowNull()][string]$ThemeName,
    [bool]$RequiresRestart,
    [AllowNull()][Nullable[bool]]$Verified,
    [string[]]$AvailableActions,
    [AllowNull()][string]$ErrorCode,
    [string[]]$RecoveryActions = @()
  )
  $envelope = $Result.Envelope
  Assert-Equal @($envelope.PSObject.Properties.Name | Sort-Object) @('error', 'ok', 'operation', 'schemaVersion', 'state') 'Unexpected envelope keys.'
  Assert-Equal @($envelope.state.PSObject.Properties.Name | Sort-Object) @('availableActions', 'codex', 'install', 'operation', 'requiresRestart', 'session', 'themeName', 'verified') 'Unexpected state keys.'
  if ($Result.ExitCode -ne $ExitCode -or $envelope.schemaVersion -ne 1 -or $envelope.ok -ne $Ok -or
    $envelope.operation -cne $Operation -or $envelope.state.install -cne $Install -or
    $envelope.state.codex -cne $Codex -or $envelope.state.session -cne $Session -or
    $envelope.state.operation -cne $OperationState -or $envelope.state.themeName -cne $ThemeName -or
    $envelope.state.requiresRestart -ne $RequiresRestart -or $envelope.state.verified -ne $Verified) {
    throw "Unexpected Studio state for $Operation/$Session."
  }
  Assert-Equal @($envelope.state.availableActions) @($AvailableActions) 'Unexpected available actions.'
  if ($null -eq $ErrorCode) {
    if ($null -ne $envelope.error) { throw 'Successful Studio envelope contains an error.' }
  } else {
    Assert-Equal @($envelope.error.PSObject.Properties.Name | Sort-Object) @('code', 'message', 'recoveryActions') 'Unexpected error keys.'
    if ($envelope.error.code -cne $ErrorCode) { throw "Unexpected error code: $($envelope.error.code)" }
    Assert-Equal @($envelope.error.recoveryActions) @($RecoveryActions) 'Unexpected recovery actions.'
  }
}

function Assert-ChildInvocation {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][string]$Expected
  )
  if (-not (Test-Path -LiteralPath $Case.ArgvPath -PathType Leaf)) { throw 'Lifecycle child was not invoked.' }
  $actual = [IO.File]::ReadAllText($Case.ArgvPath, [Text.UTF8Encoding]::new($false, $true)).Trim()
  if ($actual -cne $Expected) { throw "Unexpected lifecycle argv. Expected '$Expected', got '$actual'." }
}

function Assert-NoChildOrLog {
  param([Parameter(Mandatory = $true)][object]$Case)
  if (Test-Path -LiteralPath $Case.ArgvPath) { throw 'Rejected lifecycle request invoked a child script.' }
  if (Test-Path -LiteralPath (Join-Path $Case.StateRoot 'studio-operation.log')) {
    throw 'Rejected lifecycle request created an operation log.'
  }
}

function Assert-OperationLog {
  param([Parameter(Mandatory = $true)][object]$Case, [Parameter(Mandatory = $true)][string]$ScriptName)
  $logPath = Join-Path $Case.StateRoot 'studio-operation.log'
  if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { throw 'Lifecycle operation log is missing.' }
  $log = [IO.File]::ReadAllText($logPath)
  if (-not $log.Contains("child stdout $ScriptName") -or -not $log.Contains("child stderr $ScriptName")) {
    throw 'Lifecycle child stdout/stderr did not stay in the operation log.'
  }
}

function Get-ProtectedSnapshot {
  param([Parameter(Mandatory = $true)][object]$Case)
  return @(Get-StateSnapshot -Root $Case.StateRoot | Where-Object { $_ -notlike 'studio-operation.log|*' })
}

$adapterSource = [IO.File]::ReadAllText((Join-Path $Root 'scripts\studio-adapter.ps1'))
foreach ($required in @(
  '$EngineRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))',
  '$PrivateNodePath = Join-Path $EngineRoot ''runtime\node.exe''',
  '$powershellPath = Join-Path $PSHOME ''powershell.exe''',
  "'install-dream-skin.ps1'", "@('-NoShortcuts', '-NodePath', `$PrivateNodePath)",
  "'pause-dream-skin.ps1'", "@('-RestoreBaseTheme', '-Uninstall')",
  "[Console]::Error.WriteLine(\"DREAM_SKIN_PROGRESS=`$progress\")",
  "Get-DreamSkinNodeRuntime -NodePath `$PrivateNodePath -ExpectedVersion '22.23.1'",
  "`$childArguments += '-AdapterLockHeld'",
  "`$startInfo.EnvironmentVariables['DREAM_SKIN_ADAPTER_LOCK_OWNER_PID'] = \"`$PID\"",
  "@('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')",
  "New-DreamSkinStudioState -Install 'not-installed' -Codex 'stopped' -Session 'official'",
  'Get-DreamSkinStudioRecoveryState -StateRoot $stateRoot',
  '$recovery.Completed -or $recovery.NeverApplied',
  '$status.State.codex -ne ''running''',
  'Assert-DreamSkinNoReparseComponents -Path $stateRoot'
)) {
  if (-not $adapterSource.Contains($required)) { throw "Studio adapter contract is missing: $required" }
}
$adapterLockIndex = $adapterSource.IndexOf('$operationLock = Enter-DreamSkinOperationLock', [StringComparison]::Ordinal)
$initialStatusIndex = $adapterSource.IndexOf('$status = Get-DreamSkinLifecycleStatus', [StringComparison]::Ordinal)
$postStatusIndex = $adapterSource.IndexOf('$postStatus = Get-DreamSkinLifecycleStatus', [StringComparison]::Ordinal)
$adapterUnlockIndex = $adapterSource.LastIndexOf('Exit-DreamSkinOperationLock -Mutex $operationLock', [StringComparison]::Ordinal)
if ($adapterLockIndex -lt 0 -or $initialStatusIndex -le $adapterLockIndex -or
  $postStatusIndex -le $initialStatusIndex -or $adapterUnlockIndex -le $postStatusIndex) {
  throw 'Adapter does not hold one operation mutex through both status reads and the lifecycle child.'
}
$invalidIndex = $adapterSource.IndexOf('if ($ForceAuthorized -and -not $RestartAuthorized)', [StringComparison]::Ordinal)
$logIndex = $adapterSource.IndexOf("'studio-operation.log'", [StringComparison]::Ordinal)
$childIndex = $adapterSource.IndexOf('Invoke-DreamSkinLifecycleChild -ScriptPath', [StringComparison]::Ordinal)
if ($invalidIndex -lt 0 -or $logIndex -le $invalidIndex -or $childIndex -le $logIndex) {
  throw 'Adapter validates flags after creating its log or invoking a lifecycle child.'
}
if ($adapterSource -match '(?m)^\s*(Copy|Move|Remove)-Item\b.*(?:EngineRoot|PSScriptRoot)') {
  throw 'A running adapter mutates its versioned engine.'
}

$installSource = [IO.File]::ReadAllText((Join-Path $Root 'scripts\install-dream-skin.ps1'))
foreach ($required in @('[string]$NodePath', '[switch]$CloseRunning', '[switch]$ForceRestart',
  'if ($ForceRestart -and -not $CloseRunning)',
  'Get-DreamSkinNodeRuntime -NodePath $NodePath', 'Stop-DreamSkinCodex -Codex $registeredCodex -AllowForce:$ForceRestart',
  'Initialize-DreamSkinThemeStore -SkillRoot $SkillRoot -StateRoot $StateRoot -NodePath $node.Path')) {
  if (-not $installSource.Contains($required)) { throw "Install lifecycle contract is missing: $required" }
}
$installStop = $installSource.IndexOf('Stop-DreamSkinCodex -Codex $registeredCodex', [StringComparison]::Ordinal)
$installWrite = $installSource.IndexOf('Ensure-DreamSkinManagedDirectory', [StringComparison]::Ordinal)
if ($installStop -lt 0 -or $installWrite -le $installStop) { throw 'Install writes theme/config state before Codex closes.' }

$startSourceContract = [IO.File]::ReadAllText((Join-Path $Root 'scripts\start-dream-skin.ps1'))
foreach ($required in @('[string]$NodePath', '[switch]$ForceRestart', 'Get-DreamSkinNodeRuntime -NodePath $NodePath',
  'Stop-DreamSkinCodex -Codex $codexToStop -AllowForce:$ForceRestart', '-StateRoot $StateRoot -NodePath $node.Path')) {
  if (-not $startSourceContract.Contains($required)) { throw "Start lifecycle contract is missing: $required" }
}
$restartFailure = $startSourceContract.IndexOf("throw 'Codex is open without a verified Dream Skin CDP endpoint", [StringComparison]::Ordinal)
$startWrite = $startSourceContract.IndexOf('Ensure-DreamSkinManagedDirectory', [StringComparison]::Ordinal)
if ($restartFailure -lt 0 -or $startWrite -le $restartFailure) { throw 'Start writes theme state before restart authorization.' }

$pauseSource = [IO.File]::ReadAllText((Join-Path $Root 'scripts\pause-dream-skin.ps1'))
$pauseState = $pauseSource.IndexOf('$state = Read-DreamSkinState', [StringComparison]::Ordinal)
$pauseCdp = $pauseSource.IndexOf('$cdpIdentity = Get-DreamSkinVerifiedCdpIdentity', [StringComparison]::Ordinal)
$pauseWatcher = $pauseSource.IndexOf('Stop-DreamSkinRecordedInjector -State $state', [StringComparison]::Ordinal)
$pauseRemove = $pauseSource.IndexOf('--remove --port $Port --browser-id $cdpIdentity.BrowserId --timeout-ms 8000', [StringComparison]::Ordinal)
$pauseMarker = $pauseSource.IndexOf('Set-DreamSkinPaused -Paused $true', [StringComparison]::Ordinal)
if ($pauseState -lt 0 -or $pauseCdp -le $pauseState -or $pauseWatcher -le $pauseCdp -or
  $pauseRemove -le $pauseWatcher -or $pauseMarker -le $pauseRemove) {
  throw 'Pause does not validate identity, stop the watcher, verify removal, then write the marker.'
}

$restoreSourceContract = [IO.File]::ReadAllText((Join-Path $Root 'scripts\restore-dream-skin.ps1'))
foreach ($required in @('[switch]$CloseRunning', 'if ($ForceRestart -and -not $CloseRunning)',
  'Stop-DreamSkinCodex -Codex $codex -AllowForce:$ForceRestart')) {
  if (-not $restoreSourceContract.Contains($required)) { throw "Restore lifecycle contract is missing: $required" }
}
$restoreStop = $restoreSourceContract.IndexOf('Stop-DreamSkinCodex -Codex $codex', [StringComparison]::Ordinal)
$restoreWrite = $restoreSourceContract.IndexOf('Ensure-DreamSkinManagedDirectory', [StringComparison]::Ordinal)
if ($restoreStop -lt 0 -or $restoreWrite -le $restoreStop) { throw 'Restore mutates managed state before Codex closes.' }
$restorePublish = $restoreSourceContract.IndexOf('Publish-DreamSkinConfigBackupArchive -BackupPath $backup', [StringComparison]::Ordinal)
$restoreStateCleanup = $restoreSourceContract.IndexOf('Remove-DreamSkinRecoveryArtifact -Path $StatePath', [StringComparison]::Ordinal)
$restorePauseCleanup = $restoreSourceContract.IndexOf("Remove-DreamSkinRecoveryArtifact -Path (Join-Path `$StateRoot 'paused')", [StringComparison]::Ordinal)
$restoreMarkerToken = 'Remove-DreamSkinRecoveryArtifact -Path $backupMarkerPath'
$restoreMarkerCleanup = if ($restorePauseCleanup -ge 0) {
  $restoreSourceContract.IndexOf($restoreMarkerToken, $restorePauseCleanup, [StringComparison]::Ordinal)
} else { -1 }
$restoreBackupCleanup = if ($restoreMarkerCleanup -ge 0) {
  $restoreSourceContract.IndexOf('Remove-DreamSkinRecoveryArtifact -Path $backup',
    $restoreMarkerCleanup + $restoreMarkerToken.Length, [StringComparison]::Ordinal)
} else { -1 }
$restoreCommit = if ($restoreBackupCleanup -ge 0) {
  $restoreSourceContract.IndexOf('$transactionCommitted = $true', $restoreBackupCleanup, [StringComparison]::Ordinal)
} else { -1 }
$restoreRelaunch = if ($restoreCommit -ge 0) {
  $restoreSourceContract.IndexOf('Start-Process -FilePath $relaunchCodex.Executable', $restoreCommit, [StringComparison]::Ordinal)
} else { -1 }
$shortcutCleanup = $restoreSourceContract.IndexOf("(Join-Path `$desktop 'Codex Dream Skin.lnk')", [StringComparison]::Ordinal)
if (-not $restoreSourceContract.Contains("Join-Path `$StateRoot 'config.restored.toml'") -or
  -not $restoreSourceContract.Contains('$transactionCommitted = $false') -or
  -not $restoreSourceContract.Contains('Get-DreamSkinRecoveryArtifactSnapshot') -or
  -not $restoreSourceContract.Contains('Restore-DreamSkinRecoveryArtifactSnapshot') -or
  $restorePublish -lt 0 -or $restoreStateCleanup -le $restorePublish -or
  $restorePauseCleanup -le $restoreStateCleanup -or $restoreMarkerCleanup -le $restorePauseCleanup -or
  $restoreBackupCleanup -le $restoreMarkerCleanup -or $restoreCommit -le $restoreBackupCleanup -or
  $restoreRelaunch -le $restoreCommit -or $shortcutCleanup -le $restorePublish -or
  -not $restoreSourceContract.Contains('if (-not $transactionCommitted -and $configChanged') -or
  -not $restoreSourceContract.Contains('Write-DreamSkinBytesAtomically -Path $config -Bytes $configBeforeRestoreBytes')) {
  throw 'Restore does not publish proof, clean lifecycle state, remove live recovery artifacts, commit, and only then relaunch.'
}

$themeSourceContract = [IO.File]::ReadAllText((Join-Path $Root 'scripts\theme-windows.ps1'))
foreach ($required in @(
  'Get-DreamSkinNodeRuntime -NodePath $NodePath',
  'Get-DreamSkinValidatedImageMetadata -Path $fullPath -NodePath $NodePath',
  'Read-DreamSkinTheme -ThemeDirectory $paths.Active -NodePath $NodePath',
  'Set-DreamSkinActiveTheme -ImagePath $saved.ImagePath -Theme $theme -StateRoot $StateRoot -NodePath $NodePath'
)) {
  if (-not $themeSourceContract.Contains($required)) { throw "Theme NodePath chain is missing: $required" }
}

$commonSourceContract = [IO.File]::ReadAllText((Join-Path $Root 'scripts\common-windows.ps1'))
foreach ($required in @('[string]$ExpectedVersion', '$version -cne $ExpectedVersion',
  'function Get-DreamSkinOperationMutexName', 'function Test-DreamSkinAdapterOperationLockOwner',
  'DREAM_SKIN_ADAPTER_LOCK_OWNER_PID', 'ParentProcessId', '$mutex.WaitOne(0)')) {
  if (-not $commonSourceContract.Contains($required)) { throw "Shared lifecycle contract is missing: $required" }
}
$studioSourceContract = [IO.File]::ReadAllText((Join-Path $Root 'scripts\studio-windows.ps1'))
if (-not $studioSourceContract.Contains(
    "Get-DreamSkinNodeRuntime -NodePath (Join-Path `$EngineRoot 'runtime\node.exe') -ExpectedVersion '22.23.1'")) {
  throw 'Deep Studio status does not require the exact private Node runtime.'
}
foreach ($source in @($installSource, $startSourceContract, $pauseSource, $restoreSourceContract,
  [IO.File]::ReadAllText((Join-Path $Root 'scripts\verify-dream-skin.ps1')))) {
  if (-not $source.Contains('[switch]$AdapterLockHeld') -or
    -not $source.Contains('Test-DreamSkinAdapterOperationLockOwner -AdapterLockHeld:$AdapterLockHeld')) {
    throw 'A production lifecycle script does not validate the adapter-owned lock bypass.'
  }
}

New-Item -ItemType Directory -Path (Join-Path $engineRoot 'runtime') -Force | Out-Null
New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'scripts\studio-windows.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\status-dream-skin.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\studio-adapter.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\config-utf8.ps1') -Destination $scriptsRoot
[IO.File]::WriteAllText((Join-Path $engineRoot 'VERSION'), '1.3.0', $utf8NoBom)
[IO.File]::WriteAllText($injectorPath, '// staged injector', $utf8NoBom)

function Write-LifecycleStub {
  param([Parameter(Mandatory = $true)][string]$Name)
  $source = @'
param()
$ErrorActionPreference = 'Stop'
$name = '__NAME__'
[IO.File]::AppendAllText($env:DREAM_SKIN_TEST_ARGV, $name + ' ' + ($args -join '|') + "`r`n", [Text.UTF8Encoding]::new($false))
Write-Output "child stdout $name"
[Console]::Error.WriteLine("child stderr $name")
$scenario = $env:DREAM_SKIN_TEST_SCENARIO
if ($scenario -eq 'lifecycle-lock-hold') {
  [IO.File]::WriteAllText($env:DREAM_SKIN_TEST_SIGNAL, 'child-entered')
  Start-Sleep -Milliseconds 1500
}
if ($scenario -like '*-timeout') {
  throw 'Codex did not close within 15 seconds. Close it manually or explicitly authorize a forced restart.'
}
if ($scenario -eq 'pause-remove-fail') { throw 'LIVE_REMOVE_FAILED: The live theme could not be removed safely.' }
if ($scenario -eq 'verify-fail') { exit 9 }
if ($scenario -in @('restore-fail', 'stale-restore-fail', 'uninstall-fail')) { throw 'The restore operation failed.' }
$stateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
switch ($name) {
  'start-dream-skin.ps1' {
    Copy-Item -LiteralPath $env:DREAM_SKIN_TEST_STATE_TEMPLATE -Destination (Join-Path $stateRoot 'state.json') -Force
    Remove-Item -LiteralPath (Join-Path $stateRoot 'paused') -Force -ErrorAction SilentlyContinue
  }
  'pause-dream-skin.ps1' {
    [IO.File]::WriteAllText((Join-Path $stateRoot 'paused'), "paused`r`n", [Text.UTF8Encoding]::new($false))
  }
  'restore-dream-skin.ps1' {
    Remove-Item -LiteralPath (Join-Path $stateRoot 'state.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateRoot 'paused') -Force -ErrorAction SilentlyContinue
    if ($scenario -ne 'uninstall-incomplete') {
      Move-Item -LiteralPath (Join-Path $stateRoot 'config.before-dream-skin.toml') `
        -Destination (Join-Path $stateRoot 'config.restored.toml') -Force
    }
    if ($args -contains '-NoRelaunch') {
      [IO.File]::WriteAllText((Join-Path $stateRoot 'test-codex-stopped'), 'stopped')
    }
  }
}
'@
  [IO.File]::WriteAllText((Join-Path $scriptsRoot $Name), $source.Replace('__NAME__', $Name), $utf8NoBom)
}

foreach ($scriptName in @(
  'install-dream-skin.ps1', 'start-dream-skin.ps1', 'pause-dream-skin.ps1',
  'restore-dream-skin.ps1', 'verify-dream-skin.ps1'
)) {
  Write-LifecycleStub -Name $scriptName
}

$fakeNodeSource = @'
using System;
using System.IO;

public static class StudioFakeNode {
  public static int Main(string[] args) {
    if (args.Length == 2 && args[0] == "-p" && args[1] == "process.versions.node") {
      Console.Write(Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_NODE_VERSION") ?? "22.23.1");
      return 0;
    }
    if (args.Length == 2 && args[0] == "-p" && args[1] == "process.execPath") {
      Console.Write(System.Reflection.Assembly.GetExecutingAssembly().Location);
      return 0;
    }
    if (Array.IndexOf(args, "--remove") >= 0) {
      File.AppendAllText(Environment.GetEnvironmentVariable("DREAM_SKIN_REAL_TRACE"), "remove\n");
      return Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_SCENARIO") == "real-pause-remove-fail" ? 9 : 0;
    }
    string expectedInjector = Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_INJECTOR");
    string scenario = Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_SCENARIO");
    string expectedTimeout = scenario.StartsWith("real-") ? "30000" : "5000";
    bool exact = args.Length == 8 &&
      String.Equals(Path.GetFullPath(args[0]), Path.GetFullPath(expectedInjector), StringComparison.OrdinalIgnoreCase) &&
      args[1] == "--verify" && args[2] == "--port" && args[3] == "9335" &&
      args[4] == "--browser-id" && args[5] == "browser-123" &&
      args[6] == "--timeout-ms" && args[7] == expectedTimeout;
    if (!exact) return 8;
    string rendererTrace = Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_RENDERER_TRACE");
    if (!String.IsNullOrEmpty(rendererTrace)) File.AppendAllText(rendererTrace, "verify\n");
    return scenario == "renderer-pass" || scenario.StartsWith("lifecycle-") || scenario == "resume-hot" ||
      scenario == "active-exact-runtime" || scenario == "real-verify" ||
      scenario == "real-lock-owner-valid" ? 0 : 9;
  }
}
'@
Add-Type -TypeDefinition $fakeNodeSource -OutputAssembly $nodePath -OutputType ConsoleApplication | Out-Null

$commonStub = @'
. (Join-Path $PSScriptRoot 'config-utf8.ps1')

function Enter-DreamSkinOperationLock {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { $mutex.Dispose(); throw 'busy' }
  return $mutex
}
function Exit-DreamSkinOperationLock { param([Threading.Mutex]$Mutex) try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
function New-TestCodexInstall {
  param([string]$Name, [string]$Version)
  $root = "C:\Program Files\WindowsApps\$Name"
  return [pscustomobject]@{ Executable = (Join-Path $root 'app\ChatGPT.exe'); PackageRoot = $root; PackageFullName = "OpenAI.Codex_$Version`_x64__test"; PackageFamilyName = 'OpenAI.Codex_test' }
}
function Get-DreamSkinRegisteredCodexInstalls {
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'probe-error') { throw 'registered install probe failed' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'missing-codex') { return @() }
  $primary = New-TestCodexInstall -Name 'OpenAI.Codex.Primary' -Version '2.0.0.0'
  if ($env:DREAM_SKIN_TEST_SCENARIO -in @('secondary-install', 'saved-stopped')) {
    return @($primary, (New-TestCodexInstall -Name 'OpenAI.Codex.Secondary' -Version '1.0.0.0'))
  }
  return @($primary)
}
function Resolve-DreamSkinCodexInstallFromState {
  param([object]$State, [object[]]$RegisteredInstalls)
  foreach ($install in $RegisteredInstalls) {
    if ((Test-DreamSkinPathEqual -Left "$($State.codexExe)" -Right $install.Executable) -and
      "$($State.codexPackageFullName)" -ieq $install.PackageFullName -and
      "$($State.codexPackageFamilyName)" -ieq $install.PackageFamilyName) { return $install }
  }
  return $null
}
function Get-DreamSkinCodexProcesses {
  param([object]$Codex)
  if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\test-codex-stopped')) { return @() }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'process-error') { throw 'process probe failed' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'mutex-hold') {
    [IO.File]::WriteAllText($env:DREAM_SKIN_TEST_SIGNAL, 'entered')
    Start-Sleep -Milliseconds 1500
  }
  $running = $env:DREAM_SKIN_TEST_SCENARIO -in @(
    'running', 'active', 'stale', 'reused', 'damaged', 'renderer-pass', 'browser-mismatch',
    'renderer-fail', 'active-exact-runtime', 'active-wrong-runtime', 'mutex-hold',
    'lifecycle-install-running', 'lifecycle-install-timeout', 'lifecycle-apply',
    'lifecycle-apply-timeout', 'lifecycle-pause', 'pause-remove-fail', 'resume-hot', 'resume-cold-paused',
    'lifecycle-resume', 'lifecycle-resume-timeout', 'lifecycle-restore',
    'lifecycle-restore-timeout', 'restore-fail', 'stale-restore-fail', 'lifecycle-verify', 'verify-fail',
    'lifecycle-uninstall', 'lifecycle-uninstall-timeout', 'uninstall-fail'
  )
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'secondary-install') { $running = $Codex.PackageRoot -like '*Secondary' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'saved-stopped') { $running = $Codex.PackageRoot -like '*Primary' }
  if ($running) { return @([pscustomobject]@{ ProcessId = 5151 }) }
  return @()
}
function Read-DreamSkinState {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop) } catch { throw 'damaged state' }
}
function Get-CimInstance {
  param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
  if ($ClassName -ne 'Win32_Process' -or $env:DREAM_SKIN_TEST_SCENARIO -in @('stale', 'stale-restore-fail')) { return $null }
  $node = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe'
  $injector = Join-Path $PSScriptRoot 'injector.mjs'
  return [pscustomobject]@{ ProcessId = 4242; ExecutablePath = $node; CommandLine = "`"$node`" `"$injector`" --watch --port 9335 --browser-id browser-123" }
}
function Get-DreamSkinProcessExecutablePath { param([object]$ProcessInfo) return "$($ProcessInfo.ExecutablePath)" }
function Get-DreamSkinProcessStartedAt {
  param([int]$ProcessId)
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'reused') { return '2026-01-02T00:00:00.0000000Z' }
  return '2026-01-01T00:00:00.0000000Z'
}
function Test-DreamSkinPathEqual { param([string]$Left, [string]$Right) try { return [IO.Path]::GetFullPath($Left) -ieq [IO.Path]::GetFullPath($Right) } catch { return $false } }
function Test-DreamSkinCommandLineToken { param([string]$CommandLine, [string]$Token) return $CommandLine.Contains($Token) }
function Test-DreamSkinBrowserId { param([string]$Value) return $Value -cmatch '^[A-Za-z0-9._-]+$' }
function ConvertTo-DreamSkinProcessArgument {
  param([string]$Value)
  if ($Value.Contains('"')) { throw 'quotes are unsupported' }
  if ($Value -notmatch '\s') { return $Value }
  return '"' + $Value + '"'
}
function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [object]$Codex)
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'browser-mismatch') { return [pscustomobject]@{ BrowserId = 'browser-other' } }
  if ($env:DREAM_SKIN_TEST_SCENARIO -in @(
    'renderer-pass', 'renderer-fail', 'active-exact-runtime', 'active-wrong-runtime',
    'lifecycle-apply', 'lifecycle-pause', 'pause-remove-fail',
    'resume-hot', 'lifecycle-resume', 'lifecycle-verify', 'verify-fail'
  )) { return [pscustomobject]@{ BrowserId = 'browser-123' } }
  return $null
}
function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22, [string]$NodePath, [string]$ExpectedVersion)
  $expected = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe'
  if (-not (Test-DreamSkinPathEqual -Left $NodePath -Right $expected) -or
    -not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw 'Deep status did not use the fixed private runtime.' }
  $version = if ($env:DREAM_SKIN_TEST_SCENARIO -in @('wrong-runtime', 'active-wrong-runtime')) {
    '22.22.0'
  } else {
    '22.23.1'
  }
  if ($ExpectedVersion -and $version -cne $ExpectedVersion) { throw 'The private Node.js runtime version is invalid.' }
  return [pscustomobject]@{ Path = $NodePath; Version = $version; Major = 22 }
}
'@
$themeStub = @'
function Ensure-DreamSkinManagedDirectory { param([string]$Path, [string]$Root) New-Item -ItemType Directory -Path $Path -Force | Out-Null }
function Assert-DreamSkinNoReparseComponents {
  param([string]$Path)
  $current = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($current)
  while ($true) {
    try {
      $attributes = [IO.File]::GetAttributes($current)
      if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'fixture reparse point' }
    } catch [IO.FileNotFoundException] {
    } catch [IO.DirectoryNotFoundException] {
    }
    if ($current.TrimEnd('\') -ieq $root.TrimEnd('\')) { break }
    $parent = [IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent -ieq $current) { break }
    $current = $parent
  }
}
function Test-DreamSkinThemePathWithin {
  param([string]$Path, [string]$Root)
  try { return [IO.Path]::GetFullPath($Path).StartsWith([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) } catch { return $false }
}
function Read-DreamSkinTheme {
  param([string]$ThemeDirectory, [switch]$SkipImageMetadata, [string]$NodePath)
  $theme = [IO.File]::ReadAllText((Join-Path $ThemeDirectory 'theme.json'), [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop
  return [pscustomobject]@{ Theme = $theme }
}
function Test-DreamSkinPaused { param([string]$StateRoot) return (Test-Path -LiteralPath (Join-Path $StateRoot 'paused') -PathType Leaf) }
'@
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'common-windows.ps1'), $commonStub, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'theme-windows.ps1'), $themeStub, $utf8NoBom)

$realRoot = Join-Path $temporaryRoot 'real lifecycle engine'
$realScripts = Join-Path $realRoot 'scripts'
New-Item -ItemType Directory -Path $realScripts -Force | Out-Null
foreach ($scriptName in @(
  'install-dream-skin.ps1', 'start-dream-skin.ps1', 'pause-dream-skin.ps1',
  'restore-dream-skin.ps1', 'verify-dream-skin.ps1'
)) {
  Copy-Item -LiteralPath (Join-Path $Root "scripts\$scriptName") -Destination $realScripts
}
[IO.File]::WriteAllText((Join-Path $realScripts 'injector.mjs'), '// real lifecycle injector fixture', $utf8NoBom)

$realCommonStub = @'
. $env:DREAM_SKIN_REAL_COMMON

function Add-RealLifecycleTrace {
  param([string]$Value)
  [IO.File]::AppendAllText($env:DREAM_SKIN_REAL_TRACE, $Value + "`r`n", [Text.UTF8Encoding]::new($false))
}
function Enter-DreamSkinOperationLock { Add-RealLifecycleTrace 'lock-enter'; return [pscustomobject]@{ Held = $true } }
function Exit-DreamSkinOperationLock { param([object]$Mutex) Add-RealLifecycleTrace 'lock-exit' }
function New-RealLifecycleCodex {
  $executable = $env:DREAM_SKIN_REAL_CODEX_EXE
  return [pscustomobject]@{
    Executable = $executable
    PackageRoot = Split-Path -Parent $executable
    PackageFullName = 'OpenAI.Codex_2.0.0.0_x64__test'
    PackageFamilyName = 'OpenAI.Codex_test'
    Version = '2.0.0.0'
  }
}
function Get-DreamSkinRegisteredCodexInstalls { return @((New-RealLifecycleCodex)) }
function Get-DreamSkinCodexInstall { return New-RealLifecycleCodex }
function Read-DreamSkinState {
  param([string]$Path)
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'real-pause*') {
    return [pscustomobject]@{
      schemaVersion = 3; platform = 'windows'; port = 9335; injectorPid = 4242
      injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
      injectorPath = (Join-Path $PSScriptRoot 'injector.mjs'); nodePath = $env:DREAM_SKIN_REAL_NODE
      codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex.Test\app\ChatGPT.exe'
      codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex.Test'
      codexPackageFullName = 'OpenAI.Codex_2.0.0.0_x64__test'
      codexPackageFamilyName = 'OpenAI.Codex_test'; browserId = 'browser-123'
    }
  }
  return $null
}
function Get-DreamSkinCodexStatePathCandidate { param([object]$State) return $null }
function Resolve-DreamSkinCodexInstallFromState { param([object]$State, [object[]]$RegisteredInstalls) return New-RealLifecycleCodex }
function Get-DreamSkinCodexInstallFromState { param([object]$State) return $null }
function Get-DreamSkinCodexProcesses {
  param([object]$Codex)
  Add-RealLifecycleTrace 'codex-process'
  if ($env:DREAM_SKIN_TEST_SCENARIO -match '^real-(?:install|start|pause)' -or
    $env:DREAM_SKIN_TEST_SCENARIO -in @(
      'real-restore-unauthorized', 'real-restore-timeout', 'real-restore-force',
      'real-restore-state-unlink-fail', 'real-restore-paused-unlink-fail',
      'real-restore-archive-fail', 'real-restore-marker-unlink-fail',
      'real-restore-launch-fail', 'real-restore-post-launch-write',
      'real-uninstall-force'
    )) {
    return @([pscustomobject]@{ ProcessId = 5151 })
  }
  return @()
}
function Stop-DreamSkinCodex {
  param([object]$Codex, [switch]$AllowForce)
  Add-RealLifecycleTrace "stop:$([bool]$AllowForce)"
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-timeout') {
    throw 'Codex did not close within 15 seconds. Close it manually or explicitly authorize a forced restart.'
  }
}
function Test-DreamSkinCodexPortOwner { param([int]$Port, [object]$Codex) return $false }
function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [object]$Codex)
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'real-pause*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -in @('real-verify', 'real-lock-owner-valid')) {
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  return $null
}
function Test-DreamSkinPathEqual {
  param([string]$Left, [string]$Right)
  try { return [IO.Path]::GetFullPath($Left) -ieq [IO.Path]::GetFullPath($Right) } catch { return $false }
}
function Test-DreamSkinBrowserId { param([string]$Value) return $Value -cmatch '^[A-Za-z0-9._-]+$' }
function Get-CimInstance {
  param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
  if ($ClassName -ne 'Win32_Process') { return $null }
  if ($Filter -eq "ProcessId = $PID") {
    return [pscustomobject]@{ ProcessId = $PID; ParentProcessId = [int]$env:DREAM_SKIN_REAL_PARENT_PID }
  }
  if ($Filter -match 'ProcessId = 4242') {
    Add-RealLifecycleTrace 'injector-identity'
    return [pscustomobject]@{ ProcessId = 4242; ExecutablePath = $env:DREAM_SKIN_REAL_NODE; CommandLine = 'fixture' }
  }
  return @()
}
function Stop-DreamSkinRecordedInjector { param([object]$State) Add-RealLifecycleTrace 'watcher-stop'; return $true }
function Get-DreamSkinProcessExecutablePath { param([object]$ProcessInfo) return "$($ProcessInfo.ExecutablePath)" }
function Test-DreamSkinPortAvailable { param([int]$Port) return $true }
function Wait-DreamSkinPortAvailable { param([int]$Port, [int]$TimeoutSeconds) return $true }
function Select-DreamSkinPort { param([int]$PreferredPort) return $PreferredPort }
function Confirm-DreamSkinRestart { param([string]$Message) return $true }
function ConvertTo-DreamSkinProcessArgument { param([string]$Value) return $Value }
function Get-DreamSkinProcessStartedAt { param([int]$ProcessId) return '2026-01-01T00:00:00.0000000Z' }
function Write-DreamSkinState { param([string]$Path, [object]$State) Add-RealLifecycleTrace 'state-write' }
function Archive-DreamSkinStateFile { param([string]$Path) Add-RealLifecycleTrace 'state-archive'; return "$Path.stale" }
function ConvertFrom-DreamSkinUtf8Bytes { param([byte[]]$Bytes, [string]$Path) return [Text.Encoding]::UTF8.GetString($Bytes) }
function Read-DreamSkinUtf8File { param([string]$Path) return [IO.File]::ReadAllText($Path) }
function Install-DreamSkinBaseTheme { param([string]$ConfigPath, [string]$BackupPath) Add-RealLifecycleTrace 'install-config' }
function Restore-DreamSkinBaseTheme {
  param([string]$ConfigPath, [string]$BackupPath)
  Add-RealLifecycleTrace 'restore-config'
  [IO.File]::WriteAllText($ConfigPath, 'restored', [Text.UTF8Encoding]::new($false))
}
function Restore-DreamSkinConfigBackup {
  param([string]$ConfigPath, [string]$BackupPath, [string]$RecoveryBackupPath)
  Restore-DreamSkinBaseTheme -ConfigPath $ConfigPath -BackupPath $BackupPath
}
function Write-DreamSkinBytesAtomically {
  param([string]$Path, [byte[]]$Bytes, [byte[]]$ExpectedBytes)
  if ([IO.Path]::GetFileName($Path) -ceq 'config.restored.toml') {
    Add-RealLifecycleTrace 'archive-backup'
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-archive-fail') { throw 'fixture archive failure' }
  } elseif ([IO.Path]::GetFileName($Path) -ceq 'config.toml') {
    Add-RealLifecycleTrace 'config-rollback'
  }
  [IO.File]::WriteAllBytes($Path, $Bytes)
}
function Start-Process {
  param([string]$FilePath, [object]$ArgumentList, [object]$WindowStyle, [switch]$PassThru,
    [string]$RedirectStandardOutput, [string]$RedirectStandardError)
  Add-RealLifecycleTrace 'start-process'
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-launch-fail') { throw 'fixture relaunch failure' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-post-launch-write') {
    [IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.codex\config.toml'), 'post-launch', [Text.UTF8Encoding]::new($false))
  }
  return [pscustomobject]@{ Id = 7000; HasExited = $false }
}
function Stop-Process { param([object]$InputObject, [int]$Id, [switch]$Force, [object]$ErrorAction) Add-RealLifecycleTrace 'stop-process' }
function Remove-Item {
  param([string]$LiteralPath, [switch]$Force, [switch]$Recurse, [object]$ErrorAction)
  Add-RealLifecycleTrace "remove:$LiteralPath"
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-state-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'state.json') { throw 'fixture state unlink failure' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-paused-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'paused') { throw 'fixture paused unlink failure' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-marker-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'config.before-dream-skin.toml.appearance.json') {
    throw 'fixture backup marker unlink failure'
  }
  $testRoot = [IO.Path]::GetFullPath($env:DREAM_SKIN_REAL_CASE_ROOT).TrimEnd('\') + '\'
  if ([IO.Path]::GetFullPath($LiteralPath).StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force:$Force -Recurse:$Recurse -ErrorAction SilentlyContinue
  }
}
'@

$realThemeStub = @'
function Add-RealThemeTrace {
  param([string]$Value)
  [IO.File]::AppendAllText($env:DREAM_SKIN_REAL_TRACE, $Value + "`r`n", [Text.UTF8Encoding]::new($false))
}
function Get-DreamSkinThemePaths {
  param([string]$StateRoot)
  return [pscustomobject]@{
    Root = $StateRoot; Active = (Join-Path $StateRoot 'active-theme'); Saved = (Join-Path $StateRoot 'themes')
    Images = (Join-Path $StateRoot 'images'); PauseFile = (Join-Path $StateRoot 'paused'); State = (Join-Path $StateRoot 'state.json')
  }
}
function Assert-DreamSkinNoReparseComponents { param([string]$Path) }
function Ensure-DreamSkinManagedDirectory {
  param([string]$Path, [string]$Root)
  Add-RealThemeTrace 'ensure'
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-start-force') { throw 'fixture stop after authorized start boundary' }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}
function Initialize-DreamSkinThemeStore {
  param([string]$SkillRoot, [string]$StateRoot, [string]$NodePath)
  Add-RealThemeTrace 'initialize-theme'
  return Get-DreamSkinThemePaths -StateRoot $StateRoot
}
function Assert-DreamSkinImageFile { param([string]$Path, [string]$NodePath) }
function Read-DreamSkinTheme { param([string]$ThemeDirectory, [string]$NodePath) return [pscustomobject]@{ ImagePath = 'fixture.jpg' } }
function Test-DreamSkinPaused { param([string]$StateRoot) return $false }
function Set-DreamSkinPaused {
  param([bool]$Paused, [string]$StateRoot)
  Add-RealThemeTrace 'marker'
  [IO.File]::WriteAllText((Join-Path $StateRoot 'paused'), 'paused', [Text.UTF8Encoding]::new($false))
  return $Paused
}
'@

[IO.File]::WriteAllText((Join-Path $realScripts 'common-windows.ps1'), $realCommonStub, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $realScripts 'theme-windows.ps1'), $realThemeStub, $utf8NoBom)

function New-RealLifecycleCase {
  param([Parameter(Mandatory = $true)][string]$Name)
  $caseRoot = Join-Path $temporaryRoot "real-cases\$Name"
  $localAppData = Join-Path $caseRoot 'local app data'
  $stateRoot = Join-Path $localAppData 'CodexDreamSkin'
  $userProfile = Join-Path $caseRoot 'user profile'
  $appData = Join-Path $caseRoot 'app data'
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $userProfile '.codex') -Force | Out-Null
  New-Item -ItemType Directory -Path $appData -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $userProfile '.codex\config.toml'), 'original', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'config.before-dream-skin.toml'), 'backup', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'config.before-dream-skin.toml.appearance.json'), 'marker', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'state.json'), 'preserve-state', $utf8NoBom)
  $codexExecutable = Join-Path $caseRoot 'Codex.exe'
  [IO.File]::WriteAllText($codexExecutable, 'fixture executable', $utf8NoBom)
  return [pscustomobject]@{
    Root = $caseRoot; LocalAppData = $localAppData; StateRoot = $stateRoot; UserProfile = $userProfile
    AppData = $appData; TracePath = (Join-Path $caseRoot 'trace.txt'); CodexExecutable = $codexExecutable
  }
}

function New-RealRestoreRollbackBaseline {
  param([Parameter(Mandatory = $true)][object]$Case)
  $archive = Join-Path $Case.StateRoot 'config.restored.toml'
  [IO.File]::WriteAllText((Join-Path $Case.StateRoot 'paused'), 'paused-before', $utf8NoBom)
  [IO.File]::WriteAllText($archive, 'prior-archive', $utf8NoBom)
  [IO.File]::WriteAllText("$archive.appearance.json", 'prior-archive-marker', $utf8NoBom)
  return [pscustomobject]@{
    ConfigBytes = [IO.File]::ReadAllBytes((Join-Path $Case.UserProfile '.codex\config.toml'))
    StateSnapshot = @(Get-StateSnapshot -Root $Case.StateRoot)
  }
}

function Assert-RealRestoreRolledBack {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][object]$Baseline,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $configBytes = [IO.File]::ReadAllBytes((Join-Path $Case.UserProfile '.codex\config.toml'))
  if ([Convert]::ToBase64String($configBytes) -cne [Convert]::ToBase64String($Baseline.ConfigBytes)) {
    throw "$Message Config bytes changed."
  }
  Assert-Equal (Get-StateSnapshot -Root $Case.StateRoot) @($Baseline.StateSnapshot) $Message
}

function Invoke-RealLifecycle {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][string]$ScriptName,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string[]]$Arguments = @(),
    [ValidateSet('none', 'self', 'valid', 'invalid')][string]$LockOwner = 'none'
  )
  $stdoutPath = Join-Path $Case.Root "stdout-$([guid]::NewGuid().ToString('N')).txt"
  $stderrPath = Join-Path $Case.Root "stderr-$([guid]::NewGuid().ToString('N')).txt"
  $savedEnvironment = @{}
  foreach ($name in @(
    'LOCALAPPDATA', 'USERPROFILE', 'HOME', 'APPDATA', 'DREAM_SKIN_TEST_SCENARIO',
    'DREAM_SKIN_TEST_NODE_VERSION', 'DREAM_SKIN_TEST_INJECTOR', 'DREAM_SKIN_REAL_COMMON',
    'DREAM_SKIN_REAL_TRACE', 'DREAM_SKIN_REAL_NODE', 'DREAM_SKIN_REAL_CASE_ROOT',
    'DREAM_SKIN_REAL_PARENT_PID', 'DREAM_SKIN_REAL_CODEX_EXE', 'DREAM_SKIN_ADAPTER_LOCK_OWNER_PID'
  )) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
  $operationMutex = $null
  try {
    try {
      $env:LOCALAPPDATA = $Case.LocalAppData
      $env:USERPROFILE = $Case.UserProfile
      $env:HOME = $Case.UserProfile
      $env:APPDATA = $Case.AppData
      $env:DREAM_SKIN_TEST_SCENARIO = $Scenario
      $env:DREAM_SKIN_TEST_NODE_VERSION = '22.23.1'
      $env:DREAM_SKIN_TEST_INJECTOR = Join-Path $realScripts 'injector.mjs'
      $env:DREAM_SKIN_REAL_COMMON = Join-Path $Root 'scripts\common-windows.ps1'
      $env:DREAM_SKIN_REAL_TRACE = $Case.TracePath
      $env:DREAM_SKIN_REAL_NODE = $nodePath
      $env:DREAM_SKIN_REAL_CASE_ROOT = $Case.Root
      $env:DREAM_SKIN_REAL_PARENT_PID = "$PID"
      $env:DREAM_SKIN_REAL_CODEX_EXE = $Case.CodexExecutable
      if ($LockOwner -in @('self', 'valid')) { $env:DREAM_SKIN_ADAPTER_LOCK_OWNER_PID = "$PID" }
      elseif ($LockOwner -eq 'invalid') { $env:DREAM_SKIN_ADAPTER_LOCK_OWNER_PID = '1' }
      else { Remove-Item Env:DREAM_SKIN_ADAPTER_LOCK_OWNER_PID -ErrorAction SilentlyContinue }

      if ($LockOwner -eq 'valid') {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $operationMutex = [Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
        try { $acquired = $operationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'The test parent could not acquire the operation mutex.' }
      }

      $tokens = @('-NoProfile', '-File', (Join-Path $realScripts $ScriptName)) + $Arguments
      $argumentLine = (@($tokens | ForEach-Object { '"' + "$_" + '"' })) -join ' '
      $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    } finally {
      foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
      }
    }
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = if (Test-Path -LiteralPath $stdoutPath) { [IO.File]::ReadAllText($stdoutPath) } else { '' }
      Stderr = if (Test-Path -LiteralPath $stderrPath) { [IO.File]::ReadAllText($stderrPath) } else { '' }
      Trace = if (Test-Path -LiteralPath $Case.TracePath) { @([IO.File]::ReadAllLines($Case.TracePath)) } else { @() }
    }
  } finally {
    if ($null -ne $operationMutex) {
      try { $operationMutex.ReleaseMutex() } finally { $operationMutex.Dispose() }
    }
  }
}

function Assert-TraceOrder {
  param([string[]]$Trace, [string[]]$Expected, [string]$Message)
  $previous = -1
  foreach ($token in $Expected) {
    $index = [Array]::IndexOf($Trace, $token)
    if ($index -le $previous) { throw "$Message Missing or out of order: $token" }
    $previous = $index
  }
}

try {
  $realEngineSnapshot = @(Get-StateSnapshot -Root $realRoot)
  $privacyRejected = $false
  try { Assert-NoPrivateStudioData -Value ([pscustomobject]@{ injectorPid = 42 }) -UserProfile 'C:\Users\example' } catch { $privacyRejected = $true }
  if (-not $privacyRejected) { throw 'Privacy assertion did not reject a synthetic leaked key.' }
  $privacyRejected = $false
  try { Assert-NoPrivateStudioData -Value ([pscustomobject]@{ themeName = 'C:\Users\example\secret' }) -UserProfile 'C:\Users\example' } catch { $privacyRejected = $true }
  if (-not $privacyRejected) { throw 'Privacy assertion did not reject a synthetic leaked value.' }
  $privacyRejected = $false
  try { Assert-NoPrivateStudioData -Value ('{"themeName":"C:\\Users\\example\\secret"}' | ConvertFrom-Json) -UserProfile 'C:\Users\example' } catch { $privacyRejected = $true }
  if (-not $privacyRejected) { throw 'Privacy assertion missed a raw JSON escaped path.' }
  Assert-NoPrivateStudioData -Value ([pscustomobject]@{ themeName = 'Transport Path 午夜' }) -UserProfile 'C:\Users\example'

  $cases = @(
    @{ Name = 'missing-codex'; Args = @{ NoState = $true }; Exit = 1; Ok = $false; Codex = 'not-installed'; Session = 'official'; Restart = $false; Actions = @('apply', 'restore', 'uninstall'); Error = 'CODEX_NOT_INSTALLED'; Recovery = @('cancel') },
    @{ Name = 'missing-config'; Args = @{ NoConfig = $true; NoState = $true }; Exit = 1; Ok = $false; Codex = 'needs-first-run'; Session = 'official'; Restart = $false; Actions = @('apply', 'restore', 'uninstall'); Error = 'CODEX_FIRST_RUN_REQUIRED'; Recovery = @('open-codex', 'retry', 'cancel') },
    @{ Name = 'stopped'; Args = @{ NoState = $true }; Exit = 0; Ok = $true; Codex = 'stopped'; Session = 'official'; Restart = $false; Actions = @('apply', 'restore', 'uninstall'); Error = $null; Recovery = @() },
    @{ Name = 'running'; Args = @{ NoState = $true }; Exit = 0; Ok = $true; Codex = 'running'; Session = 'official'; Restart = $true; Actions = @('apply', 'restore', 'verify', 'uninstall'); Error = $null; Recovery = @() },
    @{ Name = 'active'; Args = @{}; Exit = 0; Ok = $true; Codex = 'running'; Session = 'active'; Restart = $false; Actions = @('pause', 'resume', 'restore', 'verify', 'uninstall'); Error = $null; Recovery = @() },
    @{ Name = 'stale'; Args = @{}; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('restore', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') },
    @{ Name = 'reused'; Args = @{}; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('restore', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') },
    @{ Name = 'damaged'; Args = @{ DamagedState = $true }; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('restore', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') },
    @{ Name = 'secondary-install'; Args = @{ SecondaryState = $true }; Exit = 0; Ok = $true; Codex = 'running'; Session = 'active'; Restart = $false; Actions = @('pause', 'resume', 'restore', 'verify', 'uninstall'); Error = $null; Recovery = @() },
    @{ Name = 'saved-stopped'; Args = @{ SecondaryState = $true }; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('restore', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') }
  )
  foreach ($definition in $cases) {
    $caseArguments = $definition.Args
    $case = New-CaseRoot -Name $definition.Name @caseArguments
    $before = Get-StateSnapshot -Root $case.StateRoot
    $result = Invoke-Studio -Case $case -Scenario $definition.Name
    Assert-Equal (Get-StateSnapshot -Root $case.StateRoot) $before "Status mutated state for $($definition.Name)."
    Assert-StudioResult -Result $result -ExitCode $definition.Exit -Ok $definition.Ok -Install 'ready' `
      -Codex $definition.Codex -Session $definition.Session -ThemeName '午夜极光' -RequiresRestart $definition.Restart `
      -Verified $null -AvailableActions $definition.Actions -ErrorCode $definition.Error -RecoveryActions $definition.Recovery
  }

  foreach ($unsafeThemeName in @(
    '../private-theme', 'C:\private-theme', "line$([char]0x1f)break", "line$([char]0x85)break",
    "line$([char]0x2028)break", "line$([char]0x2029)break"
  )) {
    $unsafeTheme = New-CaseRoot -Name "unsafe-theme-$([guid]::NewGuid().ToString('N'))" -NoState
    [IO.File]::WriteAllText((Join-Path $unsafeTheme.StateRoot 'active-theme\theme.json'),
      ([pscustomobject]@{ name = $unsafeThemeName; image = 'theme.jpg' } | ConvertTo-Json -Compress), $utf8NoBom)
    $before = Get-StateSnapshot -Root $unsafeTheme.StateRoot
    $result = Invoke-Studio -Case $unsafeTheme -Scenario 'stopped'
    Assert-Equal (Get-StateSnapshot -Root $unsafeTheme.StateRoot) $before 'Unsafe theme-name status mutated state.'
    Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'ready' -Codex 'stopped' `
      -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
      -AvailableActions @('apply', 'restore', 'uninstall') -ErrorCode $null
  }

  $paused = New-CaseRoot -Name 'paused' -NoState
  [IO.File]::WriteAllText((Join-Path $paused.StateRoot 'paused'), "paused`r`n", $utf8NoBom)
  $before = Get-StateSnapshot -Root $paused.StateRoot
  $pausedResult = Invoke-Studio -Case $paused -Scenario 'paused'
  Assert-Equal (Get-StateSnapshot -Root $paused.StateRoot) $before 'Paused status mutated state.'
  Assert-StudioResult -Result $pausedResult -ExitCode 0 -Ok $true -Install 'ready' -Codex 'stopped' -Session 'paused' `
    -ThemeName '午夜极光' -RequiresRestart $false -Verified $null -AvailableActions @('apply', 'resume', 'restore', 'verify', 'uninstall') -ErrorCode $null

  foreach ($deepDefinition in @(
    @{ Name = 'renderer-pass'; Verified = $true },
    @{ Name = 'browser-mismatch'; Verified = $false },
    @{ Name = 'renderer-fail'; Verified = $false }
  )) {
    $deep = New-CaseRoot -Name $deepDefinition.Name
    $before = Get-StateSnapshot -Root $deep.StateRoot
    $deepResult = Invoke-Studio -Case $deep -Scenario $deepDefinition.Name -ExtraArguments @('-Deep')
    Assert-Equal (Get-StateSnapshot -Root $deep.StateRoot) $before "Deep status mutated state for $($deepDefinition.Name)."
    Assert-StudioResult -Result $deepResult -ExitCode 0 -Ok $true -Install 'ready' -Codex 'running' -Session 'active' `
      -ThemeName '午夜极光' -RequiresRestart $false -Verified $deepDefinition.Verified `
      -AvailableActions @('pause', 'resume', 'restore', 'verify', 'uninstall') -ErrorCode $null
  }

  $exactRuntime = New-CaseRoot -Name 'active-exact-runtime'
  $before = Get-StateSnapshot -Root $exactRuntime.StateRoot
  $result = Invoke-Studio -Case $exactRuntime -Scenario 'active-exact-runtime' -ExtraArguments @('-Deep')
  Assert-Equal (Get-StateSnapshot -Root $exactRuntime.StateRoot) $before 'Exact-runtime deep status mutated state.'
  Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'ready' -Codex 'running' -Session 'active' `
    -ThemeName '午夜极光' -RequiresRestart $false -Verified $true `
    -AvailableActions @('pause', 'resume', 'restore', 'verify', 'uninstall') -ErrorCode $null
  if (-not (Test-Path -LiteralPath (Join-Path $exactRuntime.Root 'renderer-trace.txt') -PathType Leaf)) {
    throw 'Exact private Node did not execute deep renderer verification.'
  }

  $wrongDeepRuntime = New-CaseRoot -Name 'active-wrong-runtime'
  $before = Get-StateSnapshot -Root $wrongDeepRuntime.StateRoot
  $result = Invoke-Studio -Case $wrongDeepRuntime -Scenario 'active-wrong-runtime' -ExtraArguments @('-Deep')
  Assert-Equal (Get-StateSnapshot -Root $wrongDeepRuntime.StateRoot) $before 'Wrong-runtime deep status mutated state.'
  Assert-StudioResult -Result $result -ExitCode 1 -Ok $false -Install 'ready' -Codex 'running' -Session 'active' `
    -ThemeName '午夜极光' -RequiresRestart $false -Verified $false `
    -AvailableActions @('pause', 'resume', 'restore', 'verify', 'uninstall') -ErrorCode 'RUNTIME_INVALID' `
    -RecoveryActions @('diagnostics', 'cancel')
  if (Test-Path -LiteralPath (Join-Path $wrongDeepRuntime.Root 'renderer-trace.txt')) {
    throw 'Wrong private Node version executed deep renderer verification.'
  }

  foreach ($probeScenario in @('probe-error', 'process-error')) {
    $probeError = New-CaseRoot -Name $probeScenario -NoState
    $before = Get-StateSnapshot -Root $probeError.StateRoot
    $probeErrorResult = Invoke-Studio -Case $probeError -Scenario $probeScenario
    Assert-Equal (Get-StateSnapshot -Root $probeError.StateRoot) $before 'Probe error status mutated state.'
    Assert-StudioResult -Result $probeErrorResult -ExitCode 1 -Ok $false -Install 'not-installed' -Codex 'not-installed' -Session 'stale' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() -ErrorCode 'INTERNAL_ERROR' `
      -RecoveryActions @('retry', 'diagnostics', 'cancel')
  }

  $preflight = New-CaseRoot -Name 'preflight' -NoState
  $before = Get-StateSnapshot -Root $preflight.StateRoot
  $preflightResult = Invoke-Studio -Case $preflight -Scenario 'stopped' -Operation 'preflight'
  Assert-Equal (Get-StateSnapshot -Root $preflight.StateRoot) $before 'Preflight mutated state.'
  Assert-StudioResult -Result $preflightResult -Operation 'preflight' -ExitCode 0 -Ok $true -Install 'ready' -Codex 'stopped' -Session 'official' `
    -ThemeName '午夜极光' -RequiresRestart $false -Verified $null -AvailableActions @('apply', 'restore', 'uninstall') -ErrorCode $null

  $versionCase = New-CaseRoot -Name 'version-grammar' -NoState
  $versionPath = Join-Path $engineRoot 'VERSION'
  $bom = [byte[]](0xEF, 0xBB, 0xBF)
  foreach ($validVersion in @(
    [Text.Encoding]::UTF8.GetBytes('1.3.0'),
    [Text.Encoding]::UTF8.GetBytes("1.3.0`n"),
    [Text.Encoding]::UTF8.GetBytes("1.3.0`r`n"),
    [byte[]]($bom + [Text.Encoding]::UTF8.GetBytes('1.3.0'))
  )) {
    [IO.File]::WriteAllBytes($versionPath, $validVersion)
    $before = Get-StateSnapshot -Root $versionCase.StateRoot
    $result = Invoke-Studio -Case $versionCase -Scenario 'stopped'
    Assert-Equal (Get-StateSnapshot -Root $versionCase.StateRoot) $before 'Valid VERSION status mutated state.'
    Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'ready' -Codex 'stopped' -Session 'official' `
      -ThemeName '午夜极光' -RequiresRestart $false -Verified $null -AvailableActions @('apply', 'restore', 'uninstall') -ErrorCode $null
  }
  foreach ($invalidVersion in @(
    [Text.Encoding]::UTF8.GetBytes(' 1.3.0'),
    [Text.Encoding]::UTF8.GetBytes("1.3.0`n`n"),
    [byte[]](0x31, 0x2E, 0x33, 0x2E, 0x30, 0xFF)
  )) {
    [IO.File]::WriteAllBytes($versionPath, $invalidVersion)
    $before = Get-StateSnapshot -Root $versionCase.StateRoot
    $result = Invoke-Studio -Case $versionCase -Scenario 'stopped'
    Assert-Equal (Get-StateSnapshot -Root $versionCase.StateRoot) $before 'Invalid VERSION status mutated state.'
    Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'not-installed' -Codex 'stopped' -Session 'official' `
      -ThemeName '午夜极光' -RequiresRestart $false -Verified $null -AvailableActions @('install') -ErrorCode $null
  }
  $residualActive = New-CaseRoot -Name 'residual-active-incomplete-install'
  [IO.File]::WriteAllText($versionPath, 'invalid', $utf8NoBom)
  $result = Invoke-Studio -Case $residualActive -Scenario 'active-exact-runtime' -ExtraArguments @('-Deep')
  Assert-StudioResult -Result $result -ExitCode 1 -Ok $false -Install 'not-installed' -Codex 'running' -Session 'stale' `
    -ThemeName '午夜极光' -RequiresRestart $false -Verified $null -AvailableActions @('restore', 'uninstall') `
    -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('restore', 'diagnostics', 'cancel')
  [IO.File]::WriteAllText($versionPath, '1.3.0', $utf8NoBom)

  $mutexCase = New-CaseRoot -Name 'mutex-hold' -NoState
  $before = Get-StateSnapshot -Root $mutexCase.StateRoot
  $mutexInvocation = Start-StudioProcess -Case $mutexCase -Scenario 'mutex-hold'
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $probeMutex = [Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  $deadline = (Get-Date).AddSeconds(4)
  $signalPath = Join-Path $mutexCase.Root 'probe-entered'
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $signalPath -PathType Leaf)) { Start-Sleep -Milliseconds 25 }
  if (-not (Test-Path -LiteralPath $signalPath -PathType Leaf)) { throw 'Blocked status probe did not start.' }
  try { $acquiredWhileReading = $probeMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquiredWhileReading = $true }
  if ($acquiredWhileReading) {
    $probeMutex.ReleaseMutex()
    throw 'Status released the operation mutex before its read and envelope completed.'
  }
  $mutexResult = Complete-StudioProcess -Invocation $mutexInvocation
  try { $released = $probeMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $released = $true }
  if ($released) { $probeMutex.ReleaseMutex() }
  $probeMutex.Dispose()
  if (-not $released) { throw 'Status did not release the shared operation mutex after its envelope.' }
  Assert-Equal (Get-StateSnapshot -Root $mutexCase.StateRoot) $before 'Mutex-held status mutated state.'
  Assert-StudioResult -Result $mutexResult -ExitCode 0 -Ok $true -Install 'ready' -Codex 'running' -Session 'official' `
    -ThemeName '午夜极光' -RequiresRestart $true -Verified $null -AvailableActions @('apply', 'restore', 'verify', 'uninstall') -ErrorCode $null

  $busy = New-CaseRoot -Name 'busy' -NoState
  $heldMutex = [Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  $null = $heldMutex.WaitOne(0)
  try {
    $before = Get-StateSnapshot -Root $busy.StateRoot
    $busyResult = Invoke-Studio -Case $busy -Scenario 'busy'
    Assert-Equal (Get-StateSnapshot -Root $busy.StateRoot) $before 'Busy status mutated state.'
  } finally {
    $heldMutex.ReleaseMutex()
    $heldMutex.Dispose()
  }
  Assert-StudioResult -Result $busyResult -ExitCode 1 -Ok $false -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
    -OperationState 'busy' -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() `
    -ErrorCode 'OPERATION_BUSY' -RecoveryActions @('retry', 'cancel')

  $invalid = New-CaseRoot -Name 'invalid' -NoState
  $before = Get-StateSnapshot -Root $invalid.StateRoot
  $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -OmitOperation
  Assert-Equal (Get-StateSnapshot -Root $invalid.StateRoot) $before 'Missing operation mutated state.'
  Assert-StudioResult -Result $result -Operation 'status' -ExitCode 2 -Ok $false -Install 'not-installed' `
    -Codex 'not-installed' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'INVALID_REQUEST' -RecoveryActions @('cancel')
  $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -Operation 'unknown-operation'
  Assert-StudioResult -Result $result -Operation 'status' -ExitCode 2 -Ok $false -Install 'not-installed' `
    -Codex 'not-installed' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'INVALID_REQUEST' -RecoveryActions @('cancel')
  foreach ($invalidRequest in @(
    @{ Operation = 'status'; Arguments = @('-DeleteUserThemes') },
    @{ Operation = 'status'; Arguments = @('-ForceAuthorized') },
    @{ Operation = 'preflight'; Arguments = @('-RestartAuthorized') },
    @{ Operation = 'pause'; Arguments = @('-RestartAuthorized') },
    @{ Operation = 'verify'; Arguments = @('-RestartAuthorized') },
    @{ Operation = 'install'; Arguments = @('-ForceAuthorized') },
    @{ Operation = 'apply'; Arguments = @('-DeleteUserThemes') },
    @{ Operation = 'install'; Arguments = @('-Deep') },
    @{ Operation = 'status'; Arguments = @('-BogusFlag') }
  )) {
    $before = Get-StateSnapshot -Root $invalid.StateRoot
    $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -Operation $invalidRequest.Operation -ExtraArguments $invalidRequest.Arguments
    Assert-Equal (Get-StateSnapshot -Root $invalid.StateRoot) $before 'Invalid request flags mutated state.'
    Assert-StudioResult -Result $result -Operation $invalidRequest.Operation -ExitCode 2 -Ok $false -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() -ErrorCode 'INVALID_REQUEST' -RecoveryActions @('cancel')
  }

  $installUnauthorized = New-CaseRoot -Name 'install-unauthorized' -NoState
  $before = Get-StateSnapshot -Root $installUnauthorized.StateRoot
  $result = Invoke-Studio -Case $installUnauthorized -Scenario 'lifecycle-install-running' -Operation 'install'
  Assert-Equal (Get-StateSnapshot -Root $installUnauthorized.StateRoot) $before 'Unauthorized install changed protected state.'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'CODEX_CLOSE_REQUIRED') { throw 'Unauthorized install was not rejected.' }
  Assert-NoChildOrLog -Case $installUnauthorized

  $install = New-CaseRoot -Name 'install' -NoState
  $result = Invoke-Studio -Case $install -Scenario 'lifecycle-install-running' -Operation 'install' -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or -not $result.Envelope.ok) { throw 'Restart-authorized install failed.' }
  Assert-ChildInvocation -Case $install -Expected "install-dream-skin.ps1 -NoShortcuts|-NodePath|$nodePath|-CloseRunning|-AdapterLockHeld"
  Assert-OperationLog -Case $install -ScriptName 'install-dream-skin.ps1'

  $installStopped = New-CaseRoot -Name 'install-stopped' -NoState
  $result = Invoke-Studio -Case $installStopped -Scenario 'stopped' -Operation 'install'
  if ($result.ExitCode -ne 0) { throw 'Install with stopped Codex failed.' }
  Assert-ChildInvocation -Case $installStopped -Expected "install-dream-skin.ps1 -NoShortcuts|-NodePath|$nodePath|-AdapterLockHeld"

  $lockOwner = New-CaseRoot -Name 'lifecycle-lock-owner' -NoState
  $lockContender = New-CaseRoot -Name 'lifecycle-lock-contender' -NoState
  $lockInvocation = Start-StudioProcess -Case $lockOwner -Scenario 'lifecycle-lock-hold' -Operation 'install'
  $lockSignal = Join-Path $lockOwner.Root 'probe-entered'
  $deadline = (Get-Date).AddSeconds(4)
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $lockSignal -PathType Leaf)) {
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $lockSignal -PathType Leaf)) { throw 'Lifecycle child did not enter while the adapter held the operation lock.' }
  $contenderResult = Invoke-Studio -Case $lockContender -Scenario 'stopped' -Operation 'install'
  Assert-StudioResult -Result $contenderResult -Operation 'install' -ExitCode 1 -Ok $false `
    -Install 'not-installed' -Codex 'not-installed' -Session 'official' -OperationState 'busy' `
    -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() `
    -ErrorCode 'OPERATION_BUSY' -RecoveryActions @('retry', 'cancel')
  Assert-NoChildOrLog -Case $lockContender
  $lockOwnerResult = Complete-StudioProcess -Invocation $lockInvocation
  if ($lockOwnerResult.ExitCode -ne 0) { throw 'Lifecycle lock owner failed after its child completed.' }

  $installForce = New-CaseRoot -Name 'install-force' -NoState
  $result = Invoke-Studio -Case $installForce -Scenario 'lifecycle-install-running' -Operation 'install' `
    -ExtraArguments @('-RestartAuthorized', '-ForceAuthorized')
  if ($result.ExitCode -ne 0) { throw 'Force-authorized install failed.' }
  Assert-ChildInvocation -Case $installForce -Expected "install-dream-skin.ps1 -NoShortcuts|-NodePath|$nodePath|-CloseRunning|-ForceRestart|-AdapterLockHeld"

  $installTimeout = New-CaseRoot -Name 'install-timeout' -NoState
  $protectedBefore = Get-ProtectedSnapshot -Case $installTimeout
  $engineBefore = Get-StateSnapshot -Root $engineRoot
  $result = Invoke-Studio -Case $installTimeout -Scenario 'lifecycle-install-timeout' -Operation 'install' -ExtraArguments @('-RestartAuthorized')
  Assert-Equal (Get-ProtectedSnapshot -Case $installTimeout) $protectedBefore 'Install normal-close timeout changed protected state.'
  Assert-Equal (Get-StateSnapshot -Root $engineRoot) $engineBefore 'Install normal-close timeout changed the running engine.'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'FORCE_STOP_REQUIRED') { throw 'Install timeout was not mapped to force authorization.' }

  $applyUnauthorized = New-CaseRoot -Name 'apply-unauthorized' -NoState
  $before = Get-StateSnapshot -Root $applyUnauthorized.StateRoot
  $result = Invoke-Studio -Case $applyUnauthorized -Scenario 'lifecycle-apply' -Operation 'apply'
  Assert-Equal (Get-StateSnapshot -Root $applyUnauthorized.StateRoot) $before 'Unauthorized apply changed protected state.'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'RESTART_REQUIRED') { throw 'Unauthorized apply was not rejected.' }
  Assert-NoChildOrLog -Case $applyUnauthorized

  $apply = New-CaseRoot -Name 'apply' -NoState
  $result = Invoke-Studio -Case $apply -Scenario 'lifecycle-apply' -Operation 'apply' -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.verified -ne $true) { throw 'Authorized apply was not strictly verified.' }
  Assert-ChildInvocation -Case $apply -Expected "start-dream-skin.ps1 -NodePath|$nodePath|-RestartExisting|-AdapterLockHeld"
  Assert-OperationLog -Case $apply -ScriptName 'start-dream-skin.ps1'

  $applyForce = New-CaseRoot -Name 'apply-force' -NoState
  $result = Invoke-Studio -Case $applyForce -Scenario 'lifecycle-apply' -Operation 'apply' `
    -ExtraArguments @('-RestartAuthorized', '-ForceAuthorized')
  if ($result.ExitCode -ne 0) { throw 'Force-authorized apply failed.' }
  Assert-ChildInvocation -Case $applyForce -Expected "start-dream-skin.ps1 -NodePath|$nodePath|-RestartExisting|-ForceRestart|-AdapterLockHeld"

  $applyTimeout = New-CaseRoot -Name 'apply-timeout' -NoState
  $protectedBefore = Get-ProtectedSnapshot -Case $applyTimeout
  $result = Invoke-Studio -Case $applyTimeout -Scenario 'lifecycle-apply-timeout' -Operation 'apply' -ExtraArguments @('-RestartAuthorized')
  Assert-Equal (Get-ProtectedSnapshot -Case $applyTimeout) $protectedBefore 'Apply normal-close timeout changed protected state.'
  if ($result.Envelope.error.code -cne 'FORCE_STOP_REQUIRED') { throw 'Apply timeout was not mapped to force authorization.' }

  $pause = New-CaseRoot -Name 'pause'
  $result = Invoke-Studio -Case $pause -Scenario 'lifecycle-pause' -Operation 'pause'
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.session -cne 'paused') { throw 'Pause did not verify live removal before marking paused.' }
  Assert-ChildInvocation -Case $pause -Expected "pause-dream-skin.ps1 -NodePath|$nodePath|-AdapterLockHeld"
  Assert-OperationLog -Case $pause -ScriptName 'pause-dream-skin.ps1'

  $pauseFailure = New-CaseRoot -Name 'pause-remove-fail'
  $stateBefore = Get-StateSnapshot -Root $pauseFailure.StateRoot
  $result = Invoke-Studio -Case $pauseFailure -Scenario 'pause-remove-fail' -Operation 'pause'
  if ($result.Envelope.error.code -cne 'LIVE_REMOVE_FAILED' -or (Test-Path -LiteralPath (Join-Path $pauseFailure.StateRoot 'paused'))) {
    throw 'Failed live removal wrote the pause marker or mapped incorrectly.'
  }
  Assert-Equal @($result.Envelope.error.recoveryActions) @('restore', 'diagnostics', 'cancel') `
    'Failed live removal advertised an unusable retry.'
  Assert-Equal (Get-ProtectedSnapshot -Case $pauseFailure) @($stateBefore | Where-Object { $_ -notlike 'studio-operation.log|*' }) 'Failed pause did not preserve state.'

  $resumeHot = New-CaseRoot -Name 'resume-hot'
  [IO.File]::WriteAllText((Join-Path $resumeHot.StateRoot 'paused'), "paused`r`n", $utf8NoBom)
  $result = Invoke-Studio -Case $resumeHot -Scenario 'resume-hot' -Operation 'resume'
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.verified -ne $true) { throw 'Resume hot path was not strictly verified.' }
  Assert-ChildInvocation -Case $resumeHot -Expected "start-dream-skin.ps1 -NodePath|$nodePath|-AdapterLockHeld"
  Assert-OperationLog -Case $resumeHot -ScriptName 'start-dream-skin.ps1'

  $resumePausedCold = New-CaseRoot -Name 'resume-cold-paused'
  [IO.File]::WriteAllText((Join-Path $resumePausedCold.StateRoot 'paused'), "paused`r`n", $utf8NoBom)
  $before = Get-StateSnapshot -Root $resumePausedCold.StateRoot
  $result = Invoke-Studio -Case $resumePausedCold -Scenario 'resume-cold-paused' -Operation 'resume'
  Assert-Equal (Get-StateSnapshot -Root $resumePausedCold.StateRoot) $before 'Cold paused resume changed protected state.'
  if ($result.Envelope.error.code -cne 'RESTART_REQUIRED') { throw 'Cold paused resume did not require restart authorization.' }
  Assert-NoChildOrLog -Case $resumePausedCold

  $resumeCold = New-CaseRoot -Name 'resume-cold' -NoState
  $result = Invoke-Studio -Case $resumeCold -Scenario 'lifecycle-resume' -Operation 'resume'
  if ($result.Envelope.error.code -cne 'RESTART_REQUIRED') { throw 'Resume cold path did not require restart authorization.' }
  Assert-NoChildOrLog -Case $resumeCold

  $resumeAuthorized = New-CaseRoot -Name 'resume-authorized' -NoState
  $result = Invoke-Studio -Case $resumeAuthorized -Scenario 'lifecycle-resume' -Operation 'resume' -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.verified -ne $true) { throw 'Authorized cold resume failed strict verification.' }
  Assert-ChildInvocation -Case $resumeAuthorized -Expected "start-dream-skin.ps1 -NodePath|$nodePath|-RestartExisting|-AdapterLockHeld"

  $resumeForce = New-CaseRoot -Name 'resume-force' -NoState
  $result = Invoke-Studio -Case $resumeForce -Scenario 'lifecycle-resume' -Operation 'resume' `
    -ExtraArguments @('-RestartAuthorized', '-ForceAuthorized')
  if ($result.ExitCode -ne 0) { throw 'Force-authorized cold resume failed.' }
  Assert-ChildInvocation -Case $resumeForce -Expected "start-dream-skin.ps1 -NodePath|$nodePath|-RestartExisting|-ForceRestart|-AdapterLockHeld"

  $wrongRuntimeApply = New-CaseRoot -Name 'wrong-runtime-apply'
  $before = Get-StateSnapshot -Root $wrongRuntimeApply.StateRoot
  $result = Invoke-Studio -Case $wrongRuntimeApply -Scenario 'active-wrong-runtime' -Operation 'apply'
  Assert-Equal (Get-StateSnapshot -Root $wrongRuntimeApply.StateRoot) $before 'Wrong-runtime apply changed protected state.'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'RUNTIME_INVALID') {
    throw 'A Node-dependent operation bypassed exact runtime validation.'
  }
  Assert-NoChildOrLog -Case $wrongRuntimeApply

  $wrongRuntimeRestoreUnauthorized = New-CaseRoot -Name 'wrong-runtime-restore-unauthorized'
  $before = Get-StateSnapshot -Root $wrongRuntimeRestoreUnauthorized.StateRoot
  $result = Invoke-Studio -Case $wrongRuntimeRestoreUnauthorized -Scenario 'active-wrong-runtime' -Operation 'restore'
  Assert-Equal (Get-StateSnapshot -Root $wrongRuntimeRestoreUnauthorized.StateRoot) $before `
    'Unauthorized wrong-runtime restore changed protected state.'
  Assert-StudioResult -Result $result -Operation 'restore' -ExitCode 1 -Ok $false -Install 'ready' `
    -Codex 'running' -Session 'active' -ThemeName '午夜极光' -RequiresRestart $true -Verified $false `
    -AvailableActions @('pause', 'resume', 'restore', 'verify', 'uninstall') -ErrorCode 'RESTART_REQUIRED' `
    -RecoveryActions @('authorize-restart', 'cancel')
  Assert-NoChildOrLog -Case $wrongRuntimeRestoreUnauthorized

  $wrongRuntimeRestore = New-CaseRoot -Name 'wrong-runtime-restore'
  $result = Invoke-Studio -Case $wrongRuntimeRestore -Scenario 'active-wrong-runtime' -Operation 'restore' `
    -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.session -cne 'official') {
    throw 'Authorized Node-free restore was blocked by private Node validation.'
  }
  Assert-ChildInvocation -Case $wrongRuntimeRestore `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-CloseRunning|-AdapterLockHeld'

  $missingCodexRestore = New-CaseRoot -Name 'missing-codex-restore' -NoState
  $result = Invoke-Studio -Case $missingCodexRestore -Scenario 'missing-codex' -Operation 'restore'
  Assert-StudioResult -Result $result -Operation 'restore' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'not-installed' -Session 'official' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @('install', 'uninstall') -ErrorCode $null
  Assert-ChildInvocation -Case $missingCodexRestore `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-AdapterLockHeld'

  $missingCodexWithoutBackup = New-CaseRoot -Name 'missing-codex-restore-without-backup' -NoState
  Remove-Item -LiteralPath (Join-Path $missingCodexWithoutBackup.StateRoot 'config.before-dream-skin.toml') -Force
  $before = Get-ProtectedSnapshot -Case $missingCodexWithoutBackup
  $result = Invoke-Studio -Case $missingCodexWithoutBackup -Scenario 'missing-codex' -Operation 'restore'
  Assert-Equal (Get-ProtectedSnapshot -Case $missingCodexWithoutBackup) $before `
    'Missing-Codex restore without recovery backup changed protected state.'
  Assert-StudioResult -Result $result -Operation 'restore' -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'not-installed' -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-NoChildOrLog -Case $missingCodexWithoutBackup

  $restoreUnauthorized = New-CaseRoot -Name 'restore-unauthorized' -NoState
  $before = Get-StateSnapshot -Root $restoreUnauthorized.StateRoot
  $result = Invoke-Studio -Case $restoreUnauthorized -Scenario 'lifecycle-restore' -Operation 'restore'
  Assert-Equal (Get-StateSnapshot -Root $restoreUnauthorized.StateRoot) $before 'Unauthorized restore changed protected state.'
  if ($result.Envelope.error.code -cne 'RESTART_REQUIRED') { throw 'Unauthorized restore was not rejected.' }
  Assert-NoChildOrLog -Case $restoreUnauthorized

  $restore = New-CaseRoot -Name 'restore' -NoState
  $result = Invoke-Studio -Case $restore -Scenario 'lifecycle-restore' -Operation 'restore' -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.session -cne 'official') { throw 'Authorized restore did not return official state.' }
  Assert-ChildInvocation -Case $restore -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-CloseRunning|-AdapterLockHeld'
  Assert-OperationLog -Case $restore -ScriptName 'restore-dream-skin.ps1'

  $restoreStopped = New-CaseRoot -Name 'restore-stopped' -NoState
  $result = Invoke-Studio -Case $restoreStopped -Scenario 'stopped' -Operation 'restore'
  if ($result.ExitCode -ne 0) { throw 'Restore with stopped Codex failed.' }
  Assert-ChildInvocation -Case $restoreStopped -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-AdapterLockHeld'

  $restoreForce = New-CaseRoot -Name 'restore-force' -NoState
  $result = Invoke-Studio -Case $restoreForce -Scenario 'lifecycle-restore' -Operation 'restore' `
    -ExtraArguments @('-RestartAuthorized', '-ForceAuthorized')
  if ($result.ExitCode -ne 0) { throw 'Force-authorized restore failed.' }
  Assert-ChildInvocation -Case $restoreForce -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-CloseRunning|-ForceRestart|-AdapterLockHeld'

  foreach ($failureName in @('lifecycle-restore-timeout', 'restore-fail')) {
    $restoreFailure = New-CaseRoot -Name $failureName -NoState
    $protectedBefore = Get-ProtectedSnapshot -Case $restoreFailure
    $engineBefore = Get-StateSnapshot -Root $engineRoot
    $result = Invoke-Studio -Case $restoreFailure -Scenario $failureName -Operation 'restore' -ExtraArguments @('-RestartAuthorized')
    Assert-Equal (Get-ProtectedSnapshot -Case $restoreFailure) $protectedBefore 'Restore failure changed state, backup, config, or theme.'
    Assert-Equal (Get-StateSnapshot -Root $engineRoot) $engineBefore 'Restore failure changed the running engine.'
  }

  $staleRestoreUnauthorized = New-CaseRoot -Name 'stale-restore-unauthorized'
  $before = Get-StateSnapshot -Root $staleRestoreUnauthorized.StateRoot
  $result = Invoke-Studio -Case $staleRestoreUnauthorized -Scenario 'stale' -Operation 'restore'
  Assert-Equal (Get-StateSnapshot -Root $staleRestoreUnauthorized.StateRoot) $before 'Unauthorized stale restore changed protected state.'
  if ($result.Envelope.error.code -cne 'RESTART_REQUIRED') { throw 'Stale restore bypassed restart authorization.' }
  Assert-NoChildOrLog -Case $staleRestoreUnauthorized

  $staleRestore = New-CaseRoot -Name 'stale-restore'
  $result = Invoke-Studio -Case $staleRestore -Scenario 'stale' -Operation 'restore' -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.session -cne 'official') { throw 'STATE_UNSAFE blocked authorized restore recovery.' }
  Assert-ChildInvocation -Case $staleRestore -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-CloseRunning|-AdapterLockHeld'

  $staleRestoreFailure = New-CaseRoot -Name 'stale-restore-fail'
  $protectedBefore = Get-ProtectedSnapshot -Case $staleRestoreFailure
  $result = Invoke-Studio -Case $staleRestoreFailure -Scenario 'stale-restore-fail' -Operation 'restore' `
    -ExtraArguments @('-RestartAuthorized')
  Assert-Equal (Get-ProtectedSnapshot -Case $staleRestoreFailure) $protectedBefore 'Failed stale restore did not preserve state and backup.'
  if ($result.Envelope.error.code -cne 'OPERATION_FAILED') { throw 'Failed stale restore mapped incorrectly.' }

  $verify = New-CaseRoot -Name 'verify'
  $result = Invoke-Studio -Case $verify -Scenario 'lifecycle-verify' -Operation 'verify'
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.verified -ne $true) { throw 'Verify accepted a non-strict renderer result.' }
  Assert-ChildInvocation -Case $verify -Expected "verify-dream-skin.ps1 -NodePath|$nodePath|-AdapterLockHeld"
  Assert-OperationLog -Case $verify -ScriptName 'verify-dream-skin.ps1'

  $verifyFailure = New-CaseRoot -Name 'verify-fail'
  $result = Invoke-Studio -Case $verifyFailure -Scenario 'verify-fail' -Operation 'verify'
  if ($result.Envelope.error.code -cne 'VERIFY_FAILED') { throw 'Verify failure was not mapped safely.' }

  $partialEngineUninstall = New-CaseRoot -Name 'uninstall-partial-engine' -NoState
  $partialNodeBackup = "$nodePath.partial-engine"
  Move-Item -LiteralPath $nodePath -Destination $partialNodeBackup
  try {
    $result = Invoke-Studio -Case $partialEngineUninstall -Scenario 'stopped' -Operation 'uninstall'
  } finally {
    Move-Item -LiteralPath $partialNodeBackup -Destination $nodePath
  }
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install') -ErrorCode $null
  Assert-ChildInvocation -Case $partialEngineUninstall `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-AdapterLockHeld'
  Assert-OperationLog -Case $partialEngineUninstall -ScriptName 'restore-dream-skin.ps1'
  if (Test-Path -LiteralPath (Join-Path $partialEngineUninstall.StateRoot 'config.before-dream-skin.toml')) {
    throw 'Partial-engine uninstall skipped the retained config backup.'
  }

  $neverApplied = New-CaseRoot -Name 'uninstall-never-applied' -NoState
  Remove-Item -LiteralPath (Join-Path $neverApplied.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $neverApplied.StateRoot 'active-theme') -Recurse -Force
  $before = Get-ProtectedSnapshot -Case $neverApplied
  $result = Invoke-Studio -Case $neverApplied -Scenario 'stopped' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install') -ErrorCode $null
  Assert-Equal (Get-ProtectedSnapshot -Case $neverApplied) $before 'Never-applied uninstall changed retained theme state.'
  Assert-NoChildOrLog -Case $neverApplied

  $lostManagedRecovery = New-CaseRoot -Name 'uninstall-lost-managed-recovery' -NoState
  Remove-Item -LiteralPath (Join-Path $lostManagedRecovery.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $lostManagedRecovery.StateRoot 'active-theme') -Recurse -Force
  [IO.File]::WriteAllText((Join-Path $lostManagedRecovery.UserProfile '.codex\config.toml'),
    "[desktop]`r`nappearanceLightCodeThemeId = `"codex`"`r`n", $utf8NoBom)
  $before = Get-ProtectedSnapshot -Case $lostManagedRecovery
  $result = Invoke-Studio -Case $lostManagedRecovery -Scenario 'stopped' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'stopped' -Session 'stale' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $lostManagedRecovery) $before `
    'Managed config with lost recovery evidence changed protected state.'
  Assert-NoChildOrLog -Case $lostManagedRecovery

  $alreadyRestored = New-CaseRoot -Name 'uninstall-already-restored' -NoState
  Move-Item -LiteralPath (Join-Path $alreadyRestored.StateRoot 'config.before-dream-skin.toml') `
    -Destination (Join-Path $alreadyRestored.StateRoot 'config.restored.toml')
  $before = Get-ProtectedSnapshot -Case $alreadyRestored
  foreach ($attempt in 1..2) {
    $result = Invoke-Studio -Case $alreadyRestored -Scenario 'stopped' -Operation 'uninstall'
    if ($result.ExitCode -ne 0 -or -not $result.Envelope.ok) { throw 'Repeated already-restored uninstall failed.' }
  }
  Assert-Equal (Get-ProtectedSnapshot -Case $alreadyRestored) $before 'Repeated uninstall changed restored state.'
  Assert-NoChildOrLog -Case $alreadyRestored

  $incompleteRestored = New-CaseRoot -Name 'uninstall-incomplete-restored-marker' -NoState
  $incompleteBackup = Join-Path $incompleteRestored.StateRoot 'config.before-dream-skin.toml'
  Move-Item -LiteralPath $incompleteBackup -Destination (Join-Path $incompleteRestored.StateRoot 'config.restored.toml')
  [IO.File]::WriteAllText("$incompleteBackup.appearance.json", '{}', $utf8NoBom)
  $before = Get-ProtectedSnapshot -Case $incompleteRestored
  $result = Invoke-Studio -Case $incompleteRestored -Scenario 'stopped' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'stopped' -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $incompleteRestored) $before `
    'Fixed proof with a live backup marker changed protected state.'
  Assert-NoChildOrLog -Case $incompleteRestored

  $orphanActiveTheme = New-CaseRoot -Name 'uninstall-orphan-active-theme' -NoState
  Remove-Item -LiteralPath (Join-Path $orphanActiveTheme.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $orphanActiveTheme.StateRoot 'active-theme\theme.json') -Force
  $before = Get-ProtectedSnapshot -Case $orphanActiveTheme
  $result = Invoke-Studio -Case $orphanActiveTheme -Scenario 'stopped' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'stopped' -Session 'stale' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $orphanActiveTheme) $before `
    'Orphan active-theme entry changed protected state.'
  Assert-NoChildOrLog -Case $orphanActiveTheme

  $malformedBackup = New-CaseRoot -Name 'uninstall-malformed-backup' -NoState
  $malformedBackupPath = Join-Path $malformedBackup.StateRoot 'config.before-dream-skin.toml'
  Remove-Item -LiteralPath $malformedBackupPath -Force
  New-Item -ItemType Directory -Path $malformedBackupPath | Out-Null
  $before = Get-ProtectedSnapshot -Case $malformedBackup
  $result = Invoke-Studio -Case $malformedBackup -Scenario 'uninstall-malformed-backup' -Operation 'uninstall'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'OPERATION_FAILED') {
    throw 'Malformed backup directory was treated as affirmative restore proof.'
  }
  Assert-Equal (Get-ProtectedSnapshot -Case $malformedBackup) $before 'Malformed backup failure changed protected state.'

  $reparseBackup = New-CaseRoot -Name 'uninstall-reparse-backup' -NoState
  $reparseBackupPath = Join-Path $reparseBackup.StateRoot 'config.before-dream-skin.toml'
  $reparseTarget = Join-Path $reparseBackup.Root 'reparse-backup-target'
  Remove-Item -LiteralPath $reparseBackupPath -Force
  New-Item -ItemType Directory -Path $reparseTarget | Out-Null
  $null = New-Item -ItemType Junction -Path $reparseBackupPath -Target $reparseTarget
  try {
    $result = Invoke-Studio -Case $reparseBackup -Scenario 'stopped' -Operation 'uninstall'
    if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'OPERATION_FAILED') {
      throw 'Backup reparse point was treated as affirmative restore proof.'
    }
    Assert-NoChildOrLog -Case $reparseBackup
  } finally {
    [IO.Directory]::Delete($reparseBackupPath)
  }

  $orphanAppearance = New-CaseRoot -Name 'uninstall-orphan-appearance' -NoState
  $orphanBackup = Join-Path $orphanAppearance.StateRoot 'config.before-dream-skin.toml'
  Remove-Item -LiteralPath $orphanBackup -Force
  [IO.File]::WriteAllText("$orphanBackup.appearance.json", '{}', $utf8NoBom)
  $before = Get-ProtectedSnapshot -Case $orphanAppearance
  $result = Invoke-Studio -Case $orphanAppearance -Scenario 'stopped' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'stopped' -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $orphanAppearance) $before 'Orphan appearance recovery failure changed protected state.'
  Assert-NoChildOrLog -Case $orphanAppearance

  $runningWithoutArtifacts = New-CaseRoot -Name 'uninstall-running-without-artifacts' -NoState
  Remove-Item -LiteralPath (Join-Path $runningWithoutArtifacts.StateRoot 'config.before-dream-skin.toml') -Force
  $before = Get-ProtectedSnapshot -Case $runningWithoutArtifacts
  $result = Invoke-Studio -Case $runningWithoutArtifacts -Scenario 'running' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'running' -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $runningWithoutArtifacts) $before 'Running-Codex uninstall changed protected state before authorization.'
  Assert-NoChildOrLog -Case $runningWithoutArtifacts

  $unsafeStateRoot = New-CaseRoot -Name 'uninstall-state-root-file' -NoState
  Remove-Item -LiteralPath $unsafeStateRoot.StateRoot -Recurse -Force
  [IO.File]::WriteAllText($unsafeStateRoot.StateRoot, 'unsafe state root', $utf8NoBom)
  $stateRootHash = (Get-FileHash -LiteralPath $unsafeStateRoot.StateRoot -Algorithm SHA256).Hash
  $result = Invoke-Studio -Case $unsafeStateRoot -Scenario 'stopped' -Operation 'uninstall'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'OPERATION_FAILED' -or
    (Get-FileHash -LiteralPath $unsafeStateRoot.StateRoot -Algorithm SHA256).Hash -cne $stateRootHash) {
    throw 'Non-directory state root was treated as affirmative restore proof.'
  }
  Assert-NoChildOrLog -Case $unsafeStateRoot

  $reparseStateRoot = New-CaseRoot -Name 'uninstall-state-root-reparse' -NoState
  $reparseStateTarget = Join-Path $reparseStateRoot.Root 'state-root-target'
  Remove-Item -LiteralPath $reparseStateRoot.StateRoot -Recurse -Force
  New-Item -ItemType Directory -Path $reparseStateTarget | Out-Null
  $null = New-Item -ItemType Junction -Path $reparseStateRoot.StateRoot -Target $reparseStateTarget
  try {
    $result = Invoke-Studio -Case $reparseStateRoot -Scenario 'stopped' -Operation 'uninstall'
    if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'OPERATION_FAILED') {
      throw 'State-root reparse point was treated as affirmative restore proof.'
    }
    Assert-NoChildOrLog -Case $reparseStateRoot
  } finally {
    [IO.Directory]::Delete($reparseStateRoot.StateRoot)
  }

  $neverAppliedDelete = New-CaseRoot -Name 'uninstall-never-applied-delete' -NoState
  Remove-Item -LiteralPath (Join-Path $neverAppliedDelete.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $neverAppliedDelete.StateRoot 'active-theme') -Recurse -Force
  New-Item -ItemType Directory -Path (Join-Path $neverAppliedDelete.StateRoot 'themes') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $neverAppliedDelete.StateRoot 'images') -Force | Out-Null
  $result = Invoke-Studio -Case $neverAppliedDelete -Scenario 'stopped' -Operation 'uninstall' `
    -ExtraArguments @('-DeleteUserThemes')
  if ($result.ExitCode -ne 0 -or -not $result.Envelope.ok) {
    throw 'Never-applied uninstall with explicit theme deletion failed.'
  }
  foreach ($deleted in @('themes', 'images', 'active-theme')) {
    if (Test-Path -LiteralPath (Join-Path $neverAppliedDelete.StateRoot $deleted)) {
      throw "Never-applied uninstall retained explicitly deleted $deleted."
    }
  }
  Assert-NoChildOrLog -Case $neverAppliedDelete

  $missingCodexUninstall = New-CaseRoot -Name 'uninstall-missing-codex' -NoState
  $result = Invoke-Studio -Case $missingCodexUninstall -Scenario 'missing-codex' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install') -ErrorCode $null
  Assert-ChildInvocation -Case $missingCodexUninstall `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-AdapterLockHeld'
  $childInvocationCount = @([IO.File]::ReadAllLines($missingCodexUninstall.ArgvPath)).Count
  $result = Invoke-Studio -Case $missingCodexUninstall -Scenario 'missing-codex' -Operation 'uninstall'
  if ($result.ExitCode -ne 0 -or @([IO.File]::ReadAllLines($missingCodexUninstall.ArgvPath)).Count -ne $childInvocationCount) {
    throw 'Repeated missing-Codex uninstall reran completed recovery.'
  }

  $uninstall = New-CaseRoot -Name 'uninstall' -NoState
  New-Item -ItemType Directory -Path (Join-Path $uninstall.StateRoot 'themes\saved') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $uninstall.StateRoot 'images') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $uninstall.StateRoot 'themes\saved\theme.json'), '{}', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $uninstall.StateRoot 'images\saved.jpg'), 'image', $utf8NoBom)
  $engineBefore = Get-StateSnapshot -Root $engineRoot
  $result = Invoke-Studio -Case $uninstall -Scenario 'lifecycle-uninstall' -Operation 'uninstall' -ExtraArguments @('-RestartAuthorized')
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install') -ErrorCode $null
  Assert-ChildInvocation -Case $uninstall `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-CloseRunning|-AdapterLockHeld'
  Assert-OperationLog -Case $uninstall -ScriptName 'restore-dream-skin.ps1'
  foreach ($preserved in @('themes', 'images', 'active-theme')) {
    if (-not (Test-Path -LiteralPath (Join-Path $uninstall.StateRoot $preserved) -PathType Container)) { throw "Default uninstall deleted $preserved." }
  }
  Assert-Equal (Get-StateSnapshot -Root $engineRoot) $engineBefore 'Uninstall deleted its running versioned engine.'

  $wrongRuntimeUninstall = New-CaseRoot -Name 'wrong-runtime-uninstall'
  $result = Invoke-Studio -Case $wrongRuntimeUninstall -Scenario 'active-wrong-runtime' -Operation 'uninstall' `
    -ExtraArguments @('-RestartAuthorized')
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install') -ErrorCode $null
  Assert-ChildInvocation -Case $wrongRuntimeUninstall `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-CloseRunning|-AdapterLockHeld'

  $uninstallIncomplete = New-CaseRoot -Name 'uninstall-incomplete' -NoState
  $result = Invoke-Studio -Case $uninstallIncomplete -Scenario 'uninstall-incomplete' -Operation 'uninstall'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'OPERATION_FAILED') {
    throw 'Uninstall projected canonical success before installation removal was verified.'
  }

  $uninstallForce = New-CaseRoot -Name 'uninstall-force' -NoState
  $result = Invoke-Studio -Case $uninstallForce -Scenario 'lifecycle-uninstall' -Operation 'uninstall' `
    -ExtraArguments @('-RestartAuthorized', '-ForceAuthorized')
  if ($result.ExitCode -ne 0) { throw 'Force-authorized uninstall failed.' }
  Assert-ChildInvocation -Case $uninstallForce `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-CloseRunning|-ForceRestart|-AdapterLockHeld'

  $deleteThemes = New-CaseRoot -Name 'uninstall-delete' -NoState
  New-Item -ItemType Directory -Path (Join-Path $deleteThemes.StateRoot 'themes') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $deleteThemes.StateRoot 'images') -Force | Out-Null
  $result = Invoke-Studio -Case $deleteThemes -Scenario 'lifecycle-uninstall' -Operation 'uninstall' `
    -ExtraArguments @('-RestartAuthorized', '-DeleteUserThemes')
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install') -ErrorCode $null
  foreach ($deleted in @('themes', 'images', 'active-theme')) {
    if (Test-Path -LiteralPath (Join-Path $deleteThemes.StateRoot $deleted)) { throw "Explicit uninstall retained $deleted." }
  }

  $uninstallFailure = New-CaseRoot -Name 'uninstall-fail' -NoState
  $protectedBefore = Get-ProtectedSnapshot -Case $uninstallFailure
  $engineBefore = Get-StateSnapshot -Root $engineRoot
  $result = Invoke-Studio -Case $uninstallFailure -Scenario 'uninstall-fail' -Operation 'uninstall' -ExtraArguments @('-RestartAuthorized')
  Assert-Equal (Get-ProtectedSnapshot -Case $uninstallFailure) $protectedBefore 'Failed uninstall changed protected state.'
  Assert-Equal (Get-StateSnapshot -Root $engineRoot) $engineBefore 'Failed uninstall changed engine/runtime.'

  $missingNode = New-CaseRoot -Name 'missing-node' -NoState
  $nodeBackup = "$nodePath.missing"
  Move-Item -LiteralPath $nodePath -Destination $nodeBackup
  try {
    $before = Get-StateSnapshot -Root $missingNode.StateRoot
    $result = Invoke-Studio -Case $missingNode -Scenario 'stopped' -Operation 'install'
    Assert-Equal (Get-StateSnapshot -Root $missingNode.StateRoot) $before 'Missing private Node changed protected state.'
    if ($result.Envelope.error.code -cne 'RUNTIME_INVALID') { throw 'Missing private Node fell back to PATH.' }
    Assert-NoChildOrLog -Case $missingNode
  } finally {
    Move-Item -LiteralPath $nodeBackup -Destination $nodePath
  }

  $wrongRuntime = New-CaseRoot -Name 'wrong-runtime' -NoState
  $before = Get-StateSnapshot -Root $wrongRuntime.StateRoot
  $result = Invoke-Studio -Case $wrongRuntime -Scenario 'wrong-runtime' -Operation 'install'
  Assert-Equal (Get-StateSnapshot -Root $wrongRuntime.StateRoot) $before 'Wrong private Node version changed protected state.'
  if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'RUNTIME_INVALID') {
    throw 'Studio accepted a private Node version other than 22.23.1.'
  }
  Assert-NoChildOrLog -Case $wrongRuntime

  $realLockRejected = New-RealLifecycleCase -Name 'lock-bypass-rejected'
  $realResult = Invoke-RealLifecycle -Case $realLockRejected -ScriptName 'verify-dream-skin.ps1' `
    -Scenario 'real-lock-owner-valid' -Arguments @('-NodePath', $nodePath, '-AdapterLockHeld')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'lock-enter') {
    throw 'A direct lifecycle caller bypassed the operation lock without the adapter-owned marker.'
  }

  $realLockSelfClaimed = New-RealLifecycleCase -Name 'lock-bypass-self-claimed'
  $realResult = Invoke-RealLifecycle -Case $realLockSelfClaimed -ScriptName 'verify-dream-skin.ps1' `
    -Scenario 'real-lock-owner-valid' -Arguments @('-NodePath', $nodePath, '-AdapterLockHeld') -LockOwner self
  if ($realResult.ExitCode -eq 0) {
    throw 'A direct lifecycle wrapper bypassed the operation lock by supplying its own parent PID.'
  }

  $realLockWrongOwner = New-RealLifecycleCase -Name 'lock-bypass-wrong-owner'
  $realResult = Invoke-RealLifecycle -Case $realLockWrongOwner -ScriptName 'verify-dream-skin.ps1' `
    -Scenario 'real-lock-owner-valid' -Arguments @('-NodePath', $nodePath, '-AdapterLockHeld') -LockOwner invalid
  if ($realResult.ExitCode -eq 0) { throw 'A lifecycle child accepted a lock marker from the wrong parent process.' }

  $realLockAccepted = New-RealLifecycleCase -Name 'lock-bypass-accepted'
  $realResult = Invoke-RealLifecycle -Case $realLockAccepted -ScriptName 'verify-dream-skin.ps1' `
    -Scenario 'real-lock-owner-valid' -Arguments @('-NodePath', $nodePath, '-AdapterLockHeld') -LockOwner valid
  if ($realResult.ExitCode -ne 0 -or $realResult.Trace -contains 'lock-enter' -or
    $realResult.Trace -notcontains 'cdp') {
    throw 'An adapter-owned production lifecycle child did not reuse the adapter operation lock.'
  }

  $realMissingNode = New-RealLifecycleCase -Name 'explicit-node-missing'
  $missingNodePath = Join-Path $realMissingNode.Root 'missing-node.exe'
  $realResult = Invoke-RealLifecycle -Case $realMissingNode -ScriptName 'verify-dream-skin.ps1' `
    -Scenario 'real-verify' -Arguments @('-NodePath', $missingNodePath)
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'cdp') {
    throw 'A production lifecycle script fell back to PATH after an explicit Node path was missing.'
  }

  $realInstallUnauthorized = New-RealLifecycleCase -Name 'install-unauthorized'
  $realResult = Invoke-RealLifecycle -Case $realInstallUnauthorized -ScriptName 'install-dream-skin.ps1' `
    -Scenario 'real-install-unauthorized' -Arguments @('-NoShortcuts', '-NodePath', $nodePath)
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'stop:False' -or
    $realResult.Trace -contains 'ensure' -or $realResult.Trace -contains 'install-config') {
    throw 'Production install mutated or stopped Codex without close authorization.'
  }

  $realInstallTimeout = New-RealLifecycleCase -Name 'install-timeout'
  $realResult = Invoke-RealLifecycle -Case $realInstallTimeout -ScriptName 'install-dream-skin.ps1' `
    -Scenario 'real-install-timeout' -Arguments @('-NoShortcuts', '-NodePath', $nodePath, '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains 'stop:False' -or
    $realResult.Trace -contains 'ensure' -or $realResult.Trace -contains 'install-config') {
    throw 'Production install normal-close timeout crossed its write boundary.'
  }

  $realInstallForce = New-RealLifecycleCase -Name 'install-force'
  $realResult = Invoke-RealLifecycle -Case $realInstallForce -ScriptName 'install-dream-skin.ps1' `
    -Scenario 'real-install-force' `
    -Arguments @('-NoShortcuts', '-NodePath', $nodePath, '-CloseRunning', '-ForceRestart')
  if ($realResult.ExitCode -ne 0) { throw 'Production install rejected both authorization levels.' }
  Assert-TraceOrder -Trace $realResult.Trace -Expected @('stop:True', 'ensure', 'initialize-theme', 'install-config') `
    -Message 'Production install force authorization did not reach writes in order.'

  $realStartUnauthorized = New-RealLifecycleCase -Name 'start-unauthorized'
  $realResult = Invoke-RealLifecycle -Case $realStartUnauthorized -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'real-start-unauthorized' -Arguments @('-NodePath', $nodePath)
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'stop:False' -or
    $realResult.Trace -contains 'ensure') {
    throw 'Production start crossed its restart authorization boundary.'
  }

  $realStartTimeout = New-RealLifecycleCase -Name 'start-timeout'
  $realResult = Invoke-RealLifecycle -Case $realStartTimeout -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'real-start-timeout' -Arguments @('-NodePath', $nodePath, '-RestartExisting')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains 'stop:False' -or
    $realResult.Trace -contains 'ensure') {
    throw 'Production start normal-close timeout crossed its write boundary.'
  }

  $realStartForce = New-RealLifecycleCase -Name 'start-force'
  $realResult = Invoke-RealLifecycle -Case $realStartForce -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'real-start-force' -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart')
  if ($realResult.ExitCode -eq 0) { throw 'Bounded production start fixture did not stop after its authorized write boundary.' }
  Assert-TraceOrder -Trace $realResult.Trace -Expected @('stop:True', 'ensure') `
    -Message 'Production start did not propagate force before its first write.'

  $realPause = New-RealLifecycleCase -Name 'pause-order'
  $realResult = Invoke-RealLifecycle -Case $realPause -ScriptName 'pause-dream-skin.ps1' `
    -Scenario 'real-pause' -Arguments @('-NodePath', $nodePath)
  if ($realResult.ExitCode -ne 0) { throw 'Production pause fixture failed.' }
  Assert-TraceOrder -Trace $realResult.Trace `
    -Expected @('codex-process', 'cdp', 'injector-identity', 'watcher-stop', 'remove', 'marker') `
    -Message 'Production pause did not validate, stop, remove, then mark.'

  $realPauseFailure = New-RealLifecycleCase -Name 'pause-remove-fail'
  $realResult = Invoke-RealLifecycle -Case $realPauseFailure -ScriptName 'pause-dream-skin.ps1' `
    -Scenario 'real-pause-remove-fail' -Arguments @('-NodePath', $nodePath)
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'marker') {
    throw 'Production pause wrote its marker after live removal failed.'
  }

  $realRestoreUnauthorized = New-RealLifecycleCase -Name 'restore-unauthorized'
  $realConfig = Join-Path $realRestoreUnauthorized.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realRestoreUnauthorized.StateRoot 'config.before-dream-skin.toml'
  $realState = Join-Path $realRestoreUnauthorized.StateRoot 'state.json'
  $realResult = Invoke-RealLifecycle -Case $realRestoreUnauthorized -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-unauthorized' -Arguments @('-RestoreBaseTheme', '-NoRelaunch')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'stop:False' -or
    $realResult.Trace -contains 'restore-config' -or [IO.File]::ReadAllText($realConfig) -cne 'original' -or
    [IO.File]::ReadAllText($realBackup) -cne 'backup' -or [IO.File]::ReadAllText($realState) -cne 'preserve-state') {
    throw 'Production restore crossed its close-authorization boundary.'
  }

  $realRestoreTimeout = New-RealLifecycleCase -Name 'restore-timeout'
  $realConfig = Join-Path $realRestoreTimeout.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realRestoreTimeout.StateRoot 'config.before-dream-skin.toml'
  $realState = Join-Path $realRestoreTimeout.StateRoot 'state.json'
  $realResult = Invoke-RealLifecycle -Case $realRestoreTimeout -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-timeout' -Arguments @('-RestoreBaseTheme', '-NoRelaunch', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains 'stop:False' -or
    $realResult.Trace -contains 'ensure' -or $realResult.Trace -contains 'restore-config' -or
    [IO.File]::ReadAllText($realConfig) -cne 'original' -or [IO.File]::ReadAllText($realBackup) -cne 'backup' -or
    [IO.File]::ReadAllText($realState) -cne 'preserve-state') {
    throw 'Production restore normal-close timeout changed config, state, or backup.'
  }

  $realRestoreForce = New-RealLifecycleCase -Name 'restore-force'
  $realConfig = Join-Path $realRestoreForce.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realRestoreForce.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realRestoreForce.StateRoot 'config.restored.toml'
  $realState = Join-Path $realRestoreForce.StateRoot 'state.json'
  $realResult = Invoke-RealLifecycle -Case $realRestoreForce -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-force' `
    -Arguments @('-RestoreBaseTheme', '-NoRelaunch', '-CloseRunning', '-ForceRestart')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'restored' -or
    (Test-Path -LiteralPath $realBackup) -or -not (Test-Path -LiteralPath $realArchive) -or
    (Test-Path -LiteralPath $realState)) {
    throw 'Production restore did not complete after both close authorization levels.'
  }
  Assert-TraceOrder -Trace $realResult.Trace -Expected @('stop:True', 'ensure', 'restore-config', 'archive-backup') `
    -Message 'Production restore did not propagate force before restore writes.'

  $realStateFailure = New-RealLifecycleCase -Name 'restore-state-unlink-failure'
  $realConfig = Join-Path $realStateFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realStateFailure.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realStateFailure.StateRoot 'config.restored.toml'
  $realState = Join-Path $realStateFailure.StateRoot 'state.json'
  $realPaused = Join-Path $realStateFailure.StateRoot 'paused'
  $realBackupMarker = "$realBackup.appearance.json"
  $realArchiveMarker = "$realArchive.appearance.json"
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realStateFailure
  $realResult = Invoke-RealLifecycle -Case $realStateFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-state-unlink-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realPaused" -or
    $realResult.Trace -contains 'start-process') {
    throw 'State cleanup failure did not retain retryable restore recovery data.'
  }
  Assert-RealRestoreRolledBack -Case $realStateFailure -Baseline $realBaseline `
    -Message 'State cleanup failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'restore-config', 'archive-backup', "remove:$realState", 'config-rollback'
  ) -Message 'State cleanup failure did not roll config and published proof back before relaunch.'

  $realResult = Invoke-RealLifecycle -Case $realStateFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-uninstall-retry' -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'restored' -or
    (Test-Path -LiteralPath $realBackup) -or (Test-Path -LiteralPath $realBackupMarker) -or
    (Test-Path -LiteralPath $realState) -or (Test-Path -LiteralPath $realPaused) -or
    -not (Test-Path -LiteralPath $realArchive) -or -not (Test-Path -LiteralPath $realArchiveMarker)) {
    throw 'Uninstall could not retry and commit a restore after state cleanup failed.'
  }

  $realPausedFailure = New-RealLifecycleCase -Name 'restore-paused-unlink-failure'
  $realConfig = Join-Path $realPausedFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realPausedFailure.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realPausedFailure.StateRoot 'config.restored.toml'
  $realState = Join-Path $realPausedFailure.StateRoot 'state.json'
  $realPaused = Join-Path $realPausedFailure.StateRoot 'paused'
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realPausedFailure
  $realResult = Invoke-RealLifecycle -Case $realPausedFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-paused-unlink-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realBackup" -or
    $realResult.Trace -contains 'start-process') {
    throw 'Pause cleanup failure did not leave a retryable backup and exact remaining marker.'
  }
  Assert-RealRestoreRolledBack -Case $realPausedFailure -Baseline $realBaseline `
    -Message 'Pause cleanup failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'restore-config', 'archive-backup', "remove:$realState", "remove:$realPaused", 'config-rollback'
  ) -Message 'Pause cleanup failure did not roll config and published proof back before relaunch.'

  $realRestoreFailure = New-RealLifecycleCase -Name 'restore-archive-failure'
  $realConfig = Join-Path $realRestoreFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realRestoreFailure.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realRestoreFailure.StateRoot 'config.restored.toml'
  $realState = Join-Path $realRestoreFailure.StateRoot 'state.json'
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realRestoreFailure
  $realResult = Invoke-RealLifecycle -Case $realRestoreFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-archive-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realState" -or
    $realResult.Trace -contains 'start-process') {
    throw 'Archive failure did not preserve a retryable backup without relaunching Codex.'
  }
  Assert-RealRestoreRolledBack -Case $realRestoreFailure -Baseline $realBaseline `
    -Message 'Archive publication failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @('restore-config', 'archive-backup', 'config-rollback') `
    -Message 'Archive failure did not roll config back before any relaunch.'

  $realResult = Invoke-RealLifecycle -Case $realRestoreFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-retry' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'restored' -or
    (Test-Path -LiteralPath $realBackup) -or -not (Test-Path -LiteralPath $realArchive)) {
    throw 'Restore retry did not commit the retained backup after archive failure.'
  }

  $realMarkerFailure = New-RealLifecycleCase -Name 'restore-marker-unlink-failure'
  $realConfig = Join-Path $realMarkerFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realMarkerFailure.StateRoot 'config.before-dream-skin.toml'
  $realBackupMarker = "$realBackup.appearance.json"
  $realArchive = Join-Path $realMarkerFailure.StateRoot 'config.restored.toml'
  $realArchiveMarker = "$realArchive.appearance.json"
  $realState = Join-Path $realMarkerFailure.StateRoot 'state.json'
  $realPaused = Join-Path $realMarkerFailure.StateRoot 'paused'
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realMarkerFailure
  $realResult = Invoke-RealLifecycle -Case $realMarkerFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-marker-unlink-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realBackup" -or
    $realResult.Trace -contains 'start-process') {
    throw 'Backup marker cleanup failure reported a committed restore or relaunched Codex.'
  }
  Assert-RealRestoreRolledBack -Case $realMarkerFailure -Baseline $realBaseline `
    -Message 'Backup marker cleanup failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'restore-config', 'archive-backup', "remove:$realState", "remove:$realPaused",
    "remove:$realBackupMarker", 'config-rollback'
  ) -Message 'Backup marker cleanup failure crossed or escaped the restore transaction.'

  $realResult = Invoke-RealLifecycle -Case $realMarkerFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-marker-retry' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'restored' -or
    (Test-Path -LiteralPath $realBackup) -or (Test-Path -LiteralPath $realBackupMarker) -or
    (Test-Path -LiteralPath $realState) -or (Test-Path -LiteralPath $realPaused) -or
    -not (Test-Path -LiteralPath $realArchive) -or -not (Test-Path -LiteralPath $realArchiveMarker)) {
    throw 'Restore could not retry and commit after backup marker cleanup failed.'
  }

  $realConfig = Join-Path $realRestoreFailure.UserProfile '.codex\config.toml'
  $realArchive = Join-Path $realRestoreFailure.StateRoot 'config.restored.toml'
  $archiveBytes = [IO.File]::ReadAllBytes($realArchive)
  [IO.File]::WriteAllText($realConfig, 'after-complete', $utf8NoBom)
  [IO.File]::WriteAllText($realRestoreFailure.TracePath, '', $utf8NoBom)
  $realResult = Invoke-RealLifecycle -Case $realRestoreFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-repeat' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'after-complete' -or
    [Convert]::ToBase64String($archiveBytes) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($realArchive)) -or
    $realResult.Trace -contains 'restore-config' -or $realResult.Trace -contains 'archive-backup') {
    throw 'Repeated restore did not use fixed completion evidence idempotently.'
  }

  $realLaunchFailure = New-RealLifecycleCase -Name 'restore-launch-failure'
  $realConfig = Join-Path $realLaunchFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realLaunchFailure.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realLaunchFailure.StateRoot 'config.restored.toml'
  $realState = Join-Path $realLaunchFailure.StateRoot 'state.json'
  $realResult = Invoke-RealLifecycle -Case $realLaunchFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-launch-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'restored' -or
    (Test-Path -LiteralPath $realBackup) -or -not (Test-Path -LiteralPath $realArchive) -or
    (Test-Path -LiteralPath $realState) -or $realResult.Trace -contains 'config-rollback' -or
    (($realResult.Stdout + $realResult.Stderr) -notlike '*Codex could not be reopened automatically. The restore is complete*')) {
    throw 'Relaunch failure rolled back or failed an already committed restore.'
  }
  Assert-TraceOrder -Trace $realResult.Trace -Expected @('restore-config', 'archive-backup', 'start-process') `
    -Message 'Relaunch was attempted before restore commit.'

  $realPostLaunch = New-RealLifecycleCase -Name 'restore-post-launch-write'
  $realConfig = Join-Path $realPostLaunch.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realPostLaunch.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realPostLaunch.StateRoot 'config.restored.toml'
  $realResult = Invoke-RealLifecycle -Case $realPostLaunch -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-post-launch-write' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -ne 0 -or [IO.File]::ReadAllText($realConfig) -cne 'post-launch' -or
    (Test-Path -LiteralPath $realBackup) -or -not (Test-Path -LiteralPath $realArchive) -or
    $realResult.Trace -contains 'config-rollback') {
    throw 'A post-launch Codex config write was overwritten by restore rollback.'
  }
  Assert-TraceOrder -Trace $realResult.Trace -Expected @('restore-config', 'archive-backup', 'start-process') `
    -Message 'Codex relaunched before the restore completion archive committed.'

  $realUninstall = New-RealLifecycleCase -Name 'uninstall-order'
  $realResult = Invoke-RealLifecycle -Case $realUninstall -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-uninstall' -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
  if ($realResult.ExitCode -ne 0 -or $realResult.Trace -contains 'start-process') {
    throw 'Production uninstall relaunched Codex or failed its restore.'
  }
  $restoreIndex = [Array]::IndexOf($realResult.Trace, 'restore-config')
  $archiveIndex = [Array]::IndexOf($realResult.Trace, 'archive-backup')
  $shortcutIndex = -1
  for ($index = 0; $index -lt $realResult.Trace.Count; $index++) {
    if ($realResult.Trace[$index] -like 'remove:*Codex Dream Skin.lnk') { $shortcutIndex = $index; break }
  }
  if ($restoreIndex -lt 0 -or $archiveIndex -le $restoreIndex -or $shortcutIndex -le $archiveIndex) {
    throw 'Production uninstall removed shortcuts before restore and backup completion.'
  }

  $realUninstallForce = New-RealLifecycleCase -Name 'uninstall-force'
  $realResult = Invoke-RealLifecycle -Case $realUninstallForce -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-uninstall-force' `
    -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch', '-CloseRunning', '-ForceRestart')
  if ($realResult.ExitCode -ne 0 -or $realResult.Trace -contains 'start-process') {
    throw 'Production uninstall rejected authorized force or relaunched Codex.'
  }
  Assert-TraceOrder -Trace $realResult.Trace `
    -Expected @('stop:True', 'restore-config', 'archive-backup', "remove:$([Environment]::GetFolderPath('Desktop'))\Codex Dream Skin.lnk") `
    -Message 'Production uninstall did not stop Codex before restore and shortcut cleanup.'

  Assert-Equal (Get-StateSnapshot -Root $realRoot) $realEngineSnapshot `
    'Lifecycle success and rollback paths changed the versioned engine.'

  Write-Host 'PASS: Windows Studio status and lifecycle protocol.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
