[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
  [Parameter(Mandatory = $true)][string]$Destination,
  [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build\node-runtime.lock.json'),
  [string]$ArchivePath
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
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $runtimeArchivePath = Join-Path $stagePath $manifest.File
    Invoke-WebRequest -Uri $manifest.Url -OutFile $runtimeArchivePath -UseBasicParsing
    $downloadedArchive = $runtimeArchivePath
  }
  if ((Get-FileHash -LiteralPath $runtimeArchivePath -Algorithm SHA256).Hash -ine $manifest.Sha256) {
    throw 'The Node.js archive hash does not match the runtime manifest.'
  }

  $extractPath = Join-Path $stagePath 'extract'
  Expand-Archive -LiteralPath $runtimeArchivePath -DestinationPath $extractPath
  $archiveRoot = Join-Path $extractPath ([System.IO.Path]::GetFileNameWithoutExtension($manifest.File))
  $nodeSource = Join-Path $archiveRoot 'node.exe'
  $licenseSource = Join-Path $archiveRoot 'LICENSE'
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
