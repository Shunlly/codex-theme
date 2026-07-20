[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsRoot
$Builder = Join-Path $WindowsRoot 'scripts\build-studio-release.ps1'
$InnoSource = Join-Path $WindowsRoot 'build\dream-skin-studio.iss'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$DotNet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$InnoSetup = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
$TaskKill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
$Version = [IO.File]::ReadAllText((Join-Path $WindowsRoot 'VERSION')).Trim()
. (Join-Path $WindowsRoot 'scripts\common-windows.ps1')

function Invoke-TestProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [ValidateRange(1000, 3600000)][int]$TimeoutMilliseconds = 600000,
    [scriptblock]$AfterStart
  )
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $FilePath
  $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-DreamSkinProcessArgument -Value "$_" })) -join ' '
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $started = $false
  $forcedTermination = $false
  try {
    if (-not $process.Start()) { throw 'Test process could not start.' }
    $started = $true
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($null -ne $AfterStart) { & $AfterStart $process }
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      $forcedTermination = $true
      & $TaskKill /PID "$($process.Id)" /T /F *> $null
      $null = $process.WaitForExit(10000)
      throw 'Controlled Windows release test process timed out.'
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
  } finally {
    if ($started -and -not $process.HasExited) {
      $forcedTermination = $true
      & $TaskKill /PID "$($process.Id)" /T /F *> $null
      $null = $process.WaitForExit(10000)
    }
    if ($forcedTermination -and $null -ne $AfterStart -and $process.HasExited) {
      Get-ChildItem -LiteralPath $WindowsRoot -Directory `
          -Filter ".studio-release-$($process.Id)-*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory `
          -Filter "codex-dream-skin-studio-release-$($process.Id)-*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $process.Dispose()
  }
}

function Get-FileSnapshot {
  param([string]$Root)
  return @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
    "$($_.FullName.Substring($Root.Length))|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
  })
}

function Assert-SnapshotEqual {
  param([object[]]$Actual, [object[]]$Expected, [string]$Message)
  if ((ConvertTo-Json -InputObject @($Actual) -Compress) -cne
    (ConvertTo-Json -InputObject @($Expected) -Compress)) { throw $Message }
}

function Invoke-UninstallConfirmation {
  param(
    [ValidateRange(0, 2147483647)][int]$ProcessId,
    [Parameter(Mandatory = $true)][ValidateSet('Yes', 'No')][string]$Choice
  )
  $automationId = if ($Choice -eq 'Yes') { '6' } else { '7' }
  $namePattern = if ($Choice -eq 'Yes') { '^(?:Yes|是|はい)' } else { '^(?:No|否|いいえ)' }
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while ([DateTime]::UtcNow -lt $deadline) {
    $dialog = $null
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    for ($index = 0; $index -lt $windows.Count; $index++) {
      try {
        $candidate = $windows[$index]
        if ($candidate.Current.Name -ceq '卸载梦幻皮肤' -and
          ($ProcessId -eq 0 -or $candidate.Current.ProcessId -eq $ProcessId)) {
          $dialog = $candidate
          break
        }
      } catch [System.Windows.Automation.ElementNotAvailableException] {}
    }
    if ($null -ne $dialog) {
      $buttonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
      $buttons = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)
      for ($index = 0; $index -lt $buttons.Count; $index++) {
        $button = $buttons[$index]
        if ($button.Current.AutomationId -ceq $automationId -or $button.Current.Name -match $namePattern) {
          $pattern = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
          ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
          return
        }
      }
    }
    Start-Sleep -Milliseconds 50
  }
  throw "The real Studio $Choice confirmation button was not available."
}

function Get-StudioMainWindow {
  param([Parameter(Mandatory = $true)][int]$ProcessId, [int]$TimeoutSeconds = 30)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    for ($index = 0; $index -lt $windows.Count; $index++) {
      try {
        $candidate = $windows[$index]
        if ($candidate.Current.ProcessId -eq $ProcessId -and $candidate.Current.Name -ceq 'Codex 梦幻皮肤') {
          return $candidate
        }
      } catch [System.Windows.Automation.ElementNotAvailableException] {}
    }
    Start-Sleep -Milliseconds 50
  }
  throw 'The resident Studio window was not available.'
}

foreach ($tool in @($PowerShell, $DotNet, $InnoSetup, $TaskKill)) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'A required Windows release test tool is unavailable.' }
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$Architecture = switch ($osArchitecture) {
  'X64' { 'x64' }
  'Arm64' { 'arm64' }
  default { throw 'Windows Studio release tests require an X64 or Arm64 host.' }
}
$mismatchArchitecture = if ($Architecture -eq 'x64') { 'arm64' } else { 'x64' }
$mismatch = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
  $Builder, '-Architecture', $mismatchArchitecture, '-SkipSign', '-SkipTests')
if ($mismatch.ExitCode -eq 0 -or
  $mismatch.Output -notmatch 'Windows Studio releases require a matching X64 or Arm64 build host\.') {
  throw 'Release builder did not reject a mismatched build host before staging.'
}

$ReleaseRoot = Join-Path $WindowsRoot 'release'
$inputToken = [guid]::NewGuid().ToString('N')
$trackedInput = Join-Path $WindowsRoot 'assets\theme.json'
$untrackedInput = Join-Path $WindowsRoot "studio\TaskReleaseGuard-$inputToken.cs"
$untrackedBuildCustomization = Join-Path $WindowsRoot 'Directory.Build.targets'
$priorContamination = Join-Path $ReleaseRoot "prior-$inputToken.keep"
$trackedBytes = [IO.File]::ReadAllBytes($trackedInput)
$releaseRootExisted = Test-Path -LiteralPath $ReleaseRoot -PathType Container
try {
  New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
  [IO.File]::WriteAllText($priorContamination, 'prior release', [Text.UTF8Encoding]::new($false))
  $priorRelease = @(Get-FileSnapshot $ReleaseRoot)
  try {
    [IO.File]::AppendAllText($trackedInput, "`r`n", [Text.UTF8Encoding]::new($false))
    $dirtyBuild = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
      $Builder, '-Architecture', $Architecture, '-SkipSign', '-SkipTests')
    if ($dirtyBuild.ExitCode -eq 0 -or $dirtyBuild.Output -notmatch 'tracked regular files matching the Git index') {
      throw 'Builder accepted a dirty tracked release input.'
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $priorRelease 'Dirty tracked release input replaced prior output.'
  } finally {
    [IO.File]::WriteAllBytes($trackedInput, $trackedBytes)
  }

  try {
    [IO.File]::WriteAllText($untrackedInput, '#error untracked release payload', [Text.UTF8Encoding]::new($false))
    $untrackedBuild = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
      $Builder, '-Architecture', $Architecture, '-SkipSign', '-SkipTests')
    if ($untrackedBuild.ExitCode -eq 0 -or $untrackedBuild.Output -notmatch 'tracked regular files matching the Git index') {
      throw 'Builder accepted an untracked release payload.'
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $priorRelease 'Untracked release payload replaced prior output.'
  } finally {
    if (Test-Path -LiteralPath $untrackedInput) { Remove-Item -LiteralPath $untrackedInput -Force }
  }

  try {
    [IO.File]::WriteAllText($untrackedBuildCustomization,
      '<Project><Target Name="RejectOuterBuild" BeforeTargets="Build"><Error Text="outer untracked build customization" /></Target></Project>',
      [Text.UTF8Encoding]::new($false))
    $customizedBuild = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
      $Builder, '-Architecture', $Architecture, '-SkipSign', '-SkipTests')
    if ($customizedBuild.ExitCode -eq 0 -or $customizedBuild.Output -notmatch 'tracked regular files matching the Git index') {
      throw 'Builder accepted an outer untracked build customization.'
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $priorRelease 'Outer build customization replaced prior output.'
  } finally {
    if (Test-Path -LiteralPath $untrackedBuildCustomization) { Remove-Item -LiteralPath $untrackedBuildCustomization -Force }
  }

  $indexTree = "$(& git -C $RepoRoot write-tree)".Trim()
  $expectedAssetBlob = "$(& git -C $RepoRoot rev-parse "$indexTree`:windows/assets/theme.json")".Trim()
  $postSnapshotInput = Join-Path $WindowsRoot "assets\post-snapshot-$inputToken.txt"
  try {
    $build = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
      $Builder, '-Architecture', $Architecture, '-SkipSign', '-SkipTests') -AfterStart {
        $snapshotAsset = $null
        for ($attempt = 0; $attempt -lt 600 -and $null -eq $snapshotAsset; $attempt++) {
          if ($args[0].HasExited) { throw 'Builder exited before exposing its immutable snapshot.' }
          $snapshotAsset = Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory `
              -Filter "codex-dream-skin-studio-release-$($args[0].Id)-*" -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'snapshot\windows\assets\theme.json' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
          if ($null -eq $snapshotAsset) { Start-Sleep -Milliseconds 100 }
        }
        if ($null -eq $snapshotAsset) { throw 'Builder did not expose its immutable snapshot.' }
        [IO.File]::AppendAllText($trackedInput, "`r`npost-snapshot mutation", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($postSnapshotInput, 'post-snapshot mutation', [Text.UTF8Encoding]::new($false))
      }
  } finally {
    [IO.File]::WriteAllBytes($trackedInput, $trackedBytes)
    if (Test-Path -LiteralPath $postSnapshotInput) { Remove-Item -LiteralPath $postSnapshotInput -Force }
  }
  if ($build.ExitCode -ne 0) { throw "Unsigned Studio release build failed after post-snapshot mutation.`n$($build.Output)" }

  $StageRoot = Join-Path $ReleaseRoot "stage-$Version"
  $PrivateNode = Join-Path $StageRoot 'engine\runtime\node.exe'
  $Setup = Join-Path $ReleaseRoot "CodexDreamSkinStudio-$Version-win-$Architecture-UNSIGNED.exe"
  foreach ($required in @($StageRoot, $PrivateNode, $Setup, (Join-Path $ReleaseRoot 'SHA256SUMS.txt'),
    (Join-Path $ReleaseRoot 'release-manifest.json'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required release output is missing: $required" }
  }
  if (Test-Path -LiteralPath $priorContamination) { throw 'Successful release retained prior-release contamination.' }
  if (Test-Path -LiteralPath (Join-Path $StageRoot "engine\assets\post-snapshot-$inputToken.txt")) {
    throw 'Post-snapshot untracked payload entered the staged release.'
  }
  $stagedAssetBlob = "$(& git -C $RepoRoot hash-object --path=windows/assets/theme.json (Join-Path $StageRoot 'engine\assets\theme.json'))".Trim()
  if ($stagedAssetBlob -cne $expectedAssetBlob) { throw 'Post-snapshot mutation entered the staged release.' }
  $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $StageRoot 'CodexDreamSkinStudio.exe'))
  if ($versionInfo.FileVersion -cne "$Version.0" -or $versionInfo.ProductVersion -cne $Version) {
    throw 'Staged Studio FileVersionInfo does not match windows/VERSION.'
  }
  $setupVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Setup)
  if ($setupVersionInfo.FileVersion -cne "$Version.0" -or $setupVersionInfo.ProductVersion -cne $Version) {
    throw 'Setup FileVersionInfo does not match windows/VERSION.'
  }

  $contract = Invoke-TestProcess $PrivateNode @((Join-Path $PSScriptRoot 'studio-release-contract.test.mjs'))
  if ($contract.ExitCode -ne 0) { throw "Portable Studio release contract failed.`n$($contract.Output)" }
} finally {
  [IO.File]::WriteAllBytes($trackedInput, $trackedBytes)
  foreach ($path in @($untrackedInput, $untrackedBuildCustomization, $postSnapshotInput, $priorContamination)) {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
  }
  if (-not $releaseRootExisted -and (Test-Path -LiteralPath $ReleaseRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $ReleaseRoot -Force).Count -eq 0) {
    Remove-Item -LiteralPath $ReleaseRoot -Force
  }
}

$token = [guid]::NewGuid().ToString('N')
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dream-skin-release-$token"
$InstallRoot = Join-Path $TemporaryRoot 'installed'
$TestOutput = Join-Path $TemporaryRoot 'setup'
$TestAppId = "com.feiaway.codex-dream-skin-studio.test.$token"
$TestBaseName = "CodexDreamSkinStudio-test-$token"
$ThemeSentinel = Join-Path $env:LOCALAPPDATA "CodexDreamSkin\themes\task12-$token.keep"
$ReleaseSentinel = Join-Path $ReleaseRoot "prior-output-$token.keep"
$stub = Join-Path $TemporaryRoot 'prepare-uninstall-stub.exe'
$InstalledStudio = Join-Path $InstallRoot 'CodexDreamSkinStudio.exe'
$RealStudioBackup = Join-Path $TemporaryRoot 'CodexDreamSkinStudio.real.exe'
$PrepareTrace = Join-Path $TemporaryRoot 'prepare-uninstall-trace.txt'
$instanceMutex = $null
$ownsInstanceMutex = $false
$residentOwner = $null
$previousGuardExit = $env:DREAM_SKIN_TEST_PREPARE_EXIT
$previousPrepareScenario = $env:DREAM_SKIN_TEST_PREPARE_SCENARIO
$previousThumbprint = $env:WINDOWS_SIGN_CERT_THUMBPRINT

try {
  New-Item -ItemType Directory -Path $TestOutput -Force | Out-Null
  $stubSource = @'
using System;
public static class Program {
  public static int Main(string[] args) {
    if (args.Length != 1 || args[0] != "--prepare-uninstall") return 97;
    int code;
    return int.TryParse(Environment.GetEnvironmentVariable("DREAM_SKIN_TEST_PREPARE_EXIT"), out code) ? code : 98;
  }
}
'@
  Add-Type -TypeDefinition $stubSource -OutputAssembly $stub -OutputType ConsoleApplication | Out-Null

  $compileArguments = @(
    "/DAppVersion=`"$Version`"", "/DArchitecture=`"$Architecture`"", "/DStageRoot=`"$StageRoot`"",
    "/DOutputDir=`"$TestOutput`"", "/DOutputBaseFilename=`"$TestBaseName`"",
    '/DIconPath="compiler:SetupClassicIcon.ico"', "/DTestAppId=`"$TestAppId`"", $InnoSource
  )
  $compileOutput = "$(& $InnoSetup $compileArguments 2>&1)"
  if ($LASTEXITCODE -ne 0) { throw "Isolated Inno test installer compilation failed.`n$compileOutput" }
  $TestSetup = Join-Path $TestOutput "$TestBaseName.exe"
  if (-not (Test-Path -LiteralPath $TestSetup -PathType Leaf)) { throw 'Isolated Inno test installer is missing.' }

  $install = Invoke-TestProcess $TestSetup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$InstallRoot") `
    -TimeoutMilliseconds 120000
  if ($install.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw "Isolated Studio installation failed.`n$($install.Output)"
  }

  $InstalledPayload = Join-Path $TemporaryRoot 'installed-payload'
  New-Item -ItemType Directory -Path $InstalledPayload | Out-Null
  $expectedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($stagedFile in Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force) {
    $relative = $stagedFile.FullName.Substring($StageRoot.Length).TrimStart('\')
    $null = $expectedFiles.Add($relative)
    $installedFile = Join-Path $InstallRoot $relative
    if (-not (Test-Path -LiteralPath $installedFile -PathType Leaf) -or
      (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash -cne
        (Get-FileHash -LiteralPath $stagedFile.FullName -Algorithm SHA256).Hash) {
      throw "Installed payload does not match its staged file: $relative"
    }
    $payloadFile = Join-Path $InstalledPayload $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $payloadFile) -Force | Out-Null
    Copy-Item -LiteralPath $installedFile -Destination $payloadFile
  }
  foreach ($installedFile in Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Force) {
    $relative = $installedFile.FullName.Substring($InstallRoot.Length).TrimStart('\')
    if (-not $expectedFiles.Contains($relative) -and $relative -notmatch '^unins\d+\.(?:dat|exe|msg)$') {
      throw "Installer added an unexpected payload file: $relative"
    }
  }
  & (Join-Path $InstalledPayload 'engine\runtime\node.exe') (Join-Path $RepoRoot 'studio\release\check-contents.mjs') `
    --root $InstalledPayload --allowlist (Join-Path $RepoRoot 'studio\release\allowlist-windows.json')
  if ($LASTEXITCODE -ne 0) { throw 'Installed release content scan failed.' }

  $mutexUser = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if (-not $mutexUser) { $mutexUser = [Environment]::UserName }
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try { $mutexDigest = $sha256.ComputeHash([Text.UTF8Encoding]::new($false, $true).GetBytes($mutexUser)) }
  finally { $sha256.Dispose() }
  $mutexSuffix = ([BitConverter]::ToString($mutexDigest).Replace('-', '').ToLowerInvariant()).Substring(0, 32)
  $instanceMutex = [Threading.Mutex]::new($true, "Local\CodexDreamSkinStudio.$mutexSuffix", [ref]$ownsInstanceMutex)
  if (-not $ownsInstanceMutex) { throw 'Studio mutex fixture could not own the production instance mutex.' }
  $contended = Invoke-TestProcess $InstalledStudio @('--prepare-uninstall') `
    -TimeoutMilliseconds 30000
  if ($contended.ExitCode -eq 0) { throw 'Prepare-uninstall succeeded while the production Studio mutex was owned.' }
  $instanceMutex.ReleaseMutex()
  $instanceMutex.Dispose()
  $instanceMutex = $null
  $ownsInstanceMutex = $false

  $Uninstaller = Get-ChildItem -LiteralPath $InstallRoot -Filter 'unins*.exe' -File | Select-Object -First 1
  if ($null -eq $Uninstaller) { throw 'Isolated Studio uninstaller is missing.' }
  Copy-Item -LiteralPath $InstalledStudio -Destination $RealStudioBackup
  Copy-Item -LiteralPath $stub -Destination (Join-Path $InstallRoot 'CodexDreamSkinStudio.exe') -Force
  $beforeGuardFailure = @(Get-FileSnapshot $InstallRoot)
  $env:DREAM_SKIN_TEST_PREPARE_EXIT = '1'
  $null = Invoke-TestProcess $Uninstaller.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
    -TimeoutMilliseconds 120000
  Assert-SnapshotEqual @(Get-FileSnapshot $InstallRoot) $beforeGuardFailure 'Nonzero prepare guard changed installed files.'
  Copy-Item -LiteralPath $RealStudioBackup -Destination $InstalledStudio -Force

  $prepareFixture = @'
[CmdletBinding()]
param([string]$Operation)
$scenario = "$env:DREAM_SKIN_TEST_PREPARE_SCENARIO"
[IO.File]::AppendAllText('__TRACE__', $scenario + "`r`n", [Text.UTF8Encoding]::new($false))
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Error.WriteLine($(if ($Operation -in @('preflight', 'status')) { 'DREAM_SKIN_PROGRESS=checking' } else { 'DREAM_SKIN_PROGRESS=uninstalling' }))
if ($Operation -in @('preflight', 'status')) {
  [Console]::Out.WriteLine('{"schemaVersion":1,"ok":true,"operation":"__OPERATION__","state":{"install":"ready","codex":"stopped","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":["apply","restore","uninstall"],"verified":null},"error":null}'.Replace('__OPERATION__', $Operation))
  exit 0
}
if ($Operation -cne 'uninstall') { exit 2 }
if ($scenario -eq 'prepare-restore-failure') {
  [Console]::Out.WriteLine('{"schemaVersion":1,"ok":false,"operation":"uninstall","state":{"install":"ready","codex":"stopped","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":["restore","uninstall"],"verified":null},"error":{"code":"OPERATION_FAILED","message":"Controlled restore failure.","recoveryActions":["retry","diagnostics","cancel"]}}'.Replace('\"', '"'))
  exit 1
}
[Console]::Out.WriteLine('{"schemaVersion":1,"ok":true,"operation":"uninstall","state":{"install":"not-installed","codex":"stopped","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":["install"],"verified":null},"error":null}'.Replace('\"', '"'))
exit 0
'@
  [IO.File]::WriteAllText((Join-Path $InstallRoot 'engine\scripts\studio-adapter.ps1'),
    $prepareFixture.Replace('__TRACE__', $PrepareTrace.Replace("'", "''")), [Text.UTF8Encoding]::new($false))

  function Invoke-RealStudioPrepare {
    param(
      [Parameter(Mandatory = $true)][string]$Scenario,
      [Parameter(Mandatory = $true)][ValidateSet('Yes', 'No')][string]$Choice,
      [Parameter(Mandatory = $true)][int]$ExpectedExitCode
    )
    $env:DREAM_SKIN_TEST_PREPARE_SCENARIO = $Scenario
    $result = Invoke-TestProcess $InstalledStudio @('--prepare-uninstall') -TimeoutMilliseconds 120000 -AfterStart {
      param($startedProcess)
      Invoke-UninstallConfirmation -ProcessId $startedProcess.Id -Choice $Choice
    }
    if ($result.ExitCode -ne $ExpectedExitCode) {
      throw "Real Studio prepare-uninstall scenario failed: $Scenario ($($result.ExitCode))."
    }
  }

  Invoke-RealStudioPrepare -Scenario 'prepare-cancellation' -Choice No -ExpectedExitCode 1
  if (Test-Path -LiteralPath $PrepareTrace) { throw 'Cancelled real Studio uninstall invoked the engine.' }
  Invoke-RealStudioPrepare -Scenario 'prepare-never-applied' -Choice Yes -ExpectedExitCode 0
  Invoke-RealStudioPrepare -Scenario 'prepare-already-restored' -Choice Yes -ExpectedExitCode 0
  Invoke-RealStudioPrepare -Scenario 'prepare-already-restored' -Choice Yes -ExpectedExitCode 0
  Invoke-RealStudioPrepare -Scenario 'prepare-missing-codex' -Choice Yes -ExpectedExitCode 0
  Invoke-RealStudioPrepare -Scenario 'prepare-restore-failure' -Choice Yes -ExpectedExitCode 1
  $prepareScenarios = @([IO.File]::ReadAllLines($PrepareTrace))
  foreach ($expectedScenario in @('prepare-never-applied', 'prepare-missing-codex', 'prepare-restore-failure')) {
    if (@($prepareScenarios | Where-Object { $_ -ceq $expectedScenario }).Count -ne 1) {
      throw "Real Studio did not execute exactly one $expectedScenario engine request."
    }
  }
  if (@($prepareScenarios | Where-Object { $_ -ceq 'prepare-already-restored' }).Count -ne 2) {
    throw 'Real Studio repeated restore was not idempotent.'
  }

  New-Item -ItemType Directory -Path (Split-Path -Parent $ThemeSentinel) -Force | Out-Null
  [IO.File]::WriteAllText($ThemeSentinel, 'preserve', [Text.UTF8Encoding]::new($false))
  $beforeRealGuardFailure = @(Get-FileSnapshot $InstallRoot)
  $env:DREAM_SKIN_TEST_PREPARE_SCENARIO = 'prepare-restore-failure'
  $null = Invoke-TestProcess $Uninstaller.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
    -TimeoutMilliseconds 120000 -AfterStart {
      Invoke-UninstallConfirmation -ProcessId 0 -Choice Yes
    }
  Assert-SnapshotEqual @(Get-FileSnapshot $InstallRoot) $beforeRealGuardFailure `
    'A failed real Studio restore guard changed installed files.'

  $env:DREAM_SKIN_TEST_PREPARE_SCENARIO = 'prepare-missing-codex'
  $residentOwner = [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{
    FileName = $InstalledStudio
    UseShellExecute = $false
  })
  $ownerWindow = Get-StudioMainWindow -ProcessId $residentOwner.Id
  $windowPattern = [System.Windows.Automation.WindowPattern]$ownerWindow.GetCurrentPattern(
    [System.Windows.Automation.WindowPattern]::Pattern)
  $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized)
  $activation = Invoke-TestProcess $InstalledStudio @() -TimeoutMilliseconds 30000
  if ($activation.ExitCode -ne 0 -or $residentOwner.HasExited) {
    throw 'A second normal launch did not activate the resident Studio owner.'
  }
  $reactivatedWindow = Get-StudioMainWindow -ProcessId $residentOwner.Id
  $reactivatedPattern = [System.Windows.Automation.WindowPattern]$reactivatedWindow.GetCurrentPattern(
    [System.Windows.Automation.WindowPattern]::Pattern)
  if ($reactivatedPattern.Current.WindowVisualState -ne [System.Windows.Automation.WindowVisualState]::Normal) {
    throw 'A minimized or hidden resident Studio was not restored by a second launch.'
  }
  $successfulUninstall = Invoke-TestProcess $Uninstaller.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
    -TimeoutMilliseconds 120000 -AfterStart {
      Invoke-UninstallConfirmation -ProcessId $residentOwner.Id -Choice Yes
    }
  if ($successfulUninstall.ExitCode -ne 0) { throw "The real Studio guarded uninstall failed.`n$($successfulUninstall.Output)" }
  if (-not $residentOwner.WaitForExit(10000)) { throw 'Delegated uninstall returned before the resident owner exited.' }
  $residentOwner.Dispose()
  $residentOwner = $null
  for ($attempt = 0; $attempt -lt 50 -and (Test-Path -LiteralPath $InstallRoot); $attempt++) { Start-Sleep -Milliseconds 100 }
  if (Test-Path -LiteralPath $InstallRoot) { throw 'The real Studio guarded uninstall preserved installed files.' }
  if (-not (Test-Path -LiteralPath $ThemeSentinel -PathType Leaf)) { throw 'The real Studio guarded uninstall deleted a user theme.' }

  [IO.File]::WriteAllText($ReleaseSentinel, 'prior-output', [Text.UTF8Encoding]::new($false))
  $setupHash = (Get-FileHash -LiteralPath $Setup -Algorithm SHA256).Hash
  $env:WINDOWS_SIGN_CERT_THUMBPRINT = ''
  $failedBuild = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
    $Builder, '-Architecture', $Architecture, '-SkipTests')
  if ($failedBuild.ExitCode -eq 0 -or -not (Test-Path -LiteralPath $ReleaseSentinel -PathType Leaf) -or
    (Get-FileHash -LiteralPath $Setup -Algorithm SHA256).Hash -cne $setupHash) {
    throw 'An ordinary builder failure replaced prior release output.'
  }

  Write-Host 'PASS: Windows Studio release build, install scan, mutex, uninstall guard, and publication behavior.'
} finally {
  if ($residentOwner) {
    if (-not $residentOwner.HasExited) { & $TaskKill /PID "$($residentOwner.Id)" /T /F *> $null }
    $residentOwner.Dispose()
  }
  if ($instanceMutex) {
    if ($ownsInstanceMutex) { $instanceMutex.ReleaseMutex() }
    $instanceMutex.Dispose()
  }
  if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
    $cleanupUninstaller = Get-ChildItem -LiteralPath $InstallRoot -Filter 'unins*.exe' -File | Select-Object -First 1
    if ($cleanupUninstaller -and (Test-Path -LiteralPath $stub -PathType Leaf)) {
      Copy-Item -LiteralPath $stub -Destination (Join-Path $InstallRoot 'CodexDreamSkinStudio.exe') -Force
      $env:DREAM_SKIN_TEST_PREPARE_EXIT = '0'
      $null = Invoke-TestProcess $cleanupUninstaller.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
        -TimeoutMilliseconds 120000
    }
  }
  if (Test-Path -LiteralPath $ThemeSentinel) { Remove-Item -LiteralPath $ThemeSentinel -Force }
  if (Test-Path -LiteralPath $ReleaseSentinel) { Remove-Item -LiteralPath $ReleaseSentinel -Force }
  if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
  $env:DREAM_SKIN_TEST_PREPARE_EXIT = $previousGuardExit
  $env:DREAM_SKIN_TEST_PREPARE_SCENARIO = $previousPrepareScenario
  $env:WINDOWS_SIGN_CERT_THUMBPRINT = $previousThumbprint
}
