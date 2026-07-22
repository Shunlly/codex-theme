[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
  [Parameter(Mandatory = $true)][string]$Destination,
  [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\node-runtime.lock.json'),
  [string]$ArchivePath,
  [string]$TestOnlyToken,
  [string]$TestOnlyDownloadArchivePath,
  [string]$TestOnlyReplaceAfterHashWith
)

$ErrorActionPreference = 'Stop'

function Get-VerifiedNodeRuntimeManifest {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Architecture)

  $manifestPath = [System.IO.Path]::GetFullPath($Path)
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The Node.js runtime manifest is missing.' }
  try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { throw 'The Node.js runtime manifest is invalid.' }
  if ($manifest.schemaVersion -ne 1 -or "$($manifest.version)" -cne '22.23.1' -or $manifest.minimumMajor -ne 22) {
    throw 'The Node.js runtime manifest is invalid.'
  }
  $archive = $manifest.archives.$Architecture
  if ($null -eq $archive) { throw 'The Node.js runtime manifest is invalid.' }
  $file = "$($archive.file)"
  $url = "$($archive.url)"
  $sha256 = "$($archive.sha256)"
  $expectedFile = "node-v$($manifest.version)-win-$Architecture.zip"
  if ($file -cne $expectedFile -or [System.IO.Path]::GetFileName($file) -cne $file -or
    $url -cne "https://nodejs.org/dist/v$($manifest.version)/$file" -or $sha256 -notmatch '^[a-f0-9]{64}$') {
    throw 'The Node.js runtime manifest is invalid.'
  }
  return [pscustomobject]@{ Version = "$($manifest.version)"; File = $file; Url = $url; Sha256 = $sha256 }
}

$manifest = Get-VerifiedNodeRuntimeManifest -Path $ManifestPath -Architecture $Architecture
$testOnlyRequested = $TestOnlyToken -or $TestOnlyDownloadArchivePath -or $TestOnlyReplaceAfterHashWith
if ($testOnlyRequested -and ($TestOnlyToken -notmatch '^[a-f0-9]{32}$' -or
  "$env:DREAM_SKIN_NODE_FETCH_TEST_TOKEN" -cne $TestOnlyToken -or
  -not $TestOnlyReplaceAfterHashWith -or ($ArchivePath -and $TestOnlyDownloadArchivePath))) {
  throw 'The Node.js runtime test-only gate is invalid.'
}
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) { throw 'The Node.js runtime destination already exists.' }
$destinationParent = Split-Path -Parent $destinationPath
New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
$stagePath = Join-Path $destinationParent (".$([System.IO.Path]::GetFileName($destinationPath)).stage-$PID-$([guid]::NewGuid().ToString('N'))")
$downloadedArchive = $null

try {
  New-Item -ItemType Directory -Path $stagePath | Out-Null
  if ($ArchivePath) {
    $runtimeArchivePath = [System.IO.Path]::GetFullPath($ArchivePath)
    if (-not (Test-Path -LiteralPath $runtimeArchivePath -PathType Leaf) -or [System.IO.Path]::GetFileName($runtimeArchivePath) -cne $manifest.File) {
      throw 'The supplied Node.js archive is invalid.'
    }
  } else {
    $runtimeArchivePath = Join-Path $stagePath $manifest.File
    if ($TestOnlyDownloadArchivePath) {
      $testDownloadPath = [IO.Path]::GetFullPath($TestOnlyDownloadArchivePath)
      if (-not (Test-Path -LiteralPath $testDownloadPath -PathType Leaf) -or
        [IO.Path]::GetFileName($testDownloadPath) -cne $manifest.File) {
        throw 'The Node.js runtime test-only download source is invalid.'
      }
      Copy-Item -LiteralPath $testDownloadPath -Destination $runtimeArchivePath
    } else {
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
      Invoke-WebRequest -Uri $manifest.Url -OutFile $runtimeArchivePath -UseBasicParsing
    }
    $downloadedArchive = $runtimeArchivePath
  }

  $extractPath = Join-Path $stagePath 'extract'
  $archiveRoot = Join-Path $extractPath ([System.IO.Path]::GetFileNameWithoutExtension($manifest.File))
  $nodeSource = Join-Path $archiveRoot 'node.exe'
  $licenseSource = Join-Path $archiveRoot 'LICENSE'
  New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
  Add-Type -AssemblyName System.IO.Compression
  $archiveStream = $null
  $zipArchive = $null
  try {
    $archiveStream = [IO.File]::Open($runtimeArchivePath, [IO.FileMode]::Open,
      [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = ([BitConverter]::ToString($sha256.ComputeHash($archiveStream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
    if ($actualHash -cne $manifest.Sha256) {
      throw 'The Node.js archive hash does not match the runtime manifest.'
    }
    $archiveStream.Position = 0

    if ($TestOnlyReplaceAfterHashWith) {
      $replacementPath = [IO.Path]::GetFullPath($TestOnlyReplaceAfterHashWith)
      if (-not (Test-Path -LiteralPath $replacementPath -PathType Leaf) -or
        [IO.Path]::GetPathRoot($replacementPath) -cne [IO.Path]::GetPathRoot($runtimeArchivePath)) {
        throw 'The Node.js runtime test-only replacement is invalid.'
      }
      try { [IO.File]::Replace($replacementPath, $runtimeArchivePath, $null) } catch {
        throw 'Node archive replacement was denied after hashing.'
      }
      throw 'Node archive replacement unexpectedly succeeded after hashing.'
    }

    $zipArchive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $true)
    $archivePrefix = [IO.Path]::GetFileNameWithoutExtension($manifest.File)
    foreach ($entrySpec in @(
      @{ Name = "$archivePrefix/node.exe"; Destination = $nodeSource },
      @{ Name = "$archivePrefix/LICENSE"; Destination = $licenseSource }
    )) {
      $entries = @($zipArchive.Entries | Where-Object { $_.FullName -ceq $entrySpec.Name -and $_.Name })
      if ($entries.Count -ne 1) { throw 'The Node.js archive contents are invalid.' }
      $entry = $entries[0]
      $entryStream = $null
      $destinationStream = $null
      try {
        $entryStream = $entry.Open()
        $destinationStream = [IO.File]::Open($entrySpec.Destination, [IO.FileMode]::CreateNew,
          [IO.FileAccess]::Write, [IO.FileShare]::None)
        $entryStream.CopyTo($destinationStream)
      } finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($entryStream) { $entryStream.Dispose() }
      }
    }
  } finally {
    if ($zipArchive) { $zipArchive.Dispose() }
    if ($archiveStream) { $archiveStream.Dispose() }
  }
  if (-not (Test-Path -LiteralPath $nodeSource -PathType Leaf) -or -not (Test-Path -LiteralPath $licenseSource -PathType Leaf)) {
    throw 'The Node.js archive contents are invalid.'
  }

  $noticeSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'build\NODE-NOTICE.txt'
  if (-not (Test-Path -LiteralPath $noticeSource -PathType Leaf)) { throw 'The Node.js runtime notice is missing.' }
  $stagedRuntime = Join-Path $stagePath 'runtime'
  New-Item -ItemType Directory -Path $stagedRuntime | Out-Null
  $stagedNode = Join-Path $stagedRuntime 'node.exe'
  Copy-Item -LiteralPath $nodeSource -Destination $stagedNode
  Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $stagedRuntime 'LICENSE.node.txt')
  Copy-Item -LiteralPath $noticeSource -Destination (Join-Path $stagedRuntime 'NOTICE.node.txt')
  $version = "$(& $stagedNode -p 'process.versions.node' 2>$null)".Trim()
  if ($LASTEXITCODE -ne 0 -or -not $version -or $version -cne $manifest.Version) {
    throw 'The extracted Node.js runtime version is invalid.'
  }

  [System.IO.Directory]::Move($stagedRuntime, $destinationPath)
  Write-Host "PASS: Node.js $version win-$Architecture verified."
} finally {
  if ($downloadedArchive -and (Test-Path -LiteralPath $downloadedArchive)) { Remove-Item -LiteralPath $downloadedArchive -Force }
  if (Test-Path -LiteralPath $stagePath) { Remove-Item -LiteralPath $stagePath -Recurse -Force }
}
