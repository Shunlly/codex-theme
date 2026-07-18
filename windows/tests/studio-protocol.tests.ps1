[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dream-skin-studio-tests-$PID-$([guid]::NewGuid().ToString('N'))"
$versionRoot = Join-Path $temporaryRoot 'release\1.3.0'
$engineRoot = Join-Path $versionRoot 'engine'
$scriptsRoot = Join-Path $engineRoot 'scripts'
$adapterPath = Join-Path $scriptsRoot 'studio-adapter.ps1'
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
  if ((ConvertTo-Json -InputObject @($Actual) -Compress) -cne (ConvertTo-Json -InputObject @($Expected) -Compress)) { throw $Message }
}

function New-CaseRoot {
  param([Parameter(Mandatory = $true)][string]$Name, [switch]$NoConfig, [switch]$NoState, [switch]$DamagedState)
  $caseRoot = Join-Path $temporaryRoot "cases\$Name"
  $localAppData = Join-Path $caseRoot 'local-app-data'
  $userProfile = Join-Path $caseRoot 'profile'
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
      $state = [ordered]@{
        schemaVersion = 3
        platform = 'windows'
        port = 9335
        injectorPid = 4242
        injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
        injectorPath = (Join-Path $scriptsRoot 'injector.mjs')
        nodePath = (Join-Path $engineRoot 'runtime\node.exe')
        codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'
        codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'
        codexPackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
        codexPackageFamilyName = 'OpenAI.Codex_test'
        browserId = 'browser-123'
      }
      [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Compress), $utf8NoBom)
    }
  }
  return [pscustomobject]@{ Root = $caseRoot; LocalAppData = $localAppData; UserProfile = $userProfile; StateRoot = $stateRoot }
}

function Invoke-Studio {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$Operation = 'status',
    [string[]]$ExtraArguments = @()
  )
  $stdoutPath = Join-Path $Case.Root "stdout-$([guid]::NewGuid().ToString('N')).txt"
  $stderrPath = Join-Path $Case.Root "stderr-$([guid]::NewGuid().ToString('N')).txt"
  $savedLocalAppData = $env:LOCALAPPDATA
  $savedUserProfile = $env:USERPROFILE
  $savedScenario = $env:DREAM_SKIN_TEST_SCENARIO
  try {
    $env:LOCALAPPDATA = $Case.LocalAppData
    $env:USERPROFILE = $Case.UserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $Scenario
    $arguments = @('-NoProfile', '-File', $adapterPath, '-Operation', $Operation) + $ExtraArguments
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  } finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:USERPROFILE = $savedUserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $savedScenario
  }
  $stdoutBytes = [IO.File]::ReadAllBytes($stdoutPath)
  if ($stdoutBytes.Length -ge 3 -and $stdoutBytes[0] -eq 0xEF -and $stdoutBytes[1] -eq 0xBB -and $stdoutBytes[2] -eq 0xBF) {
    throw 'Studio stdout contains a UTF-8 BOM.'
  }
  $stdout = [Text.Encoding]::UTF8.GetString($stdoutBytes).TrimEnd([char[]]@("`r", "`n"))
  if (-not $stdout -or ($stdout -split "`r?`n").Count -ne 1) { throw 'Studio stdout is not exactly one JSON line.' }
  try { $envelope = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Studio stdout is not valid JSON.' }
  if ($stdout -match '(?i)(?:port|pid|path|cdp|powershell|[A-Z]:\\Users\\)' -or $stdout.Contains($Case.UserProfile)) {
    throw 'Studio envelope leaks an internal field or user profile path.'
  }
  $stderr = [IO.File]::ReadAllText($stderrPath).TrimEnd([char[]]@("`r", "`n"))
  if ($stderr -and $stderr -cne 'DREAM_SKIN_PROGRESS checking') { throw "Unexpected Studio stderr: $stderr" }
  if (-not $stderr -and ($null -eq $envelope.error -or $envelope.error.code -cne 'INVALID_REQUEST')) {
    throw 'Studio status omitted its progress marker.'
  }
  return [pscustomobject]@{ ExitCode = $process.ExitCode; Envelope = $envelope; Raw = $stdout }
}

function Assert-EnvelopeShape {
  param([Parameter(Mandatory = $true)][object]$Envelope)
  Assert-Equal @($Envelope.PSObject.Properties.Name | Sort-Object) @('error', 'ok', 'operation', 'schemaVersion', 'state') 'Unexpected envelope keys.'
  Assert-Equal @($Envelope.state.PSObject.Properties.Name | Sort-Object) @('availableActions', 'codex', 'install', 'operation', 'requiresRestart', 'session', 'themeName', 'verified') 'Unexpected state keys.'
  if ($Envelope.schemaVersion -ne 1) { throw 'Unexpected Studio schema version.' }
  if ($Envelope.operation -notin @('preflight', 'install', 'apply', 'status', 'pause', 'resume', 'restore', 'verify', 'uninstall') -or
    $Envelope.state.install -notin @('not-installed', 'ready') -or
    $Envelope.state.codex -notin @('not-installed', 'needs-first-run', 'stopped', 'running') -or
    $Envelope.state.session -notin @('official', 'active', 'paused', 'stale') -or
    $Envelope.state.operation -notin @('idle', 'busy')) {
    throw 'Studio envelope contains an out-of-protocol enum.'
  }
  $actions = @($Envelope.state.availableActions)
  if (@($actions | Select-Object -Unique).Count -ne $actions.Count -or
    @($actions | Where-Object { $_ -notin @('install', 'apply', 'pause', 'resume', 'restore', 'verify', 'uninstall') }).Count -gt 0) {
    throw 'Studio envelope contains invalid or duplicate available actions.'
  }
  if ($null -ne $Envelope.error) {
    Assert-Equal @($Envelope.error.PSObject.Properties.Name | Sort-Object) @('code', 'message', 'recoveryActions') 'Unexpected error keys.'
  }
}

New-Item -ItemType Directory -Path (Join-Path $engineRoot 'runtime') -Force | Out-Null
New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'scripts\studio-windows.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\status-dream-skin.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\studio-adapter.ps1') -Destination $scriptsRoot
[IO.File]::WriteAllText((Join-Path $engineRoot 'VERSION'), '1.3.0', $utf8NoBom)
[IO.File]::WriteAllBytes((Join-Path $engineRoot 'runtime\node.exe'), [byte[]](1))
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'start-dream-skin.ps1'), '# staged readable start', $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'restore-dream-skin.ps1'), '# staged readable restore', $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'injector.mjs'), '// staged injector', $utf8NoBom)

$commonStub = @'
function Enter-DreamSkinOperationLock {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $mutex = [Threading.Mutex]::new($false, "Local\CodexDreamSkin.$sid.Operation")
  try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { $mutex.Dispose(); throw 'busy' }
  return $mutex
}
function Exit-DreamSkinOperationLock { param([Threading.Mutex]$Mutex) try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
function Get-DreamSkinRegisteredCodexInstalls {
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'missing-codex') { return @() }
  return @([pscustomobject]@{ Executable = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'; PackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'; PackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'; PackageFamilyName = 'OpenAI.Codex_test' })
}
function Get-DreamSkinCodexProcesses {
  param([object]$Codex)
  if ($env:DREAM_SKIN_TEST_SCENARIO -in @('running', 'active', 'paused', 'stale', 'reused', 'damaged', 'deep', 'busy')) { return @([pscustomobject]@{ ProcessId = 5151 }) }
  return @()
}
function Read-DreamSkinState {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop) } catch { throw 'damaged state' }
}
function Get-CimInstance {
  param([string]$ClassName, [string]$Filter, [object]$ErrorAction)
  if ($ClassName -ne 'Win32_Process' -or $env:DREAM_SKIN_TEST_SCENARIO -eq 'stale') { return $null }
  $node = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe'
  $injector = Join-Path $PSScriptRoot 'injector.mjs'
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'reused') {
    return [pscustomobject]@{ ProcessId = 4242; ExecutablePath = $null; CommandLine = "`"$node`" unrelated.mjs --watch --port 9335 --browser-id browser-123" }
  }
  return [pscustomobject]@{ ProcessId = 4242; ExecutablePath = $null; CommandLine = "`"$node`" `"$injector`" --watch --port 9335 --browser-id browser-123" }
}
function Get-DreamSkinProcessExecutablePath { param([object]$ProcessInfo) return (Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe') }
function Get-DreamSkinProcessStartedAt { param([int]$ProcessId) return '2026-01-01T00:00:00.0000000Z' }
function Test-DreamSkinPathEqual { param([string]$Left, [string]$Right) try { return [IO.Path]::GetFullPath($Left) -ieq [IO.Path]::GetFullPath($Right) } catch { return $false } }
function Test-DreamSkinCommandLineToken { param([string]$CommandLine, [string]$Token) return $CommandLine.Contains($Token) }
function Test-DreamSkinBrowserId { param([string]$Value) return $Value -cmatch '^[A-Za-z0-9._-]+$' }
function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [object]$Codex)
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'deep') { return [pscustomobject]@{ BrowserId = 'browser-123' } }
  return $null
}
'@
$themeStub = @'
function Get-DreamSkinThemePaths {
  param([string]$StateRoot = (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'))
  return [pscustomobject]@{ Root = $StateRoot; Active = (Join-Path $StateRoot 'active-theme'); PauseFile = (Join-Path $StateRoot 'paused'); State = (Join-Path $StateRoot 'state.json') }
}
function Read-DreamSkinTheme {
  param([string]$ThemeDirectory, [switch]$SkipImageMetadata)
  $theme = [IO.File]::ReadAllText((Join-Path $ThemeDirectory 'theme.json'), [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json -ErrorAction Stop
  return [pscustomobject]@{ Theme = $theme }
}
function Test-DreamSkinPaused { param([string]$StateRoot) return (Test-Path -LiteralPath (Join-Path $StateRoot 'paused') -PathType Leaf) }
'@
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'common-windows.ps1'), $commonStub, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'theme-windows.ps1'), $themeStub, $utf8NoBom)

try {
  $cases = @(
    @{ Name = 'missing-codex'; Args = @{ NoState = $true }; ExpectedExit = 1; Codex = 'not-installed'; Session = 'official'; Error = 'CODEX_NOT_INSTALLED' },
    @{ Name = 'missing-config'; Args = @{ NoConfig = $true; NoState = $true }; ExpectedExit = 1; Codex = 'needs-first-run'; Session = 'official'; Error = 'CODEX_FIRST_RUN_REQUIRED' },
    @{ Name = 'stopped'; Args = @{ NoState = $true }; ExpectedExit = 0; Codex = 'stopped'; Session = 'official'; Error = $null },
    @{ Name = 'running'; Args = @{ NoState = $true }; ExpectedExit = 0; Codex = 'running'; Session = 'official'; Error = $null },
    @{ Name = 'active'; Args = @{}; ExpectedExit = 0; Codex = 'running'; Session = 'active'; Error = $null },
    @{ Name = 'stale'; Args = @{}; ExpectedExit = 1; Codex = 'running'; Session = 'stale'; Error = 'STATE_UNSAFE' },
    @{ Name = 'reused'; Args = @{}; ExpectedExit = 1; Codex = 'running'; Session = 'stale'; Error = 'STATE_UNSAFE' },
    @{ Name = 'damaged'; Args = @{ DamagedState = $true }; ExpectedExit = 1; Codex = 'running'; Session = 'stale'; Error = 'STATE_UNSAFE' }
  )
  foreach ($definition in $cases) {
    $caseArguments = $definition.Args
    $case = New-CaseRoot -Name $definition.Name @caseArguments
    $before = Get-StateSnapshot -Root $case.StateRoot
    $result = Invoke-Studio -Case $case -Scenario $definition.Name
    $after = Get-StateSnapshot -Root $case.StateRoot
    Assert-Equal $after $before "Status mutated state for $($definition.Name)."
    Assert-EnvelopeShape -Envelope $result.Envelope
    if ($result.ExitCode -ne $definition.ExpectedExit -or $result.Envelope.operation -cne 'status' -or
      $result.Envelope.state.install -cne 'ready' -or $result.Envelope.state.codex -cne $definition.Codex -or
      $result.Envelope.state.session -cne $definition.Session -or $result.Envelope.state.themeName -cne '午夜极光') {
      throw "Unexpected status mapping for $($definition.Name)."
    }
    if ($null -ne $result.Envelope.state.verified -or $result.Envelope.state.operation -cne 'idle') {
      throw "Shallow status reported verification or a non-idle operation for $($definition.Name)."
    }
    $errorCode = if ($null -eq $result.Envelope.error) { $null } else { $result.Envelope.error.code }
    if ($errorCode -cne $definition.Error) { throw "Unexpected error mapping for $($definition.Name)." }
  }

  $paused = New-CaseRoot -Name 'paused' -NoState
  [IO.File]::WriteAllText((Join-Path $paused.StateRoot 'paused'), "paused`r`n", $utf8NoBom)
  $before = Get-StateSnapshot -Root $paused.StateRoot
  $pausedResult = Invoke-Studio -Case $paused -Scenario 'paused'
  Assert-Equal (Get-StateSnapshot -Root $paused.StateRoot) $before 'Paused status mutated state.'
  if ($pausedResult.ExitCode -ne 0 -or $pausedResult.Envelope.state.session -cne 'paused') { throw 'Paused marker was not reported.' }

  $deep = New-CaseRoot -Name 'deep'
  $before = Get-StateSnapshot -Root $deep.StateRoot
  $deepResult = Invoke-Studio -Case $deep -Scenario 'deep' -ExtraArguments @('-Deep')
  Assert-Equal (Get-StateSnapshot -Root $deep.StateRoot) $before 'Deep status mutated state.'
  if ($deepResult.Envelope.state.verified -eq $true) { throw 'A soft CDP probe produced verified=true.' }

  $preflight = New-CaseRoot -Name 'preflight' -NoState
  $before = Get-StateSnapshot -Root $preflight.StateRoot
  $preflightResult = Invoke-Studio -Case $preflight -Scenario 'stopped' -Operation 'preflight'
  Assert-Equal (Get-StateSnapshot -Root $preflight.StateRoot) $before 'Preflight mutated state.'
  if ($preflightResult.ExitCode -ne 0 -or $preflightResult.Envelope.operation -cne 'preflight') { throw 'Preflight did not use the shared status mapping.' }

  $incomplete = New-CaseRoot -Name 'incomplete-install' -NoState
  $runtimePath = Join-Path $engineRoot 'runtime\node.exe'
  $heldRuntimePath = "$runtimePath.staged"
  Move-Item -LiteralPath $runtimePath -Destination $heldRuntimePath
  try {
    $before = Get-StateSnapshot -Root $incomplete.StateRoot
    $incompleteResult = Invoke-Studio -Case $incomplete -Scenario 'stopped'
    Assert-Equal (Get-StateSnapshot -Root $incomplete.StateRoot) $before 'Incomplete-install status mutated state.'
  } finally {
    Move-Item -LiteralPath $heldRuntimePath -Destination $runtimePath
  }
  if ($incompleteResult.ExitCode -ne 0 -or $incompleteResult.Envelope.state.install -cne 'not-installed') {
    throw 'The fixed engine layout accepted a missing private runtime.'
  }

  $busy = New-CaseRoot -Name 'busy' -NoState
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
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
  if ($busyResult.ExitCode -ne 1 -or $busyResult.Envelope.state.operation -cne 'busy' -or
    $busyResult.Envelope.error.code -cne 'OPERATION_BUSY') { throw 'Operation mutex busy was not reported.' }

  $invalid = New-CaseRoot -Name 'invalid' -NoState
  foreach ($operation in @('install', 'apply', 'pause', 'resume', 'restore', 'verify', 'uninstall')) {
    $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -Operation $operation
    if ($result.ExitCode -ne 2 -or $result.Envelope.error.code -cne 'INVALID_REQUEST') { throw "$operation is not rejected for Task 6." }
  }
  foreach ($invalidRequest in @(
    @{ Operation = 'status'; Arguments = @('-DeleteUserThemes') },
    @{ Operation = 'status'; Arguments = @('-ForceAuthorized') },
    @{ Operation = 'preflight'; Arguments = @('-RestartAuthorized') }
  )) {
    $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -Operation $invalidRequest.Operation -ExtraArguments $invalidRequest.Arguments
    if ($result.ExitCode -ne 2 -or $result.Envelope.error.code -cne 'INVALID_REQUEST') { throw 'Invalid request flags were accepted.' }
  }

  Write-Host 'PASS: Windows Studio status protocol.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
