[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ExpectedStudioVersion = '1.3.0'
if (([IO.File]::ReadAllText((Join-Path $Root 'VERSION')).Trim()) -cne $ExpectedStudioVersion) {
  throw "Windows VERSION must be $ExpectedStudioVersion."
}
foreach ($runtimeFile in @('scripts\injector.mjs', 'assets\renderer-inject.js')) {
  $content = [IO.File]::ReadAllText((Join-Path $Root $runtimeFile))
  if ($content -notmatch 'VERSION|__DREAM_SKIN_VERSION_JSON__') {
    throw "Windows runtime must load or receive VERSION: $runtimeFile"
  }
}
if ([IO.File]::ReadAllText((Join-Path $Root 'assets\renderer-inject.js')) -notmatch '__DREAM_SKIN_VERSION_JSON__') {
  throw 'Windows renderer must receive its version through the payload.'
}
if ([IO.File]::ReadAllText((Join-Path $Root 'scripts\studio-adapter.ps1')) -notmatch "'preflight', 'install', 'apply', 'status', 'pause', 'resume', 'restore', 'verify', 'uninstall'") {
  throw 'Windows Studio adapter must expose all Protocol v1 operations.'
}
$builderSource = [IO.File]::ReadAllText((Join-Path $Root 'scripts\build-studio-release.ps1'))
if ($builderSource -notmatch "(?m)^\s*& \`$PrivateNodePath \(Join-Path \`$SnapshotRepoRoot 'studio\\release\\check-contents\.mjs'\)") {
  throw 'Windows Studio release builder must invoke the content scanner.'
}
if (-not $builderSource.Contains('--artifacts-path $TestArtifactsRoot')) {
  throw 'Windows Studio release tests must keep .NET artifacts outside required inputs.'
}
function Assert-StudioQuickStartContract {
  param([string]$Path, [string]$QuickHeading, [string]$AdvancedHeading, [string[]]$Terms, [string[]]$Exclusions)
  $content = [IO.File]::ReadAllText($Path)
  $start = $content.IndexOf($QuickHeading, [StringComparison]::Ordinal)
  $end = $content.IndexOf($AdvancedHeading, [StringComparison]::Ordinal)
  $section = if ($start -ge 0 -and $end -gt $start) { $content.Substring($start, $end - $start) } else { '' }
  if (-not $section -or @($Terms | Where-Object { -not $section.Contains($_) }).Count -gt 0 -or
    @($Exclusions | Where-Object { -not $content.Contains($_) }).Count -gt 0) {
    throw "Studio quick-start contract is incomplete in $Path"
  }
}
Assert-StudioQuickStartContract (Join-Path $Root '..\README.md') '## 快速开始' '### 高级恢复' @('当前仓库不声称已有通过生产信任验收的 Studio 二进制发布', '生产发布完成后', 'CodexDreamSkinStudio.dmg', 'CodexDreamSkinStudio-1.3.0-win-x64.exe', 'preflight', '授权一次', '严格验证', 'Pause', 'Complete Restore') @('主题包分享', '工作区场景/绑定', '上下文配置档', '动态/视频')
Assert-StudioQuickStartContract (Join-Path $Root '..\README.en.md') '## Quick start' '### Advanced recovery' @('No trusted Studio binary is currently claimed as published or accepted', 'After a production release', 'CodexDreamSkinStudio.dmg', 'CodexDreamSkinStudio-1.3.0-win-x64.exe', 'preflight', 'authorize one', 'strict verified success', 'Pause', 'Complete Restore') @('theme-package sharing', 'workspace scenes/bindings', 'context profiles', 'motion/video')
Assert-StudioQuickStartContract (Join-Path $Root '..\docs\platforms.md') '## Studio 日常路径' '## 高级恢复' @('当前仓库不声称已有通过生产信任验收的 Studio 二进制发布', '生产发布完成后', 'CodexDreamSkinStudio.dmg', 'CodexDreamSkinStudio-1.3.0-win-x64.exe', 'preflight', '授权一次', '严格验证', 'Pause', 'Complete Restore') @('主题包分享', '工作区场景/绑定', '上下文配置档', '动态/视频')
Assert-StudioQuickStartContract (Join-Path $Root 'SKILL.md') '## Ordinary-user workflow (Studio)' '## Advanced recovery' @('No trusted Studio binary is currently claimed as published or accepted', 'Authenticode', 'SmartScreen', 'CodexDreamSkinStudio-1.3.0-win-x64.exe', 'preflight', 'authorize a single restart', 'strict verified success', 'Pause', 'Complete Restore') @('theme-package sharing', 'workspace scenes/bindings', 'context profiles', 'motion/video')
& (Join-Path $PSScriptRoot 'studio-protocol.tests.ps1')
. (Join-Path $Root 'scripts\common-windows.ps1')
. (Join-Path $Root 'scripts\theme-windows.ps1')

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "codex-dream-skin-tests-$PID-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

try {
  $shortcutDesktop = Join-Path $temporaryRoot 'legacy-shortcuts\desktop'
  $shortcutStartMenu = Join-Path $temporaryRoot 'legacy-shortcuts\start-menu'
  New-Item -ItemType Directory -Path $shortcutDesktop, $shortcutStartMenu -Force | Out-Null
  $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
  $shortcutShell = New-Object -ComObject WScript.Shell
  $versionedScript = Join-Path $env:LOCALAPPDATA `
    'Programs\CodexDreamSkinStudio\versions\1.2.9\engine\scripts\start-dream-skin.ps1'
  $manualScript = Join-Path $temporaryRoot 'old-checkout\windows\scripts\start-dream-skin.ps1'
  $unrelatedScript = Join-Path $temporaryRoot 'unrelated\start-dream-skin.ps1'
  foreach ($fixture in @(
    @{ Path = (Join-Path $shortcutDesktop 'Codex Dream Skin.lnk'); Script = $versionedScript },
    @{ Path = (Join-Path $shortcutStartMenu 'Codex Dream Skin.lnk'); Script = $manualScript },
    @{ Path = (Join-Path $shortcutDesktop 'Codex Dream Skin - Restore.lnk'); Script = $unrelatedScript }
  )) {
    $shortcut = $shortcutShell.CreateShortcut($fixture.Path)
    $shortcut.TargetPath = $powershell
    $suffix = if ($fixture.Path -like '* - Restore.lnk') { ' -RestoreBaseTheme -PromptRestart' } else { ' -PromptRestart' }
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($fixture.Script)`"$suffix"
    $shortcut.Save()
  }
  foreach ($attempt in 1..2) {
    Remove-DreamSkinManagedLegacyShortcuts -DesktopPath $shortcutDesktop -StartMenuPath $shortcutStartMenu
  }
  if ((Test-Path -LiteralPath (Join-Path $shortcutDesktop 'Codex Dream Skin.lnk')) -or
    (Test-Path -LiteralPath (Join-Path $shortcutStartMenu 'Codex Dream Skin.lnk')) -or
    -not (Test-Path -LiteralPath (Join-Path $shortcutDesktop 'Codex Dream Skin - Restore.lnk'))) {
    throw 'Guarded legacy shortcut cleanup missed historical product links or removed an unrelated link.'
  }

  $configPath = Join-Path $temporaryRoot 'config.toml'
  $backupPath = Join-Path $temporaryRoot 'config.before-dream-skin.toml'
  $projectName = -join @([char]0x4EE3, [char]0x7801, [char]0x9879, [char]0x76EE, [char]0x7532)
  $laterValue = -join @([char]0x4FDD, [char]0x7559)
  $sample = "model = `"gpt-5`"`r`n`r`n[other]`r`nappearanceTheme = `"keep-other`"`r`n`r`n[projects.'C:\$projectName']`r`ntrust_level = `"trusted`"`r`n`r`n[desktop]`r`nappearanceTheme = `"system`"`r`nappearanceLightCodeThemeId = `"theme-`$special`"`r`n"
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
  [System.IO.File]::WriteAllText($configPath, $sample, $utf8NoBom)
  $originalBytes = [System.IO.File]::ReadAllBytes($configPath)

  Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $installed = Read-DreamSkinUtf8File -Path $configPath
  if (-not $installed.Contains($projectName) -or $installed -notmatch 'appearanceTheme = "system"' -or
    $installed -notmatch 'appearanceLightCodeThemeId = "codex"') {
    throw 'Install changed a non-ASCII project name or failed to preserve the native appearance.'
  }
  if (-not (Test-Path -LiteralPath (Get-DreamSkinAppearanceMarkerPath -BackupPath $backupPath))) {
    throw 'Install did not record the appearance-preservation marker.'
  }
  $backupBytes = [System.IO.File]::ReadAllBytes($backupPath)
  if ([Convert]::ToBase64String($backupBytes) -cne [Convert]::ToBase64String($originalBytes)) {
    throw 'Install did not preserve an exact pre-change config backup.'
  }

  $markerFailureConfig = Join-Path $temporaryRoot 'marker-failure.toml'
  $markerFailureBackup = Join-Path $temporaryRoot 'marker-failure.before.toml'
  $markerFailureOriginal = "model = `"gpt-5`"`r`nproject = `"$projectName`"`r`n"
  [IO.File]::WriteAllText($markerFailureConfig, $markerFailureOriginal, $utf8NoBom)
  $markerFailureOriginalBytes = [IO.File]::ReadAllBytes($markerFailureConfig)
  $markerWriter = ${function:Write-DreamSkinAppearanceMarker}
  try {
    Set-Item Function:\Write-DreamSkinAppearanceMarker -Value { throw 'injected marker publication failure' }
    $markerFailureRejected = $false
    try {
      Install-DreamSkinBaseTheme -ConfigPath $markerFailureConfig -BackupPath $markerFailureBackup
    } catch {
      $markerFailureRejected = $_.Exception.Message -match 'injected marker publication failure'
    }
  } finally {
    Set-Item Function:\Write-DreamSkinAppearanceMarker -Value $markerWriter
  }
  if (-not $markerFailureRejected) { throw 'Marker publication failure was not surfaced.' }
  if (-not (Test-DreamSkinBytesEqual -Left $markerFailureOriginalBytes `
    -Right ([IO.File]::ReadAllBytes($markerFailureBackup)))) {
    throw 'Marker publication failure deleted or changed the only recovery backup.'
  }
  $markerFailureInstalled = Read-DreamSkinUtf8File -Path $markerFailureConfig
  if (-not $markerFailureInstalled.Contains($projectName) -or
    $markerFailureInstalled -notmatch 'appearanceLightCodeThemeId = "codex"') {
    throw 'Marker publication failure left invalid or unrelated config bytes.'
  }
  if (Test-Path -LiteralPath (Get-DreamSkinAppearanceMarkerPath -BackupPath $markerFailureBackup)) {
    throw 'Failed marker publication unexpectedly created its marker.'
  }
  Install-DreamSkinBaseTheme -ConfigPath $markerFailureConfig -BackupPath $markerFailureBackup
  if (-not (Test-DreamSkinBytesEqual -Left $markerFailureOriginalBytes `
    -Right ([IO.File]::ReadAllBytes($markerFailureBackup))) -or
    -not (Test-Path -LiteralPath (Get-DreamSkinAppearanceMarkerPath -BackupPath $markerFailureBackup))) {
    throw 'Retry after marker publication failure replaced recovery bytes or omitted the marker.'
  }

  $managedMissingRoot = Join-Path $temporaryRoot 'managed-missing-recovery'
  New-Item -ItemType Directory -Path $managedMissingRoot | Out-Null
  $managedMissingConfig = Join-Path $managedMissingRoot 'config.toml'
  $managedMissingBackup = Join-Path $managedMissingRoot 'config.before-dream-skin.toml'
  $managedMissingContent = "[desktop]`r`n$($script:DreamSkinManagedLightCodeTheme)`r`n"
  [IO.File]::WriteAllText($managedMissingConfig, $managedMissingContent, $utf8NoBom)
  $managedMissingBytes = [IO.File]::ReadAllBytes($managedMissingConfig)
  $managedMissingRejected = $false
  try {
    Install-DreamSkinBaseTheme -ConfigPath $managedMissingConfig -BackupPath $managedMissingBackup
  } catch {
    $managedMissingRejected = $true
  }
  if (-not $managedMissingRejected -or
    -not (Test-DreamSkinBytesEqual -Left $managedMissingBytes -Right ([IO.File]::ReadAllBytes($managedMissingConfig))) -or
    (Test-Path -LiteralPath $managedMissingBackup)) {
    throw 'managed-missing-recovery created a new baseline or changed managed config without prior completion proof.'
  }

  $written = [System.IO.File]::ReadAllBytes($configPath)
  if ($written.Length -ge 3 -and $written[0] -eq 0xEF -and $written[1] -eq 0xBB -and $written[2] -eq 0xBF) {
    throw 'Config writer added an unexpected UTF-8 BOM.'
  }

  $installed += "afterInstall = `"$laterValue`"`r`n"
  $installed = $installed -replace 'appearanceTheme = "system"', 'appearanceTheme = "dark"'
  Write-DreamSkinUtf8FileAtomically -Path $configPath -Content $installed
  Restore-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  $restored = Read-DreamSkinUtf8File -Path $configPath
  if (-not $restored.Contains($projectName) -or -not $restored.Contains($laterValue)) {
    throw 'Restore changed a project name or unrelated post-install setting.'
  }
  if ($restored -notmatch 'appearanceTheme = "dark"' -or -not $restored.Contains('appearanceLightCodeThemeId = "theme-$special"')) {
    throw 'Restore overwrote the user appearance or failed to restore the light code theme.'
  }
  if ($restored -notmatch '(?ms)^\[other\].*?appearanceTheme = "keep-other"') {
    throw 'Restore changed an appearance key outside the desktop section.'
  }

  $legacyConfigPath = Join-Path $temporaryRoot 'legacy-light.toml'
  $legacyBackupPath = Join-Path $temporaryRoot 'legacy-light.before.toml'
  $legacyCurrent = "[desktop]`r`n$($script:DreamSkinLegacyAppearanceTheme)`r`n$($script:DreamSkinManagedLightCodeTheme)`r`n$($script:DreamSkinManagedLightChromeTheme)`r`n"
  $legacyOriginal = "[desktop]`r`nappearanceTheme = `"system`"`r`nappearanceLightCodeThemeId = `"theme-original`"`r`nappearanceLightChromeTheme = { surface = `"original`" }`r`n"
  [System.IO.File]::WriteAllText($legacyConfigPath, $legacyCurrent, $utf8NoBom)
  [System.IO.File]::WriteAllText($legacyBackupPath, $legacyOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $legacyConfigPath -BackupPath $legacyBackupPath
  $legacyMigrated = Read-DreamSkinUtf8File -Path $legacyConfigPath
  if ($legacyMigrated -notmatch 'appearanceTheme = "system"' -or
    $legacyMigrated -notmatch 'appearanceLightCodeThemeId = "codex"') {
    throw 'Exact legacy managed light trio was not migrated to the saved native appearance.'
  }
  $legacyMigrated = $legacyMigrated -replace 'appearanceTheme = "system"', 'appearanceTheme = "dark"'
  Write-DreamSkinUtf8FileAtomically -Path $legacyConfigPath -Content $legacyMigrated
  Restore-DreamSkinBaseTheme -ConfigPath $legacyConfigPath -BackupPath $legacyBackupPath
  if ((Read-DreamSkinUtf8File -Path $legacyConfigPath) -notmatch 'appearanceTheme = "dark"') {
    throw 'A current install restore overwrote the user appearance after legacy migration.'
  }

  $lfConfigPath = Join-Path $temporaryRoot 'config-lf.toml'
  $lfBackupPath = Join-Path $temporaryRoot 'config-lf.before.toml'
  $lfOriginal = "model = `"gpt-5`"`n[projects.'C:\$projectName']`ntrust_level = `"trusted`"`n"
  [System.IO.File]::WriteAllText($lfConfigPath, $lfOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $lfConfigPath -BackupPath $lfBackupPath
  $lfInstalled = Read-DreamSkinUtf8File -Path $lfConfigPath
  if ($lfInstalled.Contains("`r") -or $lfInstalled -notmatch '(?m)^\[desktop\]$') {
    throw 'Install did not preserve LF line endings or create the desktop section.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $lfConfigPath -BackupPath $lfBackupPath
  $lfRestored = Read-DreamSkinUtf8File -Path $lfConfigPath
  if ($lfRestored.Contains("`r") -or $lfRestored -match '(?m)^\[desktop\]$' -or -not $lfRestored.Contains($projectName)) {
    throw 'Restore did not preserve LF content or remove the generated empty desktop section.'
  }

  $quotedConfigPath = Join-Path $temporaryRoot 'config-quoted.toml'
  $quotedBackupPath = Join-Path $temporaryRoot 'config-quoted.before.toml'
  $quotedOriginal = "[`"desktop`"] # retained comment`r`n`"appearanceTheme`" = `"system`"`r`n'appearanceLightCodeThemeId' = `"theme-`$special`"`r`n"
  [System.IO.File]::WriteAllText($quotedConfigPath, $quotedOriginal, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $quotedConfigPath -BackupPath $quotedBackupPath
  $quotedInstalled = Read-DreamSkinUtf8File -Path $quotedConfigPath
  if ([regex]::Matches($quotedInstalled, '(?m)^\s*\[(?:"desktop"|desktop)\]').Count -ne 1) {
    throw 'A commented or quoted desktop table was duplicated during install.'
  }
  Restore-DreamSkinBaseTheme -ConfigPath $quotedConfigPath -BackupPath $quotedBackupPath
  if ((Read-DreamSkinUtf8File -Path $quotedConfigPath) -cne $quotedOriginal) {
    throw 'Quoted desktop keys or a table-header comment were not restored exactly.'
  }

  $singleLineArrayPath = Join-Path $temporaryRoot 'config-single-line-array.toml'
  $singleLineArrayBackup = Join-Path $temporaryRoot 'config-single-line-array.before.toml'
  $singleLineArray = "labels = [`"name[1]`", `"#tag]`"]`r`n"
  [System.IO.File]::WriteAllText($singleLineArrayPath, $singleLineArray, $utf8NoBom)
  Install-DreamSkinBaseTheme -ConfigPath $singleLineArrayPath -BackupPath $singleLineArrayBackup
  if (-not (Read-DreamSkinUtf8File -Path $singleLineArrayPath).Contains($singleLineArray.TrimEnd())) {
    throw 'A safe single-line array containing bracket text was changed or rejected.'
  }

  foreach ($unsupported in @(
    'desktop.appearanceTheme = "system"',
    'desktop = { appearanceTheme = "system" }',
    '[[desktop]]',
    '[desktop.appearanceTheme]',
    '["desktop".layout]',
    '["desk\u0074op".layout]',
    '["desk\u0074op"]',
    "note = `"`"`"fake`r`n[desktop]`r`nappearanceTheme = `"dark`"`r`n`"`"`"",
    "[desktop]`r`nappearanceTheme = [`r`n  `"light`"`r`n]",
    "[desktop]`r`nlayout = [`r`n  [1, 2],`r`n  [3, 4],`r`n]`r`nappearanceTheme = `"dark`"",
    "[desktop]`r`nlayout = [`"]`",`r`n  [`"[`", `"]`"],`r`n]`r`nappearanceTheme = `"dark`""
  )) {
    $unsupportedPath = Join-Path $temporaryRoot ("unsupported-$([guid]::NewGuid().ToString('N')).toml")
    $unsupportedBackup = "$unsupportedPath.before"
    [System.IO.File]::WriteAllText($unsupportedPath, $unsupported, $utf8NoBom)
    $unsupportedRejected = $false
    try { Install-DreamSkinBaseTheme -ConfigPath $unsupportedPath -BackupPath $unsupportedBackup } catch { $unsupportedRejected = $true }
    if (-not $unsupportedRejected -or (Test-Path -LiteralPath $unsupportedBackup)) {
      throw "Unsupported TOML desktop representation was not rejected safely: $unsupported"
    }
  }

  $recoveryPath = Join-Path $temporaryRoot 'config.before-recovery.toml'
  Write-DreamSkinUtf8FileAtomically -Path $configPath -Content 'intentionally changed'
  Restore-DreamSkinConfigBackup -ConfigPath $configPath -BackupPath $backupPath -RecoveryBackupPath $recoveryPath
  $recoveredBytes = [System.IO.File]::ReadAllBytes($configPath)
  if ([Convert]::ToBase64String($recoveredBytes) -cne [Convert]::ToBase64String($originalBytes)) {
    throw 'Exact config recovery did not restore the original bytes.'
  }
  if ((Read-DreamSkinUtf8File -Path $recoveryPath) -cne 'intentionally changed') {
    throw 'Exact config recovery did not preserve the replaced current config.'
  }
  $archivePath = Join-Path $temporaryRoot 'config.restored.toml'
  $backupMarkerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $backupPath
  $archiveMarkerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $archivePath
  $expectedArchiveBytes = [IO.File]::ReadAllBytes($backupPath)
  $expectedArchiveMarkerBytes = [IO.File]::ReadAllBytes($backupMarkerPath)
  [IO.File]::WriteAllText($archivePath, 'older completed backup', $utf8NoBom)
  [IO.File]::WriteAllText($archiveMarkerPath, 'older completed marker', $utf8NoBom)
  Publish-DreamSkinConfigBackupArchive -BackupPath $backupPath -ArchivePath $archivePath
  if (-not (Test-Path -LiteralPath $backupPath) -or -not (Test-Path -LiteralPath $backupMarkerPath) -or
    -not (Test-Path -LiteralPath $archivePath) -or -not (Test-Path -LiteralPath $archiveMarkerPath) -or
    -not (Test-DreamSkinBytesEqual -Left $expectedArchiveBytes -Right ([IO.File]::ReadAllBytes($backupPath))) -or
    -not (Test-DreamSkinBytesEqual -Left $expectedArchiveMarkerBytes -Right ([IO.File]::ReadAllBytes($backupMarkerPath))) -or
    -not (Test-DreamSkinBytesEqual -Left $expectedArchiveBytes -Right ([IO.File]::ReadAllBytes($archivePath))) -or
    -not (Test-DreamSkinBytesEqual -Left $expectedArchiveMarkerBytes -Right ([IO.File]::ReadAllBytes($archiveMarkerPath)))) {
    throw 'Completion publication did not preserve the live backup while replacing the fixed archive exactly.'
  }

  $invalidationRoot = Join-Path $temporaryRoot 'generation invalidation failure'
  New-Item -ItemType Directory -Path $invalidationRoot | Out-Null
  $invalidationConfig = Join-Path $invalidationRoot 'config.toml'
  $invalidationBackup = Join-Path $invalidationRoot 'config.before-dream-skin.toml'
  $invalidationArchive = Join-Path $invalidationRoot 'config.restored.toml'
  $invalidationBaseline = "model = `"gpt-5`"`r`nproject = `"$projectName`"`r`n"
  [IO.File]::WriteAllText($invalidationConfig, $invalidationBaseline, $utf8NoBom)
  $invalidationBaselineBytes = [IO.File]::ReadAllBytes($invalidationConfig)
  New-Item -ItemType Directory -Path $invalidationArchive | Out-Null
  $invalidationRejected = $false
  try {
    Install-DreamSkinBaseTheme -ConfigPath $invalidationConfig -BackupPath $invalidationBackup
  } catch {
    $invalidationRejected = $_.Exception.Message -match 'completion evidence is not a safe file'
  }
  if (-not $invalidationRejected -or
    -not (Test-DreamSkinBytesEqual -Left $invalidationBaselineBytes -Right ([IO.File]::ReadAllBytes($invalidationConfig))) -or
    (Test-Path -LiteralPath $invalidationBackup) -or
    -not (Test-Path -LiteralPath $invalidationArchive -PathType Container)) {
    throw 'Unsafe completion proof was not rejected before backup and config mutation.'
  }
  Remove-Item -LiteralPath $invalidationArchive -Recurse -Force
  Install-DreamSkinBaseTheme -ConfigPath $invalidationConfig -BackupPath $invalidationBackup
  if ((Test-Path -LiteralPath $invalidationArchive) -or
    -not (Test-DreamSkinBytesEqual -Left $invalidationBaselineBytes -Right ([IO.File]::ReadAllBytes($invalidationBackup))) -or
    -not (Test-Path -LiteralPath (Get-DreamSkinAppearanceMarkerPath -BackupPath $invalidationBackup))) {
    throw 'Retry after completion-proof invalidation failure did not commit the fresh generation safely.'
  }

  $proofRollbackRoot = Join-Path $temporaryRoot 'completion-proof-config-commit-failure'
  New-Item -ItemType Directory -Path $proofRollbackRoot | Out-Null
  $proofRollbackConfig = Join-Path $proofRollbackRoot 'config.toml'
  $proofRollbackBackup = Join-Path $proofRollbackRoot 'config.before-dream-skin.toml'
  $proofRollbackArchive = Join-Path $proofRollbackRoot 'config.restored.toml'
  $proofRollbackArchiveMarker = Get-DreamSkinAppearanceMarkerPath -BackupPath $proofRollbackArchive
  [IO.File]::WriteAllText($proofRollbackConfig, "model = `"gpt-5`"`r`n", $utf8NoBom)
  [IO.File]::WriteAllText($proofRollbackArchive, "model = `"restored`"`r`n", $utf8NoBom)
  [IO.File]::WriteAllText($proofRollbackArchiveMarker,
    '{"schemaVersion":1,"appearanceThemeManaged":false}', $utf8NoBom)
  $proofRollbackConfigBytes = [IO.File]::ReadAllBytes($proofRollbackConfig)
  $proofRollbackArchiveBytes = [IO.File]::ReadAllBytes($proofRollbackArchive)
  $proofRollbackMarkerBytes = [IO.File]::ReadAllBytes($proofRollbackArchiveMarker)
  $originalConfigWriter = ${function:Write-DreamSkinUtf8FileAtomically}
  $proofRollbackState = [pscustomobject]@{ SawInvalidation = $false }
  $proofRollbackWriter = {
    param([string]$Path, [string]$Content, [byte[]]$ExpectedBytes, $ExpectedSnapshot, $PreparedTransaction)
    if ((Test-Path -LiteralPath $proofRollbackArchive) -or
      (Test-Path -LiteralPath $proofRollbackArchiveMarker)) {
      throw 'completion proof remained at the config commit boundary'
    }
    $proofRollbackState.SawInvalidation = $true
    throw 'injected config commit failure'
  }.GetNewClosure()
  $proofRollbackRejected = $false
  try {
    Set-Item Function:\Write-DreamSkinUtf8FileAtomically -Value $proofRollbackWriter
    try {
      Install-DreamSkinBaseTheme -ConfigPath $proofRollbackConfig -BackupPath $proofRollbackBackup
    } catch {
      $proofRollbackRejected = $_.Exception.Message -match 'injected config commit failure'
    }
  } finally {
    Set-Item Function:\Write-DreamSkinUtf8FileAtomically -Value $originalConfigWriter
  }
  if (-not $proofRollbackState.SawInvalidation -or -not $proofRollbackRejected -or
    -not (Test-DreamSkinBytesEqual -Left $proofRollbackConfigBytes -Right ([IO.File]::ReadAllBytes($proofRollbackConfig))) -or
    (Test-Path -LiteralPath $proofRollbackBackup) -or
    -not (Test-DreamSkinBytesEqual -Left $proofRollbackArchiveBytes -Right ([IO.File]::ReadAllBytes($proofRollbackArchive))) -or
    -not (Test-DreamSkinBytesEqual -Left $proofRollbackMarkerBytes -Right ([IO.File]::ReadAllBytes($proofRollbackArchiveMarker)))) {
    throw 'Config commit failure did not restore the invalidated completion proof transactionally.'
  }

  $uncertainCommitRoot = Join-Path $temporaryRoot 'completion-proof-uncertain-config-commit'
  New-Item -ItemType Directory -Path $uncertainCommitRoot | Out-Null
  $uncertainCommitConfig = Join-Path $uncertainCommitRoot 'config.toml'
  $uncertainCommitBackup = Join-Path $uncertainCommitRoot 'config.before-dream-skin.toml'
  $uncertainCommitArchive = Join-Path $uncertainCommitRoot 'config.restored.toml'
  $uncertainCommitArchiveMarker = Get-DreamSkinAppearanceMarkerPath -BackupPath $uncertainCommitArchive
  [IO.File]::WriteAllText($uncertainCommitConfig, "model = `"gpt-5`"`r`n", $utf8NoBom)
  [IO.File]::WriteAllText($uncertainCommitArchive, "model = `"restored`"`r`n", $utf8NoBom)
  [IO.File]::WriteAllText($uncertainCommitArchiveMarker,
    '{"schemaVersion":1,"appearanceThemeManaged":false}', $utf8NoBom)
  $uncertainCommitOriginalBytes = [IO.File]::ReadAllBytes($uncertainCommitConfig)
  $originalConfigWriter = ${function:Write-DreamSkinUtf8FileAtomically}
  $uncertainCommitWriter = {
    param([string]$Path, [string]$Content, [byte[]]$ExpectedBytes, $ExpectedSnapshot, $PreparedTransaction)
    if ((Test-Path -LiteralPath $uncertainCommitArchive) -or
      (Test-Path -LiteralPath $uncertainCommitArchiveMarker)) {
      throw 'completion proof remained at the uncertain config commit boundary'
    }
    $PreparedTransaction.Dispose()
    [IO.File]::WriteAllText($Path, 'uncertain-commit', $utf8NoBom)
    throw 'injected uncertain config commit failure'
  }.GetNewClosure()
  $uncertainCommitRejected = $false
  try {
    Set-Item Function:\Write-DreamSkinUtf8FileAtomically -Value $uncertainCommitWriter
    try {
      Install-DreamSkinBaseTheme -ConfigPath $uncertainCommitConfig -BackupPath $uncertainCommitBackup
    } catch {
      $uncertainCommitRejected = $_.Exception.Message -match 'injected uncertain config commit failure'
    }
  } finally {
    Set-Item Function:\Write-DreamSkinUtf8FileAtomically -Value $originalConfigWriter
  }
  if (-not $uncertainCommitRejected -or
    (Read-DreamSkinUtf8File -Path $uncertainCommitConfig) -cne 'uncertain-commit' -or
    -not (Test-DreamSkinBytesEqual -Left $uncertainCommitOriginalBytes `
      -Right ([IO.File]::ReadAllBytes($uncertainCommitBackup))) -or
    (Test-Path -LiteralPath $uncertainCommitArchive) -or
    (Test-Path -LiteralPath $uncertainCommitArchiveMarker)) {
    throw 'Uncertain config commit restored stale completion proof or discarded the recovery backup.'
  }

  Remove-Item -LiteralPath $backupMarkerPath -Force
  Remove-Item -LiteralPath $backupPath -Force
  $secondBaseline = "[desktop]`r`nappearanceTheme = `"dark`"`r`n"
  [System.IO.File]::WriteAllText($configPath, $secondBaseline, $utf8NoBom)
  $secondBaselineBytes = [System.IO.File]::ReadAllBytes($configPath)
  Install-DreamSkinBaseTheme -ConfigPath $configPath -BackupPath $backupPath
  if (-not (Test-DreamSkinBytesEqual -Left $secondBaselineBytes -Right ([System.IO.File]::ReadAllBytes($backupPath)))) {
    throw 'Reinstall did not capture a fresh config baseline after completed restore.'
  }
  if ((Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath $archiveMarkerPath)) {
    throw 'Reinstall did not invalidate the prior generation completion evidence before config commit.'
  }

  $invalidPath = Join-Path $temporaryRoot 'invalid.toml'
  $invalidBackupPath = Join-Path $temporaryRoot 'invalid.before.toml'
  [System.IO.File]::WriteAllBytes($invalidPath, [byte[]](0x66, 0x6f, 0x80))
  $rejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $invalidPath -BackupPath $invalidBackupPath } catch { $rejected = $true }
  if (-not $rejected -or (Test-Path -LiteralPath $invalidBackupPath)) {
    throw 'Invalid UTF-8 input was not rejected before backup creation.'
  }
  $utf16Path = Join-Path $temporaryRoot 'utf16.toml'
  $utf16BackupPath = Join-Path $temporaryRoot 'utf16.before.toml'
  [System.IO.File]::WriteAllText($utf16Path, 'model = "gpt-5"', [System.Text.Encoding]::Unicode)
  $utf16Rejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $utf16Path -BackupPath $utf16BackupPath } catch { $utf16Rejected = $true }
  if (-not $utf16Rejected -or (Test-Path -LiteralPath $utf16BackupPath)) {
    throw 'A UTF-16 config was silently transcoded instead of being rejected.'
  }
  $utf16NoBomPath = Join-Path $temporaryRoot 'utf16-no-bom.toml'
  $utf16NoBomBackupPath = Join-Path $temporaryRoot 'utf16-no-bom.before.toml'
  [System.IO.File]::WriteAllBytes($utf16NoBomPath, [System.Text.Encoding]::Unicode.GetBytes('model = "gpt-5"'))
  $utf16NoBomRejected = $false
  try { Install-DreamSkinBaseTheme -ConfigPath $utf16NoBomPath -BackupPath $utf16NoBomBackupPath } catch { $utf16NoBomRejected = $true }
  if (-not $utf16NoBomRejected -or (Test-Path -LiteralPath $utf16NoBomBackupPath)) {
    throw 'A BOM-less UTF-16 config was silently treated as UTF-8 instead of being rejected.'
  }
  $racePath = Join-Path $temporaryRoot 'race.toml'
  [System.IO.File]::WriteAllText($racePath, 'before', $utf8NoBom)
  $raceExpected = [System.IO.File]::ReadAllBytes($racePath)
  [System.IO.File]::WriteAllText($racePath, 'after', $utf8NoBom)
  $raceRejected = $false
  try { Assert-DreamSkinFileUnchanged -Path $racePath -ExpectedBytes $raceExpected } catch { $raceRejected = $true }
  if (-not $raceRejected) { throw 'Concurrent config modification was not detected.' }
  $conditionalWriteRejected = $false
  try {
    Write-DreamSkinUtf8FileAtomically -Path $racePath -Content 'replacement' -ExpectedBytes $raceExpected
  } catch {
    $conditionalWriteRejected = $true
  }
  if (-not $conditionalWriteRejected -or (Read-DreamSkinUtf8File -Path $racePath) -cne 'after') {
    throw 'Conditional atomic write replaced newer config content.'
  }

  $configTrustBoundaryCases = @(
    @{ Name = 'config-file-symlink-install'; Boundary = 'file-symlink'; Operation = 'install' },
    @{ Name = 'config-file-symlink-selective'; Boundary = 'file-symlink'; Operation = 'selective' },
    @{ Name = 'config-file-symlink-exact'; Boundary = 'file-symlink'; Operation = 'exact' },
    @{ Name = 'config-directory-junction-install'; Boundary = 'directory-junction'; Operation = 'install' },
    @{ Name = 'config-directory-junction-selective'; Boundary = 'directory-junction'; Operation = 'selective' },
    @{ Name = 'config-directory-junction-exact'; Boundary = 'directory-junction'; Operation = 'exact' }
  )
  foreach ($trustCase in $configTrustBoundaryCases) {
    $caseRoot = Join-Path $temporaryRoot $trustCase.Name
    $profileRoot = Join-Path $caseRoot 'profile'
    $externalRoot = Join-Path $caseRoot 'external'
    $configDirectory = Join-Path $profileRoot '.codex'
    $externalConfig = Join-Path $externalRoot 'config.toml'
    $configPathUnderTest = Join-Path $configDirectory 'config.toml'
    $caseBackup = Join-Path $caseRoot 'config.before-dream-skin.toml'
    $caseRecovery = Join-Path $caseRoot 'config.before-recovery.toml'
    $caseState = Join-Path $caseRoot 'state.json'
    New-Item -ItemType Directory -Path $profileRoot, $externalRoot | Out-Null
    $currentConfig = if ($trustCase.Operation -eq 'install') {
      "model = `"gpt-5`"`r`n"
    } else {
      "[desktop]`r`n$($script:DreamSkinManagedLightCodeTheme)`r`n$($script:DreamSkinManagedLightChromeTheme)`r`n"
    }
    [IO.File]::WriteAllText($externalConfig, $currentConfig, $utf8NoBom)
    [IO.File]::WriteAllText($caseState, 'state sentinel', $utf8NoBom)
    if ($trustCase.Operation -ne 'install') {
      [IO.File]::WriteAllText($caseBackup, "model = `"baseline`"`r`n", $utf8NoBom)
    }
    $externalBefore = [IO.File]::ReadAllBytes($externalConfig)
    $stateBefore = [IO.File]::ReadAllBytes($caseState)
    $backupBefore = if (Test-Path -LiteralPath $caseBackup -PathType Leaf) {
      [IO.File]::ReadAllBytes($caseBackup)
    } else { $null }
    $reparsePath = $null
    try {
      if ($trustCase.Boundary -eq 'file-symlink') {
        New-Item -ItemType Directory -Path $configDirectory | Out-Null
        $null = New-Item -ItemType SymbolicLink -Path $configPathUnderTest -Target $externalConfig
        $reparsePath = $configPathUnderTest
      } else {
        $null = New-Item -ItemType Junction -Path $configDirectory -Target $externalRoot
        $reparsePath = $configDirectory
      }

      $trustRejected = $false
      try {
        switch ($trustCase.Operation) {
          'install' {
            Install-DreamSkinBaseTheme -ConfigPath $configPathUnderTest -BackupPath $caseBackup
          }
          'selective' {
            Restore-DreamSkinBaseTheme -ConfigPath $configPathUnderTest -BackupPath $caseBackup
          }
          'exact' {
            Restore-DreamSkinConfigBackup -ConfigPath $configPathUnderTest -BackupPath $caseBackup `
              -RecoveryBackupPath $caseRecovery
          }
        }
      } catch {
        $trustRejected = $true
      }
      $reparseItem = Get-Item -LiteralPath $reparsePath -Force -ErrorAction Stop
      if (-not $trustRejected -or
        ($reparseItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
        -not (Test-DreamSkinBytesEqual -Left $externalBefore -Right ([IO.File]::ReadAllBytes($externalConfig))) -or
        -not (Test-DreamSkinBytesEqual -Left $stateBefore -Right ([IO.File]::ReadAllBytes($caseState))) -or
        (Test-Path -LiteralPath $caseRecovery)) {
        throw "$($trustCase.Name) crossed the config trust boundary or changed protected state."
      }
      if ($null -eq $backupBefore) {
        if (Test-Path -LiteralPath $caseBackup) {
          throw "$($trustCase.Name) created a backup before rejecting the config trust boundary."
        }
      } elseif (-not (Test-DreamSkinBytesEqual -Left $backupBefore -Right ([IO.File]::ReadAllBytes($caseBackup)))) {
        throw "$($trustCase.Name) changed the live backup before rejecting the config trust boundary."
      }
    } finally {
      if ($null -ne $reparsePath -and (Test-Path -LiteralPath $reparsePath)) {
        Remove-Item -LiteralPath $reparsePath -Force -ErrorAction SilentlyContinue
      }
    }
  }

  foreach ($identityCase in @(
    'commit-identity-install',
    'commit-identity-selective',
    'commit-identity-exact',
    'commit-identity-rollback'
  )) {
    $operation = $identityCase.Substring('commit-identity-'.Length)
    $caseRoot = Join-Path $temporaryRoot $identityCase
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $identityConfig = Join-Path $caseRoot 'config.toml'
    $identityBackup = Join-Path $caseRoot 'config.before-dream-skin.toml'
    $identityRecovery = Join-Path $caseRoot 'config.before-recovery.toml'
    $identityState = Join-Path $caseRoot 'state.json'
    $identityCurrent = if ($operation -eq 'install') {
      "model = `"gpt-5`"`r`n"
    } else {
      "[desktop]`r`n$($script:DreamSkinManagedLightCodeTheme)`r`n$($script:DreamSkinManagedLightChromeTheme)`r`n"
    }
    [IO.File]::WriteAllText($identityConfig, $identityCurrent, $utf8NoBom)
    [IO.File]::WriteAllText($identityState, 'state sentinel', $utf8NoBom)
    if ($operation -eq 'selective' -or $operation -eq 'exact') {
      [IO.File]::WriteAllText($identityBackup, "model = `"baseline`"`r`n", $utf8NoBom)
    }
    $identityConfigBefore = [IO.File]::ReadAllBytes($identityConfig)
    $identityStateBefore = [IO.File]::ReadAllBytes($identityState)
    $identityBackupBefore = if (Test-Path -LiteralPath $identityBackup -PathType Leaf) {
      [IO.File]::ReadAllBytes($identityBackup)
    } else { $null }
    $identityBefore = Get-DreamSkinStableFileSnapshot -Path $identityConfig
    $originalStableAssert = ${function:Assert-DreamSkinStableFileSnapshotUnchanged}
    $raceState = [pscustomobject]@{ Attempted = $false; Denied = $false; Replaced = $false; Replacement = $null }
    $raceTarget = [IO.Path]::GetFullPath($identityConfig)
    $raceAssert = {
      param([Parameter(Mandatory = $true)]$Snapshot)
      & $originalStableAssert -Snapshot $Snapshot
      $temporaryPattern = '.*.tmp'
      $temporaryExists = $null -ne (Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($raceTarget)) `
        -Filter $temporaryPattern -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
      if (-not $raceState.Attempted -and $temporaryExists -and
        $Snapshot.FullPath.Equals($raceTarget, [StringComparison]::OrdinalIgnoreCase)) {
        $raceState.Attempted = $true
        $replacement = Join-Path ([IO.Path]::GetDirectoryName($raceTarget)) `
          ".$([IO.Path]::GetFileName($raceTarget)).identity-race"
        $raceState.Replacement = $replacement
        [IO.File]::WriteAllBytes($replacement, [byte[]]$Snapshot.Bytes)
        try {
          [IO.File]::Replace($replacement, $raceTarget, $null)
          $raceState.Replaced = $true
        } catch {
          $raceState.Denied = $true
        }
      }
    }.GetNewClosure()
    $identityRejected = $false
    try {
      Set-Item Function:\Assert-DreamSkinStableFileSnapshotUnchanged -Value $raceAssert
      try {
        switch ($operation) {
          'install' {
            Install-DreamSkinBaseTheme -ConfigPath $identityConfig -BackupPath $identityBackup
          }
          'selective' {
            Restore-DreamSkinBaseTheme -ConfigPath $identityConfig -BackupPath $identityBackup
          }
          'exact' {
            Restore-DreamSkinConfigBackup -ConfigPath $identityConfig -BackupPath $identityBackup `
              -RecoveryBackupPath $identityRecovery
          }
          'rollback' {
            Write-DreamSkinBytesAtomically -Path $identityConfig -Bytes ($utf8NoBom.GetBytes('rollback')) `
              -ExpectedBytes $identityConfigBefore -ExpectedSnapshot $identityBefore
          }
        }
      } catch {
        $identityRejected = $true
      }
    } finally {
      Set-Item Function:\Assert-DreamSkinStableFileSnapshotUnchanged -Value $originalStableAssert
    }
    $identityAfter = Get-DreamSkinStableFileSnapshot -Path $identityConfig
    $identityRecoverySafe = if ($operation -eq 'exact') {
      (Test-Path -LiteralPath $identityRecovery -PathType Leaf) -and
        (Test-DreamSkinBytesEqual -Left $identityConfigBefore -Right ([IO.File]::ReadAllBytes($identityRecovery)))
    } else { -not (Test-Path -LiteralPath $identityRecovery) }
    $identityCanonicalCorrect = switch ($operation) {
      'install' { Test-DreamSkinBaseThemeManaged -ConfigPath $identityConfig }
      'selective' { -not (Test-DreamSkinBaseThemeManaged -ConfigPath $identityConfig) }
      'exact' { Test-DreamSkinBytesEqual -Left $identityBackupBefore -Right $identityAfter.Bytes }
      'rollback' { Test-DreamSkinBytesEqual -Left ($utf8NoBom.GetBytes('rollback')) -Right $identityAfter.Bytes }
    }
    if (-not $raceState.Attempted -or -not $raceState.Denied -or $raceState.Replaced -or $identityRejected -or
      -not (Test-Path -LiteralPath $raceState.Replacement -PathType Leaf) -or
      -not (Test-DreamSkinBytesEqual -Left $identityConfigBefore -Right ([IO.File]::ReadAllBytes($raceState.Replacement))) -or
      $identityAfter.Identity -ceq $identityBefore.Identity -or
      -not $identityCanonicalCorrect -or
      -not (Test-DreamSkinBytesEqual -Left $identityStateBefore -Right ([IO.File]::ReadAllBytes($identityState))) -or
      -not $identityRecoverySafe) {
      throw "$identityCase did not reject the external replacement while publishing the managed canonical generation."
    }
    if ($null -eq $identityBackupBefore) {
      if ($operation -eq 'install') {
        if (-not (Test-Path -LiteralPath $identityBackup -PathType Leaf) -or
          -not (Test-DreamSkinBytesEqual -Left $identityConfigBefore -Right ([IO.File]::ReadAllBytes($identityBackup)))) {
          throw "$identityCase discarded the live backup after config identity changed."
        }
      } elseif (Test-Path -LiteralPath $identityBackup) {
        throw "$identityCase created an unrelated backup after config identity changed."
      }
    } elseif (-not (Test-DreamSkinBytesEqual -Left $identityBackupBefore -Right ([IO.File]::ReadAllBytes($identityBackup)))) {
      throw "$identityCase changed the live backup after config identity changed."
    }
  }

  $lateCreatorRoot = Join-Path $temporaryRoot 'atomic-late-creator'
  New-Item -ItemType Directory -Path $lateCreatorRoot | Out-Null
  $lateCreatorPath = Join-Path $lateCreatorRoot 'config.toml'
  $lateCreatorBytes = $utf8NoBom.GetBytes('late creator')
  $lateCreatorWrite = $null
  $lateCreatorRejected = $false
  try {
    $lateCreatorWrite = [DreamSkinConfigNative]::BeginAtomicWrite(
      [IO.Path]::GetFullPath($lateCreatorPath), $utf8NoBom.GetBytes('managed candidate'))
    [IO.File]::WriteAllBytes($lateCreatorPath, $lateCreatorBytes)
    try { $lateCreatorWrite.Commit() } catch {
      $lateCreatorRejected = -not $lateCreatorWrite.RollbackConfirmed -and
        $_.Exception.Message -match 'rollback-unconfirmed'
    }
  } finally {
    if ($null -ne $lateCreatorWrite) { $lateCreatorWrite.Dispose() }
  }
  if (-not $lateCreatorRejected -or
    -not (Test-DreamSkinBytesEqual -Left $lateCreatorBytes -Right ([IO.File]::ReadAllBytes($lateCreatorPath))) -or
    (Get-ChildItem -LiteralPath $lateCreatorRoot -Filter '.*.tmp' -Force -ErrorAction SilentlyContinue) -or
    (Get-ChildItem -LiteralPath $lateCreatorRoot -Filter '.*.candidate' -Force -ErrorAction SilentlyContinue)) {
    throw 'atomic-late-creator was overwritten or did not surface rollback uncertainty.'
  }

  $tempMutationRoot = Join-Path $temporaryRoot 'atomic-temp-mutation'
  New-Item -ItemType Directory -Path $tempMutationRoot | Out-Null
  $tempMutationPath = Join-Path $tempMutationRoot 'config.toml'
  $tempMutationBytes = $utf8NoBom.GetBytes('verified candidate')
  [IO.File]::WriteAllText($tempMutationPath, 'original', $utf8NoBom)
  $tempMutationWrite = $null
  $tempMutationRejected = $false
  try {
    $tempMutationWrite = [DreamSkinConfigNative]::BeginAtomicWrite(
      [IO.Path]::GetFullPath($tempMutationPath), $tempMutationBytes)
    $heldTemps = @(Get-ChildItem -LiteralPath $tempMutationRoot -Filter '.*.tmp' -Force)
    if ($heldTemps.Count -ne 1) { throw 'atomic-temp-mutation did not expose exactly one held temp.' }
    $heldTemp = $heldTemps[0]
    try { [IO.File]::WriteAllText($heldTemp.FullName, 'mutated', $utf8NoBom) } catch {
      $tempMutationRejected = $true
    }
    $tempMutationWrite.Commit()
  } finally {
    if ($null -ne $tempMutationWrite) { $tempMutationWrite.Dispose() }
  }
  if (-not $tempMutationRejected -or
    -not (Test-DreamSkinBytesEqual -Left $tempMutationBytes -Right ([IO.File]::ReadAllBytes($tempMutationPath)))) {
    throw 'atomic-temp-mutation was not blocked before read-back verification and commit.'
  }

  $namespaceProbeScript = Join-Path $temporaryRoot 'atomic-namespace-probe.ps1'
  [IO.File]::WriteAllText($namespaceProbeScript, @'
param([string]$Operation, [string]$Path, [string]$AuxiliaryPath)
$ErrorActionPreference = 'Stop'
try {
  switch ($Operation) {
    'write' { [IO.File]::WriteAllText($Path, 'unexpected write') }
    'move' { [IO.File]::Move($Path, $AuxiliaryPath) }
    'replace' {
      [IO.File]::WriteAllText($AuxiliaryPath, 'unexpected replacement')
      [IO.File]::Replace($AuxiliaryPath, $Path, $null)
    }
    'delete' { [IO.File]::Delete($Path) }
    default { throw "unknown operation: $Operation" }
  }
  exit 0
} catch {
  exit 23
}
'@, $utf8NoBom)

  function Invoke-AtomicNamespaceProbe {
    param([string]$Operation, [string]$Path, [string]$Root)
    $auxiliary = Join-Path $Root "probe-$Operation-$([guid]::NewGuid().ToString('N'))"
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $namespaceProbeScript `
      -Operation $Operation -Path $Path -AuxiliaryPath $auxiliary
    $exitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $auxiliary) { Remove-Item -LiteralPath $auxiliary -Force }
    return $exitCode
  }

  $posixReplaceRoot = Join-Path $temporaryRoot 'atomic-existing-posix-replace'
  New-Item -ItemType Directory -Path $posixReplaceRoot | Out-Null
  $posixReplacePath = Join-Path $posixReplaceRoot 'config.toml'
  $posixOldBytes = $utf8NoBom.GetBytes('posix old')
  $posixNewBytes = $utf8NoBom.GetBytes('posix new')
  [IO.File]::WriteAllBytes($posixReplacePath, $posixOldBytes)
  $posixOldSnapshot = Get-DreamSkinStableFileSnapshot -Path $posixReplacePath
  $posixWrite = [DreamSkinConfigNative]::BeginAtomicWrite($posixReplacePath, $posixNewBytes)
  try {
    $posixCandidatePath = @(Get-ChildItem -LiteralPath $posixReplaceRoot -Filter '*.tmp' -Force).FullName
    if (@($posixCandidatePath).Count -ne 1) {
      throw 'atomic-existing-posix-replace did not expose one held candidate.'
    }
    $posixCandidateSnapshot = Get-DreamSkinStableFileSnapshot -Path $posixCandidatePath
    foreach ($operation in @('move', 'replace')) {
      if ((Invoke-AtomicNamespaceProbe -Operation $operation -Path $posixReplacePath `
        -Root $posixReplaceRoot) -ne 23) {
        throw "atomic-existing-posix-replace allowed a child $operation before commit."
      }
    }
    try {
      $posixWrite.Commit()
    } catch {
      $preserved = Get-DreamSkinStableFileSnapshot -Path $posixReplacePath
      if ($preserved.Identity -cne $posixOldSnapshot.Identity -or
        -not (Test-DreamSkinBytesEqual -Left $posixOldBytes -Right $preserved.Bytes)) {
        throw 'POSIX replacement failed without preserving the exact old target.'
      }
      throw "atomic-existing-posix-replace is unsupported or failed closed on this host: $($_.Exception.Message)"
    }
    $posixPublished = Get-DreamSkinStableFileSnapshot -Path $posixReplacePath
    if ($posixPublished.Identity -cne $posixCandidateSnapshot.Identity -or
      -not (Test-DreamSkinBytesEqual -Left $posixNewBytes -Right $posixPublished.Bytes)) {
      throw 'atomic-existing-posix-replace did not publish the held candidate identity.'
    }
    foreach ($operation in @('write', 'move', 'replace', 'delete')) {
      if ((Invoke-AtomicNamespaceProbe -Operation $operation -Path $posixReplacePath `
        -Root $posixReplaceRoot) -ne 23) {
        throw "atomic-final-proof-handle-pin allowed a child $operation after Commit before Dispose."
      }
    }
  } finally {
    $posixWrite.Dispose()
  }
  if (-not (Test-Path -LiteralPath $posixReplacePath -PathType Leaf) -or
    -not (Test-DreamSkinBytesEqual -Left $posixNewBytes -Right ([IO.File]::ReadAllBytes($posixReplacePath)))) {
    throw 'atomic-final-proof-handle-pin lost the canonical file when its handles closed.'
  }

  $atomicChildScript = Join-Path $temporaryRoot 'atomic-child.ps1'
  [IO.File]::WriteAllText($atomicChildScript, @'
param([string]$ConfigScript, [string]$Path, [string]$Payload, [string]$SignalPath, [string]$Mode)
$ErrorActionPreference = 'Stop'
. $ConfigScript
$transaction = [DreamSkinConfigNative]::BeginAtomicWrite($Path, [Convert]::FromBase64String($Payload))
[IO.File]::WriteAllText($SignalPath, 'prepared')
if ($Mode -ceq 'after') {
  $transaction.Commit()
  [IO.File]::WriteAllText($SignalPath, 'committed')
}
while ($true) { Start-Sleep -Milliseconds 100 }
'@, $utf8NoBom)

  function Wait-AtomicChildSignal {
    param([Diagnostics.Process]$Process, [string]$SignalPath, [string]$Expected, [string]$CanonicalPath)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $missingSeen = $false
    while ([DateTime]::UtcNow -lt $deadline) {
      if (-not [IO.File]::Exists($CanonicalPath)) { $missingSeen = $true }
      if ([IO.File]::Exists($SignalPath)) {
        try {
          if ([IO.File]::ReadAllText($SignalPath) -ceq $Expected) { return $missingSeen }
        } catch [IO.IOException] {}
      }
      if ($Process.HasExited) { throw "Atomic child exited before signal '$Expected': $($Process.ExitCode)" }
      Start-Sleep -Milliseconds 1
    }
    throw "Timed out waiting for atomic child signal '$Expected'."
  }

  $configScriptPath = Join-Path $Root 'scripts\config-utf8.ps1'
  foreach ($killCase in @(
    @{ Name = 'atomic-kill-before-commit'; Mode = 'before' },
    @{ Name = 'atomic-kill-after-commit'; Mode = 'after' }
  )) {
    $killMode = $killCase.Mode
    $killRoot = Join-Path $temporaryRoot $killCase.Name
    New-Item -ItemType Directory -Path $killRoot | Out-Null
    $killTarget = Join-Path $killRoot 'config.toml'
    $killSignal = Join-Path $killRoot 'signal.txt'
    $killOldBytes = $utf8NoBom.GetBytes("kill-$killMode-old")
    $killNewBytes = $utf8NoBom.GetBytes("kill-$killMode-new")
    [IO.File]::WriteAllBytes($killTarget, $killOldBytes)
    $killChild = Start-Process -FilePath $powershell -PassThru -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $atomicChildScript,
      '-ConfigScript', $configScriptPath, '-Path', $killTarget,
      '-Payload', [Convert]::ToBase64String($killNewBytes), '-SignalPath', $killSignal, '-Mode', $killMode
    )
    try {
      $expectedSignal = if ($killMode -ceq 'after') { 'committed' } else { 'prepared' }
      $missingSeen = Wait-AtomicChildSignal -Process $killChild -SignalPath $killSignal `
        -Expected $expectedSignal -CanonicalPath $killTarget
      if ($missingSeen) { throw "$($killCase.Name) observed a missing canonical path." }
    } finally {
      if (-not $killChild.HasExited) {
        Microsoft.PowerShell.Management\Stop-Process -Id $killChild.Id -Force
      }
      $killChild.WaitForExit()
      $killChild.Dispose()
    }
    $killExpected = if ($killMode -ceq 'after') { $killNewBytes } else { $killOldBytes }
    if (-not [IO.File]::Exists($killTarget) -or
      -not (Test-DreamSkinBytesEqual -Left $killExpected -Right ([IO.File]::ReadAllBytes($killTarget)))) {
      throw "$($killCase.Name) did not retain the exact expected canonical generation."
    }
    $retryBytes = $utf8NoBom.GetBytes("kill-$killMode-retry")
    Write-DreamSkinBytesAtomically -Path $killTarget -Bytes $retryBytes
    if (-not (Test-DreamSkinBytesEqual -Left $retryBytes -Right ([IO.File]::ReadAllBytes($killTarget)))) {
      throw "$($killCase.Name) could not retry in a fresh transaction."
    }
  }

  $rollbackRoot = Join-Path $temporaryRoot 'atomic-posix-rollback'
  New-Item -ItemType Directory -Path $rollbackRoot | Out-Null
  $rollbackTarget = Join-Path $rollbackRoot 'config.toml'
  $rollbackOldBytes = $utf8NoBom.GetBytes('rollback exact old')
  [IO.File]::WriteAllBytes($rollbackTarget, $rollbackOldBytes)
  $rollbackOldSnapshot = Get-DreamSkinStableFileSnapshot -Path $rollbackTarget
  $rollbackConfig = Join-Path $rollbackRoot 'config-utf8-injected.ps1'
  $rollbackSource = [IO.File]::ReadAllText($configScriptPath)
  $rollbackFinalProofPattern = '(?m)^(\s*)AssertCommitted\(\);\r?\n\1committed = true;'
  if ([regex]::Matches($rollbackSource, $rollbackFinalProofPattern).Count -ne 1) {
    throw 'atomic-posix-rollback could not locate its post-publication injection boundary.'
  }
  $rollbackSource = [regex]::Replace($rollbackSource, $rollbackFinalProofPattern,
    '$1AssertCommitted();' + [Environment]::NewLine +
    '$1throw new IOException("atomic-posix-rollback final publication marker");', 1)
  [IO.File]::WriteAllText($rollbackConfig, $rollbackSource, $utf8NoBom)
  $rollbackChildScript = Join-Path $rollbackRoot 'rollback-child.ps1'
  [IO.File]::WriteAllText($rollbackChildScript, @'
param([string]$ConfigScript, [string]$Path, [string]$Payload)
$ErrorActionPreference = 'Stop'
. $ConfigScript
$transaction = $null
$rejected = $false
try {
  $transaction = [DreamSkinConfigNative]::BeginAtomicWrite($Path, [Convert]::FromBase64String($Payload))
  $transaction.Commit()
} catch {
  $rejected = $null -ne $transaction -and $transaction.RollbackConfirmed -and
    $_.Exception.Message -match 'atomic-posix-rollback final publication marker'
} finally {
  if ($null -ne $transaction) { $transaction.Dispose() }
}
if (-not $rejected) { exit 31 }
'@, $utf8NoBom)
  $rollbackChild = Start-Process -FilePath $powershell -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rollbackChildScript,
    '-ConfigScript', $rollbackConfig, '-Path', $rollbackTarget,
    '-Payload', [Convert]::ToBase64String($utf8NoBom.GetBytes('rollback candidate'))
  )
  $rollbackMissingSeen = $false
  while (-not $rollbackChild.HasExited) {
    if (-not [IO.File]::Exists($rollbackTarget)) { $rollbackMissingSeen = $true }
    Start-Sleep -Milliseconds 1
  }
  $rollbackChild.WaitForExit()
  $rollbackExitCode = $rollbackChild.ExitCode
  $rollbackChild.Dispose()
  $rollbackAfter = Get-DreamSkinStableFileSnapshot -Path $rollbackTarget
  if ($rollbackExitCode -ne 0 -or $rollbackMissingSeen -or
    $rollbackAfter.Identity -cne $rollbackOldSnapshot.Identity -or
    -not (Test-DreamSkinBytesEqual -Left $rollbackOldBytes -Right $rollbackAfter.Bytes)) {
    throw 'atomic-posix-rollback did not atomically restore the exact held old target.'
  }

  $constructorRoot = Join-Path $temporaryRoot 'atomic-constructor-create-failure-retry'
  New-Item -ItemType Directory -Path $constructorRoot | Out-Null
  $constructorTarget = Join-Path $constructorRoot 'config.toml'
  [IO.File]::WriteAllText($constructorTarget, 'constructor old', $utf8NoBom)
  $constructorAcl = Get-Acl -LiteralPath $constructorRoot
  $blockedAcl = Get-Acl -LiteralPath $constructorRoot
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $denyCreate = [Security.AccessControl.FileSystemAccessRule]::new(
    $currentIdentity, [Security.AccessControl.FileSystemRights]::CreateFiles,
    [Security.AccessControl.InheritanceFlags]::None,
    [Security.AccessControl.PropagationFlags]::None,
    [Security.AccessControl.AccessControlType]::Deny)
  $blockedAcl.AddAccessRule($denyCreate)
  $constructorRejected = $false
  $unexpectedConstructorWrite = $null
  try {
    Set-Acl -LiteralPath $constructorRoot -AclObject $blockedAcl
    try {
      $unexpectedConstructorWrite = [DreamSkinConfigNative]::BeginAtomicWrite(
        $constructorTarget, $utf8NoBom.GetBytes('constructor blocked'))
    } catch {
      $constructorRejected = $true
    }
  } finally {
    if ($null -ne $unexpectedConstructorWrite) { $unexpectedConstructorWrite.Dispose() }
    Set-Acl -LiteralPath $constructorRoot -AclObject $constructorAcl
  }
  $constructorRetryBytes = $utf8NoBom.GetBytes('constructor retry')
  Write-DreamSkinBytesAtomically -Path $constructorTarget -Bytes $constructorRetryBytes
  if (-not $constructorRejected -or
    -not (Test-DreamSkinBytesEqual -Left $constructorRetryBytes -Right ([IO.File]::ReadAllBytes($constructorTarget)))) {
    throw 'atomic-constructor-create-failure-retry leaked a held target or failed its immediate retry.'
  }

  $proofDeleteRoot = Join-Path $temporaryRoot 'proof-replaced-before-handle-delete'
  New-Item -ItemType Directory -Path $proofDeleteRoot | Out-Null
  $proofDeletePath = Join-Path $proofDeleteRoot 'config.restored.toml'
  [IO.File]::WriteAllText($proofDeletePath, 'validated proof', $utf8NoBom)
  $proofDeleteSnapshot = Get-DreamSkinStableFileSnapshot -Path $proofDeletePath
  $proofCreator = Join-Path $proofDeleteRoot 'creator.tmp'
  [IO.File]::WriteAllText($proofCreator, 'unexpected creator', $utf8NoBom)
  [IO.File]::Replace($proofCreator, $proofDeletePath, $null)
  $proofCreatorSnapshot = Get-DreamSkinStableFileSnapshot -Path $proofDeletePath
  $proofDeleteRejected = $false
  try {
    [DreamSkinConfigNative]::DeleteExpectedFile(
      $proofDeletePath, $proofDeleteSnapshot.Identity, $proofDeleteSnapshot.Bytes)
  } catch {
    $proofDeleteRejected = $true
  }
  $proofCreatorAfter = Get-DreamSkinStableFileSnapshot -Path $proofDeletePath
  if (-not $proofDeleteRejected -or $proofCreatorAfter.Identity -cne $proofCreatorSnapshot.Identity -or
    -not (Test-DreamSkinBytesEqual -Left $proofCreatorSnapshot.Bytes -Right $proofCreatorAfter.Bytes)) {
    throw 'proof-replaced-before-handle-delete removed or accepted an unexpected creator.'
  }

  $sameProofRoot = Join-Path $temporaryRoot 'proof-same-bytes-creator-compensation'
  New-Item -ItemType Directory -Path $sameProofRoot | Out-Null
  $sameProofPath = Join-Path $sameProofRoot 'config.restored.toml'
  [IO.File]::WriteAllText($sameProofPath, 'same proof bytes', $utf8NoBom)
  $sameProofSnapshot = Get-DreamSkinStableFileSnapshot -Path $sameProofPath
  Remove-DreamSkinConfigCompletionEvidence -ArchivePath $sameProofPath -Snapshots @($sameProofSnapshot)
  [IO.File]::WriteAllBytes($sameProofPath, $sameProofSnapshot.Bytes)
  $sameProofCreator = Get-DreamSkinStableFileSnapshot -Path $sameProofPath
  $sameProofRejected = $false
  try {
    Restore-DreamSkinConfigCompletionEvidenceSnapshots -Snapshots @($sameProofSnapshot)
  } catch {
    $sameProofRejected = $true
  }
  $sameProofAfter = Get-DreamSkinStableFileSnapshot -Path $sameProofPath
  if (-not $sameProofRejected -or $sameProofAfter.Identity -cne $sameProofCreator.Identity -or
    -not (Test-DreamSkinBytesEqual -Left $sameProofSnapshot.Bytes -Right $sameProofAfter.Bytes)) {
    throw 'proof-same-bytes-creator-compensation accepted or overwrote an unexpected creator.'
  }

  $longPathRoot = Join-Path $temporaryRoot 'native-long-path'
  $longDirectory = $longPathRoot
  foreach ($index in 1..5) {
    $longDirectory = Join-Path $longDirectory (("segment-$index-") + ('x' * 48))
  }
  $nativeLongDirectory = if ($longDirectory.StartsWith('\\')) {
    '\\?\UNC\' + $longDirectory.Substring(2)
  } else { '\\?\' + $longDirectory }
  [IO.Directory]::CreateDirectory($nativeLongDirectory) | Out-Null
  $longTarget = Join-Path $longDirectory 'config.toml'
  $nativeLongTarget = if ($longTarget.StartsWith('\\')) {
    '\\?\UNC\' + $longTarget.Substring(2)
  } else { '\\?\' + $longTarget }
  $longBytes = $utf8NoBom.GetBytes('native long path')
  Write-DreamSkinBytesAtomically -Path $longTarget -Bytes $longBytes
  if ($longTarget.Length -le 260 -or
    -not (Test-DreamSkinBytesEqual -Left $longBytes -Right ([IO.File]::ReadAllBytes($nativeLongTarget)))) {
    throw 'native-long-path wrapper did not publish beyond legacy MAX_PATH.'
  }

  $longDirectTarget = Join-Path $longDirectory 'direct-config.toml'
  $nativeLongDirectTarget = if ($longDirectTarget.StartsWith('\\')) {
    '\\?\UNC\' + $longDirectTarget.Substring(2)
  } else { '\\?\' + $longDirectTarget }
  $longDirectBytes = $utf8NoBom.GetBytes('native extended long path')
  $longWrite = [DreamSkinConfigNative]::BeginAtomicWrite($nativeLongDirectTarget, $longDirectBytes)
  try { $longWrite.Commit() } finally { $longWrite.Dispose() }
  if (-not (Test-DreamSkinBytesEqual -Left $longDirectBytes `
    -Right ([IO.File]::ReadAllBytes($nativeLongDirectTarget)))) {
    throw 'native-long-path direct extended transaction failed.'
  }
  $nativeLongRoot = if ($longPathRoot.StartsWith('\\')) {
    '\\?\UNC\' + $longPathRoot.Substring(2)
  } else { '\\?\' + $longPathRoot }
  [IO.Directory]::Delete($nativeLongRoot, $true)
  New-Item -ItemType Directory -Path $longPathRoot | Out-Null

  $overlongComponent = ('z' * 256) + '.toml'
  $overlongTarget = Join-Path $longPathRoot $overlongComponent
  $overlongRejected = $false
  try {
    $null = [DreamSkinConfigNative]::BeginAtomicWrite($overlongTarget, $utf8NoBom.GetBytes('reject'))
  } catch {
    $overlongRejected = $true
  }
  if (-not $overlongRejected -or
    (Test-Path -LiteralPath $overlongTarget -ErrorAction SilentlyContinue) -or
    @(Get-ChildItem -LiteralPath $longPathRoot -Force -ErrorAction SilentlyContinue).Count -ne 0) {
    throw 'native-long-path did not reject an overlong component before mutation.'
  }
  if ($env:DREAM_SKIN_TEST_UNC_ROOT) {
    $uncRoot = Join-Path $env:DREAM_SKIN_TEST_UNC_ROOT "codex-dream-skin-$PID-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $uncRoot | Out-Null
    try {
      $uncTarget = Join-Path $uncRoot 'config.toml'
      $uncBytes = $utf8NoBom.GetBytes('native UNC comparable path')
      $nativeUncTarget = if ($uncTarget.StartsWith('\\?\UNC\')) {
        $uncTarget
      } else { '\\?\UNC\' + $uncTarget.Substring(2) }
      $uncWrite = [DreamSkinConfigNative]::BeginAtomicWrite($nativeUncTarget, $uncBytes)
      try { $uncWrite.Commit() } finally { $uncWrite.Dispose() }
      if (-not (Test-DreamSkinBytesEqual -Left $uncBytes -Right ([IO.File]::ReadAllBytes($uncTarget)))) {
        throw 'native-long-path UNC comparable-path case failed.'
      }
    } finally {
      Remove-Item -LiteralPath $uncRoot -Recurse -Force
    }
  }

  $missingParentRoot = Join-Path $temporaryRoot 'missing-parent-guard'
  $missingProfile = Join-Path $missingParentRoot 'profile'
  $missingExternal = Join-Path $missingParentRoot 'external'
  $missingComponent = Join-Path $missingProfile '.codex'
  $missingConfig = Join-Path $missingComponent 'config.toml'
  New-Item -ItemType Directory -Path $missingProfile, $missingExternal -Force | Out-Null
  foreach ($reappearance in @('directory', 'file', 'junction')) {
    $missingGuard = [DreamSkinConfigNative]::HoldMissingPath($missingConfig)
    try {
      switch ($reappearance) {
        'directory' { New-Item -ItemType Directory -Path $missingComponent | Out-Null }
        'file' { [IO.File]::WriteAllText($missingComponent, 'appeared', $utf8NoBom) }
        'junction' { New-Item -ItemType Junction -Path $missingComponent -Target $missingExternal | Out-Null }
      }
      $reappearanceRejected = $false
      try { $missingGuard.AssertUnchanged() } catch { $reappearanceRejected = $true }
      if (-not $reappearanceRejected) {
        throw "missing-parent-guard accepted $reappearance reappearance."
      }
    } finally {
      if (Test-Path -LiteralPath $missingComponent) {
        $missingItem = Get-Item -LiteralPath $missingComponent -Force
        if ($missingItem.PSIsContainer -and
          ($missingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
          Remove-Item -LiteralPath $missingComponent -Recurse -Force
        } else {
          Remove-Item -LiteralPath $missingComponent -Force
        }
      }
      $missingGuard.Dispose()
    }
  }

  $guardRetryRoot = Join-Path $temporaryRoot 'missing-guard-constructor-appearance-retry'
  $guardRetryProfile = Join-Path $guardRetryRoot 'profile'
  $guardRetryConfig = Join-Path $guardRetryProfile '.codex\config.toml'
  New-Item -ItemType Directory -Path $guardRetryProfile -Force | Out-Null
  $guardRetrySource = [IO.File]::ReadAllText($configScriptPath)
  $guardRetryNeedle =
    '                anchor = FindNearestExistingAncestor(fullPath, out trustedAnchorPath, out missingPath);'
  if (-not $guardRetrySource.Contains($guardRetryNeedle)) {
    throw 'missing-guard-constructor-appearance-retry could not locate its acquisition boundary.'
  }
  $guardRetrySource = $guardRetrySource.Replace($guardRetryNeedle,
    $guardRetryNeedle + "`r`n                Directory.CreateDirectory(missingPath);")
  $guardRetryConfigScript = Join-Path $guardRetryRoot 'config-utf8-injected.ps1'
  [IO.File]::WriteAllText($guardRetryConfigScript, $guardRetrySource, $utf8NoBom)
  $guardRetryChildScript = Join-Path $guardRetryRoot 'guard-retry-child.ps1'
  [IO.File]::WriteAllText($guardRetryChildScript, @'
param([string]$ConfigScript, [string]$ProfilePath, [string]$ConfigPath)
$ErrorActionPreference = 'Stop'
. $ConfigScript
$unexpected = $null
$rejected = $false
try {
  $unexpected = [DreamSkinConfigNative]::HoldMissingPath($ConfigPath)
} catch {
  $rejected = $true
} finally {
  if ($null -ne $unexpected) { $unexpected.Dispose() }
}
if (-not $rejected) { exit 41 }
$missingComponent = Join-Path $ProfilePath '.codex'
if (Test-Path -LiteralPath $missingComponent) {
  Remove-Item -LiteralPath $missingComponent -Recurse -Force
}
$movedProfile = "$ProfilePath-moved"
[IO.Directory]::Move($ProfilePath, $movedProfile)
[IO.Directory]::Move($movedProfile, $ProfilePath)
$guard = [DreamSkinConfigNative]::HoldMissingPath($ConfigPath)
try { $guard.Complete() } finally { $guard.Dispose() }
'@, $utf8NoBom)
  & $powershell -NoProfile -ExecutionPolicy Bypass -File $guardRetryChildScript `
    -ConfigScript $guardRetryConfigScript -ProfilePath $guardRetryProfile -ConfigPath $guardRetryConfig
  if ($LASTEXITCODE -ne 0) {
    throw "missing-guard-constructor-appearance-retry failed with exit code $LASTEXITCODE."
  }

  $nativeParentRoot = Join-Path $temporaryRoot 'commit-parent-junction-native-boundary'
  $nativeProfile = Join-Path $nativeParentRoot 'profile'
  $nativeConfigDirectory = Join-Path $nativeProfile '.codex'
  $nativeHeldDirectory = Join-Path $nativeProfile '.codex-held'
  $nativeExternalDirectory = Join-Path $nativeParentRoot 'external'
  $nativeConfig = Join-Path $nativeConfigDirectory 'config.toml'
  New-Item -ItemType Directory -Path $nativeConfigDirectory, $nativeExternalDirectory -Force | Out-Null
  [IO.File]::WriteAllText($nativeConfig, 'original native boundary', $utf8NoBom)
  $nativeConfigBytes = [IO.File]::ReadAllBytes($nativeConfig)
  $nativeConfigBefore = Get-DreamSkinStableFileSnapshot -Path $nativeConfig
  $nativeCandidateBytes = $utf8NoBom.GetBytes('sensitive candidate')
  $nativeWrite = [DreamSkinConfigNative]::BeginAtomicWrite(
    [IO.Path]::GetFullPath($nativeConfig), $nativeCandidateBytes)
  $nativeCommitRejected = $false
  $nativeRace = [pscustomobject]@{ Attempted = $false; Denied = $false; Substituted = $false }
  try {
    $nativeRace.Attempted = $true
    try {
      Move-Item -LiteralPath $nativeConfigDirectory -Destination $nativeHeldDirectory
      $nativeRace.Substituted = $true
    } catch {
      $nativeRace.Denied = $true
    }
    if ($nativeRace.Substituted) {
      New-Item -ItemType Junction -Path $nativeConfigDirectory -Target $nativeExternalDirectory | Out-Null
    }
    try { $nativeWrite.Commit() } catch {
      $nativeCommitRejected = $nativeWrite.RollbackConfirmed -and
        $_.Exception.Message -match 'atomic|commit|rollback'
    }
  } finally {
    $nativeWrite.Dispose()
    if ((Test-Path -LiteralPath $nativeConfigDirectory) -and
      ((Get-Item -LiteralPath $nativeConfigDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      Remove-Item -LiteralPath $nativeConfigDirectory -Force
    }
    if (Test-Path -LiteralPath $nativeHeldDirectory -PathType Container) {
      Move-Item -LiteralPath $nativeHeldDirectory -Destination $nativeConfigDirectory
    }
  }
  $nativeAfter = Get-DreamSkinStableFileSnapshot -Path $nativeConfig
  $nativeCanonicalCorrect = if ($nativeCommitRejected) {
    $nativeAfter.Identity -ceq $nativeConfigBefore.Identity -and
      (Test-DreamSkinBytesEqual -Left $nativeConfigBytes -Right $nativeAfter.Bytes)
  } else {
    $nativeAfter.Identity -cne $nativeConfigBefore.Identity -and
      (Test-DreamSkinBytesEqual -Left $nativeCandidateBytes -Right $nativeAfter.Bytes)
  }
  if (-not $nativeRace.Attempted -or -not $nativeRace.Denied -or $nativeRace.Substituted -or
    -not $nativeCanonicalCorrect -or
    (Get-ChildItem -LiteralPath $nativeExternalDirectory -Force -ErrorAction SilentlyContinue)) {
    throw 'commit-parent-junction-native-boundary did not deny parent substitution before canonical publication.'
  }

  foreach ($parentCase in @(
    'commit-parent-junction-install',
    'commit-parent-junction-selective',
    'commit-parent-junction-exact',
    'commit-parent-junction-rollback'
  )) {
    $operation = $parentCase.Substring('commit-parent-junction-'.Length)
    $caseRoot = Join-Path $temporaryRoot $parentCase
    $profileRoot = Join-Path $caseRoot 'profile'
    $configDirectory = Join-Path $profileRoot '.codex'
    $heldDirectory = Join-Path $profileRoot '.codex-held'
    $externalDirectory = Join-Path $caseRoot 'external'
    $parentConfig = Join-Path $configDirectory 'config.toml'
    $parentBackup = Join-Path $caseRoot 'config.before-dream-skin.toml'
    $parentRecovery = Join-Path $caseRoot 'config.before-recovery.toml'
    New-Item -ItemType Directory -Path $configDirectory, $externalDirectory -Force | Out-Null
    $parentCurrent = if ($operation -eq 'install') {
      "model = `"gpt-5`"`r`n"
    } else {
      "[desktop]`r`n$($script:DreamSkinManagedLightCodeTheme)`r`n$($script:DreamSkinManagedLightChromeTheme)`r`n"
    }
    [IO.File]::WriteAllText($parentConfig, $parentCurrent, $utf8NoBom)
    if ($operation -in @('selective', 'exact')) {
      [IO.File]::WriteAllText($parentBackup, "model = `"baseline`"`r`n", $utf8NoBom)
    }
    $parentConfigBefore = [IO.File]::ReadAllBytes($parentConfig)
    $parentBackupBefore = if (Test-Path -LiteralPath $parentBackup -PathType Leaf) {
      [IO.File]::ReadAllBytes($parentBackup)
    } else { $null }
    $parentSnapshot = Get-DreamSkinStableFileSnapshot -Path $parentConfig
    $originalStableAssert = ${function:Assert-DreamSkinStableFileSnapshotUnchanged}
    $assertionTarget = [IO.Path]::GetFullPath($parentConfig)
    $parentRace = [pscustomobject]@{ Attempted = $false; Denied = $false; Substituted = $false }
    $parentAssert = {
      param([Parameter(Mandatory = $true)]$Snapshot)
      & $originalStableAssert -Snapshot $Snapshot
      $candidateExists = $null -ne (Get-ChildItem -LiteralPath $configDirectory -Filter '.*.tmp' -Force `
        -ErrorAction SilentlyContinue | Select-Object -First 1)
      if ($Snapshot.FullPath.Equals($assertionTarget, [StringComparison]::OrdinalIgnoreCase) -and
        -not $parentRace.Attempted -and $candidateExists) {
        $parentRace.Attempted = $true
        try {
          Move-Item -LiteralPath $configDirectory -Destination $heldDirectory
          $parentRace.Substituted = $true
        } catch {
          $parentRace.Denied = $true
        }
        if ($parentRace.Substituted) {
          $null = New-Item -ItemType Junction -Path $configDirectory -Target $externalDirectory
        }
      }
    }.GetNewClosure()
    $parentRejected = $false
    try {
      Set-Item Function:\Assert-DreamSkinStableFileSnapshotUnchanged -Value $parentAssert
      try {
        switch ($operation) {
          'install' { Install-DreamSkinBaseTheme -ConfigPath $parentConfig -BackupPath $parentBackup }
          'selective' { Restore-DreamSkinBaseTheme -ConfigPath $parentConfig -BackupPath $parentBackup }
          'exact' {
            Restore-DreamSkinConfigBackup -ConfigPath $parentConfig -BackupPath $parentBackup `
              -RecoveryBackupPath $parentRecovery
          }
          'rollback' {
            Write-DreamSkinBytesAtomically -Path $parentConfig -Bytes ($utf8NoBom.GetBytes('rollback')) `
              -ExpectedBytes $parentConfigBefore -ExpectedSnapshot $parentSnapshot
          }
        }
      } catch {
        $parentRejected = $_.Exception.Message -match 'atomic|commit|rollback'
      }
    } finally {
      Set-Item Function:\Assert-DreamSkinStableFileSnapshotUnchanged -Value $originalStableAssert
      if ((Test-Path -LiteralPath $configDirectory) -and
        ((Get-Item -LiteralPath $configDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $configDirectory -Force
      }
      if (Test-Path -LiteralPath $heldDirectory -PathType Container) {
        Move-Item -LiteralPath $heldDirectory -Destination $configDirectory
      }
    }
    $parentRecoverySafe = if ($operation -eq 'exact' -and $parentRejected) {
      -not (Test-Path -LiteralPath $parentRecovery)
    } elseif ($operation -eq 'exact') {
      (Test-Path -LiteralPath $parentRecovery -PathType Leaf) -and
        (Test-DreamSkinBytesEqual -Left $parentConfigBefore -Right ([IO.File]::ReadAllBytes($parentRecovery)))
    } else { -not (Test-Path -LiteralPath $parentRecovery) }
    $parentAfter = Get-DreamSkinStableFileSnapshot -Path $parentConfig
    $parentCanonicalCorrect = if ($parentRejected) {
      $parentAfter.Identity -ceq $parentSnapshot.Identity -and
        (Test-DreamSkinBytesEqual -Left $parentConfigBefore -Right $parentAfter.Bytes)
    } else {
      switch ($operation) {
        'install' { Test-DreamSkinBaseThemeManaged -ConfigPath $parentConfig }
        'selective' { -not (Test-DreamSkinBaseThemeManaged -ConfigPath $parentConfig) }
        'exact' { Test-DreamSkinBytesEqual -Left $parentBackupBefore -Right $parentAfter.Bytes }
        'rollback' { Test-DreamSkinBytesEqual -Left ($utf8NoBom.GetBytes('rollback')) -Right $parentAfter.Bytes }
      }
    }
    if (-not $parentRace.Attempted -or -not $parentRace.Denied -or $parentRace.Substituted -or
      -not $parentCanonicalCorrect -or
      (Get-ChildItem -LiteralPath $externalDirectory -Force -ErrorAction SilentlyContinue) -or
      -not $parentRecoverySafe) {
      throw "$parentCase did not deny parent substitution while publishing or fail-closing the canonical generation."
    }
    if ($null -eq $parentBackupBefore) {
      if ($operation -eq 'install') {
        if (-not (Test-Path -LiteralPath $parentBackup -PathType Leaf) -or
          -not (Test-DreamSkinBytesEqual -Left $parentConfigBefore -Right ([IO.File]::ReadAllBytes($parentBackup)))) {
          throw "$parentCase discarded the live backup after an uncertain parent swap."
        }
      } elseif (Test-Path -LiteralPath $parentBackup) {
        throw "$parentCase created an unrelated backup before rejecting the parent swap."
      }
    } elseif (-not (Test-DreamSkinBytesEqual -Left $parentBackupBefore -Right ([IO.File]::ReadAllBytes($parentBackup)))) {
      throw "$parentCase changed its live backup after the parent swap."
    }
  }

  if (-not (Test-DreamSkinWebSocketUrl -Value 'ws://127.0.0.1:9335/devtools/page/test' -Port 9335)) {
    throw 'PowerShell loopback WebSocket validation rejected a safe target.'
  }
  foreach ($unsafe in @(
    'ws://example.com:9335/devtools/page/test',
    'ws://127.0.0.1:9336/devtools/page/test',
    'wss://127.0.0.1:9335/devtools/page/test',
    'ws://user@127.0.0.1:9335/devtools/page/test',
    'ws://127.0.0.1:9335/unexpected/test',
    'ws://127.0.0.1:9335/devtools/page/test?query=1'
  )) {
    if (Test-DreamSkinWebSocketUrl -Value $unsafe -Port 9335) { throw "Accepted unsafe CDP target: $unsafe" }
  }
  $safePageTarget = [pscustomobject]@{
    id = 'page-123'
    type = 'page'
    url = 'app://codex/'
    webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/page-123'
  }
  if (-not (Test-DreamSkinCdpPageTarget -Target $safePageTarget -Port 9335)) {
    throw 'A valid same-ID CDP page target was rejected.'
  }
  foreach ($unsafePageTarget in @(
    [pscustomobject]@{ id = 'page-123'; type = 'page'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/browser/page-123' },
    [pscustomobject]@{ id = 'other-page'; type = 'page'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/page-123' },
    [pscustomobject]@{ id = 123; type = 'page'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/123' },
    [pscustomobject]@{ id = 'page-123'; type = 'other'; url = 'app://codex/'; webSocketDebuggerUrl = 'ws://127.0.0.1:9335/devtools/page/page-123' }
  )) {
    if (Test-DreamSkinCdpPageTarget -Target $unsafePageTarget -Port 9335) {
      throw 'Accepted an inconsistent CDP page target.'
    }
  }
  $watchCommand = '"C:\Program Files\nodejs\node.exe" "C:\Dream Skin\injector.mjs" --watch --port 9335 --browser-id browser-123'
  if (-not (Test-DreamSkinCommandLineToken -CommandLine $watchCommand -Token 'C:\Dream Skin\injector.mjs') -or
    (Test-DreamSkinCommandLineToken -CommandLine $watchCommand -Token 'Dream Skin\injector.mjs')) {
    throw 'Injector command-line token validation is not boundary-safe.'
  }
  if (-not (Test-DreamSkinBrowserId -Value 'browser-123') -or
    (Test-DreamSkinBrowserId -Value 'browser 123')) {
    throw 'CDP browser ID validation is not boundary-safe.'
  }
  $quotedProfile = ConvertTo-DreamSkinProcessArgument -Value '--user-data-dir=C:\Dream Skin\Profile\'
  if ($quotedProfile -cne '"--user-data-dir=C:\Dream Skin\Profile\\"') {
    throw 'Process argument quoting did not protect spaces and a trailing backslash.'
  }

  $statePath = Join-Path $temporaryRoot 'state.json'
  $state = [pscustomobject]@{
    schemaVersion = 3
    platform = 'windows'
    port = 9335
    injectorPid = 1234
    injectorStartedAt = '2026-01-01T00:00:00.0000000Z'
    injectorPath = 'C:\Dream Skin\injector.mjs'
    nodePath = 'C:\Program Files\nodejs\node.exe'
    codexExe = 'C:\Program Files\WindowsApps\OpenAI.Codex\app\ChatGPT.exe'
    codexPackageRoot = 'C:\Program Files\WindowsApps\OpenAI.Codex'
    codexPackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    codexPackageFamilyName = 'OpenAI.Codex_test'
    browserId = 'browser-123'
  }
  Write-DreamSkinState -Path $statePath -State $state
  $loadedState = Read-DreamSkinState -Path $statePath
  if ($loadedState.schemaVersion -ne 3 -or $loadedState.port -ne 9335 -or
    $loadedState.browserId -cne 'browser-123') { throw 'State round-trip failed.' }
  $missingIdentityState = [pscustomobject]@{ schemaVersion = 3; platform = 'windows'; port = 9335 }
  Write-DreamSkinState -Path $statePath -State $missingIdentityState
  $missingIdentityRejected = $false
  try { $null = Read-DreamSkinState -Path $statePath } catch { $missingIdentityRejected = $true }
  if (-not $missingIdentityRejected) { throw 'Schema 3 accepted a state missing process and package identity.' }
  $legacyState = [pscustomobject]@{ schemaVersion = 2; platform = 'windows'; port = 9335; injectorPid = 1234 }
  Write-DreamSkinState -Path $statePath -State $legacyState
  if ((Read-DreamSkinState -Path $statePath).schemaVersion -ne 2) {
    throw 'A supported schema 2 state was rejected.'
  }

  $fakePackageRoot = Join-Path $temporaryRoot 'OpenAI.Codex_1.2.3.4_x64__test'
  $fakeExecutable = Join-Path $fakePackageRoot 'app\ChatGPT.exe'
  New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExecutable) -Force | Out-Null
  [System.IO.File]::WriteAllBytes($fakeExecutable, [byte[]]@())
  $fakePackage = [pscustomobject]@{
    Name = 'OpenAI.Codex'
    InstallLocation = $fakePackageRoot
    PackageFullName = 'OpenAI.Codex_1.2.3.4_x64__test'
    PackageFamilyName = 'OpenAI.Codex_test'
    SignatureKind = 'Store'
    IsDevelopmentMode = $false
    Version = [version]'1.2.3.4'
  }
  $fakeInstall = ConvertTo-DreamSkinCodexInstall -Package $fakePackage
  if ($null -eq $fakeInstall -or $fakeInstall.PackageFullName -cne $fakePackage.PackageFullName -or
    -not (Test-DreamSkinPathEqual -Left $fakeInstall.Executable -Right $fakeExecutable)) {
    throw 'Registered Appx package identity conversion failed.'
  }
  $fakePackage.SignatureKind = 'Developer'
  if ($null -ne (ConvertTo-DreamSkinCodexInstall -Package $fakePackage)) {
    throw 'A non-Store Appx package was accepted as official Codex.'
  }
  $fakePackage.SignatureKind = 'Store'
  $pathOnlyState = [pscustomobject]@{
    codexExe = $fakeExecutable
    codexPackageRoot = $fakePackageRoot
    codexVersion = '1.2.3.4'
  }
  if ($null -eq (Get-DreamSkinCodexStatePathCandidate -State $pathOnlyState)) {
    throw 'A structurally valid legacy Codex path was not recognized for read-only activity checks.'
  }
  if ($null -eq (Resolve-DreamSkinCodexInstallFromState -State $pathOnlyState `
    -RegisteredInstalls @($fakeInstall))) {
    throw 'A legacy state path was not revalidated against a registered Store package.'
  }
  $verifiedPackageState = [pscustomobject]@{
    codexExe = $fakeExecutable
    codexPackageRoot = $fakePackageRoot
    codexVersion = '1.2.3.4'
    codexPackageFullName = $fakePackage.PackageFullName
    codexPackageFamilyName = $fakePackage.PackageFamilyName
  }
  $resolvedInstall = Resolve-DreamSkinCodexInstallFromState -State $verifiedPackageState `
    -RegisteredInstalls @($fakeInstall)
  if ($null -eq $resolvedInstall -or -not $resolvedInstall.RegisteredPackageVerified) {
    throw 'State package identity did not resolve against the registered Appx package.'
  }
  $verifiedPackageState.codexPackageFamilyName = 'OpenAI.Codex_wrong'
  if ($null -ne (Resolve-DreamSkinCodexInstallFromState -State $verifiedPackageState `
    -RegisteredInstalls @($fakeInstall))) {
    throw 'A mismatched Appx package family was accepted from state.'
  }
  Write-DreamSkinUtf8FileAtomically -Path $statePath -Content '[]'
  $badStateRejected = $false
  try { $null = Read-DreamSkinState -Path $statePath } catch { $badStateRejected = $true }
  if (-not $badStateRejected) { throw 'A non-object state file was accepted.' }
  $staleStatePath = Archive-DreamSkinStateFile -Path $statePath
  if ((Test-Path -LiteralPath $statePath) -or -not (Test-Path -LiteralPath $staleStatePath)) {
    throw 'Stale state was not preserved under an archive name.'
  }

  $themeStateRoot = Join-Path $temporaryRoot 'theme-state'
  $themePaths = Initialize-DreamSkinThemeStore -SkillRoot $Root -StateRoot $themeStateRoot
  $initialTheme = Read-DreamSkinTheme -ThemeDirectory $themePaths.Active
  if ($initialTheme.Theme.id -cne 'preset-romantic-rose' -or
    $initialTheme.Theme.name -cne '桥本有菜' -or
    $initialTheme.Theme.appearance -cne 'auto' -or
    $initialTheme.Theme.art.safeArea -cne 'left' -or
    $initialTheme.Theme.art.taskMode -cne 'ambient' -or
    [System.IO.Path]::GetExtension($initialTheme.ImagePath) -cne '.jpg') {
    throw 'Default Windows theme did not seed the Arina Hashimoto wallpaper contract.'
  }
  $preseededThemes = @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot)
  if ($preseededThemes.Count -ne 1 -or
    $preseededThemes[0].Id -cne 'preset-romantic-rose' -or
    $preseededThemes[0].Name -cne '桥本有菜') {
    throw 'Arina Hashimoto was not preseeded in the Windows saved-theme menu.'
  }
  $updatedTheme = Set-DreamSkinActiveTheme -ImagePath (Join-Path $Root 'assets\dream-reference.jpg') `
    -Theme $null -Name '测试主题' -StateRoot $themeStateRoot
  if ($updatedTheme.Theme.name -cne '测试主题' -or
    $updatedTheme.Theme.id -cne 'custom' -or
    $updatedTheme.Theme.art.safeArea -cne 'auto' -or
    $updatedTheme.Theme.art.taskMode -cne 'auto' -or
    -not (Test-DreamSkinThemePathWithin -Path $updatedTheme.ImagePath -Root $themePaths.Active)) {
    throw 'Imported image did not reset to the generic adaptive contract inside the managed directory.'
  }
  $null = Initialize-DreamSkinThemeStore -SkillRoot $Root -StateRoot $themeStateRoot
  $idempotentTheme = Read-DreamSkinTheme -ThemeDirectory $themePaths.Active
  if ($idempotentTheme.Theme.id -cne 'custom' -or
    @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot).Count -ne 1) {
    throw 'Theme-store initialization overwrote the active custom theme or duplicated its bundled preset.'
  }
  $savedTheme = Save-DreamSkinCurrentTheme -Name '已保存主题' -StateRoot $themeStateRoot
  if ($savedTheme.Theme.name -cne '已保存主题' -or @(Get-DreamSkinSavedThemes -StateRoot $themeStateRoot).Count -ne 2) {
    throw 'Saved theme creation or discovery failed.'
  }
  $null = Use-DreamSkinSavedTheme -ThemeDirectory $savedTheme.Directory -StateRoot $themeStateRoot

  $outsideTheme = Join-Path $temporaryRoot 'outside-theme'
  New-Item -ItemType Directory -Path $outsideTheme | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'assets\dream-reference.jpg') `
    -Destination (Join-Path $outsideTheme 'dream-reference.jpg')
  Copy-Item -LiteralPath (Join-Path $Root 'assets\theme.json') `
    -Destination (Join-Path $outsideTheme 'theme.json')
  $junctionTheme = Join-Path $themePaths.Saved 'junction-escape'
  $null = New-Item -ItemType Junction -Path $junctionTheme -Target $outsideTheme
  $junctionRejected = $false
  try {
    $null = Use-DreamSkinSavedTheme -ThemeDirectory $junctionTheme -StateRoot $themeStateRoot
  } catch { $junctionRejected = $true }
  if (-not $junctionRejected) { throw 'Saved-theme junction escaped the managed theme directory.' }
  [System.IO.Directory]::Delete($junctionTheme)

  Set-DreamSkinPaused -Paused $true -StateRoot $themeStateRoot | Out-Null
  if (-not (Test-DreamSkinPaused -StateRoot $themeStateRoot)) { throw 'Pause marker was not created.' }
  Set-DreamSkinPaused -Paused $false -StateRoot $themeStateRoot | Out-Null
  if (Test-DreamSkinPaused -StateRoot $themeStateRoot) { throw 'Pause marker was not removed.' }

  $oversizedTheme = Join-Path $temporaryRoot 'oversized-theme'
  New-Item -ItemType Directory -Path $oversizedTheme | Out-Null
  $oversizedImage = Join-Path $oversizedTheme 'oversized.jpg'
  $oversizedStream = [System.IO.File]::Open($oversizedImage, [System.IO.FileMode]::CreateNew)
  try { $oversizedStream.SetLength((16 * 1024 * 1024) + 1) } finally { $oversizedStream.Dispose() }
  Write-DreamSkinUtf8FileAtomically -Path (Join-Path $oversizedTheme 'theme.json') `
    -Content "{`"image`":`"oversized.jpg`"}`r`n"
  $oversizedReadRejected = $false
  try { $null = Read-DreamSkinTheme -ThemeDirectory $oversizedTheme } catch { $oversizedReadRejected = $true }
  $oversizedSetRejected = $false
  try {
    $null = Set-DreamSkinActiveTheme -ImagePath $oversizedImage -Theme $null -StateRoot $themeStateRoot
  } catch { $oversizedSetRejected = $true }
  if (-not $oversizedReadRejected -or -not $oversizedSetRejected) {
    throw 'The 16 MB image limit was not enforced before theme copy or payload construction.'
  }

  $oversizedDimensionImage = Join-Path $temporaryRoot 'oversized-dimension.png'
  $pngHeader = New-Object byte[] 24
  [byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) | ForEach-Object -Begin { $i = 0 } -Process { $pngHeader[$i++] = $_ }
  $pngHeader[8] = 0; $pngHeader[9] = 0; $pngHeader[10] = 0; $pngHeader[11] = 13
  [byte[]](0x49, 0x48, 0x44, 0x52) | ForEach-Object -Begin { $i = 12 } -Process { $pngHeader[$i++] = $_ }
  $pngHeader[16] = 0; $pngHeader[17] = 0; $pngHeader[18] = 0x27; $pngHeader[19] = 0x10
  $pngHeader[20] = 0; $pngHeader[21] = 0; $pngHeader[22] = 0x17; $pngHeader[23] = 0x70
  [System.IO.File]::WriteAllBytes($oversizedDimensionImage, $pngHeader)
  $oversizedDimensionRejected = $false
  try { $null = Set-DreamSkinActiveTheme -ImagePath $oversizedDimensionImage -Theme $null -StateRoot $themeStateRoot } catch { $oversizedDimensionRejected = $true }
  if (-not $oversizedDimensionRejected) { throw 'A 16384px/50MP-invalid import was copied into the active theme.' }

  $reparseStateRoot = Join-Path $temporaryRoot 'reparse-state'
  New-Item -ItemType Directory -Path $reparseStateRoot | Out-Null
  $outsideActive = Join-Path $temporaryRoot 'outside-active'
  New-Item -ItemType Directory -Path $outsideActive | Out-Null
  $reparseActive = Join-Path $reparseStateRoot 'active-theme'
  $null = New-Item -ItemType Junction -Path $reparseActive -Target $outsideActive
  $reparseInitRejected = $false
  try { $null = Initialize-DreamSkinThemeStore -SkillRoot $Root -StateRoot $reparseStateRoot } catch { $reparseInitRejected = $true }
  if (-not $reparseInitRejected) { throw 'Theme-store initialization followed an active-theme junction.' }
  [System.IO.Directory]::Delete($reparseActive)

  $css = Read-DreamSkinUtf8File -Path (Join-Path $Root 'assets\dream-skin.css')
  foreach ($requiredCss in @(
    'background-image: var(--dream-art)',
    'main.main-surface > header.app-header-tint',
    '.app-shell-main-content-top-fade',
    '.thread-scroll-container .bg-gradient-to-t.from-token-main-surface-primary',
    '--dream-immersive-composer',
    'background-position: var(--dream-art-position)',
    '.dream-home-utility',
    ':has(.dream-home-utility) .composer-surface-chrome',
    ':is(.dream-task-ambient, .dream-task-banner):has(main.main-surface:not(.dream-home-shell))'
  )) {
    if (-not $css.Contains($requiredCss)) { throw "Windows immersive CSS is missing: $requiredCss" }
  }
  $traySource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\tray-dream-skin.ps1')
  foreach ($requiredTrayAction in @('System.Windows.Forms.NotifyIcon', '暂停皮肤', '更换背景图', '已保存主题', '完全恢复 Codex')) {
    if (-not $traySource.Contains($requiredTrayAction)) { throw "Tray action is missing: $requiredTrayAction" }
  }
  if (-not $traySource.Contains('$nextPaused') -or -not $traySource.Contains('[System.Windows.Forms.Application]::Exit()')) {
    throw 'Tray pause/restore closures do not terminate cleanly.'
  }
  if (-not $traySource.Contains('Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata') -or
    -not $traySource.Contains('Get-DreamSkinSavedThemes -StateRoot $StateRoot -SkipImageMetadata')) {
    throw 'Tray menu metadata enumeration still performs full image parsing on every open.'
  }
  $restoreSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\restore-dream-skin.ps1')
  if (-not $restoreSource.Contains('Stop-DreamSkinTrayProcess')) {
    throw 'Complete restore does not stop a separately launched tray process.'
  }
  $startSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\start-dream-skin.ps1')
  $stateReadIndex = $startSource.IndexOf('$previousState = Read-DreamSkinState', [System.StringComparison]::Ordinal)
  $restartPromptIndex = $startSource.IndexOf('$restartAuthorized = Confirm-DreamSkinRestart', [System.StringComparison]::Ordinal)
  $recordedStopIndex = $startSource.IndexOf('$recordedInjectorStopped = Stop-DreamSkinRecordedInjector', [System.StringComparison]::Ordinal)
  $cancelIndex = $startSource.IndexOf("Write-Host 'Dream Skin launch was cancelled", [System.StringComparison]::Ordinal)
  $pauseClearIndex = $startSource.IndexOf('Set-DreamSkinPaused -Paused $false', [System.StringComparison]::Ordinal)
  if ($stateReadIndex -lt 0 -or $pauseClearIndex -le $stateReadIndex -or
    ($restartPromptIndex -ge 0 -and $pauseClearIndex -le $restartPromptIndex) -or
    ($recordedStopIndex -ge 0 -and $pauseClearIndex -le $recordedStopIndex) -or
    ($cancelIndex -ge 0 -and $cancelIndex -ge $pauseClearIndex)) {
    throw 'Start clears the pause marker before state validation or restart consent, or before its cancellation branch.'
  }
  if (-not $startSource.Contains('$pauseWasSet = Test-DreamSkinPaused') -or
    -not $startSource.Contains('$pauseCleared = $true') -or
    -not $startSource.Contains('Set-DreamSkinPaused -Paused $true -StateRoot $StateRoot')) {
    throw 'Start does not preserve an existing pause marker when startup rolls back.'
  }

  $rendererSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'assets\renderer-inject.js')
  foreach ($requiredRendererBehavior in @('dream-home-utility', 'artMetadata', 'detectShellAppearance')) {
    if (-not $rendererSource.Contains($requiredRendererBehavior)) {
      throw "Renderer adaptive behavior is missing: $requiredRendererBehavior"
    }
  }
  $injectorSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\injector.mjs')
  foreach ($requiredInjectorBehavior in @(
    'MAX_ART_BYTES', 'createHash', 'readImageMetadata', '50MP safety limit', 'STRONG_THEME_AUDIT_MS',
    'Page.addScriptToEvaluateOnNewDocument', 'Page.removeScriptToEvaluateOnNewDocument', 'earlyPayloadFor'
  )) {
    if (-not $injectorSource.Contains($requiredInjectorBehavior)) {
      throw "Injector theme safety is missing: $requiredInjectorBehavior"
    }
  }
  $themeSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\theme-windows.ps1')
  foreach ($requiredThemeSafety in @(
    '[System.IO.FileAttributes]::ReparsePoint',
    'Ensure-DreamSkinManagedDirectory',
    'Get-DreamSkinValidatedImageMetadata',
    '16384px / 50MP safety limit',
    'Assert-DreamSkinImageFile -Path $temporary',
    'Assert-DreamSkinImageFile -Path $imageArchive'
  )) {
    if (-not $themeSource.Contains($requiredThemeSafety)) {
      throw "PowerShell theme-store safety is missing: $requiredThemeSafety"
    }
  }
  $commonSource = Read-DreamSkinUtf8File -Path (Join-Path $Root 'scripts\common-windows.ps1')
  if (-not $commonSource.Contains('State was preserved.')) {
    throw 'Mismatched live injector identity does not fail closed with preserved state.'
  }

  $fetchNodeRuntime = Join-Path $Root 'scripts\fetch-node-runtime.ps1'
  if (-not (Test-Path -LiteralPath $fetchNodeRuntime -PathType Leaf)) {
    throw 'Verified private Node runtime fetch script is missing.'
  }
  $privateNodeBranch = $commonSource.IndexOf('if ($NodePath)', [System.StringComparison]::Ordinal)
  $pathLookup = $commonSource.IndexOf('Get-Command node.exe', [System.StringComparison]::Ordinal)
  if ($privateNodeBranch -lt 0 -or $pathLookup -lt 0 -or $privateNodeBranch -gt $pathLookup) {
    throw 'Explicit NodePath validation can reach PATH lookup.'
  }

  $fakeNodeSource = @'
using System;
using System.Reflection;
public static class Program {
  public static int Main(string[] args) {
    if (args.Length != 2 || args[0] != "-p") return 1;
    if (args[1] == "process.versions.node") {
      Console.Write(Environment.GetEnvironmentVariable("DREAM_SKIN_FAKE_NODE_VERSION") ?? "22.23.1");
      return 0;
    }
    if (args[1] == "process.execPath") {
      Console.Write(Assembly.GetExecutingAssembly().Location);
      return 0;
    }
    return 1;
  }
}
'@
  $archiveName = 'node-v22.23.1-win-x64.zip'
  $archiveTop = Join-Path $temporaryRoot ([System.IO.Path]::GetFileNameWithoutExtension($archiveName))
  New-Item -ItemType Directory -Path $archiveTop | Out-Null
  $fakeNode = Join-Path $archiveTop 'node.exe'
  Add-Type -TypeDefinition $fakeNodeSource -OutputAssembly $fakeNode -OutputType ConsoleApplication | Out-Null
  $licenseText = 'Node test license complete text.'
  [System.IO.File]::WriteAllText((Join-Path $archiveTop 'LICENSE'), $licenseText, $utf8NoBom)
  $archivePath = Join-Path $temporaryRoot $archiveName
  Compress-Archive -LiteralPath $archiveTop -DestinationPath $archivePath
  $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $runtimeLockPath = Join-Path $temporaryRoot 'node-runtime.lock.json'
  [pscustomobject]@{
    schemaVersion = 1
    version = '22.23.1'
    minimumMajor = 22
    archives = [pscustomobject]@{
      x64 = [pscustomobject]@{
        file = $archiveName
        url = "https://nodejs.org/dist/v22.23.1/$archiveName"
        sha256 = $archiveHash
      }
    }
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runtimeLockPath -Encoding UTF8
  $runtimeDestination = Join-Path $temporaryRoot 'runtime\x64'
  & $fetchNodeRuntime -Architecture x64 -Destination $runtimeDestination -ManifestPath $runtimeLockPath -ArchivePath $archivePath
  $privateNode = Get-DreamSkinNodeRuntime -NodePath (Join-Path $runtimeDestination 'node.exe')
  if ($privateNode.Version -cne '22.23.1' -or -not (Test-DreamSkinPathEqual -Left $privateNode.Path -Right (Join-Path $runtimeDestination 'node.exe'))) {
    throw 'The fetched private Node runtime did not pass production self-validation.'
  }
  if (([System.IO.File]::ReadAllText((Join-Path $runtimeDestination 'LICENSE.node.txt')) -cne $licenseText) -or
    -not (Test-Path -LiteralPath (Join-Path $runtimeDestination 'NOTICE.node.txt') -PathType Leaf)) {
    throw 'Verified private Node runtime did not preserve its license and notice.'
  }

  $nodeRaceToken = [guid]::NewGuid().ToString('N')
  $previousNodeRaceToken = $env:DREAM_SKIN_NODE_FETCH_TEST_TOKEN
  try {
    $env:DREAM_SKIN_NODE_FETCH_TEST_TOKEN = $nodeRaceToken
    foreach ($mode in @('offline', 'download')) {
      $scenario = "node-$mode-replace-after-hash"
      $replacementArchive = Join-Path $temporaryRoot "$scenario-replacement.zip"
      Copy-Item -LiteralPath $archivePath -Destination $replacementArchive
      [IO.File]::AppendAllText($replacementArchive, 'replacement', $utf8NoBom)
      $raceDestination = Join-Path $temporaryRoot "runtime\$scenario"
      $raceArguments = @{
        Architecture = 'x64'
        Destination = $raceDestination
        ManifestPath = $runtimeLockPath
        TestOnlyToken = $nodeRaceToken
        TestOnlyReplaceAfterHashWith = $replacementArchive
      }
      if ($mode -eq 'offline') { $raceArguments.ArchivePath = $archivePath }
      else { $raceArguments.TestOnlyDownloadArchivePath = $archivePath }
      $raceRejected = $false
      try { & $fetchNodeRuntime @raceArguments } catch {
        $raceRejected = $_.Exception.Message -match 'Node archive replacement was denied after hashing'
      }
      if (-not $raceRejected -or (Test-Path -LiteralPath $raceDestination)) {
        throw "$scenario did not deny replacement or published a runtime."
      }
    }
  } finally {
    $env:DREAM_SKIN_NODE_FETCH_TEST_TOKEN = $previousNodeRaceToken
  }

  $tamperedLock = Get-Content -LiteralPath $runtimeLockPath -Raw | ConvertFrom-Json
  foreach ($representativeHash in @(
    ('0' + (('a' * 63) -join '')),
    ('a' + (('0' * 63) -join ''))
  )) {
    $replacementNibble = if ($representativeHash[0] -ceq '0') { '1' } else { '0' }
    $representativeTamperedHash = $replacementNibble + $representativeHash.Substring(1)
    if ($representativeTamperedHash -ceq $representativeHash -or $representativeTamperedHash -notmatch '^[a-f0-9]{64}$') {
      throw 'Node archive tamper test did not produce a different SHA-256 value.'
    }
  }
  $replacementNibble = if ($archiveHash[0] -ceq '0') { '1' } else { '0' }
  $tamperedLock.archives.x64.sha256 = $replacementNibble + $archiveHash.Substring(1)
  $tamperedLock | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runtimeLockPath -Encoding UTF8
  $tamperedDestination = Join-Path $temporaryRoot 'runtime\tampered'
  $tamperedRejected = $false
  try { & $fetchNodeRuntime -Architecture x64 -Destination $tamperedDestination -ManifestPath $runtimeLockPath -ArchivePath $archivePath } catch { $tamperedRejected = $true }
  if (-not $tamperedRejected -or (Test-Path -LiteralPath $tamperedDestination)) {
    throw 'A tampered Node archive hash published a runtime.'
  }
  $missingPrivateRuntimeRejected = $false
  try { $null = Get-DreamSkinNodeRuntime -NodePath (Join-Path $temporaryRoot 'missing-node.exe') } catch { $missingPrivateRuntimeRejected = $true }
  if (-not $missingPrivateRuntimeRejected) { throw 'A missing private Node path fell back to PATH.' }

  $node = Get-DreamSkinNodeRuntime
  & $node.Path (Join-Path $Root 'scripts\injector.mjs') --self-test *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Injector CDP self-test failed.' }
  & $node.Path (Join-Path $Root 'scripts\injector.mjs') --check-payload *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Injector self-test failed.' }
  $versionMutationRoot = Join-Path $temporaryRoot 'version-placeholder'
  New-Item -ItemType Directory -Path (Join-Path $versionMutationRoot 'scripts'), (Join-Path $versionMutationRoot 'assets') | Out-Null
  Copy-Item -LiteralPath (Join-Path $Root 'scripts\injector.mjs'), (Join-Path $Root 'scripts\image-metadata.mjs') -Destination (Join-Path $versionMutationRoot 'scripts')
  Copy-Item -LiteralPath (Join-Path $Root 'assets\dream-skin.css'), (Join-Path $Root 'assets\renderer-inject.js'), (Join-Path $Root 'assets\theme.json'), (Join-Path $Root 'assets\dream-reference.jpg') -Destination (Join-Path $versionMutationRoot 'assets')
  Copy-Item -LiteralPath (Join-Path $Root 'VERSION') -Destination $versionMutationRoot
  $mutatedInjectorPath = Join-Path $versionMutationRoot 'scripts\injector.mjs'
  $mutatedInjector = [IO.File]::ReadAllText($mutatedInjectorPath).Replace("    .replace(`"__DREAM_SKIN_VERSION_JSON__`", JSON.stringify(SKIN_VERSION));", ';')
  [IO.File]::WriteAllText($mutatedInjectorPath, $mutatedInjector, [Text.UTF8Encoding]::new($false))
  & $node.Path $mutatedInjectorPath --check-payload *> $null
  if ($LASTEXITCODE -eq 0) { throw 'Windows payload check accepted an unresolved version placeholder.' }
  & $node.Path (Join-Path $Root 'scripts\injector.mjs') --check-payload --theme-dir $themePaths.Active *> $null
  if ($LASTEXITCODE -ne 0) { throw 'Managed theme payload validation failed.' }
  & $node.Path (Join-Path $Root 'scripts\injector.mjs') --check-payload --theme-dir $oversizedTheme *> $null
  if ($LASTEXITCODE -eq 0) { throw 'Node injector accepted an image over the 16 MB limit.' }
  & $node.Path (Join-Path $PSScriptRoot 'renderer-inject.test.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Renderer auxiliary-window regression test failed.' }
  & $node.Path (Join-Path $PSScriptRoot 'injector-bootstrap.test.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Injector early-bootstrap regression test failed.' }
  & $node.Path (Join-Path $PSScriptRoot 'injector-one-shot.test.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Injector one-shot Browser ID regression test failed.' }
  & $node.Path (Join-Path $PSScriptRoot 'image-metadata.test.mjs')
  if ($LASTEXITCODE -ne 0) { throw 'Image metadata regression test failed.' }

  Write-Host 'PASS: config transactions, restore scoping, state safety, argument quoting, and loopback CDP validation.'
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
