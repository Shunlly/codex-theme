[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateSet('x64', 'arm64')][string]$Architecture,
  [switch]$SkipSign,
  [switch]$SkipTests,
  [string]$TestOnlyToken,
  [string]$TestOnlyPostTestFailureToken
)

$ErrorActionPreference = 'Stop'
$WindowsRoot = Split-Path -Parent $PSScriptRoot
$RepoRoot = Split-Path -Parent $WindowsRoot
$releaseTestRoot = $null
$TestAppId = $null
$TestDefaultDirName = $null
if ($TestOnlyToken) {
  if ($TestOnlyToken -notmatch '^[a-f0-9]{32}$' -or
    "$env:DREAM_SKIN_RELEASE_TEST_TOKEN" -cne $TestOnlyToken -or -not $SkipSign -or -not $SkipTests -or
    $TestOnlyPostTestFailureToken) {
    throw 'The Windows release test-only gate is invalid.'
  }
  $releaseTestRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dream-skin-release-$TestOnlyToken"
  $ReleaseRoot = Join-Path $releaseTestRoot 'release'
  $TestAppId = "com.feiaway.codex-dream-skin-studio.test.$TestOnlyToken"
  $TestDefaultDirName = Join-Path $releaseTestRoot 'installed'
} else {
  $ReleaseRoot = Join-Path $WindowsRoot 'release'
}
if ($TestOnlyPostTestFailureToken -and ($TestOnlyPostTestFailureToken -notmatch '^[a-f0-9]{32}$' -or
  "$env:DREAM_SKIN_RELEASE_TEST_POST_TEST_TOKEN" -cne $TestOnlyPostTestFailureToken -or
  -not $SkipSign -or $SkipTests -or $TestOnlyToken)) {
  throw 'The Windows release post-test fault gate is invalid.'
}
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

function Assert-ReleaseInputsMatchIndex {
  param([string[]]$Paths)
  & git -C $RepoRoot diff --quiet $IndexTree -- $Paths
  if ($LASTEXITCODE -ne 0) { throw 'Studio build inputs must be tracked regular files matching the Git index.' }
  $untracked = @(& git -C $RepoRoot ls-files --others --exclude-standard -- $Paths)
  if ($LASTEXITCODE -ne 0 -or $untracked.Count -ne 0) {
    throw 'Studio build inputs must be tracked regular files matching the Git index.'
  }
  $entries = @(& git -C $RepoRoot ls-files --stage -- $Paths)
  if ($LASTEXITCODE -ne 0 -or $entries.Count -eq 0) {
    throw 'Studio build inputs must be tracked regular files matching the Git index.'
  }
  foreach ($entry in $entries) {
    if ($entry -notmatch '^(100644|100755) [0-9a-f]{40,64} 0\t') {
      throw 'Studio build inputs must be tracked regular files matching the Git index.'
    }
  }
}

function Assert-PinnedIndexFile {
  param([object]$Pin, [string]$RelativePath)
  $expected = "$(& git -C $RepoRoot rev-parse "$IndexTree`:$RelativePath")".Trim()
  $actual = "$(& git -C $RepoRoot hash-object "--path=$RelativePath" $Pin.FullPath)".Trim()
  if ($LASTEXITCODE -ne 0 -or $expected -notmatch '^[0-9a-f]{40,64}$' -or $actual -cne $expected) {
    throw "The immutable snapshot file is not the indexed $RelativePath object."
  }
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

if (-not ('DreamSkinReleaseFilePin' -as [type])) {
  Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

public sealed class DreamSkinReleaseFilePin : IDisposable {
  private const uint GENERIC_READ = 0x80000000;
  private const uint OPEN_EXISTING = 3;
  private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
  private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
  private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
  private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
  private FileStream stream;

  [StructLayout(LayoutKind.Sequential)]
  internal struct FileInformation {
    internal uint FileAttributes;
    internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
    internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
    internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
    internal uint VolumeSerialNumber;
    internal uint FileSizeHigh;
    internal uint FileSizeLow;
    internal uint NumberOfLinks;
    internal uint FileIndexHigh;
    internal uint FileIndexLow;
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess, FileShare shareMode,
    IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInformation information);

  private DreamSkinReleaseFilePin(string path, SafeFileHandle handle, FileInformation information) {
    FullPath = Path.GetFullPath(path);
    Identity = IdentityOf(information);
    stream = new FileStream(handle, FileAccess.Read, 65536, false);
    Sha256 = Hash(stream);
  }

  public string FullPath { get; private set; }
  public string Identity { get; private set; }
  public string Sha256 { get; private set; }

  internal static SafeFileHandle OpenRaw(string path, bool allowDelete, out FileInformation information) {
    FileShare share = FileShare.Read | (allowDelete ? FileShare.Delete : (FileShare)0);
    SafeFileHandle handle = CreateFileW(Path.GetFullPath(path), GENERIC_READ, share, IntPtr.Zero,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
    if (handle.IsInvalid) {
      int error = Marshal.GetLastWin32Error();
      handle.Dispose();
      throw new Win32Exception(error, "Release input could not be pinned.");
    }
    if (!GetFileInformationByHandle(handle, out information)) {
      int error = Marshal.GetLastWin32Error();
      handle.Dispose();
      throw new Win32Exception(error, "Release input identity could not be read.");
    }
    if ((information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      handle.Dispose();
      throw new InvalidDataException("Release inputs cannot contain reparse points.");
    }
    return handle;
  }

  internal static bool IsDirectory(FileInformation information) {
    return (information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  }

  public static DreamSkinReleaseFilePin Open(string path, bool allowDelete) {
    FileInformation information;
    SafeFileHandle handle = OpenRaw(path, allowDelete, out information);
    if (IsDirectory(information)) {
      handle.Dispose();
      throw new InvalidDataException("A release file path resolved to a directory.");
    }
    try { return new DreamSkinReleaseFilePin(path, handle, information); }
    catch { handle.Dispose(); throw; }
  }

  public void AssertUnchanged(string path) {
    using (DreamSkinReleaseFilePin current = Open(path, true)) {
      if (!String.Equals(Identity, current.Identity, StringComparison.Ordinal) ||
        !String.Equals(Sha256, current.Sha256, StringComparison.Ordinal)) {
        throw new InvalidDataException("A pinned release file changed.");
      }
    }
  }

  public void AssertSameFile(DreamSkinReleaseFilePin other) {
    if (other == null || !String.Equals(Identity, other.Identity, StringComparison.Ordinal) ||
      !String.Equals(Sha256, other.Sha256, StringComparison.Ordinal)) {
      throw new InvalidDataException("The release pathname no longer identifies the proven file.");
    }
  }

  private static string IdentityOf(FileInformation information) {
    return information.VolumeSerialNumber.ToString("x8") + ":" +
      information.FileIndexHigh.ToString("x8") + information.FileIndexLow.ToString("x8");
  }

  private static string Hash(Stream input) {
    input.Position = 0;
    using (SHA256 sha = SHA256.Create()) {
      string value = BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
      input.Position = 0;
      return value;
    }
  }

  public void Dispose() {
    if (stream != null) {
      stream.Dispose();
      stream = null;
    }
  }
}

public sealed class DreamSkinReleaseEntry {
  internal DreamSkinReleaseEntry(string relativePath, DreamSkinReleaseFilePin pin) {
    RelativePath = relativePath;
    FullPath = pin.FullPath;
    Identity = pin.Identity;
    Sha256 = pin.Sha256;
  }
  public string RelativePath { get; private set; }
  public string FullPath { get; private set; }
  public string Identity { get; private set; }
  public string Sha256 { get; private set; }
}

public sealed class DreamSkinReleaseTreePin : IDisposable {
  private sealed class HeldEntry {
    internal string RelativePath;
    internal DreamSkinReleaseFilePin Pin;
  }
  private readonly List<SafeFileHandle> directories = new List<SafeFileHandle>();
  private readonly List<HeldEntry> files = new List<HeldEntry>();
  private readonly string root;

  private DreamSkinReleaseTreePin(string path) { root = Path.GetFullPath(path).TrimEnd('\\'); }

  public static DreamSkinReleaseTreePin Open(string path) {
    DreamSkinReleaseTreePin tree = new DreamSkinReleaseTreePin(path);
    try {
      tree.PinDirectory(tree.root, "");
      return tree;
    } catch {
      tree.Dispose();
      throw;
    }
  }

  public DreamSkinReleaseEntry[] Entries {
    get {
      DreamSkinReleaseEntry[] result = new DreamSkinReleaseEntry[files.Count];
      for (int index = 0; index < files.Count; index++) {
        result[index] = new DreamSkinReleaseEntry(files[index].RelativePath, files[index].Pin);
      }
      return result;
    }
  }

  private void PinDirectory(string directory, string relativeDirectory) {
    DreamSkinReleaseFilePin.FileInformation information;
    SafeFileHandle handle = DreamSkinReleaseFilePin.OpenRaw(directory, false, out information);
    if (!DreamSkinReleaseFilePin.IsDirectory(information)) {
      handle.Dispose();
      throw new InvalidDataException("A release directory path resolved to a file.");
    }
    directories.Add(handle);
    string[] children = Directory.GetFileSystemEntries(directory);
    Array.Sort(children, StringComparer.Ordinal);
    foreach (string child in children) {
      string name = Path.GetFileName(child);
      string relative = relativeDirectory.Length == 0 ? name : Path.Combine(relativeDirectory, name);
      FileAttributes attributes = File.GetAttributes(child);
      if ((attributes & FileAttributes.ReparsePoint) != 0) {
        throw new InvalidDataException("Release inputs cannot contain reparse points.");
      }
      if ((attributes & FileAttributes.Directory) != 0) {
        PinDirectory(child, relative);
      } else {
        files.Add(new HeldEntry {
          RelativePath = relative.Replace('/', '\\'),
          Pin = DreamSkinReleaseFilePin.Open(child, false)
        });
      }
    }
  }

  public void AssertUnchanged(string path) {
    string currentRoot = Path.GetFullPath(path).TrimEnd('\\');
    if (!String.Equals(root, currentRoot, StringComparison.OrdinalIgnoreCase)) {
      throw new InvalidDataException("The pinned release root changed.");
    }
    List<string> currentFiles = new List<string>();
    CollectFiles(currentRoot, "", currentFiles);
    if (currentFiles.Count != files.Count) throw new InvalidDataException("The staged release file set changed.");
    for (int index = 0; index < files.Count; index++) {
      if (!String.Equals(files[index].RelativePath, currentFiles[index], StringComparison.Ordinal)) {
        throw new InvalidDataException("The staged release file set changed.");
      }
      files[index].Pin.AssertUnchanged(Path.Combine(currentRoot, currentFiles[index]));
    }
  }

  private static void CollectFiles(string directory, string relativeDirectory, List<string> result) {
    string[] children = Directory.GetFileSystemEntries(directory);
    Array.Sort(children, StringComparer.Ordinal);
    foreach (string child in children) {
      string name = Path.GetFileName(child);
      string relative = relativeDirectory.Length == 0 ? name : Path.Combine(relativeDirectory, name);
      FileAttributes attributes = File.GetAttributes(child);
      if ((attributes & FileAttributes.ReparsePoint) != 0) {
        throw new InvalidDataException("Release inputs cannot contain reparse points.");
      }
      if ((attributes & FileAttributes.Directory) != 0) CollectFiles(child, relative, result);
      else result.Add(relative.Replace('/', '\\'));
    }
  }

  public void Dispose() {
    for (int index = files.Count - 1; index >= 0; index--) files[index].Pin.Dispose();
    files.Clear();
    for (int index = directories.Count - 1; index >= 0; index--) directories[index].Dispose();
    directories.Clear();
  }
}
'@
}

function Write-InnoFileManifest {
  param([object]$Tree, [string]$Path)
  $lines = @($Tree.Entries | ForEach-Object {
    $relativeDirectory = Split-Path -Parent $_.RelativePath
    $destination = if ($relativeDirectory) { "{app}\$relativeDirectory" } else { '{app}' }
    "Source: `"$($_.FullPath)`"; DestDir: `"$destination`"; Flags: ignoreversion"
  })
  if ($lines.Count -eq 0) { throw 'The staged release file manifest is empty.' }
  [IO.File]::WriteAllText($Path, (($lines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
}

function Assert-ReleaseMetadata {
  param(
    [string]$Root,
    [string]$Version,
    [string]$Architecture,
    [string]$Signing,
    [string]$File,
    [string]$SourceTree,
    [string]$ExpectedHash
  )
  $expectedKeys = 'schemaVersion,version,architecture,signing,file,sha256,sourceTree'
  $manifestPath = Join-Path $Root 'release-manifest.json'
  $checksumPath = Join-Path $Root 'SHA256SUMS.txt'
  $setupPath = Join-Path $Root $File
  $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
  $freshHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($freshHash -cne $ExpectedHash) { throw 'Release metadata does not match the fresh setup SHA-256.' }
  $expectedManifest = [ordered]@{
    schemaVersion = 1
    version = $Version
    architecture = $Architecture
    signing = $Signing
    file = $File
    sha256 = $ExpectedHash
    sourceTree = $SourceTree
  }
  $expectedManifestText = (($expectedManifest | ConvertTo-Json -Depth 3) + "`r`n")
  try { $manifestText = $strictUtf8.GetString([IO.File]::ReadAllBytes($manifestPath)) } catch {
    throw 'Release manifest is not strict UTF-8.'
  }
  if ($manifestText -cne $expectedManifestText -or
    ((($manifestText | ConvertFrom-Json).PSObject.Properties.Name) -join ',') -cne $expectedKeys) {
    throw 'Release manifest keys or values are not exact.'
  }
  try { $checksumText = $strictUtf8.GetString([IO.File]::ReadAllBytes($checksumPath)) } catch {
    throw 'Release checksum is not strict UTF-8.'
  }
  if ($checksumText -cne "$ExpectedHash  $File`r`n") {
    throw 'Release metadata must contain exactly one checksum entry.'
  }
}

function Invoke-TestOnlyReleaseReplacement {
  param(
    [string]$Phase,
    [string]$Target,
    [string]$Replacement,
    [string]$Proof,
    [switch]$ExpectSuccess
  )
  if (-not $TestOnlyToken -or "$env:DREAM_SKIN_RELEASE_TEST_REPLACE_PHASE" -cne $Phase) { return }
  if (-not (Test-Path -LiteralPath $Replacement -PathType Leaf)) {
    throw 'The release replacement test seam is invalid.'
  }
  try { [IO.File]::Replace($Replacement, $Target, $null) } catch {
    if ($ExpectSuccess) { throw 'setup-publication-replacement-unexpectedly-denied' }
    throw "$Proof`: replacement was denied by the pinned release identity."
  }
  if ($ExpectSuccess) { return }
  throw "$Proof`: replacement unexpectedly succeeded."
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

function Sign-File {
  param([string]$Path, [string]$SignTool, [string]$Thumbprint)
  & $SignTool sign /sha1 $Thumbprint /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $Path
  Assert-LastExitCode 'Windows code signing failed.'
}

function Assert-FileSignature {
  param([string]$Path, [string]$SignTool)
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
$SnapshotTemporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-dream-skin-studio-release-$token"
$SnapshotRepoRoot = Join-Path $SnapshotTemporaryRoot 'snapshot'
$SnapshotWindowsRoot = Join-Path $SnapshotRepoRoot 'windows'
$SnapshotIndex = Join-Path $SnapshotTemporaryRoot 'snapshot.index'
$PublishRoot = Join-Path $TemporaryRoot 'publish'
$PublishOutput = Join-Path $SnapshotTemporaryRoot 'dotnet-publish'
$TestArtifactsRoot = Join-Path $SnapshotTemporaryRoot 'test-artifacts'
$IconPath = Join-Path $SnapshotTemporaryRoot 'CodexDreamSkinStudio.ico'
$InnoFilesManifest = Join-Path $SnapshotTemporaryRoot 'stage-files.iss'
$ReplacementRoot = Join-Path $TemporaryRoot 'test-replacements'
$ReleaseParent = Split-Path -Parent $ReleaseRoot
$OldRelease = Join-Path $ReleaseParent ".release-old-$token"
$FailedRelease = Join-Path $ReleaseParent ".release-failed-$token"
$swapped = $false
$releaseMoved = $false
$stagePins = $null
$manifestPin = $null
$innoSourcePin = $null
$scannerPin = $null
$allowlistPin = $null
$iconPin = $null
$setupPin = $null
$finalSetupPin = $null
$setupPublicationIdentity = $null
$setupPublicationHash = $null
$releaseInputPaths = @(
  'Directory.Build.props', 'Directory.Build.targets',
  'windows/Directory.Build.props', 'windows/Directory.Build.targets',
  'windows/assets', 'windows/build', 'windows/scripts', 'windows/studio',
  'windows/LICENSE', 'windows/NOTICE.md', 'windows/VERSION',
  'studio/assets/app-icon-source.png', 'studio/protocol/README.md', 'studio/protocol/fixtures-v1.json',
  'studio/release/check-contents.mjs', 'studio/release/allowlist-windows.json'
)
if (-not $SkipTests) {
  $releaseInputPaths += @(
    'windows/studio-tests', 'windows/tests', 'windows/SKILL.md',
    'README.md', 'README.en.md', 'docs/platforms.md'
  )
}

try {
  New-Item -ItemType Directory -Path $ReleaseParent -Force | Out-Null
  New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $ReplacementRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $SnapshotTemporaryRoot -Force | Out-Null
  $StageReplacement = Join-Path $ReplacementRoot 'stage-adapter.ps1'
  $ManifestReplacement = Join-Path $ReplacementRoot 'stage-files.iss'
  $SetupReplacement = Join-Path $ReplacementRoot 'setup.exe'
  [IO.File]::WriteAllText($StageReplacement, 'Write-Host replacement', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($ManifestReplacement,
    'Source: "C:\\replacement.exe"; DestDir: "{app}"; Flags: ignoreversion',
    [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($SetupReplacement, 'replacement', [Text.UTF8Encoding]::new($false))
  $treeOutput = & git -C $RepoRoot write-tree
  if ($LASTEXITCODE -ne 0) { throw 'Studio build inputs must be tracked regular files matching the Git index.' }
  $IndexTree = "$treeOutput".Trim()
  if ($IndexTree -notmatch '^[0-9a-f]{40,64}$') {
    throw 'Studio build inputs must be tracked regular files matching the Git index.'
  }

  $previousGitIndexFile = $env:GIT_INDEX_FILE
  try {
    $env:GIT_INDEX_FILE = $SnapshotIndex
    & git -C $RepoRoot read-tree $IndexTree
    Assert-LastExitCode 'Studio build inputs must be tracked regular files matching the Git index.'
    Assert-ReleaseInputsMatchIndex -Paths $releaseInputPaths
  } finally {
    if ($null -eq $previousGitIndexFile) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    else { $env:GIT_INDEX_FILE = $previousGitIndexFile }
  }

  if (-not $SkipTests) {
    & $PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $WindowsRoot 'tests\run-tests.ps1')
    Assert-LastExitCode 'Windows PowerShell self-checks failed.'
  }
  if ($TestOnlyPostTestFailureToken) { throw 'forced-post-test-release-failure' }

  $currentTree = "$(& git -C $RepoRoot write-tree)".Trim()
  if ($LASTEXITCODE -ne 0 -or $currentTree -cne $IndexTree) {
    throw 'Studio build inputs must be tracked regular files matching the Git index.'
  }
  try {
    $env:GIT_INDEX_FILE = $SnapshotIndex
    Assert-ReleaseInputsMatchIndex -Paths $releaseInputPaths
  } finally {
    if ($null -eq $previousGitIndexFile) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    else { $env:GIT_INDEX_FILE = $previousGitIndexFile }
  }

  try {
    $env:GIT_INDEX_FILE = $SnapshotIndex
    New-Item -ItemType Directory -Path $SnapshotRepoRoot -Force | Out-Null
    $snapshotPrefix = ($SnapshotRepoRoot -replace '\\', '/').TrimEnd('/') + '/'
    & git -C $RepoRoot checkout-index --all --force "--prefix=$snapshotPrefix"
    Assert-LastExitCode 'The immutable Git-index snapshot could not be created.'
  } finally {
    if ($null -eq $previousGitIndexFile) { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    else { $env:GIT_INDEX_FILE = $previousGitIndexFile }
  }

  if (-not $SkipTests) {
    Push-Location $SnapshotRepoRoot
    try {
      & $DotNet run --project (Join-Path $SnapshotWindowsRoot 'studio-tests\CodexDreamSkinStudio.Tests.csproj') `
        -c Release -r "win-$Architecture" --artifacts-path $TestArtifactsRoot
      Assert-LastExitCode 'Windows Studio console self-checks failed.'
    } finally {
      Pop-Location
    }
  }

  $Version = [IO.File]::ReadAllText((Join-Path $SnapshotWindowsRoot 'VERSION')).Trim()
  if ($Version -cne '1.3.0') { throw 'The Windows release version is invalid.' }
  $StageRoot = Join-Path $PublishRoot "stage-$Version"
  $EngineRoot = Join-Path $StageRoot 'engine'
  New-Item -ItemType Directory -Path $EngineRoot -Force | Out-Null
  New-StudioIcon -Source (Join-Path $SnapshotRepoRoot 'studio\assets\app-icon-source.png') -Destination $IconPath

  Push-Location $SnapshotRepoRoot
  try {
    & $DotNet publish (Join-Path $SnapshotWindowsRoot 'studio\CodexDreamSkinStudio.csproj') -c Release -r "win-$Architecture" `
      --self-contained true -o $PublishOutput /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true `
      /p:DebugType=None /p:DebugSymbols=false /p:ContinuousIntegrationBuild=true `
      "/p:PathMap=$SnapshotRepoRoot=/_/src" "/p:ApplicationIcon=$IconPath" "/p:Version=$Version" `
      "/p:FileVersion=$Version.0" "/p:AssemblyVersion=$Version.0" "/p:InformationalVersion=$Version" `
      /p:IncludeSourceRevisionInInformationalVersion=false
    Assert-LastExitCode 'Windows Studio publish failed.'
  } finally {
    Pop-Location
  }
  Copy-ReleaseFile (Join-Path $PublishOutput 'CodexDreamSkinStudio.exe') (Join-Path $StageRoot 'CodexDreamSkinStudio.exe')

  $runtimeRoot = Join-Path $EngineRoot 'runtime'
  & (Join-Path $SnapshotWindowsRoot 'scripts\fetch-node-runtime.ps1') -Architecture $Architecture -Destination $runtimeRoot
  Assert-LastExitCode 'Private Node.js runtime staging failed.'

  $runtimeScripts = @(
    'common-windows.ps1', 'config-utf8.ps1', 'image-metadata.mjs', 'injector.mjs',
    'install-dream-skin.ps1', 'pause-dream-skin.ps1', 'restore-dream-skin.ps1',
    'start-dream-skin.ps1', 'status-dream-skin.ps1', 'studio-adapter.ps1',
    'studio-windows.ps1', 'theme-windows.ps1', 'tray-dream-skin.ps1', 'verify-dream-skin.ps1'
  )
  foreach ($script in $runtimeScripts) {
    Copy-ReleaseFile (Join-Path $SnapshotWindowsRoot "scripts\$script") (Join-Path $EngineRoot "scripts\$script")
  }
  New-Item -ItemType Directory -Path (Join-Path $EngineRoot 'assets') -Force | Out-Null
  $runtimeAssets = @('dream-reference.jpg', 'dream-skin.css', 'renderer-inject.js', 'theme.json')
  foreach ($asset in $runtimeAssets) {
    Copy-ReleaseFile (Join-Path $SnapshotWindowsRoot "assets\$asset") (Join-Path $EngineRoot "assets\$asset")
  }
  Copy-ReleaseFile (Join-Path $SnapshotWindowsRoot 'LICENSE') (Join-Path $EngineRoot 'LICENSE')
  Copy-ReleaseFile (Join-Path $SnapshotWindowsRoot 'NOTICE.md') (Join-Path $EngineRoot 'NOTICE.md')
  Copy-ReleaseFile (Join-Path $SnapshotWindowsRoot 'VERSION') (Join-Path $EngineRoot 'VERSION')
  Copy-ReleaseFile (Join-Path $SnapshotRepoRoot 'studio\protocol\README.md') (Join-Path $EngineRoot 'protocol\README.md')
  Copy-ReleaseFile (Join-Path $SnapshotRepoRoot 'studio\protocol\fixtures-v1.json') (Join-Path $EngineRoot 'protocol\fixtures-v1.json')

  $studioPath = Join-Path $StageRoot 'CodexDreamSkinStudio.exe'
  if (-not $SkipSign) { Sign-File -Path $studioPath -SignTool $SignTool -Thumbprint $Thumbprint }
  $PrivateNodePath = Join-Path $runtimeRoot 'node.exe'
  $label = if ($SkipSign) { 'UNSIGNED' } else { $null }
  $baseName = (@("CodexDreamSkinStudio-$Version-win-$Architecture", $label) | Where-Object { $_ }) -join '-'
  $stagePins = [DreamSkinReleaseTreePin]::Open($StageRoot)
  $innoSourcePath = Join-Path $SnapshotWindowsRoot 'build\dream-skin-studio.iss'
  $scannerPath = Join-Path $SnapshotRepoRoot 'studio\release\check-contents.mjs'
  $allowlistPath = Join-Path $SnapshotRepoRoot 'studio\release\allowlist-windows.json'
  $innoSourcePin = [DreamSkinReleaseFilePin]::Open($innoSourcePath, $false)
  $scannerPin = [DreamSkinReleaseFilePin]::Open($scannerPath, $false)
  $allowlistPin = [DreamSkinReleaseFilePin]::Open($allowlistPath, $false)
  $iconPin = [DreamSkinReleaseFilePin]::Open($IconPath, $false)
  Assert-PinnedIndexFile -Pin $innoSourcePin -RelativePath 'windows/build/dream-skin-studio.iss'
  Assert-PinnedIndexFile -Pin $scannerPin -RelativePath 'studio/release/check-contents.mjs'
  Assert-PinnedIndexFile -Pin $allowlistPin -RelativePath 'studio/release/allowlist-windows.json'
  try {
    if (-not $SkipSign) { Assert-FileSignature -Path $studioPath -SignTool $SignTool }
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($studioPath)
    if ($versionInfo.ProductVersion -cne $Version -or $versionInfo.FileVersion -cne "$Version.0") {
      throw 'The staged Studio version metadata does not match windows/VERSION.'
    }
    & $PrivateNodePath $scannerPath --root $StageRoot --allowlist $allowlistPath
    if ($LASTEXITCODE -ne 0) { throw 'Release content scan failed.' }
    Invoke-TestOnlyReleaseReplacement -Phase 'stage-after-scan' `
      -Target (Join-Path $EngineRoot 'scripts\studio-adapter.ps1') -Replacement $StageReplacement `
      -Proof 'stage-adapter-replacement-denied'

    Write-InnoFileManifest -Tree $stagePins -Path $InnoFilesManifest
    if ($TestOnlyToken -and "$env:DREAM_SKIN_RELEASE_TEST_PAYLOAD_FAULT" -ceq 'payload-fault-omit-engine-adapter') {
      $manifestLines = @([IO.File]::ReadAllLines($InnoFilesManifest))
      $filteredManifestLines = @($manifestLines | Where-Object {
        $_ -notmatch 'engine\\scripts\\studio-adapter\.ps1'
      })
      if ($filteredManifestLines.Count -ge $manifestLines.Count) {
        throw 'payload-fault-omit-engine-adapter could not identify its target entry.'
      }
      [IO.File]::WriteAllText($InnoFilesManifest, (($filteredManifestLines -join "`r`n") + "`r`n"),
        [Text.UTF8Encoding]::new($false))
      Write-Host 'payload-fault-omit-engine-adapter'
    }
    $innoArguments = @(
      "/DAppVersion=`"$Version`"", "/DArchitecture=`"$Architecture`"", "/DStageRoot=`"$StageRoot`"",
      "/DStageFilesManifest=`"$InnoFilesManifest`"", "/DOutputDir=`"$PublishRoot`"",
      "/DOutputBaseFilename=`"$baseName`"", "/DIconPath=`"$IconPath`""
    )
    if ($TestOnlyToken) {
      $innoArguments += "/DTestAppId=`"$TestAppId`""
      $innoArguments += "/DTestDefaultDirName=`"$TestDefaultDirName`""
    }
    $manifestPin = [DreamSkinReleaseFilePin]::Open($InnoFilesManifest, $false)
    Invoke-TestOnlyReleaseReplacement -Phase 'manifest-before-iscc' -Target $InnoFilesManifest `
      -Replacement $ManifestReplacement -Proof 'manifest-replacement-denied'
    $innoArguments += $innoSourcePath
    & $InnoSetup $innoArguments
    Assert-LastExitCode 'Inno Setup compilation failed.'
    $stagePins.AssertUnchanged($StageRoot)
    $manifestPin.AssertUnchanged($InnoFilesManifest)
    $innoSourcePin.AssertUnchanged($innoSourcePath)
    $scannerPin.AssertUnchanged($scannerPath)
    $allowlistPin.AssertUnchanged($allowlistPath)
    $iconPin.AssertUnchanged($IconPath)
  } finally {
    if ($stagePins) { $stagePins.Dispose(); $stagePins = $null }
    if ($manifestPin) { $manifestPin.Dispose(); $manifestPin = $null }
    if ($innoSourcePin) { $innoSourcePin.Dispose(); $innoSourcePin = $null }
    if ($scannerPin) { $scannerPin.Dispose(); $scannerPin = $null }
    if ($allowlistPin) { $allowlistPin.Dispose(); $allowlistPin = $null }
    if ($iconPin) { $iconPin.Dispose(); $iconPin = $null }
  }

  $setupPath = Join-Path $PublishRoot "$baseName.exe"
  if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'Inno Setup output is missing.' }
  if (-not $SkipSign) { Sign-File -Path $setupPath -SignTool $SignTool -Thumbprint $Thumbprint }
  $setupPin = [DreamSkinReleaseFilePin]::Open($setupPath, $false)
  if (-not $SkipSign) { Assert-FileSignature -Path $setupPath -SignTool $SignTool }
  $setupVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setupPath)
  $setupProductVersion = "$($setupVersionInfo.ProductVersion)".Trim()
  $setupFileVersion = "$($setupVersionInfo.FileVersion)".Trim()
  if ($setupProductVersion -notin @($Version, "$Version.0") -or
    $setupFileVersion -cne "$Version.0") {
    throw "The setup version metadata does not match windows/VERSION: ProductVersion='$setupProductVersion', FileVersion='$setupFileVersion'."
  }
  Invoke-TestOnlyReleaseReplacement -Phase 'setup-after-signature' -Target $setupPath `
    -Replacement $SetupReplacement -Proof 'setup-replacement-denied'

  $hash = $setupPin.Sha256
  [IO.File]::WriteAllText((Join-Path $PublishRoot 'SHA256SUMS.txt'), "$hash  $baseName.exe`r`n", [Text.UTF8Encoding]::new($false))
  $signingMode = if ($SkipSign) { 'UNSIGNED' } else { 'signed' }
  $manifest = [ordered]@{
    schemaVersion = 1
    version = $Version
    architecture = $Architecture
    signing = $signingMode
    file = "$baseName.exe"
    sha256 = $hash
    sourceTree = $IndexTree
  }
  [IO.File]::WriteAllText((Join-Path $PublishRoot 'release-manifest.json'),
    (($manifest | ConvertTo-Json -Depth 3) + "`r`n"), [Text.UTF8Encoding]::new($false))
  Assert-ReleaseMetadata -Root $PublishRoot -Version $Version -Architecture $Architecture `
    -Signing $signingMode -File "$baseName.exe" -SourceTree $IndexTree -ExpectedHash $hash

  $setupPublicationIdentity = $setupPin.Identity
  $setupPublicationHash = $setupPin.Sha256
  $setupPin.Dispose()
  $setupPin = $null
  Invoke-TestOnlyReleaseReplacement -Phase 'setup-before-publication' -Target $setupPath `
    -Replacement $SetupReplacement -Proof 'setup-publication-identity-mismatch' -ExpectSuccess

  if (Test-Path -LiteralPath $ReleaseRoot) { [IO.Directory]::Move($ReleaseRoot, $OldRelease) }
  try {
    [IO.Directory]::Move($PublishRoot, $ReleaseRoot)
    $releaseMoved = $true
    $finalSetupPath = Join-Path $ReleaseRoot "$baseName.exe"
    $finalSetupPin = [DreamSkinReleaseFilePin]::Open($finalSetupPath, $false)
    if ($finalSetupPin.Identity -cne $setupPublicationIdentity -or
      $finalSetupPin.Sha256 -cne $setupPublicationHash) {
      throw 'setup-publication-identity-mismatch'
    }
    if (-not $SkipSign) { Assert-FileSignature -Path $finalSetupPath -SignTool $SignTool }
    $finalSetupVersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($finalSetupPath)
    $finalSetupProductVersion = "$($finalSetupVersionInfo.ProductVersion)".Trim()
    $finalSetupFileVersion = "$($finalSetupVersionInfo.FileVersion)".Trim()
    if ($finalSetupProductVersion -notin @($Version, "$Version.0") -or
      $finalSetupFileVersion -cne "$Version.0") {
      throw "The final setup version metadata does not match windows/VERSION: ProductVersion='$finalSetupProductVersion', FileVersion='$finalSetupFileVersion'."
    }
    Assert-ReleaseMetadata -Root $ReleaseRoot -Version $Version -Architecture $Architecture `
      -Signing $signingMode -File "$baseName.exe" -SourceTree $IndexTree -ExpectedHash $finalSetupPin.Sha256
    $finalSetupPin.Dispose()
    $finalSetupPin = $null
    $swapped = $true
  } catch {
    if ($finalSetupPin) { $finalSetupPin.Dispose(); $finalSetupPin = $null }
    if ($releaseMoved -and (Test-Path -LiteralPath $ReleaseRoot)) {
      [IO.Directory]::Move($ReleaseRoot, $FailedRelease)
      $releaseMoved = $false
    }
    if ((Test-Path -LiteralPath $OldRelease) -and -not (Test-Path -LiteralPath $ReleaseRoot)) {
      [IO.Directory]::Move($OldRelease, $ReleaseRoot)
    }
    if (Test-Path -LiteralPath $FailedRelease) { Remove-Item -LiteralPath $FailedRelease -Recurse -Force }
    throw
  }
  if (Test-Path -LiteralPath $OldRelease) { Remove-Item -LiteralPath $OldRelease -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Host "Created $(Join-Path $ReleaseRoot "$baseName.exe")"
  if ($SkipSign) { Write-Warning 'Created an UNSIGNED development installer.' }
} finally {
  if ($stagePins) { $stagePins.Dispose() }
  if ($manifestPin) { $manifestPin.Dispose() }
  if ($innoSourcePin) { $innoSourcePin.Dispose() }
  if ($scannerPin) { $scannerPin.Dispose() }
  if ($allowlistPin) { $allowlistPin.Dispose() }
  if ($iconPin) { $iconPin.Dispose() }
  if ($setupPin) { $setupPin.Dispose() }
  if ($finalSetupPin) { $finalSetupPin.Dispose() }
  if (-not $swapped -and (Test-Path -LiteralPath $OldRelease) -and -not (Test-Path -LiteralPath $ReleaseRoot)) {
    [IO.Directory]::Move($OldRelease, $ReleaseRoot)
  }
  if (Test-Path -LiteralPath $FailedRelease) { Remove-Item -LiteralPath $FailedRelease -Recurse -Force }
  if (Test-Path -LiteralPath $TemporaryRoot) { Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force }
  if (Test-Path -LiteralPath $SnapshotTemporaryRoot) {
    Remove-Item -LiteralPath $SnapshotTemporaryRoot -Recurse -Force
  }
}
