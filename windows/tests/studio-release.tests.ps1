[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsRoot
$version = [IO.File]::ReadAllText((Join-Path $WindowsRoot 'VERSION')).Trim()
$innoPath = Join-Path $WindowsRoot 'build\dream-skin-studio.iss'
$builderPath = Join-Path $WindowsRoot 'scripts\build-studio-release.ps1'
$appPath = Join-Path $WindowsRoot 'studio\App.xaml.cs'
$windowPath = Join-Path $WindowsRoot 'studio\MainWindow.xaml.cs'

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Message)
  if ($Text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) { throw $Message }
}

function Assert-NotContains {
  param([string]$Text, [string]$Unexpected, [string]$Message)
  if ($Text.IndexOf($Unexpected, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw $Message }
}

foreach ($required in @($innoPath, $builderPath, $appPath, $windowPath)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Required Studio release source is missing: $required"
  }
}

$inno = [IO.File]::ReadAllText($innoPath)
$builder = [IO.File]::ReadAllText($builderPath)
$app = [IO.File]::ReadAllText($appPath)
$window = [IO.File]::ReadAllText($windowPath)

Assert-Contains $inno 'AppId=com.feiaway.codex-dream-skin-studio' 'Installer AppId is not fixed.'
Assert-Contains $inno 'PrivilegesRequired=lowest' 'Installer is not per-user.'
Assert-Contains $inno 'DefaultDirName={localappdata}\Programs\CodexDreamSkinStudio\versions\{#AppVersion}' 'Installer path is not versioned under LocalAppData.'
Assert-Contains $inno 'UsePreviousAppDir=no' 'Upgrade can overwrite an older version directory.'
Assert-Contains $inno "ExpandConstant('{app}\CodexDreamSkinStudio.exe')" 'Uninstall does not launch the installed Studio.'
Assert-Contains $inno "'--prepare-uninstall'" 'Uninstall does not pass the exact restore-guard argument.'
Assert-Contains $inno 'ewWaitUntilTerminated' 'Uninstall does not wait for the restore guard.'
Assert-Contains $inno 'ResultCode = 0' 'Uninstall does not require successful restore.'
Assert-Contains $inno 'postinstall' 'Finish-page launch is missing.'
Assert-NotContains $inno 'PrivilegesRequiredOverridesAllowed' 'Installer permits an elevation override.'
Assert-NotContains $inno 'deleteUserThemes' 'Installer can delete user themes.'
Assert-NotContains $inno '\CodexDreamSkin\themes' 'Installer owns user themes.'
Assert-NotContains $inno '\CodexDreamSkin\images' 'Installer owns user images.'
Assert-NotContains $inno '\CodexDreamSkin\active-theme' 'Installer owns the active user theme.'

Assert-Contains $builder "[ValidateSet('x64', 'arm64')]" 'Builder does not constrain architectures.'
Assert-Contains $builder '[switch]$SkipSign' 'Builder has no development signing mode.'
Assert-Contains $builder '[switch]$SkipTests' 'Builder cannot skip only test execution.'
Assert-Contains $builder 'fetch-node-runtime.ps1' 'Builder duplicates or omits private Node fetching.'
Assert-Contains $builder "studio\release\check-contents.mjs" 'Builder does not use the shared scanner.'
Assert-Contains $builder "studio\release\allowlist-windows.json" 'Builder does not use the Windows executable allowlist.'
Assert-Contains $builder '--self-contained' 'Builder does not publish self-contained Studio.'
Assert-Contains $builder 'WINDOWS_SIGN_CERT_THUMBPRINT' 'Formal signing does not require a certificate thumbprint.'
Assert-Contains $builder 'Get-AuthenticodeSignature' 'Builder does not verify Authenticode.'
Assert-Contains $builder 'UNSIGNED' 'Development output is not visibly unsigned.'
Assert-Contains $builder 'SHA256SUMS.txt' 'Builder does not publish SHA-256 metadata.'
Assert-Contains $builder '[IO.Directory]::Move' 'Release publication is not an atomic directory move.'

Assert-Contains $app 'e.Args.Length == 1' 'Prepare-uninstall argument matching is not exact.'
Assert-Contains $app '"--prepare-uninstall"' 'Prepare-uninstall entry is missing.'
Assert-Contains $app 'Shutdown(1)' 'Unknown arguments or mutex contention do not fail closed.'
Assert-Contains $window 'EngineOperation.Uninstall' 'Prepare-uninstall does not reuse the Studio uninstall operation.'
Assert-Contains $window 'DispatchAsync' 'Prepare-uninstall bypasses the existing dispatcher.'
Assert-Contains $window 'Shutdown(exitCode)' 'Prepare-uninstall does not report its result to Inno.'
Assert-NotContains $app 'DeleteUserThemes' 'Installer startup forwards theme deletion.'

if ($version -cne '1.3.0') { throw 'Windows VERSION must be 1.3.0 for this installer.' }

$stageRoot = Join-Path $WindowsRoot "release\stage-$version"
if (Test-Path -LiteralPath $stageRoot -PathType Container) {
  foreach ($required in @(
    'CodexDreamSkinStudio.exe', 'engine\scripts\studio-adapter.ps1', 'engine\assets\theme.json',
    'engine\runtime\node.exe', 'engine\runtime\LICENSE.node.txt', 'engine\runtime\NOTICE.node.txt',
    'engine\protocol\README.md', 'engine\protocol\fixtures-v1.json', 'engine\LICENSE',
    'engine\NOTICE.md', 'engine\VERSION'
  )) {
    if (-not (Test-Path -LiteralPath (Join-Path $stageRoot $required) -PathType Leaf)) {
      throw "Staged release file is missing: $required"
    }
  }
  & (Join-Path $stageRoot 'engine\runtime\node.exe') (Join-Path $RepoRoot 'studio\release\check-contents.mjs') `
    --root $stageRoot --allowlist (Join-Path $RepoRoot 'studio\release\allowlist-windows.json')
  if ($LASTEXITCODE -ne 0) { throw 'Staged release content scan failed.' }
}

Write-Host 'PASS: Windows Studio release source and staged-content contracts.'
