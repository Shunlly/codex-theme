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
  return [pscustomobject]@{ Root = $caseRoot; LocalAppData = $localAppData; UserProfile = $userProfile; StateRoot = $stateRoot }
}

function Start-StudioProcess {
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
  $savedInjector = $env:DREAM_SKIN_TEST_INJECTOR
  $savedSignal = $env:DREAM_SKIN_TEST_SIGNAL
  try {
    $env:LOCALAPPDATA = $Case.LocalAppData
    $env:USERPROFILE = $Case.UserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $Scenario
    $env:DREAM_SKIN_TEST_INJECTOR = $injectorPath
    $env:DREAM_SKIN_TEST_SIGNAL = Join-Path $Case.Root 'probe-entered'
    $argumentLine = "-NoProfile -File `"$adapterPath`" -Operation $Operation"
    if ($ExtraArguments.Count -gt 0) { $argumentLine += ' ' + ($ExtraArguments -join ' ') }
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -PassThru `
      -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  } finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    $env:USERPROFILE = $savedUserProfile
    $env:DREAM_SKIN_TEST_SCENARIO = $savedScenario
    $env:DREAM_SKIN_TEST_INJECTOR = $savedInjector
    $env:DREAM_SKIN_TEST_SIGNAL = $savedSignal
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
  if ($stderr -and $stderr -cne 'DREAM_SKIN_PROGRESS checking') { throw "Unexpected Studio stderr: $stderr" }
  if (-not $stderr -and ($null -eq $envelope.error -or $envelope.error.code -cne 'INVALID_REQUEST')) {
    throw 'Studio status omitted its progress marker.'
  }
  return [pscustomobject]@{ ExitCode = $Invocation.Process.ExitCode; Envelope = $envelope; Raw = $stdout }
}

function Invoke-Studio {
  param(
    [Parameter(Mandatory = $true)][object]$Case,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$Operation = 'status',
    [string[]]$ExtraArguments = @()
  )
  $invocation = Start-StudioProcess -Case $Case -Scenario $Scenario -Operation $Operation -ExtraArguments $ExtraArguments
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

New-Item -ItemType Directory -Path (Join-Path $engineRoot 'runtime') -Force | Out-Null
New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $Root 'scripts\studio-windows.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\status-dream-skin.ps1') -Destination $scriptsRoot
Copy-Item -LiteralPath (Join-Path $Root 'scripts\studio-adapter.ps1') -Destination $scriptsRoot
[IO.File]::WriteAllText((Join-Path $engineRoot 'VERSION'), '1.3.0', $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'start-dream-skin.ps1'), '# staged readable start', $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $scriptsRoot 'restore-dream-skin.ps1'), '# staged readable restore', $utf8NoBom)
[IO.File]::WriteAllText($injectorPath, '// staged injector', $utf8NoBom)

$fakeNodeSource = @'
using System;
using System.IO;

public static class StudioFakeNode {
  public static int Main(string[] args) {
    string expectedInjector = Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_INJECTOR");
    bool exact = args.Length == 8 &&
      String.Equals(Path.GetFullPath(args[0]), Path.GetFullPath(expectedInjector), StringComparison.OrdinalIgnoreCase) &&
      args[1] == "--verify" && args[2] == "--port" && args[3] == "9335" &&
      args[4] == "--browser-id" && args[5] == "browser-123" &&
      args[6] == "--timeout-ms" && args[7] == "5000";
    if (!exact) return 8;
    return Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_SCENARIO") == "renderer-pass" ? 0 : 9;
  }
}
'@
Add-Type -TypeDefinition $fakeNodeSource -OutputAssembly $nodePath -OutputType ConsoleApplication | Out-Null

$commonStub = @'
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
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'process-error') { throw 'process probe failed' }
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'mutex-hold') {
    [IO.File]::WriteAllText($env:DREAM_SKIN_TEST_SIGNAL, 'entered')
    Start-Sleep -Milliseconds 1500
  }
  $running = $env:DREAM_SKIN_TEST_SCENARIO -in @('running', 'active', 'stale', 'reused', 'damaged', 'renderer-pass', 'browser-mismatch', 'renderer-fail', 'mutex-hold')
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
  if ($ClassName -ne 'Win32_Process' -or $env:DREAM_SKIN_TEST_SCENARIO -eq 'stale') { return $null }
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
function Get-DreamSkinVerifiedCdpIdentity {
  param([int]$Port, [object]$Codex)
  if ($env:DREAM_SKIN_TEST_SCENARIO -eq 'browser-mismatch') { return [pscustomobject]@{ BrowserId = 'browser-other' } }
  if ($env:DREAM_SKIN_TEST_SCENARIO -in @('renderer-pass', 'renderer-fail')) { return [pscustomobject]@{ BrowserId = 'browser-123' } }
  return $null
}
function Get-DreamSkinNodeRuntime {
  param([int]$MinimumMajor = 22, [string]$NodePath)
  $expected = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\node.exe'
  if (-not (Test-DreamSkinPathEqual -Left $NodePath -Right $expected)) { throw 'Deep status did not use the fixed private runtime.' }
  return [pscustomobject]@{ Path = $NodePath; Version = '22.0.0'; Major = 22 }
}
'@
$themeStub = @'
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
    @{ Name = 'stale'; Args = @{}; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('apply', 'restore', 'verify', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') },
    @{ Name = 'reused'; Args = @{}; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('apply', 'restore', 'verify', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') },
    @{ Name = 'damaged'; Args = @{ DamagedState = $true }; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('apply', 'restore', 'verify', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') },
    @{ Name = 'secondary-install'; Args = @{ SecondaryState = $true }; Exit = 0; Ok = $true; Codex = 'running'; Session = 'active'; Restart = $false; Actions = @('pause', 'resume', 'restore', 'verify', 'uninstall'); Error = $null; Recovery = @() },
    @{ Name = 'saved-stopped'; Args = @{ SecondaryState = $true }; Exit = 1; Ok = $false; Codex = 'running'; Session = 'stale'; Restart = $false; Actions = @('apply', 'restore', 'verify', 'uninstall'); Error = 'STATE_UNSAFE'; Recovery = @('restore', 'diagnostics', 'cancel') }
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
  foreach ($operation in @('install', 'apply', 'pause', 'resume', 'restore', 'verify', 'uninstall')) {
    $before = Get-StateSnapshot -Root $invalid.StateRoot
    $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -Operation $operation
    Assert-Equal (Get-StateSnapshot -Root $invalid.StateRoot) $before "$operation mutated state before Task 7."
    Assert-StudioResult -Result $result -Operation $operation -ExitCode 2 -Ok $false -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() -ErrorCode 'INVALID_REQUEST' -RecoveryActions @('cancel')
  }
  foreach ($invalidRequest in @(
    @{ Operation = 'status'; Arguments = @('-DeleteUserThemes') },
    @{ Operation = 'status'; Arguments = @('-ForceAuthorized') },
    @{ Operation = 'preflight'; Arguments = @('-RestartAuthorized') }
  )) {
    $before = Get-StateSnapshot -Root $invalid.StateRoot
    $result = Invoke-Studio -Case $invalid -Scenario 'stopped' -Operation $invalidRequest.Operation -ExtraArguments $invalidRequest.Arguments
    Assert-Equal (Get-StateSnapshot -Root $invalid.StateRoot) $before 'Invalid request flags mutated state.'
    Assert-StudioResult -Result $result -Operation $invalidRequest.Operation -ExitCode 2 -Ok $false -Install 'not-installed' -Codex 'not-installed' -Session 'official' `
      -ThemeName $null -RequiresRestart $false -Verified $null -AvailableActions @() -ErrorCode 'INVALID_REQUEST' -RecoveryActions @('cancel')
  }

  Write-Host 'PASS: Windows Studio status protocol.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
