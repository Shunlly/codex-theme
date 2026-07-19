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
    [ValidateRange(1000, 3600000)][int]$TimeoutMilliseconds = 600000
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
  try {
    if (-not $process.Start()) { throw 'Test process could not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
      & $TaskKill /PID "$($process.Id)" /T /F *> $null
      $null = $process.WaitForExit(10000)
      throw 'Controlled Windows release test process timed out.'
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result + $stderr.Result }
  } finally {
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

foreach ($tool in @($PowerShell, $DotNet, $InnoSetup, $TaskKill)) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'A required Windows release test tool is unavailable.' }
}

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

$build = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
  $Builder, '-Architecture', $Architecture, '-SkipSign', '-SkipTests')
if ($build.ExitCode -ne 0) { throw "Unsigned Studio release build failed.`n$($build.Output)" }

$ReleaseRoot = Join-Path $WindowsRoot 'release'
$StageRoot = Join-Path $ReleaseRoot "stage-$Version"
$PrivateNode = Join-Path $StageRoot 'engine\runtime\node.exe'
$Setup = Join-Path $ReleaseRoot "CodexDreamSkinStudio-$Version-win-$Architecture-UNSIGNED.exe"
foreach ($required in @($StageRoot, $PrivateNode, $Setup, (Join-Path $ReleaseRoot 'SHA256SUMS.txt'),
  (Join-Path $ReleaseRoot 'release-manifest.json'))) {
  if (-not (Test-Path -LiteralPath $required)) { throw "Required release output is missing: $required" }
}

$contract = Invoke-TestProcess $PrivateNode @((Join-Path $PSScriptRoot 'studio-release-contract.test.mjs'))
if ($contract.ExitCode -ne 0) { throw "Portable Studio release contract failed.`n$($contract.Output)" }

$token = [guid]::NewGuid().ToString('N')
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dream-skin-release-$token"
$InstallRoot = Join-Path $TemporaryRoot 'installed'
$TestOutput = Join-Path $TemporaryRoot 'setup'
$TestAppId = "com.feiaway.codex-dream-skin-studio.test.$token"
$TestBaseName = "CodexDreamSkinStudio-test-$token"
$ThemeSentinel = Join-Path $env:LOCALAPPDATA "CodexDreamSkin\themes\task12-$token.keep"
$ReleaseSentinel = Join-Path $ReleaseRoot "prior-output-$token.keep"
$stub = Join-Path $TemporaryRoot 'prepare-uninstall-stub.exe'
$instanceMutex = $null
$ownsInstanceMutex = $false
$previousGuardExit = $env:DREAM_SKIN_TEST_PREPARE_EXIT
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
  $instanceMutex = [Threading.Mutex]::new($true, "Local\CodexDreamSkinStudio.$mutexUser", [ref]$ownsInstanceMutex)
  if (-not $ownsInstanceMutex) { throw 'Studio mutex fixture could not own the production instance mutex.' }
  $contended = Invoke-TestProcess (Join-Path $InstallRoot 'CodexDreamSkinStudio.exe') @('--prepare-uninstall') `
    -TimeoutMilliseconds 15000
  if ($contended.ExitCode -eq 0) { throw 'Prepare-uninstall succeeded while the production Studio mutex was owned.' }
  $instanceMutex.ReleaseMutex()
  $instanceMutex.Dispose()
  $instanceMutex = $null
  $ownsInstanceMutex = $false

  Copy-Item -LiteralPath $stub -Destination (Join-Path $InstallRoot 'CodexDreamSkinStudio.exe') -Force
  New-Item -ItemType Directory -Path (Split-Path -Parent $ThemeSentinel) -Force | Out-Null
  [IO.File]::WriteAllText($ThemeSentinel, 'preserve', [Text.UTF8Encoding]::new($false))

  $Uninstaller = Get-ChildItem -LiteralPath $InstallRoot -Filter 'unins*.exe' -File | Select-Object -First 1
  if ($null -eq $Uninstaller) { throw 'Isolated Studio uninstaller is missing.' }
  $beforeGuardFailure = @(Get-FileSnapshot $InstallRoot)
  $env:DREAM_SKIN_TEST_PREPARE_EXIT = '1'
  $null = Invoke-TestProcess $Uninstaller.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
    -TimeoutMilliseconds 120000
  Assert-SnapshotEqual @(Get-FileSnapshot $InstallRoot) $beforeGuardFailure 'Nonzero prepare guard changed installed files.'

  $env:DREAM_SKIN_TEST_PREPARE_EXIT = '0'
  $successfulUninstall = Invoke-TestProcess $Uninstaller.FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') `
    -TimeoutMilliseconds 120000
  if ($successfulUninstall.ExitCode -ne 0) { throw "Successful guarded uninstall failed.`n$($successfulUninstall.Output)" }
  for ($attempt = 0; $attempt -lt 50 -and (Test-Path -LiteralPath $InstallRoot); $attempt++) { Start-Sleep -Milliseconds 100 }
  if (Test-Path -LiteralPath $InstallRoot) { throw 'Successful guarded uninstall preserved installed files.' }
  if (-not (Test-Path -LiteralPath $ThemeSentinel -PathType Leaf)) { throw 'Successful installer uninstall deleted a user theme.' }

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
  $env:WINDOWS_SIGN_CERT_THUMBPRINT = $previousThumbprint
}
