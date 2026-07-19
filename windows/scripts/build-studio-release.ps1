[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
  [switch]$SkipSign,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsRoot
$ReleaseRoot = Join-Path $WindowsRoot 'release'
$Version = [IO.File]::ReadAllText((Join-Path $WindowsRoot 'VERSION')).Trim()
if ($Version -cne '1.3.0') { throw 'The Windows release version is invalid.' }
$hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$requiredHostArchitecture = if ($Architecture -eq 'x64') { 'X64' } else { 'Arm64' }
if ($hostArchitecture -cne $requiredHostArchitecture) {
  throw 'Windows Studio releases require a matching X64 or Arm64 build host.'
}

$DotNet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$InnoSetup = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
foreach ($tool in @($DotNet, $PowerShell, $InnoSetup)) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'A required Windows release tool is unavailable.' }
}

function Assert-LastExitCode {
  param([string]$Message)
  if ($LASTEXITCODE -ne 0) { throw $Message }
}

function Copy-ReleaseFile {
  param([string]$Source, [string]$Destination)
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'A required release input is missing.' }
  $parent = Split-Path -Parent $Destination
  if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  Copy-Item -LiteralPath $Source -Destination $Destination
}

function New-StudioIcon {
  param([string]$Source, [string]$Destination)
  Add-Type -AssemblyName System.Drawing
  if (-not ('DreamSkinNativeIcon' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DreamSkinNativeIcon {
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool DestroyIcon(IntPtr handle);
}
'@
  }
  $sourceImage = [Drawing.Bitmap]::new($Source)
  $bitmap = [Drawing.Bitmap]::new($sourceImage, 256, 256)
  $handle = $bitmap.GetHicon()
  $icon = [Drawing.Icon]::FromHandle($handle)
  $stream = [IO.File]::Create($Destination)
  try { $icon.Save($stream) } finally {
    $stream.Dispose()
    $icon.Dispose()
    [DreamSkinNativeIcon]::DestroyIcon($handle) | Out-Null
    $bitmap.Dispose()
    $sourceImage.Dispose()
  }
}

function Get-SignTool {
  $kitsBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
  if (-not (Test-Path -LiteralPath $kitsBin -PathType Container)) { throw 'The Windows signing tools are unavailable.' }
  $candidate = Get-ChildItem -LiteralPath $kitsBin -Directory | Sort-Object Name -Descending | ForEach-Object {
    Join-Path $_.FullName 'x64\signtool.exe'
  } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if (-not $candidate) { throw 'The Windows signing tools are unavailable.' }
  return $candidate
}

function Sign-And-Verify {
  param([string]$Path, [string]$SignTool, [string]$Thumbprint)
  & $SignTool sign /sha1 $Thumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $Path
  Assert-LastExitCode 'Windows code signing failed.'
  & $SignTool verify /pa /all $Path
  Assert-LastExitCode 'Windows signature verification failed.'
  if ((Get-AuthenticodeSignature -LiteralPath $Path).Status -ne 'Valid') {
    throw 'Windows Authenticode verification failed.'
  }
}

$SignTool = $null
$Thumbprint = $null
if (-not $SkipSign) {
  $Thumbprint = "$env:WINDOWS_SIGN_CERT_THUMBPRINT".Trim()
  if ($Thumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or
    -not (Test-Path -LiteralPath "Cert:\CurrentUser\My\$Thumbprint")) {
    throw 'WINDOWS_SIGN_CERT_THUMBPRINT must identify a current-user signing certificate.'
  }
  $SignTool = Get-SignTool
}

$token = "$PID-$([guid]::NewGuid().ToString('N'))"
$TemporaryRoot = Join-Path $WindowsRoot ".studio-release-$token"
$PublishRoot = Join-Path $TemporaryRoot 'publish'
$StageRoot = Join-Path $PublishRoot "stage-$Version"
$EngineRoot = Join-Path $StageRoot 'engine'
$PublishOutput = Join-Path $TemporaryRoot 'dotnet-publish'
$IconPath = Join-Path $TemporaryRoot 'CodexDreamSkinStudio.ico'
$OldRelease = Join-Path $WindowsRoot ".release-old-$token"
$swapped = $false

try {
  New-Item -ItemType Directory -Path $EngineRoot -Force | Out-Null
  New-StudioIcon -Source (Join-Path $RepoRoot 'studio\assets\app-icon-source.png') -Destination $IconPath

  if (-not $SkipTests) {
    & $PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $WindowsRoot 'tests\run-tests.ps1')
    Assert-LastExitCode 'Windows PowerShell self-checks failed.'
    & $DotNet run --project (Join-Path $WindowsRoot 'studio-tests\CodexDreamSkinStudio.Tests.csproj') -c Release -r "win-$Architecture"
    Assert-LastExitCode 'Windows Studio console self-checks failed.'
  }

  & $DotNet publish (Join-Path $WindowsRoot 'studio\CodexDreamSkinStudio.csproj') -c Release -r "win-$Architecture" `
    --self-contained true -o $PublishOutput /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true `
    /p:DebugType=None /p:DebugSymbols=false /p:ContinuousIntegrationBuild=true "/p:PathMap=$RepoRoot=/_/src" `
    "/p:ApplicationIcon=$IconPath"
  Assert-LastExitCode 'Windows Studio publish failed.'
  Copy-ReleaseFile (Join-Path $PublishOutput 'CodexDreamSkinStudio.exe') (Join-Path $StageRoot 'CodexDreamSkinStudio.exe')

  $runtimeRoot = Join-Path $EngineRoot 'runtime'
  & (Join-Path $PSScriptRoot 'fetch-node-runtime.ps1') -Architecture $Architecture -Destination $runtimeRoot
  Assert-LastExitCode 'Private Node.js runtime staging failed.'

  $runtimeScripts = @(
    'common-windows.ps1', 'config-utf8.ps1', 'image-metadata.mjs', 'injector.mjs',
    'install-dream-skin.ps1', 'pause-dream-skin.ps1', 'restore-dream-skin.ps1',
    'start-dream-skin.ps1', 'status-dream-skin.ps1', 'studio-adapter.ps1',
    'studio-windows.ps1', 'theme-windows.ps1', 'tray-dream-skin.ps1', 'verify-dream-skin.ps1'
  )
  foreach ($script in $runtimeScripts) {
    Copy-ReleaseFile (Join-Path $WindowsRoot "scripts\$script") (Join-Path $EngineRoot "scripts\$script")
  }
  New-Item -ItemType Directory -Path (Join-Path $EngineRoot 'assets') -Force | Out-Null
  Copy-Item -Path (Join-Path $WindowsRoot 'assets\*') -Destination (Join-Path $EngineRoot 'assets') -Recurse
  Copy-ReleaseFile (Join-Path $WindowsRoot 'LICENSE') (Join-Path $EngineRoot 'LICENSE')
  Copy-ReleaseFile (Join-Path $WindowsRoot 'NOTICE.md') (Join-Path $EngineRoot 'NOTICE.md')
  Copy-ReleaseFile (Join-Path $WindowsRoot 'VERSION') (Join-Path $EngineRoot 'VERSION')
  Copy-ReleaseFile (Join-Path $RepoRoot 'studio\protocol\README.md') (Join-Path $EngineRoot 'protocol\README.md')
  Copy-ReleaseFile (Join-Path $RepoRoot 'studio\protocol\fixtures-v1.json') (Join-Path $EngineRoot 'protocol\fixtures-v1.json')

  if (-not $SkipSign) { Sign-And-Verify -Path (Join-Path $StageRoot 'CodexDreamSkinStudio.exe') -SignTool $SignTool -Thumbprint $Thumbprint }

  if (-not $SkipTests) {
    & (Join-Path $runtimeRoot 'node.exe') (Join-Path $WindowsRoot 'tests\studio-release-contract.test.mjs')
    Assert-LastExitCode 'Portable Windows Studio release checks failed.'
  }

  $PrivateNodePath = Join-Path $runtimeRoot 'node.exe'
  & $PrivateNodePath (Join-Path $RepoRoot 'studio\release\check-contents.mjs') `
    --root $StageRoot --allowlist (Join-Path $RepoRoot 'studio\release\allowlist-windows.json')
  if ($LASTEXITCODE -ne 0) { throw 'Release content scan failed.' }

  $label = if ($SkipSign) { 'UNSIGNED' } else { $null }
  $baseName = (@("CodexDreamSkinStudio-$Version-win-$Architecture", $label) | Where-Object { $_ }) -join '-'
  $innoArguments = @(
    "/DAppVersion=`"$Version`"", "/DArchitecture=`"$Architecture`"", "/DStageRoot=`"$StageRoot`"",
    "/DOutputDir=`"$PublishRoot`"", "/DOutputBaseFilename=`"$baseName`"", "/DIconPath=`"$IconPath`"",
    (Join-Path $WindowsRoot 'build\dream-skin-studio.iss')
  )
  & $InnoSetup $innoArguments
  Assert-LastExitCode 'Inno Setup compilation failed.'

  $setupPath = Join-Path $PublishRoot "$baseName.exe"
  if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'Inno Setup output is missing.' }
  if (-not $SkipSign) { Sign-And-Verify -Path $setupPath -SignTool $SignTool -Thumbprint $Thumbprint }

  $hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText((Join-Path $PublishRoot 'SHA256SUMS.txt'), "$hash  $baseName.exe`r`n", [Text.UTF8Encoding]::new($false))
  $signingMode = if ($SkipSign) { 'UNSIGNED' } else { 'signed' }
  $manifest = [ordered]@{
    schemaVersion = 1
    version = $Version
    architecture = $Architecture
    signing = $signingMode
    file = "$baseName.exe"
    sha256 = $hash
  }
  [IO.File]::WriteAllText((Join-Path $PublishRoot 'release-manifest.json'),
    (($manifest | ConvertTo-Json -Depth 3) + "`r`n"), [Text.UTF8Encoding]::new($false))

  if (Test-Path -LiteralPath $ReleaseRoot) { [IO.Directory]::Move($ReleaseRoot, $OldRelease) }
  try {
    [IO.Directory]::Move($PublishRoot, $ReleaseRoot)
    $swapped = $true
  } catch {
    if (Test-Path -LiteralPath $OldRelease) { [IO.Directory]::Move($OldRelease, $ReleaseRoot) }
    throw
  }
  if (Test-Path -LiteralPath $OldRelease) { Remove-Item -LiteralPath $OldRelease -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Host "Created $(Join-Path $ReleaseRoot "$baseName.exe")"
  if ($SkipSign) { Write-Warning 'Created an UNSIGNED development installer.' }
} finally {
  if (-not $swapped -and (Test-Path -LiteralPath $OldRelease) -and -not (Test-Path -LiteralPath $ReleaseRoot)) {
    [IO.Directory]::Move($OldRelease, $ReleaseRoot)
  }
  if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
}
