[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsRoot
$Builder = Join-Path $WindowsRoot 'scripts\build-studio-release.ps1'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$DotNet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
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

function Assert-TestReleaseMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [Parameter(Mandatory = $true)][string]$ExpectedArchitecture,
    [Parameter(Mandatory = $true)][string]$ExpectedSigning,
    [Parameter(Mandatory = $true)][string]$ExpectedFile,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceTree
  )
  $manifestPath = Join-Path $Root 'release-manifest.json'
  $checksumPath = Join-Path $Root 'SHA256SUMS.txt'
  $setupPath = Join-Path $Root $ExpectedFile
  $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
  try {
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    if ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and
      $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF) { throw 'manifest BOM' }
    $manifest = $strictUtf8.GetString($manifestBytes) | ConvertFrom-Json
  } catch { throw 'Release manifest is not strict UTF-8 JSON.' }
  $keys = @($manifest.PSObject.Properties.Name) -join ','
  if ($keys -cne 'schemaVersion,version,architecture,signing,file,sha256,sourceTree' -or
    $manifest.schemaVersion -ne 1 -or "$($manifest.version)" -cne $ExpectedVersion -or
    "$($manifest.architecture)" -cne $ExpectedArchitecture -or
    "$($manifest.signing)" -cne $ExpectedSigning -or "$($manifest.file)" -cne $ExpectedFile -or
    "$($manifest.sourceTree)" -cne $ExpectedSourceTree -or "$($manifest.sha256)" -notmatch '^[a-f0-9]{64}$') {
    throw 'Release manifest values are not exact.'
  }
  if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'Release setup is missing.' }
  $freshHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($freshHash -cne "$($manifest.sha256)") { throw 'Release manifest does not match the fresh setup SHA-256.' }
  $checksumBytes = [IO.File]::ReadAllBytes($checksumPath)
  if ($checksumBytes.Length -lt 1 -or $checksumBytes[$checksumBytes.Length - 1] -ne 0x0A -or
    ($checksumBytes.Length -ge 2 -and $checksumBytes[$checksumBytes.Length - 2] -eq 0x0D)) {
    throw 'Release checksum must end with LF, not CRLF.'
  }
  $checksumLines = @([IO.File]::ReadAllLines($checksumPath, $strictUtf8))
  if ($checksumLines.Count -ne 1 -or $checksumLines[0] -cne "$freshHash  $ExpectedFile") {
    throw 'Release metadata must contain exactly one checksum entry.'
  }
  return $manifest
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

foreach ($tool in @($PowerShell, $DotNet, $TaskKill)) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { throw 'A required Windows release test tool is unavailable.' }
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$Architecture = switch ($osArchitecture) {
  'X64' { 'x64' }
  'Arm64' { 'arm64' }
  default { throw 'Windows Studio release tests require an X64 or Arm64 host.' }
}
$token = [guid]::NewGuid().ToString('N')
$TemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dream-skin-release-$token"
$ProductionReleaseRoot = Join-Path $WindowsRoot 'release'
$ProductionReleaseBackup = Join-Path $WindowsRoot ".release-test-backup-$token"
$productionReleaseExisted = Test-Path -LiteralPath $ProductionReleaseRoot -PathType Container
$previousReleaseTestToken = $env:DREAM_SKIN_RELEASE_TEST_TOKEN
$previousReleaseFault = $env:DREAM_SKIN_RELEASE_TEST_REPLACE_PHASE
$previousPostTestFaultToken = $env:DREAM_SKIN_RELEASE_TEST_POST_TEST_TOKEN
$protectedProductionRelease = @()
try {
if ($productionReleaseExisted) { [IO.Directory]::Move($ProductionReleaseRoot, $ProductionReleaseBackup) }
New-Item -ItemType Directory -Path (Join-Path $ProductionReleaseRoot 'nested') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $ProductionReleaseRoot 'seed-a.txt'), 'seed-a', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ProductionReleaseRoot 'nested\seed-b.txt'), 'seed-b', [Text.UTF8Encoding]::new($false))
$protectedProductionRelease = @(Get-FileSnapshot $ProductionReleaseRoot)

$mismatchArchitecture = if ($Architecture -eq 'x64') { 'arm64' } else { 'x64' }
$mismatch = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
  $Builder, '-Architecture', $mismatchArchitecture, '-SkipSign', '-SkipTests')
if ($mismatch.ExitCode -eq 0 -or
  $mismatch.Output -notmatch 'Windows Studio releases require a matching X64 or Arm64 build host\.') {
  throw 'Release builder did not reject a mismatched build host before staging.'
}

$ReleaseRoot = Join-Path $TemporaryRoot 'release'
$env:DREAM_SKIN_RELEASE_TEST_TOKEN = $token
$BuilderTestArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
  $Builder, '-Architecture', $Architecture, '-SkipSign', '-SkipTests', '-TestOnlyToken', $token)
$inputToken = [guid]::NewGuid().ToString('N')
$trackedInput = Join-Path $WindowsRoot 'assets\theme.json'
$untrackedInput = Join-Path $WindowsRoot "studio\TaskReleaseGuard-$inputToken.cs"
$untrackedBuildCustomization = Join-Path $WindowsRoot 'Directory.Build.targets'
$priorContamination = Join-Path $ReleaseRoot "prior-$inputToken.keep"
$trackedBytes = [IO.File]::ReadAllBytes($trackedInput)
try {
  New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
  [IO.File]::WriteAllText($priorContamination, 'prior release', [Text.UTF8Encoding]::new($false))
  $priorRelease = @(Get-FileSnapshot $ReleaseRoot)
  try {
    [IO.File]::AppendAllText($trackedInput, "`r`n", [Text.UTF8Encoding]::new($false))
    $dirtyBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
    if ($dirtyBuild.ExitCode -eq 0 -or $dirtyBuild.Output -notmatch 'tracked regular files matching the Git index') {
      throw 'Builder accepted a dirty tracked release input.'
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $priorRelease 'Dirty tracked release input replaced prior output.'
  } finally {
    [IO.File]::WriteAllBytes($trackedInput, $trackedBytes)
  }

  try {
    [IO.File]::WriteAllText($untrackedInput, '#error untracked release payload', [Text.UTF8Encoding]::new($false))
    $untrackedBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
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
    $customizedBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
    if ($customizedBuild.ExitCode -eq 0 -or $customizedBuild.Output -notmatch 'tracked regular files matching the Git index') {
      throw 'Builder accepted an outer untracked build customization.'
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $priorRelease 'Outer build customization replaced prior output.'
  } finally {
    if (Test-Path -LiteralPath $untrackedBuildCustomization) { Remove-Item -LiteralPath $untrackedBuildCustomization -Force }
  }

  $unexpectedAsset = Join-Path $WindowsRoot 'assets\.env'
  try {
    [IO.File]::WriteAllText($unexpectedAsset, 'API_KEY=must-not-ship', [Text.UTF8Encoding]::new($false))
    $assetBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
    if ($assetBuild.ExitCode -eq 0 -or $assetBuild.Output -notmatch 'tracked regular files matching the Git index') {
      throw 'Builder accepted an extra .env release asset.'
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $priorRelease 'An extra .env asset entered release output.'
  } finally {
    if (Test-Path -LiteralPath $unexpectedAsset) { Remove-Item -LiteralPath $unexpectedAsset -Force }
  }

  $indexTree = "$(& git -C $RepoRoot write-tree)".Trim()
  $expectedAssetBlob = "$(& git -C $RepoRoot rev-parse "$indexTree`:windows/assets/theme.json")".Trim()
  $postSnapshotInput = Join-Path $WindowsRoot "assets\post-snapshot-$inputToken.txt"
  try {
    $build = Invoke-TestProcess $PowerShell $BuilderTestArguments -AfterStart {
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
  $expectedAssets = @('dream-reference.jpg', 'dream-skin.css', 'renderer-inject.js', 'theme.json')
  $actualAssets = @(Get-ChildItem -LiteralPath (Join-Path $StageRoot 'engine\assets') -File -Force |
    ForEach-Object Name | Sort-Object)
  if ((ConvertTo-Json -InputObject @($actualAssets) -Compress) -cne
    (ConvertTo-Json -InputObject @($expectedAssets) -Compress)) {
    throw 'The staged asset set is not exact.'
  }
  $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $StageRoot 'CodexDreamSkinStudio.exe'))
  if ($versionInfo.FileVersion -cne "$Version.0" -or $versionInfo.ProductVersion -cne $Version) {
    throw 'Staged Studio FileVersionInfo does not match windows/VERSION.'
  }
  $setupVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Setup)
  $setupProductVersion = "$($setupVersionInfo.ProductVersion)".Trim()
  $setupFileVersion = "$($setupVersionInfo.FileVersion)".Trim()
  if ($setupFileVersion -cne "$Version.0" -or
    $setupProductVersion -notin @($Version, "$Version.0")) {
    throw 'Setup FileVersionInfo does not match windows/VERSION.'
  }
  $setupFile = [IO.Path]::GetFileName($Setup)
  $null = Assert-TestReleaseMetadata -Root $ReleaseRoot -ExpectedVersion $Version `
    -ExpectedArchitecture $Architecture -ExpectedSigning 'UNSIGNED' -ExpectedFile $setupFile `
    -ExpectedSourceTree $indexTree

  $metadataMutationRoot = Join-Path $TemporaryRoot 'metadata-mutations'
  New-Item -ItemType Directory -Path $metadataMutationRoot | Out-Null
  foreach ($metadataFile in @($setupFile, 'release-manifest.json', 'SHA256SUMS.txt')) {
    Copy-Item -LiteralPath (Join-Path $ReleaseRoot $metadataFile) -Destination $metadataMutationRoot
  }
  $manifestPath = Join-Path $metadataMutationRoot 'release-manifest.json'
  $checksumPath = Join-Path $metadataMutationRoot 'SHA256SUMS.txt'
  $mutationSetupPath = Join-Path $metadataMutationRoot $setupFile
  $originalManifestBytes = [IO.File]::ReadAllBytes($manifestPath)
  $originalChecksumBytes = [IO.File]::ReadAllBytes($checksumPath)
  $metadataMutations = @(
    @{ Name = 'manifest-schemaVersion-mutation'; Property = 'schemaVersion'; Value = 2 },
    @{ Name = 'manifest-version-mutation'; Property = 'version'; Value = '9.9.9' },
    @{ Name = 'manifest-architecture-mutation'; Property = 'architecture'; Value = $mismatchArchitecture },
    @{ Name = 'manifest-signing-mutation'; Property = 'signing'; Value = 'signed' },
    @{ Name = 'manifest-file-mutation'; Property = 'file'; Value = 'other.exe' },
    @{ Name = 'manifest-sha256-mutation'; Property = 'sha256'; Value = (('0' * 64) -join '') },
    @{ Name = 'manifest-sourceTree-mutation'; Property = 'sourceTree'; Value = (('0' * $indexTree.Length) -join '') }
  )
  foreach ($mutation in $metadataMutations) {
    [IO.File]::WriteAllBytes($manifestPath, $originalManifestBytes)
    $changed = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $changed.PSObject.Properties[$mutation.Property].Value = $mutation.Value
    [IO.File]::WriteAllText($manifestPath, (($changed | ConvertTo-Json -Depth 3) + "`r`n"),
      [Text.UTF8Encoding]::new($false))
    $rejected = $false
    try {
      $null = Assert-TestReleaseMetadata -Root $metadataMutationRoot -ExpectedVersion $Version `
        -ExpectedArchitecture $Architecture -ExpectedSigning 'UNSIGNED' -ExpectedFile $setupFile `
        -ExpectedSourceTree $indexTree
    } catch { $rejected = $true }
    if (-not $rejected) { throw "$($mutation.Name) was accepted." }
  }
  [IO.File]::WriteAllBytes($manifestPath, $originalManifestBytes)
  $extraKeyManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $extraKeyManifest | Add-Member -NotePropertyName unexpected -NotePropertyValue true
  [IO.File]::WriteAllText($manifestPath, (($extraKeyManifest | ConvertTo-Json -Depth 3) + "`r`n"),
    [Text.UTF8Encoding]::new($false))
  $extraKeyRejected = $false
  try {
    $null = Assert-TestReleaseMetadata -Root $metadataMutationRoot -ExpectedVersion $Version `
      -ExpectedArchitecture $Architecture -ExpectedSigning 'UNSIGNED' -ExpectedFile $setupFile `
      -ExpectedSourceTree $indexTree
  } catch { $extraKeyRejected = $true }
  if (-not $extraKeyRejected) { throw 'manifest-extra-key-mutation was accepted.' }
  [IO.File]::WriteAllBytes($manifestPath, $originalManifestBytes)

  foreach ($checksumMutation in @(
    @{ Name = 'checksum-hash-mutation'; Text = "$((('0' * 64) -join ''))  $setupFile`n" },
    @{ Name = 'checksum-file-mutation'; Text = "$((Get-FileHash -LiteralPath $mutationSetupPath -Algorithm SHA256).Hash.ToLowerInvariant())  other.exe`n" },
    @{ Name = 'checksum-extra-entry-mutation'; Text = "$([Text.UTF8Encoding]::new($false).GetString($originalChecksumBytes))$((('0' * 64) -join ''))  other.exe`n" },
    @{ Name = 'checksum-crlf-mutation'; Text = "$((Get-FileHash -LiteralPath $mutationSetupPath -Algorithm SHA256).Hash.ToLowerInvariant())  $setupFile`r`n" }
  )) {
    [IO.File]::WriteAllText($checksumPath, $checksumMutation.Text, [Text.UTF8Encoding]::new($false))
    $rejected = $false
    try {
      $null = Assert-TestReleaseMetadata -Root $metadataMutationRoot -ExpectedVersion $Version `
        -ExpectedArchitecture $Architecture -ExpectedSigning 'UNSIGNED' -ExpectedFile $setupFile `
        -ExpectedSourceTree $indexTree
    } catch { $rejected = $true }
    if (-not $rejected) { throw "$($checksumMutation.Name) was accepted." }
  }
  [IO.File]::WriteAllBytes($checksumPath, $originalChecksumBytes)
  $mutationSetupLength = (Get-Item -LiteralPath $mutationSetupPath).Length
  $mutationStream = [IO.File]::Open($mutationSetupPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $mutationStream.Position = $mutationStream.Length
    $mutationStream.WriteByte(0)
  } finally { $mutationStream.Dispose() }
  $setupMutationRejected = $false
  try {
    $null = Assert-TestReleaseMetadata -Root $metadataMutationRoot -ExpectedVersion $Version `
      -ExpectedArchitecture $Architecture -ExpectedSigning 'UNSIGNED' -ExpectedFile $setupFile `
      -ExpectedSourceTree $indexTree
  } catch { $setupMutationRejected = $true }
  if (-not $setupMutationRejected) { throw 'setup-byte-mutation was accepted.' }
  $mutationStream = [IO.File]::Open($mutationSetupPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $mutationStream.SetLength($mutationSetupLength) } finally { $mutationStream.Dispose() }

  $goodRelease = @(Get-FileSnapshot $ReleaseRoot)
  $faultInstallRoot = Join-Path $TemporaryRoot 'fault-installed'
  $previousPayloadFault = $env:DREAM_SKIN_RELEASE_TEST_PAYLOAD_FAULT
  try {
    $env:DREAM_SKIN_RELEASE_TEST_PAYLOAD_FAULT = 'payload-fault-omit-engine-adapter'
    $faultBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
    if ($faultBuild.ExitCode -ne 0 -or $faultBuild.Output -notmatch 'payload-fault-omit-engine-adapter') {
      throw 'The deterministic payload-fault-omit-engine-adapter builder seam did not produce a setup.'
    }
    $faultSetup = Join-Path $ReleaseRoot $setupFile
    $faultInstall = Invoke-TestProcess $faultSetup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$faultInstallRoot") `
      -TimeoutMilliseconds 120000
    if ($faultInstall.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $faultInstallRoot -PathType Container)) {
      throw "The faulty builder-produced setup could not be installed.`n$($faultInstall.Output)"
    }
    $faultMismatch = $false
    foreach ($stagedFile in Get-ChildItem -LiteralPath $StageRoot -Recurse -File -Force) {
      $relative = $stagedFile.FullName.Substring($StageRoot.Length).TrimStart('\')
      $installedFile = Join-Path $faultInstallRoot $relative
      if (-not (Test-Path -LiteralPath $installedFile -PathType Leaf) -or
        (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash -cne
          (Get-FileHash -LiteralPath $stagedFile.FullName -Algorithm SHA256).Hash) {
        $faultMismatch = $true
        break
      }
    }
    if (-not $faultMismatch) { throw 'The faulty builder-produced setup did not trigger the production setup payload mismatch.' }
  } finally {
    $env:DREAM_SKIN_RELEASE_TEST_PAYLOAD_FAULT = $previousPayloadFault
    if (Test-Path -LiteralPath $faultInstallRoot) { Remove-Item -LiteralPath $faultInstallRoot -Recurse -Force }
  }
  $cleanBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
  if ($cleanBuild.ExitCode -ne 0) { throw "Clean builder setup could not be restored after payload fault.`n$($cleanBuild.Output)" }
  $StageRoot = Join-Path $ReleaseRoot "stage-$Version"
  $Setup = Join-Path $ReleaseRoot "CodexDreamSkinStudio-$Version-win-$Architecture-UNSIGNED.exe"
  $setupFile = [IO.Path]::GetFileName($Setup)
  $goodRelease = @(Get-FileSnapshot $ReleaseRoot)
  foreach ($race in @(
    @{ Phase = 'stage-after-scan'; Proof = 'stage-adapter-replacement-denied'; Failure = 'stage replacement race replaced prior release' },
    @{ Phase = 'manifest-before-iscc'; Proof = 'manifest-replacement-denied'; Failure = 'manifest replacement race replaced prior release' },
    @{ Phase = 'setup-after-signature'; Proof = 'setup-replacement-denied'; Failure = 'setup replacement race replaced prior release' },
    @{
      Phase = 'setup-before-publication'
      Proof = 'setup-publication-identity-mismatch'
      Forbidden = 'setup-publication-replacement-unexpectedly-denied'
      Failure = 'setup publication race replaced prior release'
    }
  )) {
    $env:DREAM_SKIN_RELEASE_TEST_REPLACE_PHASE = $race.Phase
    $raceBuild = Invoke-TestProcess $PowerShell $BuilderTestArguments
    if ($raceBuild.ExitCode -eq 0 -or $raceBuild.Output -notmatch [regex]::Escape($race.Proof) -or
      ($race.Forbidden -and $raceBuild.Output -match [regex]::Escape($race.Forbidden))) {
      throw "The $($race.Phase) replacement seam did not prove denial."
    }
    Assert-SnapshotEqual @(Get-FileSnapshot $ReleaseRoot) $goodRelease $race.Failure
  }
  $env:DREAM_SKIN_RELEASE_TEST_REPLACE_PHASE = $null
  Assert-SnapshotEqual @(Get-FileSnapshot $ProductionReleaseRoot) $protectedProductionRelease `
    'The protected production release changed during isolated builder tests.'

  $contract = Invoke-TestProcess $PrivateNode @((Join-Path $PSScriptRoot 'studio-release-contract.test.mjs'))
  if ($contract.ExitCode -ne 0) { throw "Portable Studio release contract failed.`n$($contract.Output)" }
} finally {
  [IO.File]::WriteAllBytes($trackedInput, $trackedBytes)
  foreach ($path in @($untrackedInput, $untrackedBuildCustomization, $postSnapshotInput, $priorContamination)) {
    if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
  }
}

$InstallRoot = Join-Path $TemporaryRoot 'installed'
$ThemeSentinel = Join-Path $env:LOCALAPPDATA "CodexDreamSkin\themes\task12-$token.keep"
$stub = Join-Path $TemporaryRoot 'prepare-uninstall-stub.exe'
$InstalledStudio = Join-Path $InstallRoot 'CodexDreamSkinStudio.exe'
$RealStudioBackup = Join-Path $TemporaryRoot 'CodexDreamSkinStudio.real.exe'
$PrepareTrace = Join-Path $TemporaryRoot 'prepare-uninstall-trace.txt'
$instanceMutex = $null
$ownsInstanceMutex = $false
$residentOwner = $null
$residentNode = $null
$previousGuardExit = $env:DREAM_SKIN_TEST_PREPARE_EXIT
$previousPrepareScenario = $env:DREAM_SKIN_TEST_PREPARE_SCENARIO
$previousThumbprint = $env:WINDOWS_SIGN_CERT_THUMBPRINT

try {
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

  $install = Invoke-TestProcess $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$InstallRoot") `
    -TimeoutMilliseconds 120000
  if ($install.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw "The builder-produced Studio setup installation failed.`n$($install.Output)"
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
      throw "The production setup payload mismatch was: $relative"
    }
    $payloadFile = Join-Path $InstalledPayload $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $payloadFile) -Force | Out-Null
    Copy-Item -LiteralPath $installedFile -Destination $payloadFile
  }
  foreach ($installedFile in Get-ChildItem -LiteralPath $InstallRoot -Recurse -File -Force) {
    $relative = $installedFile.FullName.Substring($InstallRoot.Length).TrimStart('\')
    if (-not $expectedFiles.Contains($relative) -and $relative -notmatch '^unins\d+\.(?:dat|exe|msg)$') {
      throw "The production setup payload mismatch was an unexpected file: $relative"
    }
  }
  & (Join-Path $InstalledPayload 'engine\runtime\node.exe') (Join-Path $RepoRoot 'studio\release\check-contents.mjs') `
    --root $InstalledPayload --allowlist (Join-Path $RepoRoot 'studio\release\allowlist-windows.json')
  if ($LASTEXITCODE -ne 0) { throw 'Installed release content scan failed.' }

  $sameVersionSentinel = Join-Path $InstallRoot 'same-version-stale.keep'
  [IO.File]::WriteAllText($sameVersionSentinel, 'preserve', [Text.UTF8Encoding]::new($false))
  $beforeSameVersion = @(Get-FileSnapshot $InstallRoot)
  $sameVersionReinstall = Invoke-TestProcess $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$InstallRoot") `
    -TimeoutMilliseconds 120000
  if ($sameVersionReinstall.ExitCode -eq 0) { throw 'A same-version reinstall did not explicitly refuse the nonempty target.' }
  Assert-SnapshotEqual @(Get-FileSnapshot $InstallRoot) $beforeSameVersion `
    'A same-version reinstall changed original tree.'
  Remove-Item -LiteralPath $sameVersionSentinel -Force

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
  $beforeRunningReinstall = @(Get-FileSnapshot $InstallRoot)
  $runningReinstall = Invoke-TestProcess $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$InstallRoot") `
    -TimeoutMilliseconds 120000
  if ($runningReinstall.ExitCode -eq 0) { throw 'A running same-version reinstall did not explicitly refuse the nonempty target.' }
  Assert-SnapshotEqual @(Get-FileSnapshot $InstallRoot) $beforeRunningReinstall `
    'A running same-version reinstall changed original tree.'

  $nodeStartInfo = [Diagnostics.ProcessStartInfo]::new()
  $nodeStartInfo.FileName = Join-Path $InstallRoot 'engine\runtime\node.exe'
  $nodeStartInfo.Arguments = (@('-e', 'setInterval(() => {}, 1000)') | ForEach-Object {
    ConvertTo-DreamSkinProcessArgument -Value $_
  }) -join ' '
  $nodeStartInfo.UseShellExecute = $false
  $nodeStartInfo.CreateNoWindow = $true
  $residentNode = [Diagnostics.Process]::Start($nodeStartInfo)
  $beforeRunningNodeReinstall = @(Get-FileSnapshot $InstallRoot)
  $runningNodeReinstall = Invoke-TestProcess $Setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', "/DIR=$InstallRoot") `
    -TimeoutMilliseconds 120000
  if ($runningNodeReinstall.ExitCode -eq 0) { throw 'A running-private-node same-version reinstall did not explicitly refuse the nonempty target.' }
  Assert-SnapshotEqual @(Get-FileSnapshot $InstallRoot) $beforeRunningNodeReinstall `
    'A running-private-node same-version reinstall changed original tree.'
  & $TaskKill /PID "$($residentNode.Id)" /T /F *> $null
  $null = $residentNode.WaitForExit(10000)
  $residentNode.Dispose()
  $residentNode = $null

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

  $env:DREAM_SKIN_RELEASE_TEST_POST_TEST_TOKEN = $token
  $failedBuild = Invoke-TestProcess $PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File',
    $Builder, '-Architecture', $Architecture, '-SkipSign', '-TestOnlyPostTestFailureToken', $token)
  if ($failedBuild.ExitCode -eq 0 -or $failedBuild.Output -notmatch 'forced-post-test-release-failure') {
    throw 'The deterministic post-test outer builder failure did not run.'
  }
  Assert-SnapshotEqual @(Get-FileSnapshot $ProductionReleaseRoot) $protectedProductionRelease `
    'A post-test outer builder failure changed production release.'

  Write-Host 'PASS: Windows Studio release build, install scan, mutex, uninstall guard, and publication behavior.'
} finally {
  if ($residentNode) {
    if (-not $residentNode.HasExited) { & $TaskKill /PID "$($residentNode.Id)" /T /F *> $null }
    $residentNode.Dispose()
  }
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
  if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
  $env:DREAM_SKIN_TEST_PREPARE_EXIT = $previousGuardExit
  $env:DREAM_SKIN_TEST_PREPARE_SCENARIO = $previousPrepareScenario
  $env:WINDOWS_SIGN_CERT_THUMBPRINT = $previousThumbprint
}
} finally {
  $env:DREAM_SKIN_RELEASE_TEST_TOKEN = $previousReleaseTestToken
  $env:DREAM_SKIN_RELEASE_TEST_REPLACE_PHASE = $previousReleaseFault
  $env:DREAM_SKIN_RELEASE_TEST_POST_TEST_TOKEN = $previousPostTestFaultToken
  $productionReleaseChanged = $false
  if (Test-Path -LiteralPath $ProductionReleaseRoot) {
    try {
      Assert-SnapshotEqual @(Get-FileSnapshot $ProductionReleaseRoot) $protectedProductionRelease `
        'The protected production release changed.'
    } catch { $productionReleaseChanged = $true }
    Remove-Item -LiteralPath $ProductionReleaseRoot -Recurse -Force
  } elseif ($protectedProductionRelease.Count -ne 0) { $productionReleaseChanged = $true }
  if ($productionReleaseExisted -and (Test-Path -LiteralPath $ProductionReleaseBackup -PathType Container)) {
    [IO.Directory]::Move($ProductionReleaseBackup, $ProductionReleaseRoot)
  }
  if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
  if ($productionReleaseChanged) { throw 'The protected production release changed.' }
}
