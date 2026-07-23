[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex dream skin studio tests $PID $([guid]::NewGuid().ToString('N'))"
$versionRoot = Join-Path $temporaryRoot 'release\1.3.1'
$engineRoot = Join-Path $versionRoot 'engine'
$scriptsRoot = Join-Path $engineRoot 'scripts'
$adapterPath = Join-Path $scriptsRoot 'studio-adapter.ps1'
$nodePath = Join-Path $engineRoot 'runtime\node.exe'
$injectorPath = Join-Path $scriptsRoot 'injector.mjs'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
. (Join-Path $Root 'scripts\config-utf8.ps1')

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
  $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 8
  $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 8
  if ($actualJson -cne $expectedJson) {
    throw "$Message Expected: $expectedJson. Actual: $actualJson."
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
  $savedRelease = $env:DREAM_SKIN_TEST_RELEASE
  $savedArgv = $env:DREAM_SKIN_TEST_ARGV
  $savedStateTemplate = $env:DREAM_SKIN_TEST_STATE_TEMPLATE
  $savedRendererTrace = $env:DREAM_SKIN_TEST_RENDERER_TRACE
  $savedRuntimeTrace = $env:DREAM_SKIN_TEST_RUNTIME_TRACE
  try {
    $env:LOCALAPPDATA = $Case.LocalAppData
    $env:USERPROFILE = $Case.UserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $Scenario
    $env:DREAM_SKIN_TEST_INJECTOR = $injectorPath
    $env:DREAM_SKIN_TEST_SIGNAL = Join-Path $Case.Root 'probe-entered'
    $env:DREAM_SKIN_TEST_RELEASE = Join-Path $Case.Root 'probe-release'
    $env:DREAM_SKIN_TEST_ARGV = $Case.ArgvPath
    $env:DREAM_SKIN_TEST_STATE_TEMPLATE = $Case.StateTemplate
    $env:DREAM_SKIN_TEST_RENDERER_TRACE = Join-Path $Case.Root 'renderer-trace.txt'
    $env:DREAM_SKIN_TEST_RUNTIME_TRACE = Join-Path $Case.Root 'runtime-trace.txt'
    $argumentLine = "-NoProfile -File `"$adapterPath`""
    if (-not $OmitOperation) { $argumentLine += " -Operation $Operation" }
    if ($ExtraArguments.Count -gt 0) { $argumentLine += ' ' + ($ExtraArguments -join ' ') }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    # Windows PowerShell 5.1 needs an open handle to retain a fast child's exit code.
    $null = $process.Handle
  } finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:USERPROFILE = $savedUserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $savedScenario
    $env:DREAM_SKIN_TEST_INJECTOR = $savedInjector
    $env:DREAM_SKIN_TEST_SIGNAL = $savedSignal
    $env:DREAM_SKIN_TEST_RELEASE = $savedRelease
    $env:DREAM_SKIN_TEST_ARGV = $savedArgv
    $env:DREAM_SKIN_TEST_STATE_TEMPLATE = $savedStateTemplate
    $env:DREAM_SKIN_TEST_RENDERER_TRACE = $savedRendererTrace
    $env:DREAM_SKIN_TEST_RUNTIME_TRACE = $savedRuntimeTrace
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
    [AllowNull()][object]$ThemeName,
    [bool]$RequiresRestart,
    [AllowNull()][Nullable[bool]]$Verified,
    [string[]]$AvailableActions,
    [AllowNull()][object]$ErrorCode,
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
    throw "Unexpected Studio state for $Operation/$Session. Expected exit=$ExitCode, ok=$Ok, install=$Install, codex=$Codex, operationState=$OperationState, themeName=$ThemeName, requiresRestart=$RequiresRestart, verified=$Verified. Actual exit=$($Result.ExitCode): $($Result.Raw)"
  }
  Assert-Equal @($envelope.state.availableActions) @($AvailableActions) 'Unexpected available actions.'
  if ($null -eq $ErrorCode) {
    if ($null -ne $envelope.error) { throw 'Successful Studio envelope contains an error.' }
  } else {
    Assert-Equal @($envelope.error.PSObject.Properties.Name | Sort-Object) @('code', 'message', 'recoveryActions') `
      "Unexpected error keys for $Operation/$Session. Raw: $($Result.Raw)"
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
  "'pause-dream-skin.ps1'", "@('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')",
  '[Console]::Error.WriteLine("DREAM_SKIN_PROGRESS=$progress")',
  "Get-DreamSkinNodeRuntime -NodePath `$PrivateNodePath -ExpectedVersion '22.23.1'",
  "`$childArguments += '-AdapterLockHeld'",
  '$startInfo.EnvironmentVariables[''DREAM_SKIN_ADAPTER_LOCK_OWNER_PID''] = "$PID"',
  "@('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')",
  "New-DreamSkinStudioState -Install 'not-installed' -Codex 'stopped' -Session 'official'",
  'Get-DreamSkinStudioRecoveryState -StateRoot $stateRoot',
  '$recovery.Completed -or $recovery.NeverApplied',
  '$status.State.codex -eq ''running'' -or $status.State.requiresRestart'
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
$restorePauseCleanup = $restoreSourceContract.IndexOf("Remove-DreamSkinRecoveryArtifact -Path (Join-Path `$StateRoot 'paused')", [StringComparison]::Ordinal)
$restoreMarkerToken = 'Remove-DreamSkinRecoveryArtifact -Path $backupMarkerPath'
$restoreMarkerCleanup = if ($restorePauseCleanup -ge 0) {
  $restoreSourceContract.IndexOf($restoreMarkerToken, $restorePauseCleanup, [StringComparison]::Ordinal)
} else { -1 }
$restoreBackupCleanup = if ($restoreMarkerCleanup -ge 0) {
  $restoreSourceContract.IndexOf('Remove-DreamSkinRecoveryArtifact -Path $backup',
    $restoreMarkerCleanup + $restoreMarkerToken.Length, [StringComparison]::Ordinal)
} else { -1 }
$restoreGuardComplete = if ($restoreBackupCleanup -ge 0) {
  $restoreSourceContract.IndexOf('$missingConfigGuard.Complete()', $restoreBackupCleanup, [StringComparison]::Ordinal)
} else { -1 }
$restoreStateCleanup = if ($restoreGuardComplete -ge 0) {
  $restoreSourceContract.IndexOf('[DreamSkinConfigNative]::DeleteExpectedFile(',
    $restoreGuardComplete, [StringComparison]::Ordinal)
} else { -1 }
$restoreStateGuardComplete = if ($restoreStateCleanup -ge 0) {
  $restoreSourceContract.IndexOf('$statePathGuard.Complete()', $restoreStateCleanup, [StringComparison]::Ordinal)
} else { -1 }
$restoreCommit = if ($restoreStateGuardComplete -ge 0) {
  $restoreSourceContract.IndexOf('$transactionCommitted = $true', $restoreStateGuardComplete, [StringComparison]::Ordinal)
} else { -1 }
$restoreRelaunch = if ($restoreCommit -ge 0) {
  $restoreSourceContract.IndexOf('Start-Process -FilePath $relaunchCodex.Executable', $restoreCommit, [StringComparison]::Ordinal)
} else { -1 }
$shortcutCleanup = $restoreSourceContract.IndexOf('Remove-DreamSkinManagedLegacyShortcuts', [StringComparison]::Ordinal)
if (-not $restoreSourceContract.Contains("Join-Path `$StateRoot 'config.restored.toml'") -or
  -not $restoreSourceContract.Contains('$transactionCommitted = $false') -or
  -not $restoreSourceContract.Contains('Get-DreamSkinRecoveryArtifactSnapshot') -or
  -not $restoreSourceContract.Contains('Restore-DreamSkinRecoveryArtifactSnapshot') -or
  $restorePublish -lt 0 -or $restorePauseCleanup -le $restorePublish -or
  $restoreMarkerCleanup -le $restorePauseCleanup -or
  $restoreBackupCleanup -le $restoreMarkerCleanup -or $restoreGuardComplete -le $restoreBackupCleanup -or
  $restoreStateCleanup -le $restoreGuardComplete -or
  $restoreStateGuardComplete -le $restoreStateCleanup -or $restoreCommit -le $restoreStateGuardComplete -or
  $restoreRelaunch -le $restoreCommit -or $shortcutCleanup -le $restorePublish -or
  -not $restoreSourceContract.Contains('if (-not $transactionCommitted -and $configChanged') -or
  -not $restoreSourceContract.Contains('Write-DreamSkinBytesAtomically -Path $config -Bytes $configBeforeRestoreSnapshot.Bytes') -or
  -not $restoreSourceContract.Contains('-ExpectedSnapshot $currentConfigSnapshot')) {
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
if (-not $studioSourceContract.Contains('Assert-DreamSkinNoReparseComponents -Path $StateRoot')) {
  throw 'Shared Studio recovery classification does not validate the state root.'
}
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
[IO.File]::WriteAllText((Join-Path $engineRoot 'VERSION'), '1.3.1', $utf8NoBom)
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
  $releaseDeadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $releaseDeadline -and
    -not (Test-Path -LiteralPath $env:DREAM_SKIN_TEST_RELEASE -PathType Leaf)) {
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $env:DREAM_SKIN_TEST_RELEASE -PathType Leaf)) {
    throw 'Lifecycle lock fixture was not released by its parent.'
  }
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
    $liveBackup = Join-Path $stateRoot 'config.before-dream-skin.toml'
    if ($scenario -ne 'uninstall-incomplete' -and (Test-Path -LiteralPath $liveBackup -PathType Leaf)) {
      Move-Item -LiteralPath (Join-Path $stateRoot 'config.before-dream-skin.toml') `
        -Destination (Join-Path $stateRoot 'config.restored.toml') -Force
    }
    $configMissing = -not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.codex\config.toml'))
    if ($args -contains '-NoRelaunch' -or $configMissing) {
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
    string scenario = Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_SCENARIO");
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
      File.AppendAllText(Environment.GetEnvironmentVariable("DREAM_SKIN_REAL_TRACE"),
        "remove-args:" + String.Join(" ", args) + "\n");
      return scenario == "real-pause-remove-fail" ||
        scenario == "start-rollback-remove-fail" || scenario == "resume-rollback-remove-fail" ? 9 : 0;
    }
    if (Array.IndexOf(args, "--watch") >= 0) {
      File.AppendAllText(Environment.GetEnvironmentVariable("DREAM_SKIN_REAL_TRACE"), "foreground-watch\n");
      if (scenario == "start-foreground-state-replaced" ||
        scenario == "combined-closed-new-foreground-resume-saved-state-replaced") {
        string statePath = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA"),
          "CodexDreamSkin", "state.json");
        File.Delete(statePath);
        File.WriteAllText(statePath, "{\"schemaVersion\":3,\"newTransaction\":true}",
          new System.Text.UTF8Encoding(false));
        File.AppendAllText(Environment.GetEnvironmentVariable("DREAM_SKIN_REAL_TRACE"),
          "foreground-state-replaced\n");
      }
      if (scenario == "combined-closed-new-foreground-resume-saved-browser-replaced") {
        File.AppendAllText(Environment.GetEnvironmentVariable("DREAM_SKIN_REAL_TRACE"),
          "foreground-browser-replaced\n");
      }
      return scenario == "start-foreground-success" ? 0 : 9;
    }
    string expectedInjector = Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_INJECTOR");
    bool realLifecycle = scenario.StartsWith("real-") || scenario.StartsWith("start-rollback-") ||
      scenario.StartsWith("resume-rollback-");
    string expectedTimeout = realLifecycle ? "30000" : "5000";
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
function Remove-DreamSkinManagedLegacyShortcuts {}
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
    'renderer-fail', 'active-exact-runtime', 'active-wrong-runtime', 'deep-active-wrong-runtime', 'mutex-hold',
    'lifecycle-install-running', 'lifecycle-install-timeout', 'lifecycle-apply',
    'lifecycle-apply-timeout', 'lifecycle-pause', 'pause-remove-fail', 'resume-hot', 'resume-cold-paused',
    'lifecycle-resume', 'lifecycle-resume-timeout', 'lifecycle-restore',
    'lifecycle-restore-timeout', 'restore-fail', 'stale-restore-fail', 'lifecycle-verify', 'verify-fail',
    'lifecycle-uninstall', 'lifecycle-uninstall-timeout', 'uninstall-fail', 'running-missing-config',
    'missing-config-restore-running-unauthorized', 'missing-config-restore-running-authorized',
    'missing-config-uninstall-running-unauthorized', 'missing-config-uninstall-running-authorized'
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
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-existing-fail') {
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-existing-identity-replaced') {
    Add-RealLifecycleTrace 'cdp'
    if ((Test-Path -LiteralPath $env:DREAM_SKIN_REAL_TRACE -PathType Leaf) -and
      [IO.File]::ReadAllText($env:DREAM_SKIN_REAL_TRACE).Contains('foreground-watch')) {
      return [pscustomobject]@{ BrowserId = 'browser-other' }
    }
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq
    'combined-closed-new-foreground-resume-saved-browser-replaced') {
    if (-not $script:DreamSkinCdpLaunched) { return $null }
    Add-RealLifecycleTrace 'cdp'
    if ((Test-Path -LiteralPath $env:DREAM_SKIN_REAL_TRACE -PathType Leaf) -and
      [IO.File]::ReadAllText($env:DREAM_SKIN_REAL_TRACE).Contains('foreground-browser-replaced')) {
      return [pscustomobject]@{ BrowserId = 'browser-other' }
    }
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'start-foreground-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-foreground-*') {
    if (-not $script:DreamSkinCdpLaunched) { return $null }
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'browser-mismatch') { return [pscustomobject]@{ BrowserId = 'browser-other' } }
  if ($env:DREAM_SKIN_TEST_SCENARIO -in @(
    'renderer-pass', 'renderer-fail', 'active-exact-runtime', 'active-wrong-runtime', 'deep-active-wrong-runtime',
    'lifecycle-apply', 'lifecycle-pause', 'pause-remove-fail',
    'resume-hot', 'lifecycle-resume', 'lifecycle-verify', 'verify-fail'
  )) { return [pscustomobject]@{ BrowserId = 'browser-123' } }
  return $null
}
function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22, [string]$NodePath, [string]$ExpectedVersion)
  if ($env:DREAM_SKIN_TEST_RUNTIME_TRACE) {
    [IO.File]::AppendAllText($env:DREAM_SKIN_TEST_RUNTIME_TRACE, "runtime`r`n", [Text.UTF8Encoding]::new($false))
  }
  $expected = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe'
  if (-not (Test-DreamSkinPathEqual -Left $NodePath -Right $expected) -or
    -not (Test-Path -LiteralPath $NodePath -PathType Leaf)) { throw 'Deep status did not use the fixed private runtime.' }
  $version = if ($env:DREAM_SKIN_TEST_SCENARIO -match 'wrong-runtime') {
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
$realRestoreFixturePath = Join-Path $realScripts 'restore-dream-skin.ps1'
$realRestoreFixture = [IO.File]::ReadAllText($realRestoreFixturePath)
$managedStateProofToken = '      Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $stateArtifactSnapshot'
if (-not $realRestoreFixture.Contains($managedStateProofToken)) {
  throw 'schema-4 state race fixture could not locate the pre-mutation state proof.'
}
$realRestoreFixture = $realRestoreFixture.Replace($managedStateProofToken, @'
      Invoke-DreamSkinManagedStateRace -Phase 'before-proof'
      Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $stateArtifactSnapshot
      Invoke-DreamSkinManagedStateRace -Phase 'post-proof'
'@.TrimEnd())
$managedStateGuardToken = '      $statePathGuard = [DreamSkinConfigNative]::HoldMissingPath($StatePath)'
if (-not $realRestoreFixture.Contains($managedStateGuardToken)) {
  throw 'schema-4 state race fixture could not locate the post-delete path guard.'
}
$realRestoreFixture = $realRestoreFixture.Replace($managedStateGuardToken, @'
      $statePathGuard = [DreamSkinConfigNative]::HoldMissingPath($StatePath)
      Invoke-DreamSkinManagedStateRace -Phase 'post-delete'
'@.TrimEnd())
$transitionBeforeSnapshotToken = '  $registeredCodexInstalls = @(Get-DreamSkinRegisteredCodexInstalls)'
if (-not $realRestoreFixture.Contains($transitionBeforeSnapshotToken)) {
  throw 'state transition fixture could not locate the pre-snapshot boundary.'
}
$realRestoreFixture = $realRestoreFixture.Replace($transitionBeforeSnapshotToken, @'
  Invoke-DreamSkinStateTransitionRace -Phase 'before-snapshot'
  $registeredCodexInstalls = @(Get-DreamSkinRegisteredCodexInstalls)
'@.TrimEnd())
$transitionAfterSnapshotToken = '  $configBeforeRestoreSnapshot = $null'
if (-not $realRestoreFixture.Contains($transitionAfterSnapshotToken)) {
  throw 'state transition fixture could not locate the post-snapshot boundary.'
}
$realRestoreFixture = $realRestoreFixture.Replace($transitionAfterSnapshotToken, @'
  Invoke-DreamSkinStateTransitionRace -Phase 'after-snapshot'
  $configBeforeRestoreSnapshot = $null
'@.TrimEnd())
$transitionRollbackToken = '    if (-not $transactionCommitted) {'
if (-not $realRestoreFixture.Contains($transitionRollbackToken)) {
  throw 'state transition fixture could not locate the artifact rollback boundary.'
}
$realRestoreFixture = $realRestoreFixture.Replace($transitionRollbackToken, @'
    Invoke-DreamSkinStateTransitionRace -Phase 'during-rollback'
    if (-not $transactionCommitted) {
'@.TrimEnd())
$stateQuarantineToken = '      $damagedStatePathGuard = [DreamSkinConfigNative]::HoldMissingPath($StatePath)'
if (-not $realRestoreFixture.Contains($stateQuarantineToken)) {
  throw 'damaged-state race fixture could not locate the post-quarantine guard.'
}
$realRestoreFixture = $realRestoreFixture.Replace($stateQuarantineToken, @'
      $damagedStatePathGuard = [DreamSkinConfigNative]::HoldMissingPath($StatePath)
      Invoke-DreamSkinStateRace -Phase 'post-proof'
'@.TrimEnd())
$stateArchiveToken = '      $quarantinedStatePath = Archive-DreamSkinStateFile -Path $StatePath `'
if (-not $realRestoreFixture.Contains($stateArchiveToken)) {
  throw 'damaged-state race fixture could not locate the quarantine boundary.'
}
$realRestoreFixture = $realRestoreFixture.Replace($stateArchiveToken, @'
      Invoke-DreamSkinStateRace -Phase 'before-quarantine'
      $quarantinedStatePath = Archive-DreamSkinStateFile -Path $StatePath `
'@.TrimEnd())
$completeBoundaryToken = '    if ($null -ne $missingConfigGuard) { $missingConfigGuard.Complete() }'
if (-not $realRestoreFixture.Contains($completeBoundaryToken)) {
  throw 'missing-config-complete-boundary could not locate MissingPathGuard.Complete().'
}
$realRestoreFixture = $realRestoreFixture.Replace($completeBoundaryToken, @'
    Invoke-DreamSkinCompleteBoundaryFault -Phase 'before'
    if ($null -ne $missingConfigGuard) { $missingConfigGuard.Complete() }
    Invoke-DreamSkinCompleteBoundaryFault -Phase 'after'
'@.TrimEnd())
[IO.File]::WriteAllText($realRestoreFixturePath, $realRestoreFixture, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $realScripts 'injector.mjs'), '// real lifecycle injector fixture', $utf8NoBom)

$realCommonStub = @'
. $env:DREAM_SKIN_REAL_COMMON
$script:realShortcutCleanup = ${function:Remove-DreamSkinManagedLegacyShortcuts}
$script:realArchiveState = ${function:Archive-DreamSkinStateFile}
$script:realReadState = ${function:Read-DreamSkinState}
$script:realStableFileSnapshot = ${function:Get-DreamSkinStableFileSnapshot}
$script:realStrictCodexProcesses = ${function:Get-DreamSkinCodexProcessesStrict}
$script:realStrictPortListeners = ${function:Get-DreamSkinPortListenersStrict}

function Remove-DreamSkinManagedLegacyShortcuts {
  & $script:realShortcutCleanup `
    -DesktopPath (Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'desktop') `
    -StartMenuPath (Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'app data\Microsoft\Windows\Start Menu\Programs')
}

function Add-RealLifecycleTrace {
  param([string]$Value)
  [IO.File]::AppendAllText($env:DREAM_SKIN_REAL_TRACE, $Value + "`r`n", [Text.UTF8Encoding]::new($false))
}
function Get-DreamSkinStableFileSnapshot {
  param([string]$Path, [switch]$AllowMissing)
  if (($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*-state-snapshot-fail*' -or
      $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error*state-snapshot-fail*') -and
    [IO.Path]::GetFileName($Path) -ceq 'state.json') {
    Add-RealLifecycleTrace 'state-snapshot-fail'
    throw 'fixture state snapshot failure'
  }
  return & $script:realStableFileSnapshot -Path $Path -AllowMissing:$AllowMissing
}
function Get-DreamSkinCodexProcessesStrict {
  param([object]$Codex)
  $identity = if ([IO.Path]::GetFileName("$($Codex.Executable)") -ceq 'OldCodex.exe') {
    'saved'
  } else { 'current' }
  Add-RealLifecycleTrace "strict-codex:$identity"
  return & $script:realStrictCodexProcesses -Codex $Codex
}
function Get-DreamSkinPortListenersStrict {
  param([int]$Port)
  Add-RealLifecycleTrace "strict-listener:$Port"
  return & $script:realStrictPortListeners -Port $Port
}
function Invoke-DreamSkinStateTransitionRace {
  param([ValidateSet('before-snapshot', 'after-snapshot', 'during-rollback')][string]$Phase)
  $scenario = $env:DREAM_SKIN_TEST_SCENARIO
  if ($scenario -notlike 'state-transition-*') { return }
  $expectedPhase = if ($scenario -like '*-before-snapshot-*') {
    'before-snapshot'
  } elseif ($scenario -like '*-after-snapshot-*') {
    'after-snapshot'
  } else {
    'during-rollback'
  }
  if ($Phase -cne $expectedPhase) { return }
  $statePath = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\state.json'
  if (Test-Path -LiteralPath $statePath) {
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $statePath `
      -Destination (Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'initial-state.json') -Force
  }
  $codex = New-RealLifecycleCodex
  $newState = [ordered]@{
    schemaVersion = 4; platform = 'windows'; recoveryKind = 'managed-cdp'; port = 19473
    codexExe = $codex.Executable; codexPackageRoot = $codex.PackageRoot
    codexPackageFullName = $codex.PackageFullName; codexPackageFamilyName = $codex.PackageFamilyName
    codexVersion = $codex.Version; createdAt = '2026-01-01T00:00:00.0000000Z'; newAuthority = $true
  }
  [IO.File]::WriteAllText($statePath, ($newState | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  Add-RealLifecycleTrace "state-transition:$Phase"
}
function Invoke-DreamSkinManagedStateRace {
  param([ValidateSet('before-proof', 'post-proof', 'post-delete')][string]$Phase)
  $scenario = $env:DREAM_SKIN_TEST_SCENARIO
  if ($scenario -notlike 'schema4-state-race-*') { return }
  $race = if ($scenario -like '*-same-bytes-*') {
    'same-bytes'
  } elseif ($scenario -like '*-post-proof-*') {
    'post-proof'
  } elseif ($scenario -like '*-post-delete-*') {
    'post-delete'
  } elseif ($scenario -like '*-reparse-*') {
    'reparse'
  } else {
    'replacement'
  }
  $expectedPhase = switch ($race) {
    'post-proof' { 'post-proof' }
    'post-delete' { 'post-delete' }
    default { 'before-proof' }
  }
  if ($Phase -cne $expectedPhase) { return }
  $statePath = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\state.json'
  if ($Phase -cne 'post-delete') {
    $heldPath = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'classified-state.json'
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $statePath -Destination $heldPath -Force
  }
  if ($race -ceq 'same-bytes') {
    [IO.File]::WriteAllBytes($statePath, [IO.File]::ReadAllBytes($heldPath))
  } elseif ($race -ceq 'reparse') {
    $external = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'replacement-state-directory'
    [IO.Directory]::CreateDirectory($external) | Out-Null
    New-Item -ItemType Junction -Path $statePath -Target $external | Out-Null
  } else {
    $replacement = if ($Phase -ceq 'post-delete') {
      '{"schemaVersion":4,"postDeleteTransaction":true}'
    } else {
      '{"schemaVersion":4,"newTransaction":true}'
    }
    [IO.File]::WriteAllText($statePath, $replacement, [Text.UTF8Encoding]::new($false))
  }
  Add-RealLifecycleTrace "schema4-state-race:$Phase"
}
function Invoke-DreamSkinStateRace {
  param([ValidateSet('before-quarantine', 'post-proof')][string]$Phase)
  $scenario = $env:DREAM_SKIN_TEST_SCENARIO
  $statePath = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\state.json'
  if ($Phase -ceq 'before-quarantine' -and $scenario -like 'damaged-race-before-*') {
    $heldPath = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'classified-state.json'
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $statePath -Destination $heldPath -Force
    if ($scenario -like '*same-bytes*') {
      [IO.File]::WriteAllBytes($statePath, [IO.File]::ReadAllBytes($heldPath))
    } elseif ($scenario -like '*reparse*') {
      $external = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'replacement-state-directory'
      [IO.Directory]::CreateDirectory($external) | Out-Null
      New-Item -ItemType Junction -Path $statePath -Target $external | Out-Null
    } else {
      [IO.File]::WriteAllText($statePath, '{"schemaVersion":4,"replacement":true}', [Text.UTF8Encoding]::new($false))
    }
    Add-RealLifecycleTrace "state-race:$Phase"
  } elseif ($Phase -ceq 'post-proof' -and $scenario -like 'damaged-race-post-proof-*') {
    [IO.File]::WriteAllText($statePath, '{"schemaVersion":4,"postProof":true}', [Text.UTF8Encoding]::new($false))
    Add-RealLifecycleTrace "state-race:$Phase"
  }
}
function Invoke-DreamSkinCompleteBoundaryFault {
  param([ValidateSet('before', 'after')][string]$Phase)
  $scenario = $env:DREAM_SKIN_TEST_SCENARIO
  if ($scenario -notlike 'missing-config-complete-boundary-*') { return }
  $config = Join-Path $env:USERPROFILE '.codex\config.toml'
  $configDirectory = Split-Path -Parent $config
  if ($Phase -ceq 'before') {
    switch ($scenario) {
      'missing-config-complete-boundary-config' {
        [IO.File]::WriteAllText($config, 'complete-boundary config creator', [Text.UTF8Encoding]::new($false))
      }
      'missing-config-complete-boundary-parent' {
        [IO.Directory]::CreateDirectory($configDirectory) | Out-Null
      }
      'missing-config-complete-boundary-junction' {
        $external = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'complete-boundary-external'
        [IO.Directory]::CreateDirectory($external) | Out-Null
        New-Item -ItemType Junction -Path $configDirectory -Target $external | Out-Null
      }
    }
  } elseif ($scenario -ceq 'missing-config-complete-boundary-post-complete') {
    [IO.File]::WriteAllText($config, 'complete-boundary post-complete creator', [Text.UTF8Encoding]::new($false))
  }
  Add-RealLifecycleTrace "complete-boundary:$Phase"
}
function Enter-DreamSkinOperationLock {
  Add-RealLifecycleTrace 'lock-enter'
  $script:DreamSkinOperationLockEntries = 1 + [int]$script:DreamSkinOperationLockEntries
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq
    'combined-closed-new-foreground-resume-saved-lock-reentry-fail' -and
    $script:DreamSkinOperationLockEntries -eq 2) {
    Add-RealLifecycleTrace 'lock-reentry-error'
    throw 'fixture foreground operation-lock reentry failure'
  }
  return [pscustomobject]@{ Held = $true }
}
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
function New-RealOlderCodex {
  $executable = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'OldCodex.exe'
  return [pscustomobject]@{
    Executable = $executable
    PackageRoot = Split-Path -Parent $executable
    PackageFullName = 'OpenAI.Codex_1.9.0.0_x64__test'
    PackageFamilyName = 'OpenAI.Codex_test'
    Version = '1.9.0.0'
  }
}
function Get-DreamSkinRegisteredCodexInstalls {
  Add-RealLifecycleTrace 'appx-scan'
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-appx-provider-error') {
    throw 'fixture terminating Appx provider failure'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-appx-update-race') {
    $script:DreamSkinAppxScans = 1 + [int]$script:DreamSkinAppxScans
    if ($script:DreamSkinAppxScans -gt 1) { throw 'fixture Appx inventory was re-enumerated' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-older-codex') {
    return @((New-RealLifecycleCodex), (New-RealOlderCodex))
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -in @(
    'schema4-current-running', 'schema4-appx-update-race',
    'schema4-appx-distinct-current-running')) {
    return @((New-RealLifecycleCodex), (New-RealOlderCodex))
  }
  return @((New-RealLifecycleCodex))
}
function Get-DreamSkinCodexInstall { return New-RealLifecycleCodex }
function Read-DreamSkinState {
  param([string]$Path, [byte[]]$Bytes)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') {
    $codex = if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-saved-*') {
      New-RealOlderCodex
    } else { New-RealLifecycleCodex }
    return [pscustomobject]@{
      schemaVersion = 3; platform = 'windows'; port = 9335; injectorPid = 4242
      injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
      injectorPath = (Join-Path $PSScriptRoot 'injector.mjs'); nodePath = $env:DREAM_SKIN_REAL_NODE
      codexExe = $codex.Executable; codexPackageRoot = $codex.PackageRoot
      codexPackageFullName = $codex.PackageFullName; codexPackageFamilyName = $codex.PackageFamilyName
      codexVersion = $codex.Version; browserId = 'browser-123'
    }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'schema4-*') {
    $codex = if ($env:DREAM_SKIN_TEST_SCENARIO -in @(
      'schema4-current-running', 'schema4-appx-update-race',
      'schema4-appx-distinct-current-running')) {
      New-RealOlderCodex
    } else {
      New-RealLifecycleCodex
    }
    return [pscustomobject]@{
      schemaVersion = 4; platform = 'windows'; recoveryKind = 'managed-cdp'; port = 19473
      codexExe = $codex.Executable; codexPackageRoot = $codex.PackageRoot
      codexPackageFullName = $codex.PackageFullName; codexPackageFamilyName = $codex.PackageFamilyName
      codexVersion = $codex.Version
    }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'state-transition-*') {
    return & $script:realReadState -Path $Path -Bytes $Bytes
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'damaged-recovery-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'damaged-race-*') {
    return & $script:realReadState -Path $Path -Bytes $Bytes
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'real-pause*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'resume-rollback-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like '*-prior-state-fail') {
    $codex = New-RealLifecycleCodex
    return [pscustomobject]@{
      schemaVersion = 3; platform = 'windows'; port = 9335; injectorPid = 4242
      injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
      injectorPath = (Join-Path $PSScriptRoot 'injector.mjs'); nodePath = $env:DREAM_SKIN_REAL_NODE
      codexExe = $codex.Executable; codexPackageRoot = $codex.PackageRoot
      codexPackageFullName = $codex.PackageFullName
      codexPackageFamilyName = $codex.PackageFamilyName; browserId = 'browser-123'
    }
  }
  return $null
}
function Get-DreamSkinCodexStatePathCandidate { param([object]$State) return $null }
function Resolve-DreamSkinCodexInstallFromState {
  param([object]$State, [object[]]$RegisteredInstalls)
  foreach ($install in $RegisteredInstalls) {
    if ((Test-DreamSkinPathEqual -Left "$($State.codexExe)" -Right $install.Executable) -and
      "$($State.codexPackageFullName)" -ieq $install.PackageFullName -and
      "$($State.codexPackageFamilyName)" -ieq $install.PackageFamilyName) {
      return $install
    }
  }
  return $null
}
function Get-DreamSkinCodexInstallFromState {
  param([object]$State)
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') {
    if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-saved-*') { return New-RealOlderCodex }
    return New-RealLifecycleCodex
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-current-running') { return New-RealOlderCodex }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'schema4-*') { return New-RealLifecycleCodex }
  return $null
}
function Get-DreamSkinCodexProcesses {
  param([object]$Codex)
  Add-RealLifecycleTrace 'codex-process'
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') {
    $expected = if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-saved-*') {
      New-RealOlderCodex
    } else { New-RealLifecycleCodex }
    if (-not $script:DreamSkinPrelaunchCodexStopped -and
      (Test-DreamSkinPathEqual -Left $Codex.Executable -Right $expected.Executable)) {
      return @([pscustomobject]@{ ProcessId = 5152; ExecutablePath = $Codex.Executable })
    }
    return @()
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-older-codex' -and
    [IO.Path]::GetFileName("$($Codex.Executable)") -ceq 'OldCodex.exe' -and
    -not $script:DreamSkinOlderCodexStopped) {
    return @([pscustomobject]@{ ProcessId = 5252; ExecutablePath = $Codex.Executable })
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -match '^real-(?:install|start|pause)' -or
    $env:DREAM_SKIN_TEST_SCENARIO -in @(
      'real-restore-unauthorized', 'real-restore-timeout', 'real-restore-force',
      'real-restore-paused-unlink-fail', 'real-restore-archive-fail',
      'real-restore-archive-marker-publish-fail',
      'real-restore-archive-marker-unlink-fail', 'real-restore-marker-unlink-fail',
      'real-restore-backup-unlink-fail',
      'real-restore-launch-fail', 'real-restore-post-launch-write',
      'real-uninstall-force',
      'missing-config-restore-running-unauthorized', 'missing-config-restore-running-authorized',
      'missing-config-uninstall-running-unauthorized', 'missing-config-uninstall-running-authorized'
    )) {
    return @([pscustomobject]@{ ProcessId = 5151 })
  }
  return @()
}
function Stop-DreamSkinCodex {
  param([object]$Codex, [switch]$AllowForce)
  Add-RealLifecycleTrace "stop:$([bool]$AllowForce)"
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-new-fail' -and
    $script:DreamSkinCdpLaunched) {
    $script:DreamSkinCdpLaunched = $false
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') {
    $identity = if ([IO.Path]::GetFileName("$($Codex.Executable)") -ceq 'OldCodex.exe') {
      'saved'
    } else { 'current' }
    Add-RealLifecycleTrace "stop-codex:$identity"
    $script:DreamSkinPrelaunchCodexStopped = $true
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-timeout' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like '*-rollback-close-fail' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-force-fail') {
    throw 'Codex did not close within 15 seconds. Close it manually or explicitly authorize a forced restart.'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-older-codex' -and
    [IO.Path]::GetFileName("$($Codex.Executable)") -ceq 'OldCodex.exe') {
    $script:DreamSkinOlderCodexStopped = $true
  }
}
function Test-DreamSkinCodexPortOwner { param([int]$Port, [object]$Codex) return $false }
function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [object]$Codex)
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-existing-fail') {
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-existing-identity-replaced') {
    Add-RealLifecycleTrace 'cdp'
    if ((Test-Path -LiteralPath $env:DREAM_SKIN_REAL_TRACE -PathType Leaf) -and
      [IO.File]::ReadAllText($env:DREAM_SKIN_REAL_TRACE).Contains('foreground-watch')) {
      return [pscustomobject]@{ BrowserId = 'browser-other' }
    }
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq
    'combined-closed-new-foreground-resume-saved-browser-replaced') {
    if (-not $script:DreamSkinCdpLaunched) { return $null }
    Add-RealLifecycleTrace 'cdp'
    if ((Test-Path -LiteralPath $env:DREAM_SKIN_REAL_TRACE -PathType Leaf) -and
      [IO.File]::ReadAllText($env:DREAM_SKIN_REAL_TRACE).Contains('foreground-browser-replaced')) {
      return [pscustomobject]@{ BrowserId = 'browser-other' }
    }
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'start-foreground-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-foreground-*') {
    if (-not $script:DreamSkinCdpLaunched) { return $null }
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-rollback-identity-lost') {
    $script:DreamSkinRollbackIdentityCalls = 1 + [int]$script:DreamSkinRollbackIdentityCalls
    if ($script:DreamSkinRollbackIdentityCalls -le 3) {
      Add-RealLifecycleTrace 'cdp'
      return [pscustomobject]@{ BrowserId = 'browser-123' }
    }
    Add-RealLifecycleTrace 'cdp-missing'
    return $null
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-rollback-close-fail' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like '*-rollback-listener-stuck') {
    if (-not $script:DreamSkinCdpLaunched) { return $null }
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-rollback-remove-fail') {
    Add-RealLifecycleTrace 'cdp'
    return [pscustomobject]@{ BrowserId = 'browser-123' }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'real-pause*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'resume-rollback-*' -or
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
  if ($Filter -eq "Name = 'ChatGPT.exe'") {
    if ("$ErrorAction" -eq 'Stop') { Add-RealLifecycleTrace 'strict-cim-scan' }
    if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -and "$ErrorAction" -eq 'Stop') {
      $script:DreamSkinPrelaunchStrictCimScans = 1 + [int]$script:DreamSkinPrelaunchStrictCimScans
      $closedError = $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-closed-cim-error'
      $currentError = $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-current-cim-error'
      if (($closedError -and $script:DreamSkinPrelaunchStrictCimScans -eq 1) -or
        ($currentError -and $script:DreamSkinPrelaunchStrictCimScans -eq 2)) {
        Add-RealLifecycleTrace 'strict-cim-error'
        throw 'fixture pre-launch closed-session CIM enumeration failure'
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -and "$ErrorAction" -eq 'Stop') {
      $script:DreamSkinCombinedStrictCimScans = 1 + [int]$script:DreamSkinCombinedStrictCimScans
      $newError = $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-new-cim-error'
      $closedError = $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-closed-cim-error'
      if (($newError -and $script:DreamSkinCombinedStrictCimScans -eq 1) -or
        ($closedError -and $script:DreamSkinCombinedStrictCimScans -eq 2)) {
        Add-RealLifecycleTrace 'strict-cim-error'
        throw 'fixture combined cleanup CIM enumeration failure'
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq
      'combined-closed-new-foreground-resume-saved-browser-replaced' -and
      "$ErrorAction" -eq 'Stop') {
      $codex = New-RealLifecycleCodex
      return [pscustomobject]@{
        ProcessId = 5260; ExecutablePath = $codex.Executable; CommandLine = 'Codex.exe'
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-new-fail' -and
      "$ErrorAction" -eq 'Stop' -and $script:DreamSkinCdpLaunched) {
      $codex = New-RealLifecycleCodex
      return [pscustomobject]@{
        ProcessId = 5261; ExecutablePath = $codex.Executable; CommandLine = 'Codex.exe'
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-restore-cim-error' -and "$ErrorAction" -eq 'Stop') {
      throw 'fixture retained-state CIM enumeration failure'
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-restore-process-appears' -and
      "$ErrorAction" -eq 'Stop') {
      $script:DreamSkinSchema4ProcessScans = 1 + [int]$script:DreamSkinSchema4ProcessScans
      if ($script:DreamSkinSchema4ProcessScans -ge 2) {
        $codex = New-RealLifecycleCodex
        return [pscustomobject]@{
          ProcessId = 5257; ExecutablePath = $codex.Executable; CommandLine = 'Codex.exe'
        }
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -in @(
      'schema4-current-running', 'schema4-appx-distinct-current-running') -and
      "$ErrorAction" -eq 'Stop') {
      $codex = New-RealLifecycleCodex
      return [pscustomobject]@{
        ProcessId = 5258; ExecutablePath = $codex.Executable; CommandLine = 'Codex.exe'
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-cim-error' -and "$ErrorAction" -eq 'Stop') {
      Add-RealLifecycleTrace 'strict-cim-error'
      throw 'fixture CIM enumeration failure'
    }
    Add-RealLifecycleTrace 'codex-absence-scan'
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-uninspectable-codex') {
      return [pscustomobject]@{ ProcessId = 5253; ExecutablePath = $null; CommandLine = $null }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-unmatched-codex') {
      return [pscustomobject]@{
        ProcessId = 5254
        ExecutablePath = 'C:\Other\ChatGPT.exe'
        CommandLine = '"C:\Other\ChatGPT.exe"'
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-older-codex' -and
      -not $script:DreamSkinOlderCodexStopped) {
      $older = New-RealOlderCodex
      return [pscustomobject]@{ ProcessId = 5252; ExecutablePath = $older.Executable; CommandLine = 'OldCodex.exe' }
    }
    return @()
  }
  if ($Filter -eq "Name = 'powershell.exe' OR Name = 'pwsh.exe'") {
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-tray-like') {
      return [pscustomobject]@{
        ProcessId = 6161
        ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        CommandLine = "powershell.exe -File `"$PSScriptRoot\tray-dream-skin.ps1`""
      }
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-uninspectable-tray') {
      return [pscustomobject]@{ ProcessId = 6162; ExecutablePath = $null; CommandLine = $null }
    }
    return @()
  }
  if ($Filter -eq "Name = 'node.exe'") {
    Add-RealLifecycleTrace 'watcher-scan'
    $scenario = $env:DREAM_SKIN_TEST_SCENARIO
    if ($scenario -eq 'damaged-recovery-watcher-appears') {
      $script:DreamSkinDamagedWatcherScans = 1 + [int]$script:DreamSkinDamagedWatcherScans
      if ($script:DreamSkinDamagedWatcherScans -eq 1) { return @() }
      $scenario = 'damaged-recovery-matching-watcher'
    }
    if ($scenario -eq 'damaged-recovery-matching-watcher') {
      return [pscustomobject]@{
        ProcessId = 8101
        ExecutablePath = $env:DREAM_SKIN_REAL_NODE
        CommandLine = "`"$env:DREAM_SKIN_REAL_NODE`" `"$PSScriptRoot\injector.mjs`" --watch --port 9335 --browser-id browser-123"
      }
    }
    if ($scenario -eq 'damaged-recovery-mismatched-watcher') {
      return [pscustomobject]@{
        ProcessId = 8102
        ExecutablePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe'
        CommandLine = '"C:\Other\node.exe" "C:\Other\foreign.mjs" --watch'
      }
    }
    if ($scenario -eq 'damaged-recovery-uninspectable-watcher') {
      return [pscustomobject]@{ ProcessId = 8103; ExecutablePath = $null; CommandLine = $null }
    }
    if ($scenario -eq 'damaged-recovery-versioned-watcher') {
      $oldNode = Join-Path $env:LOCALAPPDATA `
        'Programs\CodexDreamSkinStudio\versions\1.2.0\engine\runtime\node.exe'
      return [pscustomobject]@{
        ProcessId = 8104
        ExecutablePath = $oldNode
        CommandLine = "`"$oldNode`" `"C:\Other\foreign.mjs`" --watch"
      }
    }
    if ($scenario -eq 'damaged-recovery-historical-watcher') {
      $historicalInjector = Join-Path $env:DREAM_SKIN_REAL_CASE_ROOT 'checkout\windows\scripts\injector.mjs'
      return [pscustomobject]@{
        ProcessId = 8105
        ExecutablePath = 'C:\Tools\node.exe'
        CommandLine = "`"C:\Tools\node.exe`" `"$historicalInjector`" --watch"
      }
    }
    return @()
  }
  if ($Filter -eq "ProcessId = $PID") {
    return [pscustomobject]@{ ProcessId = $PID; ParentProcessId = [int]$env:DREAM_SKIN_REAL_PARENT_PID }
  }
  if ($Filter -match 'ProcessId = 4242') {
    if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') {
      if ("$ErrorAction" -eq 'Stop') {
        Add-RealLifecycleTrace 'recorded-injector-cim-provider-error'
        throw 'fixture recorded injector CIM provider failure'
      }
      Add-RealLifecycleTrace 'recorded-injector-cim-provider-suppressed'
      return $null
    }
    Add-RealLifecycleTrace 'injector-identity'
    return [pscustomobject]@{ ProcessId = 4242; ExecutablePath = $env:DREAM_SKIN_REAL_NODE; CommandLine = 'fixture' }
  }
  return @()
}
if ($env:DREAM_SKIN_TEST_SCENARIO -notlike 'prior-watcher-provider-error-*') {
  function Stop-DreamSkinRecordedInjector {
    param([object]$State)
    Add-RealLifecycleTrace 'watcher-stop'
    if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-prior-state-fail*') {
      throw 'fixture prior state validation failure'
    }
    return $true
  }
}
function Get-DreamSkinProcessExecutablePath { param([object]$ProcessInfo) return "$($ProcessInfo.ExecutablePath)" }
function Test-DreamSkinPortAvailable {
  param([int]$Port)
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -or
    (($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -or
        $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') -and
      $env:DREAM_SKIN_TEST_SCENARIO -like '*-state-*-fail*')) {
    Add-RealLifecycleTrace "port-unavailable:$Port"
    return $false
  }
  return $env:DREAM_SKIN_TEST_SCENARIO -ne 'damaged-recovery-residual-listener'
}
function Get-NetTCPConnection {
  param([string]$State, [int]$LocalPort, [object]$ErrorAction)
  Add-RealLifecycleTrace 'listener-scan'
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -and "$ErrorAction" -eq 'Stop') {
    $script:DreamSkinCombinedStrictTcpScans = 1 + [int]$script:DreamSkinCombinedStrictTcpScans
    $newError = $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-new-tcp-error'
    $closedError = $env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-closed-tcp-error'
    if (($newError -and $script:DreamSkinCombinedStrictTcpScans -eq 1) -or
      ($closedError -and $script:DreamSkinCombinedStrictTcpScans -eq 2)) {
      Add-RealLifecycleTrace 'strict-tcp-error'
      throw 'fixture combined cleanup TCP enumeration failure'
    }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq
    'combined-closed-new-foreground-resume-saved-browser-replaced' -and
    "$ErrorAction" -eq 'Stop') {
    return [pscustomobject]@{
      LocalAddress = '127.0.0.1'; LocalPort = 19473; OwningProcess = 5260
    }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'start-foreground-new-fail' -and
    "$ErrorAction" -eq 'Stop' -and $script:DreamSkinCdpLaunched) {
    return [pscustomobject]@{
      LocalAddress = '127.0.0.1'; LocalPort = 19473; OwningProcess = 5261
    }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-cleanup-tcp-error' -and "$ErrorAction" -eq 'Stop') {
    Add-RealLifecycleTrace 'strict-tcp-error'
    throw 'fixture TCP enumeration failure'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-restore-tcp-error' -and "$ErrorAction" -eq 'Stop') {
    throw 'fixture retained-state TCP enumeration failure'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'schema4-restore-listener-appears' -and
    "$ErrorAction" -eq 'Stop') {
    $script:DreamSkinSchema4ListenerScans = 1 + [int]$script:DreamSkinSchema4ListenerScans
    if ($script:DreamSkinSchema4ListenerScans -ge 2) {
      return [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 19473; OwningProcess = 5259 }
    }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-listener-probe-fail') {
    throw 'fixture listener enumeration failure'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'damaged-recovery-residual-listener') {
    return [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9335; OwningProcess = 5255 }
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-rollback-listener-stuck') {
    return [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 9335; OwningProcess = 5256 }
  }
  return @()
}
function Wait-DreamSkinPortAvailable {
  param([int]$Port, [int]$TimeoutSeconds)
  Add-RealLifecycleTrace 'wait-port'
  return $env:DREAM_SKIN_TEST_SCENARIO -notlike '*-rollback-listener-stuck'
}
function Select-DreamSkinPort {
  param([int]$PreferredPort)
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'combined-closed-new-*' -or
    $env:DREAM_SKIN_TEST_SCENARIO -like 'prior-watcher-provider-error-*') {
    Add-RealLifecycleTrace 'port-selected:19473'
    return 19473
  }
  return $PreferredPort
}
function Confirm-DreamSkinRestart { param([string]$Message) return $true }
function Get-Date {
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-early-wait-*') {
    $script:DreamSkinFakeClock = 1 + [int]$script:DreamSkinFakeClock
    return ([datetime]'2026-01-01T00:00:00Z').AddSeconds(60 * $script:DreamSkinFakeClock)
  }
  return Microsoft.PowerShell.Utility\Get-Date
}
function Start-Sleep {
  param([int]$Milliseconds)
  if ($env:DREAM_SKIN_TEST_SCENARIO -like '*-early-wait-*') { return }
  Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
}
function ConvertTo-DreamSkinProcessArgument { param([string]$Value) return $Value }
function Get-DreamSkinProcessStartedAt { param([int]$ProcessId) return '2026-01-01T00:00:00.0000000Z' }
function Write-DreamSkinState {
  param([string]$Path, [object]$State)
  Add-RealLifecycleTrace 'state-write'
  Add-RealLifecycleTrace "state-write:$($State.schemaVersion):$($State.port):$($State.recoveryKind)"
  if ($env:DREAM_SKIN_TEST_SCENARIO -like 'prelaunch-closed-*-state-write-fail*') {
    throw 'fixture state publication failure'
  }
  [IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
function Archive-DreamSkinStateFile {
  param([string]$Path, [object]$ExpectedSnapshot)
  Add-RealLifecycleTrace 'state-archive'
  if ($PSBoundParameters.ContainsKey('ExpectedSnapshot')) {
    return & $script:realArchiveState -Path $Path -ExpectedSnapshot $ExpectedSnapshot
  }
  return & $script:realArchiveState -Path $Path
}
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
  param([string]$Path, [byte[]]$Bytes, [byte[]]$ExpectedBytes, [object]$ExpectedSnapshot)
  if ([IO.Path]::GetFileName($Path) -ceq 'config.restored.toml') {
    Add-RealLifecycleTrace 'archive-backup'
    if ($env:DREAM_SKIN_TEST_SCENARIO -like 'state-transition-*-during-rollback-*') {
      throw 'fixture transition rollback failure'
    }
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-archive-fail') { throw 'fixture archive failure' }
  } elseif ([IO.Path]::GetFileName($Path) -ceq 'config.restored.toml.appearance.json') {
    Add-RealLifecycleTrace 'archive-marker'
    if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-archive-marker-publish-fail' -and
      -not $script:DreamSkinArchiveMarkerPublishFailed) {
      $script:DreamSkinArchiveMarkerPublishFailed = $true
      throw 'fixture archive marker publication failure'
    }
  } elseif ([IO.Path]::GetFileName($Path) -ceq 'config.toml') {
    Add-RealLifecycleTrace 'config-rollback'
  }
  [IO.File]::WriteAllBytes($Path, $Bytes)
}
function Start-Process {
  param([string]$FilePath, [object]$ArgumentList, [object]$WindowStyle, [switch]$PassThru,
    [string]$RedirectStandardOutput, [string]$RedirectStandardError)
  Add-RealLifecycleTrace 'start-process'
  if (Test-DreamSkinPathEqual -Left $FilePath -Right $env:DREAM_SKIN_REAL_NODE) {
    Add-RealLifecycleTrace 'start-watcher'
  } elseif ($null -ne $ArgumentList) {
    $script:DreamSkinCdpLaunched = $true
    Add-RealLifecycleTrace 'start-cdp'
  } else {
    Add-RealLifecycleTrace 'start-official'
    $identity = if ([IO.Path]::GetFileName($FilePath) -ceq 'OldCodex.exe') { 'saved' } else { 'current' }
    Add-RealLifecycleTrace "start-official:$identity"
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-launch-fail') { throw 'fixture relaunch failure' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-post-launch-write') {
    [IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.codex\config.toml'), 'post-launch', [Text.UTF8Encoding]::new($false))
  }
  return [pscustomobject]@{ Id = 7000; HasExited = $false }
}
function Stop-Process { param([object]$InputObject, [int]$Id, [switch]$Force, [object]$ErrorAction) Add-RealLifecycleTrace 'stop-process' }
function Move-Item {
  param([string]$LiteralPath, [string]$Destination, [switch]$Force, [object]$ErrorAction)
  Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination `
    -Force:$Force -ErrorAction $ErrorAction
}
function Remove-Item {
  param([string]$LiteralPath, [switch]$Force, [switch]$Recurse, [object]$ErrorAction)
  Add-RealLifecycleTrace "remove:$LiteralPath"
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-paused-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'paused') { throw 'fixture paused unlink failure' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-marker-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'config.before-dream-skin.toml.appearance.json') {
    throw 'fixture backup marker unlink failure'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-backup-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'config.before-dream-skin.toml') {
    throw 'fixture live backup unlink failure'
  }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'real-restore-archive-marker-unlink-fail' -and
    [IO.Path]::GetFileName($LiteralPath) -ceq 'config.restored.toml.appearance.json') {
    throw 'fixture archive marker unlink failure'
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
function Test-DreamSkinPaused {
  param([string]$StateRoot)
  return Test-Path -LiteralPath (Join-Path $StateRoot 'paused') -PathType Leaf
}
function Set-DreamSkinPaused {
  param([bool]$Paused, [string]$StateRoot)
  Add-RealThemeTrace 'marker'
  Add-RealThemeTrace "pause-write:$Paused"
  $path = Join-Path $StateRoot 'paused'
  if ($Paused) {
    [IO.File]::WriteAllText($path, 'paused', [Text.UTF8Encoding]::new($false))
  } else {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
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
  $desktop = Join-Path $caseRoot 'desktop'
  $startMenu = Join-Path $appData 'Microsoft\Windows\Start Menu\Programs'
  New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $userProfile '.codex') -Force | Out-Null
  New-Item -ItemType Directory -Path $appData, $desktop, $startMenu -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $userProfile '.codex\config.toml'), 'original', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'config.before-dream-skin.toml'), 'backup', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'config.before-dream-skin.toml.appearance.json'),
    '{"schemaVersion":1,"appearanceThemeManaged":false}', $utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $stateRoot 'state.json'), 'preserve-state', $utf8NoBom)
  $codexExecutable = Join-Path $caseRoot 'Codex.exe'
  [IO.File]::WriteAllText($codexExecutable, 'fixture executable', $utf8NoBom)
  $managedShortcutPath = $null
  $unrelatedShortcutPath = $null
  if ($Name -like 'uninstall-*') {
    $managedShortcutPath = Join-Path $desktop 'Codex Dream Skin.lnk'
    $unrelatedShortcutPath = Join-Path $desktop 'Codex Dream Skin - Restore.lnk'
    $managedScript = Join-Path $localAppData `
      'Programs\CodexDreamSkinStudio\versions\fixture\engine\scripts\start-dream-skin.ps1'
    $shortcutShell = New-Object -ComObject WScript.Shell
    $shortcut = $shortcutShell.CreateShortcut($managedShortcutPath)
    $shortcut.TargetPath = (Get-Command powershell.exe -ErrorAction Stop).Source
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$managedScript`" -PromptRestart"
    $shortcut.Save()
    $unrelatedShortcut = $shortcutShell.CreateShortcut($unrelatedShortcutPath)
    $unrelatedShortcut.TargetPath = $shortcut.TargetPath
    $unrelatedShortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$caseRoot\unrelated.ps1`" -RestoreBaseTheme -PromptRestart"
    $unrelatedShortcut.Save()
  }
  return [pscustomobject]@{
    Root = $caseRoot; LocalAppData = $localAppData; StateRoot = $stateRoot; UserProfile = $userProfile
    AppData = $appData; TracePath = (Join-Path $caseRoot 'trace.txt'); CodexExecutable = $codexExecutable
    ManagedShortcutPath = $managedShortcutPath; UnrelatedShortcutPath = $unrelatedShortcutPath
  }
}

function New-RealRestoreRollbackBaseline {
  param([Parameter(Mandatory = $true)][object]$Case)
  $archive = Join-Path $Case.StateRoot 'config.restored.toml'
  [IO.File]::WriteAllText((Join-Path $Case.StateRoot 'paused'), 'paused-before', $utf8NoBom)
  [IO.File]::WriteAllText($archive, 'prior-archive', $utf8NoBom)
  [IO.File]::WriteAllText("$archive.appearance.json",
    '{"schemaVersion":1,"appearanceThemeManaged":false}', $utf8NoBom)
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

function Assert-RealMissingConfigCompletion {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$ExpectedClose
  )
  $config = Join-Path $Case.UserProfile '.codex\config.toml'
  $backup = Join-Path $Case.StateRoot 'config.before-dream-skin.toml'
  $archive = Join-Path $Case.StateRoot 'config.restored.toml'
  $state = Join-Path $Case.StateRoot 'state.json'
  if ($Result.ExitCode -ne 0 -or (Test-Path -LiteralPath $config) -or
    (Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath "$backup.appearance.json") -or
    (Test-Path -LiteralPath $state) -or -not (Test-Path -LiteralPath $archive -PathType Leaf) -or
    -not (Test-Path -LiteralPath "$archive.appearance.json" -PathType Leaf) -or
    $Result.Trace -contains 'restore-config' -or $Result.Trace -contains 'start-process' -or
    ($ExpectedClose -and $Result.Trace -notcontains 'stop:False')) {
    throw $Message
  }
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
      $null = $process.Handle
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
    $index = [Array]::IndexOf($Trace, $token, $previous + 1)
    if ($index -lt 0) {
      throw "$Message Missing or out of order: $token. Trace=$($Trace -join '|')"
    }
    $previous = $index
  }
}

function Test-StudioFixturePathEqual {
  param([string]$Left, [string]$Right)
  try {
    return [IO.Path]::GetFullPath($Left).Equals(
      [IO.Path]::GetFullPath($Right), [StringComparison]::OrdinalIgnoreCase)
  } catch {
    return $false
  }
}

function Assert-RealStartRollbackState {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][string]$Message,
    [switch]$Paused
  )
  $statePath = Join-Path $Case.StateRoot 'state.json'
  if ($Result.ExitCode -eq 0 -or -not (Test-Path -LiteralPath $statePath -PathType Leaf) -or
    $Result.Trace -notcontains 'watcher-stop' -or $Result.Trace -contains 'start-official') {
    throw $Message
  }
  try { $state = [IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop } catch {
    throw "$Message Retained state is not parseable."
  }
  $expectedInjector = Join-Path $realScripts 'injector.mjs'
  $expectedTheme = Join-Path $Case.StateRoot 'active-theme'
  $expectedPause = Join-Path $Case.StateRoot 'paused'
  if ($state.schemaVersion -ne 3 -or "$($state.platform)" -cne 'windows' -or $state.port -ne 9335 -or
    $state.injectorPid -ne 7000 -or "$($state.injectorStartedAt)" -cne '2026-01-01T00:00:00.0000000Z' -or
    -not (Test-StudioFixturePathEqual -Left "$($state.injectorPath)" -Right $expectedInjector) -or
    -not (Test-StudioFixturePathEqual -Left "$($state.nodePath)" -Right $nodePath) -or
    "$($state.nodeVersion)" -cne '22.23.1' -or
    -not (Test-StudioFixturePathEqual -Left "$($state.codexExe)" -Right $Case.CodexExecutable) -or
    -not (Test-StudioFixturePathEqual -Left "$($state.codexPackageRoot)" -Right (Split-Path -Parent $Case.CodexExecutable)) -or
    "$($state.codexPackageFullName)" -cne 'OpenAI.Codex_2.0.0.0_x64__test' -or
    "$($state.codexPackageFamilyName)" -cne 'OpenAI.Codex_test' -or "$($state.codexVersion)" -cne '2.0.0.0' -or
    "$($state.browserId)" -cne 'browser-123' -or
    -not (Test-StudioFixturePathEqual -Left "$($state.themeDir)" -Right $expectedTheme) -or
    -not (Test-StudioFixturePathEqual -Left "$($state.pauseFile)" -Right $expectedPause)) {
    throw "$Message Retained state lost its exact cleanup identity."
  }
  if ($Paused -and -not (Test-Path -LiteralPath $expectedPause -PathType Leaf)) {
    throw "$Message Resume did not restore the prior pause marker."
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
    @{ Name = 'running-missing-config'; Args = @{ NoConfig = $true; NoState = $true }; Exit = 1; Ok = $false; Codex = 'needs-first-run'; Session = 'official'; Restart = $true; Actions = @('apply', 'restore', 'uninstall'); Error = 'CODEX_FIRST_RUN_REQUIRED'; Recovery = @('open-codex', 'retry', 'cancel') },
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

  $neverAppliedStatus = New-CaseRoot -Name 'never-applied-status-actions' -NoState
  Remove-Item -LiteralPath (Join-Path $neverAppliedStatus.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $neverAppliedStatus.StateRoot 'active-theme') -Recurse -Force
  $result = Invoke-Studio -Case $neverAppliedStatus -Scenario 'stopped'
  Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'not-installed' -Codex 'stopped' `
    -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install', 'uninstall') -ErrorCode $null

  $completedStatus = New-CaseRoot -Name 'completed-recovery-status-actions' -NoState
  Move-Item -LiteralPath (Join-Path $completedStatus.StateRoot 'config.before-dream-skin.toml') `
    -Destination (Join-Path $completedStatus.StateRoot 'config.restored.toml')
  $result = Invoke-Studio -Case $completedStatus -Scenario 'stopped'
  Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'not-installed' -Codex 'stopped' `
    -Session 'official' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null

  $retainedResume = New-CaseRoot -Name 'retained-schema4-paused-status-resume'
  $retainedStatePath = Join-Path $retainedResume.StateRoot 'state.json'
  $retainedPausePath = Join-Path $retainedResume.StateRoot 'paused'
  $retainedState = [ordered]@{
    schemaVersion = 4; platform = 'windows'; recoveryKind = 'managed-cdp'; port = 19473
    codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex.Primary\app\ChatGPT.exe'
    codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex.Primary'
    codexPackageFullName = 'OpenAI.Codex_2.0.0.0_x64__test'
    codexPackageFamilyName = 'OpenAI.Codex_test'; codexVersion = '2.0.0.0'
    createdAt = '2026-01-01T00:00:00.0000000Z'
  }
  [IO.File]::WriteAllText($retainedStatePath, ($retainedState | ConvertTo-Json -Compress), $utf8NoBom)
  [IO.File]::WriteAllText($retainedPausePath, 'paused', $utf8NoBom)
  $retainedBefore = Get-ProtectedSnapshot -Case $retainedResume
  $result = Invoke-Studio -Case $retainedResume -Scenario 'active'
  Assert-StudioResult -Result $result -ExitCode 1 -Ok $false -Install 'ready' -Codex 'running' `
    -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @('restore', 'uninstall') -ErrorCode 'STATE_UNSAFE' `
    -RecoveryActions @('restore', 'diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $retainedResume) $retainedBefore `
    'Retained schema-4 status changed state or prior Resume pause intent.'
  $result = Invoke-Studio -Case $retainedResume -Scenario 'active' -Operation 'resume'
  Assert-StudioResult -Result $result -Operation 'resume' -ExitCode 1 -Ok $false -Install 'ready' `
    -Codex 'running' -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @('restore', 'uninstall') -ErrorCode 'STATE_UNSAFE' `
    -RecoveryActions @('restore', 'diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $retainedResume) $retainedBefore `
    'Rejected retained schema-4 Resume changed state or removed its pause marker.'
  Assert-NoChildOrLog -Case $retainedResume

  foreach ($malformedDefinition in @(
    @{ Name = 'malformed-regular-backup'; Marker = $false },
    @{ Name = 'malformed-regular-marker'; Marker = $true }
  )) {
    $malformed = New-CaseRoot -Name $malformedDefinition.Name -NoState
    $malformedBackup = Join-Path $malformed.StateRoot 'config.before-dream-skin.toml'
    if ($malformedDefinition.Marker) {
      [IO.File]::WriteAllText("$malformedBackup.appearance.json", '{}', $utf8NoBom)
    } else {
      [IO.File]::WriteAllBytes($malformedBackup, [byte[]](0x66, 0x6f, 0x80))
    }
    $before = Get-ProtectedSnapshot -Case $malformed
    $result = Invoke-Studio -Case $malformed -Scenario 'stopped'
    Assert-StudioResult -Result $result -ExitCode 1 -Ok $false -Install 'not-installed' `
      -Codex 'stopped' -Session 'stale' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
      -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
    Assert-Equal (Get-ProtectedSnapshot -Case $malformed) $before `
      "Malformed recovery evidence changed protected bytes for $($malformedDefinition.Name)."
    Assert-NoChildOrLog -Case $malformed
  }

  $orphanArchiveMarker = New-CaseRoot -Name 'orphan-archive-marker' -NoState
  Remove-Item -LiteralPath (Join-Path $orphanArchiveMarker.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $orphanArchiveMarker.StateRoot 'active-theme') -Recurse -Force
  $orphanArchive = Join-Path $orphanArchiveMarker.StateRoot 'config.restored.toml'
  [IO.File]::WriteAllText("$orphanArchive.appearance.json", '{}', $utf8NoBom)
  $before = Get-ProtectedSnapshot -Case $orphanArchiveMarker
  $result = Invoke-Studio -Case $orphanArchiveMarker -Scenario 'stopped'
  Assert-StudioResult -Result $result -ExitCode 1 -Ok $false -Install 'not-installed' `
    -Codex 'stopped' -Session 'stale' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @() -ErrorCode 'STATE_UNSAFE' -RecoveryActions @('diagnostics', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $orphanArchiveMarker) $before `
    'Orphan archive marker status changed protected bytes.'
  Assert-NoChildOrLog -Case $orphanArchiveMarker

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

  $deepFreshWrongRuntime = New-CaseRoot -Name 'deep-fresh-wrong-runtime' -NoState
  Remove-Item -LiteralPath (Join-Path $deepFreshWrongRuntime.StateRoot 'config.before-dream-skin.toml') -Force
  Remove-Item -LiteralPath (Join-Path $deepFreshWrongRuntime.StateRoot 'active-theme') -Recurse -Force
  $deepOfficialWrongRuntime = New-CaseRoot -Name 'deep-official-wrong-runtime' -NoState
  $deepPausedWrongRuntime = New-CaseRoot -Name 'deep-paused-wrong-runtime' -NoState
  [IO.File]::WriteAllText((Join-Path $deepPausedWrongRuntime.StateRoot 'paused'), "paused`r`n", $utf8NoBom)
  $deepActiveWrongRuntime = New-CaseRoot -Name 'deep-active-wrong-runtime'
  foreach ($definition in @(
    @{ Case = $deepFreshWrongRuntime; Scenario = 'deep-fresh-wrong-runtime'; Operation = 'preflight'; Session = 'official' },
    @{ Case = $deepOfficialWrongRuntime; Scenario = 'deep-official-wrong-runtime'; Operation = 'status'; Session = 'official' },
    @{ Case = $deepPausedWrongRuntime; Scenario = 'deep-paused-wrong-runtime'; Operation = 'status'; Session = 'paused' },
    @{ Case = $deepActiveWrongRuntime; Scenario = 'deep-active-wrong-runtime'; Operation = 'status'; Session = 'active' }
  )) {
    $before = Get-StateSnapshot -Root $definition.Case.StateRoot
    $result = Invoke-Studio -Case $definition.Case -Scenario $definition.Scenario `
      -Operation $definition.Operation -ExtraArguments @('-Deep')
    Assert-Equal (Get-StateSnapshot -Root $definition.Case.StateRoot) $before `
      "$($definition.Scenario) mutated protected state."
    if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'RUNTIME_INVALID' -or
      $result.Envelope.state.session -cne $definition.Session -or
      -not (Test-Path -LiteralPath (Join-Path $definition.Case.Root 'runtime-trace.txt') -PathType Leaf)) {
      throw "$($definition.Scenario) did not validate exact private Node during deep status."
    }
  }

  $deepMissingRuntime = New-CaseRoot -Name 'deep-missing-runtime' -NoState
  $restoreMissingRuntime = New-CaseRoot -Name 'restore-missing-runtime' -NoState
  $uninstallMissingRuntime = New-CaseRoot -Name 'uninstall-missing-runtime' -NoState
  $nodeMissingBackup = "$nodePath.deep-missing"
  Move-Item -LiteralPath $nodePath -Destination $nodeMissingBackup
  try {
    $result = Invoke-Studio -Case $deepMissingRuntime -Scenario 'deep-missing-runtime' -ExtraArguments @('-Deep')
    if ($result.ExitCode -ne 1 -or $result.Envelope.error.code -cne 'RUNTIME_INVALID' -or
      -not (Test-Path -LiteralPath (Join-Path $deepMissingRuntime.Root 'runtime-trace.txt') -PathType Leaf)) {
      throw 'Deep status did not reject a missing private runtime.'
    }

    $result = Invoke-Studio -Case $restoreMissingRuntime -Scenario 'restore-missing-runtime' -Operation 'restore'
    if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath (Join-Path $restoreMissingRuntime.Root 'runtime-trace.txt'))) {
      throw 'Restore probed or required the missing private runtime.'
    }
    Assert-ChildInvocation -Case $restoreMissingRuntime `
      -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-AdapterLockHeld'

    $result = Invoke-Studio -Case $uninstallMissingRuntime -Scenario 'uninstall-missing-runtime' -Operation 'uninstall'
    if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath (Join-Path $uninstallMissingRuntime.Root 'runtime-trace.txt'))) {
      throw 'Uninstall probed or required the missing private runtime.'
    }
    Assert-ChildInvocation -Case $uninstallMissingRuntime `
      -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-AdapterLockHeld'
  } finally {
    Move-Item -LiteralPath $nodeMissingBackup -Destination $nodePath
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
    [Text.Encoding]::UTF8.GetBytes('1.3.1'),
    [Text.Encoding]::UTF8.GetBytes("1.3.1`n"),
    [Text.Encoding]::UTF8.GetBytes("1.3.1`r`n"),
    [byte[]]($bom + [Text.Encoding]::UTF8.GetBytes('1.3.1'))
  )) {
    [IO.File]::WriteAllBytes($versionPath, $validVersion)
    $before = Get-StateSnapshot -Root $versionCase.StateRoot
    $result = Invoke-Studio -Case $versionCase -Scenario 'stopped'
    Assert-Equal (Get-StateSnapshot -Root $versionCase.StateRoot) $before 'Valid VERSION status mutated state.'
    Assert-StudioResult -Result $result -ExitCode 0 -Ok $true -Install 'ready' -Codex 'stopped' -Session 'official' `
      -ThemeName '午夜极光' -RequiresRestart $false -Verified $null -AvailableActions @('apply', 'restore', 'uninstall') -ErrorCode $null
  }
  foreach ($invalidVersion in @(
    [Text.Encoding]::UTF8.GetBytes(' 1.3.1'),
    [Text.Encoding]::UTF8.GetBytes("1.3.1`n`n"),
    [byte[]](0x31, 0x2E, 0x33, 0x2E, 0x31, 0xFF)
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
  [IO.File]::WriteAllText($versionPath, '1.3.1', $utf8NoBom)

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
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $lockSignal -PathType Leaf)) {
    Start-Sleep -Milliseconds 25
  }
  if (-not (Test-Path -LiteralPath $lockSignal -PathType Leaf)) {
    $timedOutLockOwner = Complete-StudioProcess -Invocation $lockInvocation
    throw "Lifecycle child did not enter while the adapter held the operation lock. Exit=$($timedOutLockOwner.ExitCode); Raw=$($timedOutLockOwner.Raw)"
  }
  $lockRelease = Join-Path $lockOwner.Root 'probe-release'
  try {
    $contenderResult = Invoke-Studio -Case $lockContender -Scenario 'stopped' -Operation 'install'
    Assert-StudioResult -Result $contenderResult -Operation 'install' -ExitCode 1 -Ok $false `
      -Install 'not-installed' -Codex 'not-installed' -Session 'official' -OperationState 'busy' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() `
      -ErrorCode 'OPERATION_BUSY' -RecoveryActions @('retry', 'cancel')
    Assert-NoChildOrLog -Case $lockContender
  } finally {
    [IO.File]::WriteAllText($lockRelease, 'release', $utf8NoBom)
    $lockOwnerResult = Complete-StudioProcess -Invocation $lockInvocation
  }
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
    -Codex 'running' -Session 'active' -ThemeName '午夜极光' -RequiresRestart $true -Verified $null `
    -AvailableActions @('pause', 'resume', 'restore', 'verify', 'uninstall') -ErrorCode 'RESTART_REQUIRED' `
    -RecoveryActions @('authorize-restart', 'cancel')
  Assert-NoChildOrLog -Case $wrongRuntimeRestoreUnauthorized

  $wrongRuntimeRestore = New-CaseRoot -Name 'wrong-runtime-restore'
  $result = Invoke-Studio -Case $wrongRuntimeRestore -Scenario 'active-wrong-runtime' -Operation 'restore' `
    -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.session -cne 'official') {
    throw 'Authorized Node-free restore was blocked by private Node validation.'
  }
  if (Test-Path -LiteralPath (Join-Path $wrongRuntimeRestore.Root 'runtime-trace.txt')) {
    throw 'Node-free restore still probed the private runtime.'
  }
  Assert-ChildInvocation -Case $wrongRuntimeRestore `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-CloseRunning|-AdapterLockHeld'

  $missingCodexRestore = New-CaseRoot -Name 'missing-codex-restore' -NoState
  $result = Invoke-Studio -Case $missingCodexRestore -Scenario 'missing-codex' -Operation 'restore'
  Assert-StudioResult -Result $result -Operation 'restore' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'not-installed' -Session 'official' -ThemeName '午夜极光' -RequiresRestart $false -Verified $null `
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null
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

  $missingConfigRestoreStopped = New-CaseRoot -Name 'missing-config-restore-stopped-first' `
    -NoConfig -NoState
  $missingConfigPath = Join-Path $missingConfigRestoreStopped.UserProfile '.codex\config.toml'
  $result = Invoke-Studio -Case $missingConfigRestoreStopped -Scenario 'stopped' -Operation 'restore'
  if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $missingConfigPath) -or
    -not (Test-Path -LiteralPath (Join-Path $missingConfigRestoreStopped.StateRoot 'config.restored.toml') -PathType Leaf)) {
    throw 'missing-config-restore-stopped-first did not complete without creating config.'
  }
  Assert-ChildInvocation -Case $missingConfigRestoreStopped `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-AdapterLockHeld'
  $restoreInvocationCount = @([IO.File]::ReadAllLines($missingConfigRestoreStopped.ArgvPath)).Count
  $result = Invoke-Studio -Case $missingConfigRestoreStopped `
    -Scenario 'missing-config-restore-stopped-retry' -Operation 'restore'
  if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $missingConfigPath) -or
    @([IO.File]::ReadAllLines($missingConfigRestoreStopped.ArgvPath)).Count -ne ($restoreInvocationCount + 1)) {
    throw 'missing-config-restore-stopped-retry was not idempotent.'
  }

  $missingConfigRestoreUnauthorized = New-CaseRoot `
    -Name 'missing-config-restore-running-unauthorized' -NoConfig -NoState
  $before = Get-ProtectedSnapshot -Case $missingConfigRestoreUnauthorized
  $result = Invoke-Studio -Case $missingConfigRestoreUnauthorized `
    -Scenario 'missing-config-restore-running-unauthorized' -Operation 'restore'
  Assert-StudioResult -Result $result -Operation 'restore' -ExitCode 1 -Ok $false -Install 'ready' `
    -Codex 'needs-first-run' -Session 'official' -ThemeName '午夜极光' -RequiresRestart $true -Verified $null `
    -AvailableActions @('apply', 'restore', 'uninstall') -ErrorCode 'RESTART_REQUIRED' `
    -RecoveryActions @('authorize-restart', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $missingConfigRestoreUnauthorized) $before `
    'missing-config-restore-running-unauthorized changed protected state.'
  Assert-NoChildOrLog -Case $missingConfigRestoreUnauthorized

  $missingConfigRestoreAuthorized = New-CaseRoot `
    -Name 'missing-config-restore-running-authorized' -NoConfig -NoState
  $missingConfigPath = Join-Path $missingConfigRestoreAuthorized.UserProfile '.codex\config.toml'
  $result = Invoke-Studio -Case $missingConfigRestoreAuthorized `
    -Scenario 'missing-config-restore-running-authorized' -Operation 'restore' `
    -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $missingConfigPath)) {
    throw 'missing-config-restore-running-authorized failed or created config.'
  }
  Assert-ChildInvocation -Case $missingConfigRestoreAuthorized `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-CloseRunning|-AdapterLockHeld'

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

  $damagedRestoreDispatch = New-CaseRoot -Name 'damaged-recovery-restore-absent' -DamagedState
  $result = Invoke-Studio -Case $damagedRestoreDispatch -Scenario 'damaged-recovery-restore-absent' `
    -Operation 'restore'
  if ($result.ExitCode -ne 0 -or $result.Envelope.state.session -cne 'official') {
    throw 'Adapter did not dispatch malformed-state Restore recovery.'
  }
  Assert-ChildInvocation -Case $damagedRestoreDispatch `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-RecoverDamagedState|-AdapterLockHeld'

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
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null
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
  $configBefore = (Get-FileHash -LiteralPath (Join-Path $neverApplied.UserProfile '.codex\config.toml') -Algorithm SHA256).Hash
  foreach ($attempt in 1..2) {
    $result = Invoke-Studio -Case $neverApplied -Scenario 'stopped' -Operation 'uninstall'
    Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
      -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
      -AvailableActions @('install', 'uninstall') -ErrorCode $null
  }
  Assert-Equal (Get-ProtectedSnapshot -Case $neverApplied) $before 'Never-applied uninstall changed retained theme state.'
  if ((Get-FileHash -LiteralPath (Join-Path $neverApplied.UserProfile '.codex\config.toml') -Algorithm SHA256).Hash -cne $configBefore) {
    throw 'Repeated never-applied uninstall reran config restore.'
  }
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
  $configBefore = (Get-FileHash -LiteralPath (Join-Path $alreadyRestored.UserProfile '.codex\config.toml') -Algorithm SHA256).Hash
  foreach ($attempt in 1..2) {
    $result = Invoke-Studio -Case $alreadyRestored -Scenario 'stopped' -Operation 'uninstall'
    if ($result.ExitCode -ne 0 -or -not $result.Envelope.ok) { throw 'Repeated already-restored uninstall failed.' }
  }
  Assert-Equal (Get-ProtectedSnapshot -Case $alreadyRestored) $before 'Repeated uninstall changed restored state.'
  if ((Get-FileHash -LiteralPath (Join-Path $alreadyRestored.UserProfile '.codex\config.toml') -Algorithm SHA256).Hash -cne $configBefore) {
    throw 'Repeated already-restored uninstall reran config restore.'
  }
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

  $missingConfigUninstallStopped = New-CaseRoot -Name 'missing-config-uninstall-stopped-first' `
    -NoConfig -NoState
  $missingConfigPath = Join-Path $missingConfigUninstallStopped.UserProfile '.codex\config.toml'
  $result = Invoke-Studio -Case $missingConfigUninstallStopped -Scenario 'stopped' -Operation 'uninstall'
  if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $missingConfigPath) -or
    -not (Test-Path -LiteralPath (Join-Path $missingConfigUninstallStopped.StateRoot 'config.restored.toml') -PathType Leaf)) {
    throw 'missing-config-uninstall-stopped-first did not complete without creating config.'
  }
  Assert-ChildInvocation -Case $missingConfigUninstallStopped `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-AdapterLockHeld'
  $uninstallInvocationCount = @([IO.File]::ReadAllLines($missingConfigUninstallStopped.ArgvPath)).Count
  $result = Invoke-Studio -Case $missingConfigUninstallStopped `
    -Scenario 'missing-config-uninstall-stopped-retry' -Operation 'uninstall'
  if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $missingConfigPath) -or
    @([IO.File]::ReadAllLines($missingConfigUninstallStopped.ArgvPath)).Count -ne $uninstallInvocationCount) {
    throw 'missing-config-uninstall-stopped-retry reran config restore or created config.'
  }

  $missingConfigUninstallUnauthorized = New-CaseRoot `
    -Name 'missing-config-uninstall-running-unauthorized' -NoConfig -NoState
  $before = Get-ProtectedSnapshot -Case $missingConfigUninstallUnauthorized
  $result = Invoke-Studio -Case $missingConfigUninstallUnauthorized `
    -Scenario 'missing-config-uninstall-running-unauthorized' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 1 -Ok $false -Install 'ready' `
    -Codex 'needs-first-run' -Session 'official' -ThemeName '午夜极光' -RequiresRestart $true -Verified $null `
    -AvailableActions @('apply', 'restore', 'uninstall') -ErrorCode 'RESTART_REQUIRED' `
    -RecoveryActions @('authorize-restart', 'cancel')
  Assert-Equal (Get-ProtectedSnapshot -Case $missingConfigUninstallUnauthorized) $before `
    'missing-config-uninstall-running-unauthorized changed protected state.'
  Assert-NoChildOrLog -Case $missingConfigUninstallUnauthorized

  $missingConfigUninstallAuthorized = New-CaseRoot `
    -Name 'missing-config-uninstall-running-authorized' -NoConfig -NoState
  $missingConfigPath = Join-Path $missingConfigUninstallAuthorized.UserProfile '.codex\config.toml'
  $result = Invoke-Studio -Case $missingConfigUninstallAuthorized `
    -Scenario 'missing-config-uninstall-running-authorized' -Operation 'uninstall' `
    -ExtraArguments @('-RestartAuthorized')
  if ($result.ExitCode -ne 0 -or (Test-Path -LiteralPath $missingConfigPath)) {
    throw 'missing-config-uninstall-running-authorized failed or created config.'
  }
  Assert-ChildInvocation -Case $missingConfigUninstallAuthorized `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-CloseRunning|-AdapterLockHeld'

  $missingCodexUninstall = New-CaseRoot -Name 'uninstall-missing-codex' -NoState
  $result = Invoke-Studio -Case $missingCodexUninstall -Scenario 'missing-codex' -Operation 'uninstall'
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null
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
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null
  Assert-ChildInvocation -Case $uninstall `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-CloseRunning|-AdapterLockHeld'
  Assert-OperationLog -Case $uninstall -ScriptName 'restore-dream-skin.ps1'
  foreach ($preserved in @('themes', 'images', 'active-theme')) {
    if (-not (Test-Path -LiteralPath (Join-Path $uninstall.StateRoot $preserved) -PathType Container)) { throw "Default uninstall deleted $preserved." }
  }
  Assert-Equal (Get-StateSnapshot -Root $engineRoot) $engineBefore 'Uninstall deleted its running versioned engine.'

  $damagedUninstallDispatch = New-CaseRoot -Name 'damaged-recovery-uninstall-absent' -DamagedState
  $result = Invoke-Studio -Case $damagedUninstallDispatch -Scenario 'damaged-recovery-uninstall-absent' `
    -Operation 'uninstall'
  if ($result.ExitCode -ne 0 -or -not $result.Envelope.ok) {
    throw 'Adapter did not dispatch malformed-state Uninstall recovery.'
  }
  Assert-ChildInvocation -Case $damagedUninstallDispatch `
    -Expected 'restore-dream-skin.ps1 -RestoreBaseTheme|-Uninstall|-NoRelaunch|-RecoverDamagedState|-AdapterLockHeld'

  $wrongRuntimeUninstall = New-CaseRoot -Name 'wrong-runtime-uninstall'
  $result = Invoke-Studio -Case $wrongRuntimeUninstall -Scenario 'active-wrong-runtime' -Operation 'uninstall' `
    -ExtraArguments @('-RestartAuthorized')
  Assert-StudioResult -Result $result -Operation 'uninstall' -ExitCode 0 -Ok $true -Install 'not-installed' `
    -Codex 'stopped' -Session 'official' -ThemeName $null -RequiresRestart $false -Verified $null `
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null
  if (Test-Path -LiteralPath (Join-Path $wrongRuntimeUninstall.Root 'runtime-trace.txt')) {
    throw 'Node-free uninstall still probed the private runtime.'
  }
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
    -AvailableActions @('install', 'restore', 'uninstall') -ErrorCode $null
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
    throw "Production install mutated or stopped Codex without close authorization. Exit=$($realResult.ExitCode); Trace=$($realResult.Trace -join '|'); Stderr=$($realResult.Stderr)"
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
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'stop:True', 'ensure', 'strict-codex:current', 'strict-listener:9335',
    'start-official', 'start-official:current'
  ) -Message 'Production start did not recover the first post-close pre-launch failure.'

  $priorWatcherProvider = New-RealLifecycleCase -Name 'prior-watcher-provider-error-state-snapshot-fail'
  $priorWatcherState = Join-Path $priorWatcherProvider.StateRoot 'state.json'
  $priorWatcherBytes = [IO.File]::ReadAllBytes($priorWatcherState)
  $realResult = Invoke-RealLifecycle -Case $priorWatcherProvider -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'prior-watcher-provider-error-state-snapshot-fail' `
    -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart')
  if ($realResult.ExitCode -eq 0 -or
    $realResult.Trace -notcontains 'recorded-injector-cim-provider-error' -or
    $realResult.Trace -contains 'state-write' -or $realResult.Trace -contains 'start-cdp' -or
    $realResult.Trace -contains 'start-official' -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($priorWatcherState)) -cne
      [Convert]::ToBase64String($priorWatcherBytes)) {
    throw 'Production recorded-watcher CIM provider failure was treated as cleanup authority.'
  }

  foreach ($operation in @('start', 'resume')) {
    foreach ($closedIdentity in @('current', 'saved')) {
      $scenario = "combined-closed-new-$operation-$closedIdentity-early-wait-success"
      $combinedCleanup = New-RealLifecycleCase -Name $scenario
      if ($operation -ceq 'resume') {
        [IO.File]::WriteAllText((Join-Path $combinedCleanup.StateRoot 'paused'), 'paused', $utf8NoBom)
      }
      $realResult = Invoke-RealLifecycle -Case $combinedCleanup -ScriptName 'start-dream-skin.ps1' `
        -Scenario $scenario -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart')
      $statePath = Join-Path $combinedCleanup.StateRoot 'state.json'
      $strictIdentities = @($realResult.Trace | Where-Object { $_ -like 'strict-codex:*' })
      $expectedIdentities = if ($closedIdentity -ceq 'saved') {
        @('strict-codex:current', 'strict-codex:saved')
      } else { @('strict-codex:current') }
      $strictPorts = @($realResult.Trace | Where-Object { $_ -like 'strict-listener:*' })
      if ($realResult.ExitCode -eq 0 -or (Test-Path -LiteralPath $statePath) -or
        $realResult.Trace -notcontains "stop-codex:$closedIdentity" -or
        $realResult.Trace -notcontains 'state-write:4:19473:managed-cdp' -or
        $realResult.Trace -notcontains 'start-cdp' -or
        $realResult.Trace -notcontains 'start-official:current') {
        throw "$scenario did not consume combined closed/new cleanup authority before relaunch."
      }
      Assert-Equal $strictIdentities $expectedIdentities `
        "$scenario did not deduplicate and prove current plus closed package identities."
      Assert-Equal $strictPorts @('strict-listener:19473', 'strict-listener:9335') `
        "$scenario did not prove both the new and previously closed listener ports."
      if ($operation -ceq 'resume' -and
        -not (Test-Path -LiteralPath (Join-Path $combinedCleanup.StateRoot 'paused') -PathType Leaf)) {
        throw "$scenario discarded Resume pause intent."
      }
    }
  }

  foreach ($definition in @(
    @{
      Scenario = 'combined-closed-new-start-saved-early-wait-cleanup-new-cim-error'
      Expected = @('strict-codex:current', 'strict-cim-error')
      Forbidden = @('strict-listener:19473', 'strict-codex:saved', 'strict-listener:9335')
    },
    @{
      Scenario = 'combined-closed-new-start-saved-early-wait-cleanup-new-tcp-error'
      Expected = @('strict-codex:current', 'strict-listener:19473', 'strict-tcp-error')
      Forbidden = @('strict-codex:saved', 'strict-listener:9335')
    },
    @{
      Scenario = 'combined-closed-new-start-saved-early-wait-cleanup-closed-cim-error'
      Expected = @('strict-codex:current', 'strict-listener:19473', 'strict-codex:saved', 'strict-cim-error')
      Forbidden = @('strict-listener:9335')
    },
    @{
      Scenario = 'combined-closed-new-start-saved-early-wait-cleanup-closed-tcp-error'
      Expected = @(
        'strict-codex:current', 'strict-listener:19473', 'strict-codex:saved',
        'strict-listener:9335', 'strict-tcp-error'
      )
      Forbidden = @()
    }
  )) {
    $combinedUncertain = New-RealLifecycleCase -Name $definition.Scenario
    $statePath = Join-Path $combinedUncertain.StateRoot 'state.json'
    $realResult = Invoke-RealLifecycle -Case $combinedUncertain -ScriptName 'start-dream-skin.ps1' `
      -Scenario $definition.Scenario -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart')
    $retainedState = [IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
    if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'start-official' -or
      $retainedState.schemaVersion -ne 4 -or $retainedState.port -ne 19473 -or
      "$($retainedState.recoveryKind)" -cne 'managed-cdp') {
      throw "$($definition.Scenario) consumed state or relaunched with incomplete combined cleanup proof."
    }
    Assert-TraceOrder -Trace $realResult.Trace -Expected $definition.Expected `
      -Message "$($definition.Scenario) did not reach its intended combined provider boundary."
    foreach ($token in $definition.Forbidden) {
      if ($realResult.Trace -contains $token) {
        throw "$($definition.Scenario) crossed the fail-closed boundary at $token."
      }
    }
  }

  foreach ($operation in @('start', 'resume')) {
    foreach ($closedIdentity in @('current', 'saved')) {
      foreach ($failure in @('prior-state', 'state-write', 'state-snapshot')) {
        $scenario = "prelaunch-closed-$operation-$closedIdentity-$failure-fail"
        $prelaunchFailure = New-RealLifecycleCase -Name $scenario
        $statePath = Join-Path $prelaunchFailure.StateRoot 'state.json'
        $priorStateBytes = [IO.File]::ReadAllBytes($statePath)
        if ($operation -ceq 'resume') {
          [IO.File]::WriteAllText((Join-Path $prelaunchFailure.StateRoot 'paused'), 'paused', $utf8NoBom)
        }
        $realResult = Invoke-RealLifecycle -Case $prelaunchFailure -ScriptName 'start-dream-skin.ps1' `
          -Scenario $scenario -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart')
        $strictIdentities = @($realResult.Trace | Where-Object { $_ -like 'strict-codex:*' })
        $expectedStrictIdentities = if ($closedIdentity -ceq 'saved') {
          @('strict-codex:saved', 'strict-codex:current')
        } else { @('strict-codex:current') }
        $failureTrace = switch ($failure) {
          'prior-state' { 'watcher-stop' }
          'state-write' { 'state-write:4:19473:managed-cdp' }
          'state-snapshot' { 'state-snapshot-fail' }
        }
        $expectRelaunch = $failure -cne 'prior-state'
        if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains "stop-codex:$closedIdentity" -or
          $realResult.Trace -contains 'start-cdp' -or $realResult.Trace -notcontains $failureTrace -or
          $realResult.Trace -notcontains 'strict-listener:9335' -or
          $realResult.Trace -contains 'strict-listener:19473' -or
          ($expectRelaunch -and $realResult.Trace -notcontains 'start-official:current') -or
          (-not $expectRelaunch -and $realResult.Trace -contains 'start-official')) {
          throw "$scenario mishandled prior watcher or pre-launch closed-session authority. Exit=$($realResult.ExitCode); Trace=$($realResult.Trace -join '|'); Stdout=$($realResult.Stdout); Stderr=$($realResult.Stderr)"
        }
        Assert-Equal $strictIdentities $expectedStrictIdentities `
          "$scenario did not scan the exact closed identity and distinct current identity in order."
        $expectedOrder = @("stop-codex:$closedIdentity", $failureTrace) + $expectedStrictIdentities +
          @('strict-listener:9335')
        if ($expectRelaunch) { $expectedOrder += 'start-official:current' }
        Assert-TraceOrder -Trace $realResult.Trace -Expected $expectedOrder `
          -Message "$scenario crossed its closed-session cleanup ordering boundary."
        if ($failure -ceq 'state-snapshot') {
          $retainedState = [IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
          if ($retainedState.schemaVersion -ne 4 -or $retainedState.port -ne 19473 -or
            "$($retainedState.recoveryKind)" -cne 'managed-cdp') {
            throw "$scenario deleted or damaged state published before snapshot failure."
          }
        } elseif ([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -cne
          [Convert]::ToBase64String($priorStateBytes)) {
          throw "$scenario changed prior state before its pre-launch failure committed."
        }
        if ($operation -ceq 'resume' -and
          -not (Test-Path -LiteralPath (Join-Path $prelaunchFailure.StateRoot 'paused') -PathType Leaf)) {
          throw "$scenario discarded Resume pause intent."
        }
      }
    }
  }

  foreach ($definition in @(
    @{
      Scenario = 'prelaunch-closed-start-saved-state-snapshot-fail-cleanup-closed-cim-error'
      Expected = @('strict-codex:saved', 'strict-cim-error')
      Forbidden = @('strict-codex:current', 'strict-listener:9335')
    },
    @{
      Scenario = 'prelaunch-closed-start-saved-state-snapshot-fail-cleanup-current-cim-error'
      Expected = @('strict-codex:saved', 'strict-codex:current', 'strict-cim-error')
      Forbidden = @('strict-listener:9335')
    },
    @{
      Scenario = 'prelaunch-closed-start-saved-state-snapshot-fail-cleanup-tcp-error'
      Expected = @('strict-codex:saved', 'strict-codex:current', 'strict-listener:9335', 'strict-tcp-error')
      Forbidden = @()
    }
  )) {
    $prelaunchUncertain = New-RealLifecycleCase -Name $definition.Scenario
    $statePath = Join-Path $prelaunchUncertain.StateRoot 'state.json'
    $realResult = Invoke-RealLifecycle -Case $prelaunchUncertain -ScriptName 'start-dream-skin.ps1' `
      -Scenario $definition.Scenario -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart')
    $retainedState = [IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
    if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'start-official' -or
      $retainedState.schemaVersion -ne 4 -or $retainedState.port -ne 19473 -or
      "$($retainedState.recoveryKind)" -cne 'managed-cdp') {
      throw "$($definition.Scenario) relaunched without strict closed-session cleanup proof."
    }
    Assert-TraceOrder -Trace $realResult.Trace -Expected $definition.Expected `
      -Message "$($definition.Scenario) did not reach its intended provider uncertainty boundary."
    foreach ($token in $definition.Forbidden) {
      if ($realResult.Trace -contains $token) {
        throw "$($definition.Scenario) crossed the fail-closed boundary at $token."
      }
    }
  }

  foreach ($operation in @('start', 'resume')) {
    $earlySuccessName = "$operation-early-wait-cleanup-success"
    $earlySuccess = New-RealLifecycleCase -Name $earlySuccessName
    if ($operation -ceq 'resume') {
      [IO.File]::WriteAllText((Join-Path $earlySuccess.StateRoot 'paused'), 'paused', $utf8NoBom)
    }
    $realResult = Invoke-RealLifecycle -Case $earlySuccess -ScriptName 'start-dream-skin.ps1' `
      -Scenario $earlySuccessName -Arguments @('-NodePath', $nodePath, '-Port', '19473')
    if ($realResult.ExitCode -eq 0 -or
      (Test-Path -LiteralPath (Join-Path $earlySuccess.StateRoot 'state.json')) -or
      $realResult.Trace -notcontains 'state-write:4:19473:managed-cdp' -or
      $realResult.Trace -notcontains 'strict-cim-scan' -or
      $realResult.Trace -notcontains 'listener-scan' -or
      $realResult.Trace -notcontains 'start-official') {
      throw "$operation early Browser/wait failure did not consume proven cleanup authority."
    }
    Assert-TraceOrder -Trace $realResult.Trace `
      -Expected @('state-write:4:19473:managed-cdp', 'start-cdp', 'stop:True',
        'strict-cim-scan', 'listener-scan', 'start-official') `
      -Message "$operation early cleanup did not follow its durable recovery transaction."
    if ($operation -ceq 'resume' -and
      -not (Test-Path -LiteralPath (Join-Path $earlySuccess.StateRoot 'paused') -PathType Leaf)) {
      throw 'Resume early cleanup discarded its prior pause intent.'
    }

    foreach ($failure in @('cleanup-force-fail', 'cleanup-cim-error', 'cleanup-tcp-error')) {
      $scenario = "$operation-early-wait-$failure"
      $earlyFailure = New-RealLifecycleCase -Name $scenario
      if ($operation -ceq 'resume') {
        [IO.File]::WriteAllText((Join-Path $earlyFailure.StateRoot 'paused'), 'paused', $utf8NoBom)
      }
      $realResult = Invoke-RealLifecycle -Case $earlyFailure -ScriptName 'start-dream-skin.ps1' `
        -Scenario $scenario -Arguments @('-NodePath', $nodePath, '-Port', '19473')
      $statePath = Join-Path $earlyFailure.StateRoot 'state.json'
      if ($realResult.ExitCode -eq 0 -or -not (Test-Path -LiteralPath $statePath -PathType Leaf) -or
        $realResult.Trace -notcontains 'state-write:4:19473:managed-cdp' -or
        $realResult.Trace -contains 'start-official') {
        throw "$scenario did not retain its exact CDP-only recovery record."
      }
      $recoveryState = [IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
      if ($recoveryState.schemaVersion -ne 4 -or $recoveryState.port -ne 19473 -or
        "$($recoveryState.recoveryKind)" -cne 'managed-cdp') {
        throw "$scenario retained unusable cleanup authority."
      }
      $failureTrace = switch ($failure) {
        'cleanup-force-fail' { 'stop:True' }
        'cleanup-cim-error' { 'strict-cim-error' }
        'cleanup-tcp-error' { 'strict-tcp-error' }
      }
      if ($realResult.Trace -notcontains $failureTrace) {
        throw "$scenario did not reach the intended fail-closed provider branch."
      }
    }

    $priorFailureName = "$operation-prior-state-fail"
    $priorFailure = New-RealLifecycleCase -Name $priorFailureName
    $priorBytes = [IO.File]::ReadAllBytes((Join-Path $priorFailure.StateRoot 'state.json'))
    $realResult = Invoke-RealLifecycle -Case $priorFailure -ScriptName 'start-dream-skin.ps1' `
      -Scenario $priorFailureName -Arguments @('-NodePath', $nodePath)
    if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains 'watcher-stop' -or
      $realResult.Trace -contains 'state-write' -or $realResult.Trace -contains 'start-cdp' -or
      [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $priorFailure.StateRoot 'state.json'))) -cne
        [Convert]::ToBase64String($priorBytes)) {
      throw "$operation prior-state validation failure crossed the debug-launch boundary."
    }
  }

  $foregroundFailure = New-RealLifecycleCase -Name 'start-foreground-new-fail'
  $realResult = Invoke-RealLifecycle -Case $foregroundFailure -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-foreground-new-fail' `
    -Arguments @('-NodePath', $nodePath, '-Port', '19473', '-ForegroundInjector')
  if ($realResult.ExitCode -eq 0 -or
    (Test-Path -LiteralPath (Join-Path $foregroundFailure.StateRoot 'state.json')) -or
    $realResult.Trace -notcontains 'foreground-watch' -or
    $realResult.Trace -notcontains 'state-write:4:19473:managed-cdp' -or
    $realResult.Trace -notcontains 'strict-cim-scan' -or
    $realResult.Trace -notcontains 'listener-scan' -or
    $realResult.Trace -notcontains 'start-official') {
    throw 'New-CDP foreground watcher failure bypassed unified cleanup or left recovery state.'
  }
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'state-write:4:19473:managed-cdp', 'start-cdp', 'foreground-watch', 'stop:True',
    'strict-cim-scan', 'listener-scan', 'start-official'
  ) -Message 'Foreground watcher failure did not use the normal new-CDP cleanup transaction.'

  $foregroundReplacement = New-RealLifecycleCase -Name 'start-foreground-state-replaced'
  $foregroundReplacementState = Join-Path $foregroundReplacement.StateRoot 'state.json'
  $realResult = Invoke-RealLifecycle -Case $foregroundReplacement -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-foreground-state-replaced' `
    -Arguments @('-NodePath', $nodePath, '-Port', '19473', '-ForegroundInjector')
  $replacementState = [IO.File]::ReadAllText($foregroundReplacementState, $utf8NoBom)
  $lastLockEntry = [Array]::LastIndexOf($realResult.Trace, 'lock-enter')
  $replacementIndex = [Array]::IndexOf($realResult.Trace, 'foreground-state-replaced')
  if ($realResult.ExitCode -eq 0 -or $replacementState -cne '{"schemaVersion":3,"newTransaction":true}' -or
    $replacementIndex -lt 0 -or $lastLockEntry -le $replacementIndex -or
    @($realResult.Trace | Where-Object { $_ -ceq 'lock-enter' }).Count -ne 2 -or
    $realResult.Trace -contains 'stop:True' -or $realResult.Trace -contains 'strict-cim-scan' -or
    $realResult.Trace -contains 'listener-scan' -or $realResult.Trace -contains 'start-official') {
    throw 'Foreground failure used stale cleanup authority after concurrent state replacement.'
  }

  foreach ($definition in @(
    @{
      Scenario = 'combined-closed-new-foreground-resume-saved-state-replaced'
      ExpectedState = '{"schemaVersion":3,"newTransaction":true}'
      ExpectedBoundary = 'foreground-state-replaced'
    },
    @{
      Scenario = 'combined-closed-new-foreground-resume-saved-lock-reentry-fail'
      ExpectedState = $null
      ExpectedBoundary = 'lock-reentry-error'
    }
  )) {
    $foregroundClosedPaused = New-RealLifecycleCase -Name $definition.Scenario
    $foregroundClosedPausedState = Join-Path $foregroundClosedPaused.StateRoot 'state.json'
    $foregroundClosedPausedMarker = Join-Path $foregroundClosedPaused.StateRoot 'paused'
    [IO.File]::WriteAllText($foregroundClosedPausedMarker, 'paused', $utf8NoBom)
    $realResult = Invoke-RealLifecycle -Case $foregroundClosedPaused -ScriptName 'start-dream-skin.ps1' `
      -Scenario $definition.Scenario `
      -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart', '-ForegroundInjector')
    $retainedForegroundState = [IO.File]::ReadAllText($foregroundClosedPausedState, $utf8NoBom)
    if ($null -eq $definition.ExpectedState) {
      $retainedForegroundRecovery = $retainedForegroundState | ConvertFrom-Json -ErrorAction Stop
      $statePreserved = $retainedForegroundRecovery.schemaVersion -eq 4 -and
        $retainedForegroundRecovery.port -eq 19473 -and
        "$($retainedForegroundRecovery.recoveryKind)" -ceq 'managed-cdp'
    } else {
      $statePreserved = $retainedForegroundState -ceq $definition.ExpectedState
    }
    if ($realResult.ExitCode -eq 0 -or -not $statePreserved -or
      $realResult.Trace -notcontains 'stop-codex:saved' -or
      $realResult.Trace -notcontains 'state-write:4:19473:managed-cdp' -or
      $realResult.Trace -notcontains 'start-cdp' -or
      $realResult.Trace -notcontains 'pause-write:False' -or
      $realResult.Trace -notcontains 'foreground-watch' -or
      $realResult.Trace -notcontains $definition.ExpectedBoundary -or
      @($realResult.Trace | Where-Object { $_ -ceq 'lock-enter' }).Count -ne 2 -or
      @($realResult.Trace | Where-Object { $_ -like 'strict-codex:*' }).Count -ne 0 -or
      @($realResult.Trace | Where-Object { $_ -like 'strict-listener:*' }).Count -ne 0 -or
      $realResult.Trace -contains 'start-official' -or
      $realResult.Trace -contains 'pause-write:True' -or
      (Test-Path -LiteralPath $foregroundClosedPausedMarker)) {
      throw "$($definition.Scenario) retained stale cleanup or pause authority outside the operation lock."
    }
  }

  $foregroundBrowserScenario = 'combined-closed-new-foreground-resume-saved-browser-replaced'
  $foregroundBrowserReplaced = New-RealLifecycleCase -Name $foregroundBrowserScenario
  $foregroundBrowserState = Join-Path $foregroundBrowserReplaced.StateRoot 'state.json'
  $foregroundBrowserMarker = Join-Path $foregroundBrowserReplaced.StateRoot 'paused'
  [IO.File]::WriteAllText($foregroundBrowserMarker, 'paused', $utf8NoBom)
  $realResult = Invoke-RealLifecycle -Case $foregroundBrowserReplaced -ScriptName 'start-dream-skin.ps1' `
    -Scenario $foregroundBrowserScenario `
    -Arguments @('-NodePath', $nodePath, '-RestartExisting', '-ForceRestart', '-ForegroundInjector')
  $retainedBrowserRecovery = [IO.File]::ReadAllText(
    $foregroundBrowserState, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
  $strictBrowserIdentities = @($realResult.Trace | Where-Object { $_ -like 'strict-codex:*' })
  $strictBrowserPorts = @($realResult.Trace | Where-Object { $_ -like 'strict-listener:*' })
  if ($realResult.ExitCode -eq 0 -or $retainedBrowserRecovery.schemaVersion -ne 4 -or
    $retainedBrowserRecovery.port -ne 19473 -or
    "$($retainedBrowserRecovery.recoveryKind)" -cne 'managed-cdp' -or
    $realResult.Trace -notcontains 'stop-codex:saved' -or
    $realResult.Trace -notcontains 'state-write:4:19473:managed-cdp' -or
    $realResult.Trace -notcontains 'foreground-watch' -or
    $realResult.Trace -notcontains 'foreground-browser-replaced' -or
    @($realResult.Trace | Where-Object { $_ -ceq 'lock-enter' }).Count -ne 2 -or
    $realResult.Trace -contains 'stop-codex:current' -or
    $realResult.Trace -contains 'start-official' -or
    $realResult.Trace -contains 'pause-write:True' -or
    (Test-Path -LiteralPath $foregroundBrowserMarker)) {
    throw 'New-managed foreground Browser replacement retained stale cleanup or pause authority.'
  }
  Assert-Equal $strictBrowserIdentities @('strict-codex:current') `
    'New-managed foreground Browser replacement crossed the current-process revalidation boundary.'
  Assert-Equal $strictBrowserPorts @('strict-listener:19473') `
    'New-managed foreground Browser replacement crossed the current-listener revalidation boundary.'

  $foregroundSuccess = New-RealLifecycleCase -Name 'start-foreground-success'
  $foregroundSuccessState = Join-Path $foregroundSuccess.StateRoot 'state.json'
  $realResult = Invoke-RealLifecycle -Case $foregroundSuccess -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-foreground-success' `
    -Arguments @('-NodePath', $nodePath, '-Port', '19473', '-ForegroundInjector')
  $successState = [IO.File]::ReadAllText($foregroundSuccessState, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
  if ($realResult.ExitCode -ne 0 -or $successState.schemaVersion -ne 4 -or
    "$($successState.recoveryKind)" -cne 'managed-cdp' -or $successState.port -ne 19473 -or
    @($realResult.Trace | Where-Object { $_ -ceq 'lock-enter' }).Count -ne 1 -or
    $realResult.Trace -contains 'stop:True' -or $realResult.Trace -contains 'start-official') {
    throw 'Successful foreground watcher did not retain its managed-CDP recovery authority.'
  }

  $foregroundExisting = New-RealLifecycleCase -Name 'start-foreground-existing-fail'
  $foregroundExistingState = Join-Path $foregroundExisting.StateRoot 'state.json'
  $foregroundExistingBytes = [IO.File]::ReadAllBytes($foregroundExistingState)
  $realResult = Invoke-RealLifecycle -Case $foregroundExisting -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-foreground-existing-fail' `
    -Arguments @('-NodePath', $nodePath, '-Port', '19473', '-ForegroundInjector')
  $existingRemove = "remove-args:$realScripts\injector.mjs --remove --port 19473 --browser-id browser-123 --timeout-ms 5000"
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains $existingRemove -or
    @($realResult.Trace | Where-Object { $_ -ceq 'lock-enter' }).Count -ne 2 -or
    $realResult.Trace -contains 'start-cdp' -or $realResult.Trace -contains 'stop:True' -or
    $realResult.Trace -contains 'start-official' -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($foregroundExistingState)) -cne
      [Convert]::ToBase64String($foregroundExistingBytes)) {
    throw 'Foreground existing-CDP failure did not revalidate and remove with the same Browser identity.'
  }

  $foregroundIdentityReplaced = New-RealLifecycleCase -Name 'start-foreground-existing-identity-replaced'
  $foregroundIdentityState = Join-Path $foregroundIdentityReplaced.StateRoot 'state.json'
  $foregroundIdentityBytes = [IO.File]::ReadAllBytes($foregroundIdentityState)
  $realResult = Invoke-RealLifecycle -Case $foregroundIdentityReplaced -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-foreground-existing-identity-replaced' `
    -Arguments @('-NodePath', $nodePath, '-Port', '19473', '-ForegroundInjector')
  if ($realResult.ExitCode -eq 0 -or
    @($realResult.Trace | Where-Object { $_ -ceq 'lock-enter' }).Count -ne 2 -or
    $realResult.Trace -contains 'remove' -or $realResult.Trace -contains 'start-cdp' -or
    $realResult.Trace -contains 'stop:True' -or $realResult.Trace -contains 'start-official' -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($foregroundIdentityState)) -cne
      [Convert]::ToBase64String($foregroundIdentityBytes)) {
    throw 'Foreground existing-CDP failure used cleanup authority after the Browser identity changed.'
  }

  $schema4DirectRetry = New-RealLifecycleCase -Name 'schema4-direct-retry'
  $schema4DirectState = Join-Path $schema4DirectRetry.StateRoot 'state.json'
  $schema4DirectBytes = [IO.File]::ReadAllBytes($schema4DirectState)
  $realResult = Invoke-RealLifecycle -Case $schema4DirectRetry -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'schema4-direct-retry' -Arguments @('-NodePath', $nodePath)
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'codex-process' -or
    $realResult.Trace -contains 'listener-scan' -or $realResult.Trace -contains 'start-cdp' -or
    $realResult.Trace -contains 'state-write' -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($schema4DirectState)) -cne
      [Convert]::ToBase64String($schema4DirectBytes)) {
    throw 'Direct start reinterpreted retained schema-4 evidence instead of requiring Restore.'
  }

  foreach ($providerFailure in @('cim', 'tcp')) {
    $scenario = "schema4-restore-$providerFailure-error"
    $schema4RestoreFailure = New-RealLifecycleCase -Name $scenario
    $configPath = Join-Path $schema4RestoreFailure.UserProfile '.codex\config.toml'
    $configBytes = [IO.File]::ReadAllBytes($configPath)
    $stateSnapshot = @(Get-StateSnapshot -Root $schema4RestoreFailure.StateRoot)
    $realResult = Invoke-RealLifecycle -Case $schema4RestoreFailure `
      -ScriptName 'restore-dream-skin.ps1' -Scenario $scenario -Arguments @('-RestoreBaseTheme')
    if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains 'strict-cim-scan' -or
      $realResult.Trace -contains 'restore-config' -or
      [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -cne
        [Convert]::ToBase64String($configBytes)) {
      throw "$scenario did not fail closed before retained-state Restore mutation."
    }
    if ($providerFailure -ceq 'tcp' -and $realResult.Trace -notcontains 'listener-scan') {
      throw 'Retained-state Restore did not reach the strict TCP provider failure.'
    }
    Assert-Equal (Get-StateSnapshot -Root $schema4RestoreFailure.StateRoot) $stateSnapshot `
      "$scenario changed retained recovery evidence."
  }

  $schema4RestoreAbsent = New-RealLifecycleCase -Name 'schema4-restore-absent'
  $realResult = Invoke-RealLifecycle -Case $schema4RestoreAbsent `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'schema4-restore-absent' `
    -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -ne 0 -or
    (Test-Path -LiteralPath (Join-Path $schema4RestoreAbsent.StateRoot 'state.json')) -or
    [IO.File]::ReadAllText((Join-Path $schema4RestoreAbsent.UserProfile '.codex\config.toml')) -cne 'restored' -or
    $realResult.Trace -notcontains 'strict-cim-scan' -or
    $realResult.Trace -notcontains 'listener-scan') {
    throw 'Retained schema-4 Restore could not consume strictly proven absent process/listener evidence.'
  }

  foreach ($scenario in @('schema4-restore-process-appears', 'schema4-restore-listener-appears')) {
    $schema4RestoreRace = New-RealLifecycleCase -Name $scenario
    $baseline = New-RealRestoreRollbackBaseline -Case $schema4RestoreRace
    $realResult = Invoke-RealLifecycle -Case $schema4RestoreRace `
      -ScriptName 'restore-dream-skin.ps1' -Scenario $scenario -Arguments @('-RestoreBaseTheme')
    $expectedScan = if ($scenario -ceq 'schema4-restore-process-appears') {
      'strict-cim-scan'
    } else {
      'listener-scan'
    }
    $strictScanCount = @($realResult.Trace | Where-Object { $_ -ceq $expectedScan }).Count
    if ($realResult.ExitCode -eq 0 -or $strictScanCount -lt 2 -or
      $realResult.Trace -contains 'ensure' -or
      $realResult.Trace -contains 'restore-config') {
      throw "$scenario crossed the retained-state transaction absence gate."
    }
    Assert-RealRestoreRolledBack -Case $schema4RestoreRace -Baseline $baseline `
      -Message "$scenario changed config, backup, or retained recovery evidence."
  }

  $schema4CurrentRunning = New-RealLifecycleCase -Name 'schema4-current-running'
  $currentRunningBaseline = New-RealRestoreRollbackBaseline -Case $schema4CurrentRunning
  $realResult = Invoke-RealLifecycle -Case $schema4CurrentRunning `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'schema4-current-running' `
    -Arguments @('-RestoreBaseTheme')
  $strictCurrentScans = @($realResult.Trace | Where-Object { $_ -ceq 'strict-cim-scan' }).Count
  if ($realResult.ExitCode -eq 0 -or $strictCurrentScans -lt 2 -or
    $realResult.Trace -contains 'ensure' -or
    $realResult.Trace -contains 'restore-config' -or $realResult.Trace -contains 'stop:False') {
    throw 'Retained schema-4 Restore ignored a running current Codex package version.'
  }
  Assert-RealRestoreRolledBack -Case $schema4CurrentRunning -Baseline $currentRunningBaseline `
    -Message 'Current-version activity changed config, backup, or retained recovery evidence.'

  $schema4PortMismatch = New-RealLifecycleCase -Name 'schema4-explicit-port-mismatch'
  $portMismatchBaseline = New-RealRestoreRollbackBaseline -Case $schema4PortMismatch
  $realResult = Invoke-RealLifecycle -Case $schema4PortMismatch `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'schema4-explicit-port-mismatch' `
    -Arguments @('-RestoreBaseTheme', '-Port', '19474')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'strict-cim-scan' -or
    $realResult.Trace -contains 'listener-scan' -or $realResult.Trace -contains 'ensure' -or
    $realResult.Trace -contains 'restore-config') {
    throw 'Retained schema-4 Restore probed or mutated using an explicit mismatched port.'
  }
  Assert-RealRestoreRolledBack -Case $schema4PortMismatch -Baseline $portMismatchBaseline `
    -Message 'Explicit port mismatch changed config, backup, or retained recovery evidence.'

  $schema4AppxFailure = New-RealLifecycleCase -Name 'schema4-appx-provider-error'
  $appxFailureBaseline = New-RealRestoreRollbackBaseline -Case $schema4AppxFailure
  $realResult = Invoke-RealLifecycle -Case $schema4AppxFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'schema4-appx-provider-error' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -eq 0 -or
    @($realResult.Trace | Where-Object { $_ -ceq 'appx-scan' }).Count -ne 1 -or
    $realResult.Trace -contains 'strict-cim-scan' -or $realResult.Trace -contains 'listener-scan' -or
    $realResult.Trace -contains 'ensure' -or $realResult.Trace -contains 'restore-config') {
    throw 'Schema-4 Restore suppressed or crossed a terminating Appx provider failure.'
  }
  Assert-RealRestoreRolledBack -Case $schema4AppxFailure -Baseline $appxFailureBaseline `
    -Message 'Appx provider failure changed config, backup, or retained recovery evidence.'

  $schema4AppxUpdate = New-RealLifecycleCase -Name 'schema4-appx-update-race'
  $realResult = Invoke-RealLifecycle -Case $schema4AppxUpdate -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'schema4-appx-update-race' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -ne 0 -or
    @($realResult.Trace | Where-Object { $_ -ceq 'appx-scan' }).Count -ne 1 -or
    (Test-Path -LiteralPath (Join-Path $schema4AppxUpdate.StateRoot 'state.json')) -or
    [IO.File]::ReadAllText((Join-Path $schema4AppxUpdate.UserProfile '.codex\config.toml')) -cne 'restored') {
    throw 'Schema-4 Restore did not retain one exact Appx inventory across a package update race.'
  }

  $schema4DistinctCurrent = New-RealLifecycleCase -Name 'schema4-appx-distinct-current-running'
  $distinctCurrentBaseline = New-RealRestoreRollbackBaseline -Case $schema4DistinctCurrent
  $realResult = Invoke-RealLifecycle -Case $schema4DistinctCurrent -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'schema4-appx-distinct-current-running' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -eq 0 -or
    @($realResult.Trace | Where-Object { $_ -ceq 'appx-scan' }).Count -ne 1 -or
    @($realResult.Trace | Where-Object { $_ -ceq 'strict-cim-scan' }).Count -lt 2 -or
    $realResult.Trace -contains 'ensure' -or $realResult.Trace -contains 'restore-config') {
    throw 'Schema-4 Restore ignored a distinct running current package from its Appx snapshot.'
  }
  Assert-RealRestoreRolledBack -Case $schema4DistinctCurrent -Baseline $distinctCurrentBaseline `
    -Message 'Distinct current package activity changed retained recovery evidence.'

  foreach ($race in @('replacement', 'same-bytes', 'reparse', 'post-proof', 'post-delete')) {
    foreach ($operation in @('restore', 'uninstall')) {
      $scenario = "schema4-state-race-$race-$operation"
      $schema4StateRace = New-RealLifecycleCase -Name $scenario
      $statePath = Join-Path $schema4StateRace.StateRoot 'state.json'
      $configPath = Join-Path $schema4StateRace.UserProfile '.codex\config.toml'
      $backupPath = Join-Path $schema4StateRace.StateRoot 'config.before-dream-skin.toml'
      $pausePath = Join-Path $schema4StateRace.StateRoot 'paused'
      [IO.File]::WriteAllText($pausePath, 'paused', $utf8NoBom)
      $classifiedBytes = [IO.File]::ReadAllBytes($statePath)
      $arguments = if ($operation -ceq 'restore') {
        @('-RestoreBaseTheme')
      } else {
        @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
      }
      $realResult = Invoke-RealLifecycle -Case $schema4StateRace -ScriptName 'restore-dream-skin.ps1' `
        -Scenario $scenario -Arguments $arguments
      $expectedPhase = if ($race -in @('post-proof', 'post-delete')) { $race } else { 'before-proof' }
      if ($realResult.ExitCode -eq 0 -or
        $realResult.Trace -notcontains "schema4-state-race:$expectedPhase" -or
        [IO.File]::ReadAllText($configPath) -cne 'original' -or
        [IO.File]::ReadAllText($backupPath) -cne 'backup' -or
        -not (Test-Path -LiteralPath $pausePath -PathType Leaf) -or
        @(Get-ChildItem -LiteralPath $schema4StateRace.StateRoot -Filter 'state.stale-*.json' -File).Count -ne 0) {
        throw "$scenario crossed the exact retained-state consumption boundary."
      }
      if ($race -ceq 'reparse') {
        $item = Get-Item -LiteralPath $statePath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
          throw "$scenario did not preserve the replacement reparse point."
        }
      } elseif (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "$scenario did not preserve replacement state evidence."
      } elseif ($race -ceq 'same-bytes') {
        $held = [DreamSkinConfigNative]::Snapshot((Join-Path $schema4StateRace.Root 'classified-state.json'), $true)
        $replacement = [DreamSkinConfigNative]::Snapshot($statePath, $true)
        if ($held.Identity -ceq $replacement.Identity -or
          [Convert]::ToBase64String($replacement.Bytes) -cne [Convert]::ToBase64String($classifiedBytes)) {
          throw "$scenario did not replace the classified identity with the same bytes."
        }
      }
    }
  }

  foreach ($initialState in @('missing', 'schema3')) {
    foreach ($phase in @('before-snapshot', 'after-snapshot', 'during-rollback')) {
      foreach ($operation in @('restore', 'uninstall')) {
        $scenario = "state-transition-$initialState-$phase-$operation"
        $transition = New-RealLifecycleCase -Name $scenario
        $statePath = Join-Path $transition.StateRoot 'state.json'
        $pausePath = Join-Path $transition.StateRoot 'paused'
        $configPath = Join-Path $transition.UserProfile '.codex\config.toml'
        $backupPath = Join-Path $transition.StateRoot 'config.before-dream-skin.toml'
        if ($initialState -ceq 'missing') {
          Microsoft.PowerShell.Management\Remove-Item -LiteralPath $statePath -Force
        } else {
          $initial = [ordered]@{
            schemaVersion = 3; platform = 'windows'; port = 9335; injectorPid = 4242
            injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
            injectorPath = (Join-Path $realScripts 'injector.mjs'); nodePath = $nodePath
            codexExe = $transition.CodexExecutable
            codexPackageRoot = Split-Path -Parent $transition.CodexExecutable
            codexPackageFullName = 'OpenAI.Codex_2.0.0.0_x64__test'
            codexPackageFamilyName = 'OpenAI.Codex_test'
            browserId = 'browser-123'
          }
          [IO.File]::WriteAllText($statePath, ($initial | ConvertTo-Json -Compress), $utf8NoBom)
        }
        [IO.File]::WriteAllText($pausePath, 'paused', $utf8NoBom)
        $arguments = if ($operation -ceq 'restore') {
          @('-RestoreBaseTheme')
        } else {
          @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
        }
        $realResult = Invoke-RealLifecycle -Case $transition -ScriptName 'restore-dream-skin.ps1' `
          -Scenario $scenario -Arguments $arguments
        $newState = [IO.File]::ReadAllText($statePath, $utf8NoBom) | ConvertFrom-Json -ErrorAction Stop
        if ($realResult.ExitCode -eq 0 -or $newState.schemaVersion -ne 4 -or
          "$($newState.recoveryKind)" -cne 'managed-cdp' -or $newState.newAuthority -ne $true -or
          $realResult.Trace -notcontains "state-transition:$phase" -or
          [IO.File]::ReadAllText($configPath) -cne 'original' -or
          [IO.File]::ReadAllText($backupPath) -cne 'backup' -or
          -not (Test-Path -LiteralPath $pausePath -PathType Leaf)) {
          throw "$scenario consumed or overwrote newer schema-4 recovery authority."
        }
      }
    }
  }

  $rollbackIdentityLost = New-RealLifecycleCase -Name 'start-rollback-identity-lost'
  $realResult = Invoke-RealLifecycle -Case $rollbackIdentityLost -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-rollback-identity-lost' -Arguments @('-NodePath', $nodePath)
  Assert-RealStartRollbackState -Case $rollbackIdentityLost -Result $realResult `
    -Message 'Apply discarded retryable state after rollback lost its anchored Browser ID.'
  if ($realResult.Trace -notcontains 'cdp-missing' -or $realResult.Trace -contains 'remove') {
    throw 'Apply attempted unanchored renderer removal after rollback identity disappeared.'
  }

  $resumeIdentityLost = New-RealLifecycleCase -Name 'resume-rollback-identity-lost'
  [IO.File]::WriteAllText((Join-Path $resumeIdentityLost.StateRoot 'paused'), 'paused', $utf8NoBom)
  $realResult = Invoke-RealLifecycle -Case $resumeIdentityLost -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'resume-rollback-identity-lost' -Arguments @('-NodePath', $nodePath)
  Assert-RealStartRollbackState -Case $resumeIdentityLost -Result $realResult -Paused `
    -Message 'Resume discarded retryable state after rollback lost its anchored Browser ID.'
  if ($realResult.Trace -notcontains 'cdp-missing' -or $realResult.Trace -contains 'remove') {
    throw 'Resume did not reach the missing-identity rollback branch safely.'
  }

  $expectedRemove = "remove-args:$realScripts\injector.mjs --remove --port 9335 --browser-id browser-123 --timeout-ms 5000"
  $applyRemoveFailure = New-RealLifecycleCase -Name 'start-rollback-remove-fail'
  $realResult = Invoke-RealLifecycle -Case $applyRemoveFailure -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-rollback-remove-fail' -Arguments @('-NodePath', $nodePath)
  Assert-RealStartRollbackState -Case $applyRemoveFailure -Result $realResult `
    -Message 'Apply discarded retryable state after anchored removal failed.'
  if ($realResult.Trace -notcontains $expectedRemove) {
    throw 'Apply rollback did not execute exact Browser-anchored removal before retaining state.'
  }

  $rollbackRemoveFailure = New-RealLifecycleCase -Name 'resume-rollback-remove-fail'
  [IO.File]::WriteAllText((Join-Path $rollbackRemoveFailure.StateRoot 'paused'), 'paused', $utf8NoBom)
  $realResult = Invoke-RealLifecycle -Case $rollbackRemoveFailure -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'resume-rollback-remove-fail' -Arguments @('-NodePath', $nodePath)
  Assert-RealStartRollbackState -Case $rollbackRemoveFailure -Result $realResult -Paused `
    -Message 'Resume discarded retryable state or pause intent after anchored removal failed.'
  if ($realResult.Trace -notcontains $expectedRemove) {
    throw 'Resume rollback did not use the exact saved Browser ID for anchored removal.'
  }

  $rollbackCloseFailure = New-RealLifecycleCase -Name 'start-rollback-close-fail'
  $realResult = Invoke-RealLifecycle -Case $rollbackCloseFailure -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-rollback-close-fail' -Arguments @('-NodePath', $nodePath)
  Assert-RealStartRollbackState -Case $rollbackCloseFailure -Result $realResult `
    -Message 'Apply discarded retryable state when its newly launched Codex could not close.'
  if ($realResult.Trace -notcontains 'stop:True' -or $realResult.Trace -contains 'listener-scan') {
    throw 'Apply treated a failed Codex close as eligible for listener closure proof.'
  }

  $rollbackListenerStuck = New-RealLifecycleCase -Name 'start-rollback-listener-stuck'
  $realResult = Invoke-RealLifecycle -Case $rollbackListenerStuck -ScriptName 'start-dream-skin.ps1' `
    -Scenario 'start-rollback-listener-stuck' -Arguments @('-NodePath', $nodePath)
  Assert-RealStartRollbackState -Case $rollbackListenerStuck -Result $realResult `
    -Message 'Apply discarded retryable state while the newly launched CDP listener remained open.'
  if ($realResult.Trace -notcontains 'stop:True' -or $realResult.Trace -notcontains 'listener-scan') {
    throw 'Apply rollback never checked that its newly launched CDP listener closed.'
  }

  foreach ($scenario in @('resume-rollback-close-fail', 'resume-rollback-listener-stuck')) {
    $resumeCloseFailure = New-RealLifecycleCase -Name $scenario
    [IO.File]::WriteAllText((Join-Path $resumeCloseFailure.StateRoot 'paused'), 'paused', $utf8NoBom)
    $realResult = Invoke-RealLifecycle -Case $resumeCloseFailure -ScriptName 'start-dream-skin.ps1' `
      -Scenario $scenario -Arguments @('-NodePath', $nodePath)
    Assert-RealStartRollbackState -Case $resumeCloseFailure -Result $realResult -Paused `
      -Message "$scenario discarded retryable Resume state before CDP closure proof."
    if ($realResult.Trace -notcontains 'stop:True') {
      throw 'Cold Resume rollback did not execute its Codex close branch.'
    }
    if ($scenario -like '*close-fail' -and $realResult.Trace -contains 'listener-scan') {
      throw 'Cold Resume checked listener closure after Codex close already failed.'
    }
    if ($scenario -like '*listener-stuck' -and $realResult.Trace -notcontains 'listener-scan') {
      throw 'Cold Resume rollback did not check listener closure.'
    }
  }

  $realPause = New-RealLifecycleCase -Name 'pause-order'
  $realResult = Invoke-RealLifecycle -Case $realPause -ScriptName 'pause-dream-skin.ps1' `
    -Scenario 'real-pause' -Arguments @('-NodePath', $nodePath)
  if ($realResult.ExitCode -ne 0) {
    throw "Production pause fixture failed. Exit=$($realResult.ExitCode); Trace=$($realResult.Trace -join '|'); Stdout=$($realResult.Stdout); Stderr=$($realResult.Stderr)"
  }
  Assert-TraceOrder -Trace $realResult.Trace `
    -Expected @('codex-process', 'cdp', 'injector-identity', 'watcher-stop', 'remove', 'marker') `
    -Message 'Production pause did not validate, stop, remove, then mark.'

  $realPauseFailure = New-RealLifecycleCase -Name 'pause-remove-fail'
  $realResult = Invoke-RealLifecycle -Case $realPauseFailure -ScriptName 'pause-dream-skin.ps1' `
    -Scenario 'real-pause-remove-fail' -Arguments @('-NodePath', $nodePath)
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'marker') {
    throw 'Production pause wrote its marker after live removal failed.'
  }

  foreach ($definition in @(
    @{ Name = 'damaged-recovery-normalized-snapshot'; Arguments = @('-RestoreBaseTheme', '-RecoverDamagedState') },
    @{ Name = 'damaged-recovery-restore-absent'; Arguments = @('-RestoreBaseTheme', '-RecoverDamagedState') },
    @{ Name = 'damaged-recovery-uninstall-absent'; Arguments = @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch', '-RecoverDamagedState') }
  )) {
    $damagedRecovery = New-RealLifecycleCase -Name $definition.Name
    $configPath = Join-Path $damagedRecovery.UserProfile '.codex\config.toml'
    $statePath = Join-Path $damagedRecovery.StateRoot 'state.json'
    $stateBytes = [IO.File]::ReadAllBytes($statePath)
    $realResult = Invoke-RealLifecycle -Case $damagedRecovery -ScriptName 'restore-dream-skin.ps1' `
      -Scenario $definition.Name -Arguments $definition.Arguments
    $quarantines = @(Get-ChildItem -LiteralPath $damagedRecovery.StateRoot -Filter 'state.stale-*.json' -File)
    $configContent = if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      [IO.File]::ReadAllText($configPath)
    } else { '<missing>' }
    $stateExists = Test-Path -LiteralPath $statePath
    $backupExists = Test-Path -LiteralPath (Join-Path $damagedRecovery.StateRoot 'config.before-dream-skin.toml')
    $watcherScans = @($realResult.Trace | Where-Object { $_ -ceq 'watcher-scan' }).Count
    $quarantineMatches = $false
    if ($quarantines.Count -eq 1) {
      $quarantineMatches = [Convert]::ToBase64String([IO.File]::ReadAllBytes($quarantines[0].FullName)) -ceq
        [Convert]::ToBase64String($stateBytes)
    }
    if ($realResult.ExitCode -ne 0 -or $configContent -cne 'restored' -or
      $stateExists -or $quarantines.Count -ne 1 -or -not $quarantineMatches -or $backupExists -or
      $watcherScans -ne 2 -or
      $realResult.Trace -notcontains 'state-archive' -or $realResult.Trace -contains 'watcher-stop' -or
      $realResult.Trace -contains 'stop-process') {
      throw "$($definition.Name) did not prove watcher absence and quarantine exact malformed state. Exit=$($realResult.ExitCode); Config=$configContent; StateExists=$stateExists; Quarantines=$($quarantines.Count); QuarantineMatches=$quarantineMatches; BackupExists=$backupExists; WatcherScans=$watcherScans; Trace=$($realResult.Trace -join '|'); Stdout=$($realResult.Stdout); Stderr=$($realResult.Stderr)"
    }
  }

  foreach ($scenario in @(
    'damaged-recovery-matching-watcher',
    'damaged-recovery-mismatched-watcher',
    'damaged-recovery-uninspectable-watcher',
    'damaged-recovery-versioned-watcher',
    'damaged-recovery-historical-watcher',
    'damaged-recovery-uninspectable-codex',
    'damaged-recovery-unmatched-codex',
    'damaged-recovery-residual-listener',
    'damaged-recovery-listener-probe-fail',
    'damaged-recovery-tray-like',
    'damaged-recovery-uninspectable-tray'
  )) {
    foreach ($operation in @('restore', 'uninstall')) {
      $damagedBlocked = New-RealLifecycleCase -Name "$scenario-$operation"
      $configPath = Join-Path $damagedBlocked.UserProfile '.codex\config.toml'
      $configBytes = [IO.File]::ReadAllBytes($configPath)
      $stateSnapshot = @(Get-StateSnapshot -Root $damagedBlocked.StateRoot)
      $arguments = if ($operation -ceq 'restore') {
        @('-RestoreBaseTheme', '-RecoverDamagedState')
      } else {
        @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch', '-RecoverDamagedState')
      }
      $realResult = Invoke-RealLifecycle -Case $damagedBlocked -ScriptName 'restore-dream-skin.ps1' `
        -Scenario $scenario -Arguments $arguments
      if ($realResult.ExitCode -eq 0 -or $realResult.Trace -notcontains 'watcher-scan' -or
        $realResult.Trace -contains 'restore-config' -or $realResult.Trace -contains 'watcher-stop' -or
        $realResult.Trace -contains 'stop-process' -or $realResult.Trace -contains 'state-archive' -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -cne
          [Convert]::ToBase64String($configBytes)) {
        throw "$scenario $operation crossed the fail-closed watcher boundary."
      }
      Assert-Equal (Get-StateSnapshot -Root $damagedBlocked.StateRoot) $stateSnapshot `
        "$scenario $operation changed backup or malformed state evidence."
    }
  }

  $damagedWatcherAppears = New-RealLifecycleCase -Name 'damaged-recovery-watcher-appears'
  $configPath = Join-Path $damagedWatcherAppears.UserProfile '.codex\config.toml'
  $configBytes = [IO.File]::ReadAllBytes($configPath)
  $stateSnapshot = @(Get-StateSnapshot -Root $damagedWatcherAppears.StateRoot)
  $realResult = Invoke-RealLifecycle -Case $damagedWatcherAppears -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'damaged-recovery-watcher-appears' -Arguments @('-RestoreBaseTheme', '-RecoverDamagedState')
  $scanIndexes = @()
  for ($index = 0; $index -lt $realResult.Trace.Count; $index++) {
    if ($realResult.Trace[$index] -ceq 'watcher-scan') { $scanIndexes += $index }
  }
  $restoreIndex = [Array]::IndexOf($realResult.Trace, 'restore-config')
  $rollbackIndex = [Array]::IndexOf($realResult.Trace, 'config-rollback')
  if ($realResult.ExitCode -eq 0 -or $scanIndexes.Count -ne 2 -or
    $restoreIndex -le $scanIndexes[0] -or $scanIndexes[1] -le $restoreIndex -or
    $rollbackIndex -le $scanIndexes[1] -or $realResult.Trace -contains 'state-archive' -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -cne
      [Convert]::ToBase64String($configBytes)) {
    throw 'A watcher appearing after config restore was not detected and rolled back.'
  }
  Assert-Equal (Get-StateSnapshot -Root $damagedWatcherAppears.StateRoot) $stateSnapshot `
    'Post-restore watcher detection did not preserve exact recovery evidence.'

  $damagedOlderCodex = New-RealLifecycleCase -Name 'damaged-recovery-older-codex'
  $realResult = Invoke-RealLifecycle -Case $damagedOlderCodex -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'damaged-recovery-older-codex' `
    -Arguments @('-RestoreBaseTheme', '-RecoverDamagedState', '-CloseRunning')
  if ($realResult.ExitCode -ne 0 -or $realResult.Trace -notcontains 'stop:False' -or
    @($realResult.Trace | Where-Object { $_ -ceq 'codex-absence-scan' }).Count -ne 2 -or
    $realResult.Trace -contains 'stop-process') {
    throw 'Malformed recovery did not close and disprove the older registered Codex session safely.'
  }

  foreach ($race in @('replacement', 'same-bytes', 'reparse', 'post-proof')) {
    foreach ($operation in @('restore', 'uninstall')) {
      $phase = if ($race -ceq 'post-proof') { 'post-proof' } else { 'before' }
      $scenario = "damaged-race-$phase-$race-$operation"
      $damagedRace = New-RealLifecycleCase -Name $scenario
      $configPath = Join-Path $damagedRace.UserProfile '.codex\config.toml'
      $backupPath = Join-Path $damagedRace.StateRoot 'config.before-dream-skin.toml'
      $statePath = Join-Path $damagedRace.StateRoot 'state.json'
      $classifiedBytes = [IO.File]::ReadAllBytes($statePath)
      $arguments = if ($operation -ceq 'restore') {
        @('-RestoreBaseTheme', '-RecoverDamagedState')
      } else {
        @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch', '-RecoverDamagedState')
      }
      $realResult = Invoke-RealLifecycle -Case $damagedRace -ScriptName 'restore-dream-skin.ps1' `
        -Scenario $scenario -Arguments $arguments
      $quarantines = @(Get-ChildItem -LiteralPath $damagedRace.StateRoot -Filter 'state.stale-*.json' -File)
      $expectedRaceTrace = if ($phase -ceq 'before') {
        'state-race:before-quarantine'
      } else { 'state-race:post-proof' }
      if ($realResult.ExitCode -eq 0 -or [IO.File]::ReadAllText($configPath) -cne 'original' -or
        [IO.File]::ReadAllText($backupPath) -cne 'backup' -or
        $realResult.Trace -notcontains $expectedRaceTrace) {
        throw "$scenario crossed the stable malformed-state quarantine boundary."
      }
      if ($race -ceq 'reparse') {
        $item = Get-Item -LiteralPath $statePath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
          throw "$scenario did not preserve the replacement reparse point."
        }
      } else {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
          throw "$scenario did not preserve the live replacement state."
        }
        if ($race -ceq 'same-bytes') {
          $held = [DreamSkinConfigNative]::Snapshot((Join-Path $damagedRace.Root 'classified-state.json'), $true)
          $replacement = [DreamSkinConfigNative]::Snapshot($statePath, $true)
          if ($held.Identity -ceq $replacement.Identity -or
            [Convert]::ToBase64String($replacement.Bytes) -cne [Convert]::ToBase64String($classifiedBytes)) {
            throw "$scenario did not exercise same bytes on a different file identity."
          }
        }
      }
      if ($race -ceq 'post-proof') {
        if ($quarantines.Count -ne 1 -or
          [Convert]::ToBase64String([IO.File]::ReadAllBytes($quarantines[0].FullName)) -cne
            [Convert]::ToBase64String($classifiedBytes)) {
          throw "$scenario did not retain the exact classified quarantine beside the replacement."
        }
      } elseif ($quarantines.Count -ne 0 -or
        -not (Test-Path -LiteralPath (Join-Path $damagedRace.Root 'classified-state.json') -PathType Leaf)) {
        throw "$scenario consumed the original classified state after a pre-quarantine replacement."
      }
    }
  }

  $damagedSwitchReadable = New-RealLifecycleCase -Name 'damaged-switch-readable'
  $baseline = New-RealRestoreRollbackBaseline -Case $damagedSwitchReadable
  $realResult = Invoke-RealLifecycle -Case $damagedSwitchReadable -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-pause' -Arguments @('-RestoreBaseTheme', '-RecoverDamagedState')
  if ($realResult.ExitCode -eq 0) { throw 'Malformed-state recovery accepted readable state.' }
  Assert-RealRestoreRolledBack -Case $damagedSwitchReadable -Baseline $baseline `
    -Message 'Readable-state recovery switch changed protected artifacts.'

  $damagedSwitchMissing = New-RealLifecycleCase -Name 'damaged-switch-missing'
  Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $damagedSwitchMissing.StateRoot 'state.json') -Force
  $baseline = New-RealRestoreRollbackBaseline -Case $damagedSwitchMissing
  $realResult = Invoke-RealLifecycle -Case $damagedSwitchMissing -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'damaged-switch-missing' -Arguments @('-RestoreBaseTheme', '-RecoverDamagedState')
  if ($realResult.ExitCode -eq 0) { throw 'Malformed-state recovery accepted missing state.' }
  Assert-RealRestoreRolledBack -Case $damagedSwitchMissing -Baseline $baseline `
    -Message 'Missing-state recovery switch changed protected artifacts.'

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

  $missingConfigRestoreStopped = New-RealLifecycleCase -Name 'missing-config-restore-stopped-first'
  Remove-Item -LiteralPath (Join-Path $missingConfigRestoreStopped.UserProfile '.codex\config.toml') -Force
  $realResult = Invoke-RealLifecycle -Case $missingConfigRestoreStopped `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-restore-stopped-first' `
    -Arguments @('-RestoreBaseTheme')
  Assert-RealMissingConfigCompletion -Case $missingConfigRestoreStopped -Result $realResult `
    -Message 'missing-config-restore-stopped-first failed, created config, or relaunched Codex.'
  $missingConfigRestoreArchive = Join-Path $missingConfigRestoreStopped.StateRoot 'config.restored.toml'
  $restoreArchiveBytes = [IO.File]::ReadAllBytes($missingConfigRestoreArchive)
  $restoreArchiveMarkerBytes = [IO.File]::ReadAllBytes("$missingConfigRestoreArchive.appearance.json")
  [IO.File]::WriteAllText($missingConfigRestoreStopped.TracePath, '', $utf8NoBom)
  $realResult = Invoke-RealLifecycle -Case $missingConfigRestoreStopped `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-restore-stopped-retry' `
    -Arguments @('-RestoreBaseTheme')
  Assert-RealMissingConfigCompletion -Case $missingConfigRestoreStopped -Result $realResult `
    -Message 'missing-config-restore-stopped-retry failed, created config, or relaunched Codex.'
  if ($realResult.Trace -contains 'archive-backup' -or
    -not (Test-DreamSkinBytesEqual -Left $restoreArchiveBytes `
      -Right ([IO.File]::ReadAllBytes($missingConfigRestoreArchive))) -or
    -not (Test-DreamSkinBytesEqual -Left $restoreArchiveMarkerBytes `
      -Right ([IO.File]::ReadAllBytes("$missingConfigRestoreArchive.appearance.json")))) {
    throw 'missing-config-restore-stopped-retry changed fixed completion proof.'
  }

  $missingConfigRestoreUnauthorized = New-RealLifecycleCase `
    -Name 'missing-config-restore-running-unauthorized'
  Remove-Item -LiteralPath (Join-Path $missingConfigRestoreUnauthorized.UserProfile '.codex\config.toml') -Force
  $missingConfigStateBefore = @(Get-StateSnapshot -Root $missingConfigRestoreUnauthorized.StateRoot)
  $realResult = Invoke-RealLifecycle -Case $missingConfigRestoreUnauthorized `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-restore-running-unauthorized' `
    -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'stop:False' -or
    $realResult.Trace -contains 'restore-config' -or (Test-Path -LiteralPath `
      (Join-Path $missingConfigRestoreUnauthorized.UserProfile '.codex\config.toml'))) {
    throw 'missing-config-restore-running-unauthorized crossed its close boundary.'
  }
  Assert-Equal (Get-StateSnapshot -Root $missingConfigRestoreUnauthorized.StateRoot) `
    $missingConfigStateBefore 'Unauthorized running first-run Restore changed recovery state.'

  $missingConfigRestoreAuthorized = New-RealLifecycleCase `
    -Name 'missing-config-restore-running-authorized'
  Remove-Item -LiteralPath (Join-Path $missingConfigRestoreAuthorized.UserProfile '.codex\config.toml') -Force
  $realResult = Invoke-RealLifecycle -Case $missingConfigRestoreAuthorized `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-restore-running-authorized' `
    -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  Assert-RealMissingConfigCompletion -Case $missingConfigRestoreAuthorized -Result $realResult -ExpectedClose `
    -Message 'missing-config-restore-running-authorized failed, created config, or relaunched Codex.'

  foreach ($completeBoundaryKind in @('config', 'parent', 'junction')) {
    $completeBoundaryCase = New-RealLifecycleCase `
      -Name "missing-config-complete-boundary-$completeBoundaryKind"
    $completeBoundaryConfigDirectory = Join-Path $completeBoundaryCase.UserProfile '.codex'
    $completeBoundaryConfig = Join-Path $completeBoundaryConfigDirectory 'config.toml'
    Remove-Item -LiteralPath $completeBoundaryConfig -Force
    if ($completeBoundaryKind -in @('parent', 'junction')) {
      Remove-Item -LiteralPath $completeBoundaryConfigDirectory -Recurse -Force
    }
    $completeBoundaryState = @(Get-StateSnapshot -Root $completeBoundaryCase.StateRoot)
    $realResult = Invoke-RealLifecycle -Case $completeBoundaryCase `
      -ScriptName 'restore-dream-skin.ps1' `
      -Scenario "missing-config-complete-boundary-$completeBoundaryKind" `
      -Arguments @('-RestoreBaseTheme', '-NoRelaunch')
    if ($realResult.ExitCode -eq 0 -or
      $realResult.Trace -notcontains 'complete-boundary:before') {
      throw "missing-config-complete-boundary-$completeBoundaryKind crossed the Complete boundary."
    }
    Assert-Equal (Get-StateSnapshot -Root $completeBoundaryCase.StateRoot) $completeBoundaryState `
      "missing-config-complete-boundary-$completeBoundaryKind did not compensate lifecycle artifacts."
    if ($completeBoundaryKind -ceq 'config') {
      if ([IO.File]::ReadAllText($completeBoundaryConfig) -cne 'complete-boundary config creator') {
        throw 'missing-config-complete-boundary-config did not preserve the unexpected creator.'
      }
    } else {
      $completeBoundaryItem = Get-Item -LiteralPath $completeBoundaryConfigDirectory -Force
      $isReparse = ($completeBoundaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
      if (($completeBoundaryKind -ceq 'junction') -ne $isReparse) {
        throw "missing-config-complete-boundary-$completeBoundaryKind changed the appeared component."
      }
    }
  }

  $postCompleteCase = New-RealLifecycleCase -Name 'missing-config-complete-boundary-post-complete'
  $postCompleteConfig = Join-Path $postCompleteCase.UserProfile '.codex\config.toml'
  Remove-Item -LiteralPath $postCompleteConfig -Force
  $realResult = Invoke-RealLifecycle -Case $postCompleteCase -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'missing-config-complete-boundary-post-complete' `
    -Arguments @('-RestoreBaseTheme', '-NoRelaunch')
  $postCompleteBackup = Join-Path $postCompleteCase.StateRoot 'config.before-dream-skin.toml'
  $postCompleteArchive = Join-Path $postCompleteCase.StateRoot 'config.restored.toml'
  if ($realResult.ExitCode -ne 0 -or
    [IO.File]::ReadAllText($postCompleteConfig) -cne 'complete-boundary post-complete creator' -or
    (Test-Path -LiteralPath $postCompleteBackup) -or
    -not (Test-Path -LiteralPath $postCompleteArchive -PathType Leaf)) {
    throw 'missing-config-complete-boundary post-Complete creator was reinterpreted as transaction failure.'
  }

  $missingConfigUninstallStopped = New-RealLifecycleCase -Name 'missing-config-uninstall-stopped-first'
  Remove-Item -LiteralPath (Join-Path $missingConfigUninstallStopped.UserProfile '.codex\config.toml') -Force
  $realResult = Invoke-RealLifecycle -Case $missingConfigUninstallStopped `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-uninstall-stopped-first' `
    -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
  Assert-RealMissingConfigCompletion -Case $missingConfigUninstallStopped -Result $realResult `
    -Message 'missing-config-uninstall-stopped-first failed or created config.'
  $missingConfigUninstallArchive = Join-Path $missingConfigUninstallStopped.StateRoot 'config.restored.toml'
  $uninstallArchiveBytes = [IO.File]::ReadAllBytes($missingConfigUninstallArchive)
  [IO.File]::WriteAllText($missingConfigUninstallStopped.TracePath, '', $utf8NoBom)
  $realResult = Invoke-RealLifecycle -Case $missingConfigUninstallStopped `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-uninstall-stopped-retry' `
    -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
  Assert-RealMissingConfigCompletion -Case $missingConfigUninstallStopped -Result $realResult `
    -Message 'missing-config-uninstall-stopped-retry failed or created config.'
  if ($realResult.Trace -contains 'archive-backup' -or
    -not (Test-DreamSkinBytesEqual -Left $uninstallArchiveBytes `
      -Right ([IO.File]::ReadAllBytes($missingConfigUninstallArchive)))) {
    throw 'missing-config-uninstall-stopped-retry changed fixed completion proof.'
  }

  $missingConfigUninstallUnauthorized = New-RealLifecycleCase `
    -Name 'missing-config-uninstall-running-unauthorized'
  Remove-Item -LiteralPath (Join-Path $missingConfigUninstallUnauthorized.UserProfile '.codex\config.toml') -Force
  $missingConfigStateBefore = @(Get-StateSnapshot -Root $missingConfigUninstallUnauthorized.StateRoot)
  $realResult = Invoke-RealLifecycle -Case $missingConfigUninstallUnauthorized `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-uninstall-running-unauthorized' `
    -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'stop:False' -or
    $realResult.Trace -contains 'restore-config' -or (Test-Path -LiteralPath `
      (Join-Path $missingConfigUninstallUnauthorized.UserProfile '.codex\config.toml'))) {
    throw 'missing-config-uninstall-running-unauthorized crossed its close boundary.'
  }
  Assert-Equal (Get-StateSnapshot -Root $missingConfigUninstallUnauthorized.StateRoot) `
    $missingConfigStateBefore 'Unauthorized running first-run Uninstall changed recovery state.'

  $missingConfigUninstallAuthorized = New-RealLifecycleCase `
    -Name 'missing-config-uninstall-running-authorized'
  Remove-Item -LiteralPath (Join-Path $missingConfigUninstallAuthorized.UserProfile '.codex\config.toml') -Force
  $realResult = Invoke-RealLifecycle -Case $missingConfigUninstallAuthorized `
    -ScriptName 'restore-dream-skin.ps1' -Scenario 'missing-config-uninstall-running-authorized' `
    -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch', '-CloseRunning')
  Assert-RealMissingConfigCompletion -Case $missingConfigUninstallAuthorized -Result $realResult -ExpectedClose `
    -Message 'missing-config-uninstall-running-authorized failed or created config.'

  $directOrphanMarker = New-RealLifecycleCase -Name 'direct-restore-orphan-marker'
  $directConfig = Join-Path $directOrphanMarker.UserProfile '.codex\config.toml'
  $directBackup = Join-Path $directOrphanMarker.StateRoot 'config.before-dream-skin.toml'
  $directMarker = "$directBackup.appearance.json"
  $directArchive = Join-Path $directOrphanMarker.StateRoot 'config.restored.toml'
  $directState = Join-Path $directOrphanMarker.StateRoot 'state.json'
  [IO.File]::WriteAllText($directArchive, 'completed-backup', $utf8NoBom)
  Remove-Item -LiteralPath $directBackup -Force
  Remove-Item -LiteralPath $directState -Force
  $directConfigBytes = [IO.File]::ReadAllBytes($directConfig)
  $directStateSnapshot = @(Get-StateSnapshot -Root $directOrphanMarker.StateRoot)
  $realResult = Invoke-RealLifecycle -Case $directOrphanMarker -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'direct-restore-orphan-marker' -Arguments @('-RestoreBaseTheme')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'restore-config' -or
    $realResult.Trace -contains 'archive-backup' -or -not (Test-Path -LiteralPath $directMarker)) {
    throw 'Direct restore treated archive plus an orphan live marker as a completed restore.'
  }
  if ([Convert]::ToBase64String($directConfigBytes) -cne
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($directConfig))) {
    throw 'Direct restore with an orphan live marker changed config bytes.'
  }
  Assert-Equal (Get-StateSnapshot -Root $directOrphanMarker.StateRoot) $directStateSnapshot `
    'Direct restore with an orphan live marker changed marker or archive bytes.'

  $realPausedFailure = New-RealLifecycleCase -Name 'restore-paused-unlink-failure'
  $realConfig = Join-Path $realPausedFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realPausedFailure.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realPausedFailure.StateRoot 'config.restored.toml'
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
    'restore-config', 'archive-backup', "remove:$realPaused", 'config-rollback'
  ) -Message 'Pause cleanup failure did not roll config and published proof back before relaunch.'

  $realRestoreFailure = New-RealLifecycleCase -Name 'restore-archive-failure'
  $realConfig = Join-Path $realRestoreFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realRestoreFailure.StateRoot 'config.before-dream-skin.toml'
  $realArchive = Join-Path $realRestoreFailure.StateRoot 'config.restored.toml'
  $realPaused = Join-Path $realRestoreFailure.StateRoot 'paused'
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realRestoreFailure
  $realResult = Invoke-RealLifecycle -Case $realRestoreFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-archive-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realPaused" -or
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
    'restore-config', 'archive-backup', "remove:$realPaused", "remove:$realBackupMarker",
    'config-rollback'
  ) -Message 'Backup marker cleanup failure crossed or escaped the restore transaction.'

  $realBackupFailure = New-RealLifecycleCase -Name 'restore-backup-unlink-failure'
  $realBackup = Join-Path $realBackupFailure.StateRoot 'config.before-dream-skin.toml'
  $realBackupMarker = "$realBackup.appearance.json"
  $realPaused = Join-Path $realBackupFailure.StateRoot 'paused'
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realBackupFailure
  $realMarkerBytes = [IO.File]::ReadAllBytes($realBackupMarker)
  $realResult = Invoke-RealLifecycle -Case $realBackupFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-backup-unlink-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains 'start-process' -or
    -not (Test-Path -LiteralPath $realBackupMarker) -or
    [Convert]::ToBase64String($realMarkerBytes) -cne
      [Convert]::ToBase64String([IO.File]::ReadAllBytes($realBackupMarker))) {
    throw 'Live-backup cleanup failure did not restore the already-removed live marker exactly.'
  }
  Assert-RealRestoreRolledBack -Case $realBackupFailure -Baseline $realBaseline `
    -Message 'Live-backup cleanup failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'restore-config', 'archive-backup', 'archive-marker', "remove:$realPaused", "remove:$realBackupMarker",
    "remove:$realBackup", 'config-rollback'
  ) -Message 'Live-backup cleanup failure crossed or escaped the restore transaction.'

  $realArchiveMarkerPublishFailure = New-RealLifecycleCase -Name 'restore-archive-marker-publish-failure'
  $realPaused = Join-Path $realArchiveMarkerPublishFailure.StateRoot 'paused'
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realArchiveMarkerPublishFailure
  $realResult = Invoke-RealLifecycle -Case $realArchiveMarkerPublishFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-archive-marker-publish-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realPaused" -or
    $realResult.Trace -contains 'start-process') {
    throw 'Archive-marker publication failure crossed the restore cleanup or relaunch boundary.'
  }
  Assert-RealRestoreRolledBack -Case $realArchiveMarkerPublishFailure -Baseline $realBaseline `
    -Message 'Archive-marker publication failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'restore-config', 'archive-backup', 'archive-marker', 'config-rollback'
  ) -Message 'Archive-marker publication failure did not roll back before cleanup or relaunch.'

  $realArchiveMarkerUnlinkFailure = New-RealLifecycleCase -Name 'restore-archive-marker-unlink-failure'
  $realBackup = Join-Path $realArchiveMarkerUnlinkFailure.StateRoot 'config.before-dream-skin.toml'
  $realBackupMarker = "$realBackup.appearance.json"
  $realArchive = Join-Path $realArchiveMarkerUnlinkFailure.StateRoot 'config.restored.toml'
  $realArchiveMarker = "$realArchive.appearance.json"
  $realPaused = Join-Path $realArchiveMarkerUnlinkFailure.StateRoot 'paused'
  Remove-Item -LiteralPath $realBackupMarker -Force
  $realBaseline = New-RealRestoreRollbackBaseline -Case $realArchiveMarkerUnlinkFailure
  $realResult = Invoke-RealLifecycle -Case $realArchiveMarkerUnlinkFailure -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-restore-archive-marker-unlink-fail' -Arguments @('-RestoreBaseTheme', '-CloseRunning')
  if ($realResult.ExitCode -eq 0 -or $realResult.Trace -contains "remove:$realPaused" -or
    $realResult.Trace -contains 'start-process') {
    throw 'Archive-marker removal failure crossed the restore cleanup or relaunch boundary.'
  }
  Assert-RealRestoreRolledBack -Case $realArchiveMarkerUnlinkFailure -Baseline $realBaseline `
    -Message 'Archive-marker removal failure did not restore every entry artifact exactly.'
  Assert-TraceOrder -Trace $realResult.Trace -Expected @(
    'restore-config', 'archive-backup', "remove:$realArchiveMarker", 'config-rollback'
  ) -Message 'Archive-marker removal failure did not roll back before cleanup or relaunch.'

  $realConfig = Join-Path $realMarkerFailure.UserProfile '.codex\config.toml'
  $realBackup = Join-Path $realMarkerFailure.StateRoot 'config.before-dream-skin.toml'
  $realBackupMarker = "$realBackup.appearance.json"
  $realArchive = Join-Path $realMarkerFailure.StateRoot 'config.restored.toml'
  $realArchiveMarker = "$realArchive.appearance.json"
  $realState = Join-Path $realMarkerFailure.StateRoot 'state.json'
  $realPaused = Join-Path $realMarkerFailure.StateRoot 'paused'
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
  if ($realResult.ExitCode -ne 0 -or $realResult.Trace -contains 'start-process' -or
    (Test-Path -LiteralPath $realUninstall.ManagedShortcutPath) -or
    -not (Test-Path -LiteralPath $realUninstall.UnrelatedShortcutPath)) {
    throw 'Production uninstall relaunched Codex or failed its restore.'
  }
  $restoreIndex = [Array]::IndexOf($realResult.Trace, 'restore-config')
  $archiveIndex = [Array]::IndexOf($realResult.Trace, 'archive-backup')
  $shortcutIndex = [Array]::IndexOf($realResult.Trace, "remove:$($realUninstall.ManagedShortcutPath)")
  if ($restoreIndex -lt 0 -or $archiveIndex -le $restoreIndex -or $shortcutIndex -le $archiveIndex) {
    throw 'Production uninstall removed shortcuts before restore and backup completion.'
  }

  $realUninstallForce = New-RealLifecycleCase -Name 'uninstall-force'
  $realResult = Invoke-RealLifecycle -Case $realUninstallForce -ScriptName 'restore-dream-skin.ps1' `
    -Scenario 'real-uninstall-force' `
    -Arguments @('-RestoreBaseTheme', '-Uninstall', '-NoRelaunch', '-CloseRunning', '-ForceRestart')
  if ($realResult.ExitCode -ne 0 -or $realResult.Trace -contains 'start-process' -or
    (Test-Path -LiteralPath $realUninstallForce.ManagedShortcutPath) -or
    -not (Test-Path -LiteralPath $realUninstallForce.UnrelatedShortcutPath)) {
    throw 'Production uninstall rejected authorized force or relaunched Codex.'
  }
  Assert-TraceOrder -Trace $realResult.Trace `
    -Expected @('stop:True', 'restore-config', 'archive-backup', "remove:$($realUninstallForce.ManagedShortcutPath)") `
    -Message 'Production uninstall did not stop Codex before restore and shortcut cleanup.'

  Assert-Equal (Get-StateSnapshot -Root $realRoot) $realEngineSnapshot `
    'Lifecycle success and rollback paths changed the versioned engine.'

  Write-Host 'PASS: Windows Studio status and lifecycle protocol.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
