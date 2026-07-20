$script:DreamSkinUtf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$script:DreamSkinLegacyAppearanceTheme = 'appearanceTheme = "light"'
$script:DreamSkinManagedLightCodeTheme = 'appearanceLightCodeThemeId = "codex"'
$script:DreamSkinManagedLightChromeTheme = 'appearanceLightChromeTheme = { accent = "#B65CFF", contrast = 64, fonts = { code = "Cascadia Code", ui = "Microsoft YaHei UI" }, ink = "#4A235F", opaqueWindows = true, semanticColors = { diffAdded = "#BCE8CF", diffRemoved = "#F7B8CE", skill = "#C47BFF" }, surface = "#FFF4FA" }'

function Assert-DreamSkinNoReparseComponents {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  $current = $fullPath
  while ($true) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Managed Dream Skin path contains a junction or symbolic link: $current"
      }
    }
    $currentNormalized = $current.TrimEnd('\')
    $rootNormalized = $root.TrimEnd('\')
    if ($currentNormalized.Equals($rootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [System.IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $current = $parent
  }
}

if (-not ('DreamSkinConfigNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class DreamSkinNativePathSnapshot
{
    public string Identity { get; set; }
    public string ResolvedPath { get; set; }
    public byte[] Bytes { get; set; }
}

public static class DreamSkinConfigNative
{
    private const uint GENERIC_READ = 0x80000000;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle handle,
        StringBuilder path,
        uint pathLength,
        uint flags);

    public static DreamSkinNativePathSnapshot Snapshot(string path, bool readBytes)
    {
        uint access = readBytes ? GENERIC_READ : FILE_READ_ATTRIBUTES;
        uint flags = FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS;
        using (SafeFileHandle handle = CreateFileW(
            path,
            access,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero,
            OPEN_EXISTING,
            flags,
            IntPtr.Zero))
        {
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not open a stable Dream Skin path handle: " + path,
                    new Win32Exception(error));
            }

            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not inspect a stable Dream Skin path handle: " + path,
                    new Win32Exception(error));
            }
            if ((information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            {
                throw new IOException("Managed Dream Skin path contains a junction or symbolic link: " + path);
            }

            StringBuilder resolved = new StringBuilder(512);
            uint resolvedLength = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
            if (resolvedLength == 0)
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not resolve a stable Dream Skin path handle: " + path,
                    new Win32Exception(error));
            }
            if (resolvedLength >= resolved.Capacity)
            {
                resolved = new StringBuilder((int)resolvedLength + 1);
                resolvedLength = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
                if (resolvedLength == 0 || resolvedLength >= resolved.Capacity)
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new IOException("Could not resolve a stable Dream Skin path handle: " + path,
                        new Win32Exception(error));
                }
            }

            byte[] bytes = null;
            if (readBytes)
            {
                using (FileStream stream = new FileStream(handle, FileAccess.Read))
                {
                    if (stream.Length > Int32.MaxValue)
                    {
                        throw new IOException("Dream Skin config file is too large to read safely: " + path);
                    }
                    bytes = new byte[(int)stream.Length];
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        int count = stream.Read(bytes, offset, bytes.Length - offset);
                        if (count == 0) throw new EndOfStreamException("Config changed while being read: " + path);
                        offset += count;
                    }
                }
            }

            return new DreamSkinNativePathSnapshot
            {
                Identity = information.VolumeSerialNumber.ToString("X8") + ":" +
                    information.FileIndexHigh.ToString("X8") + ":" + information.FileIndexLow.ToString("X8"),
                ResolvedPath = resolved.ToString(),
                Bytes = bytes
            };
        }
    }
}
'@
}

function ConvertTo-DreamSkinComparablePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  $value = $Path
  if ($value.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $value = '\\' + $value.Substring(8)
  } elseif ($value.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) {
    $value = $value.Substring(4)
  }
  $fullPath = [System.IO.Path]::GetFullPath($value)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  if ($fullPath.Length -gt $root.Length) { $fullPath = $fullPath.TrimEnd('\') }
  return $fullPath
}

function Get-DreamSkinStablePathComponentSnapshots {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $root = [System.IO.Path]::GetPathRoot($fullPath)
  $paths = [System.Collections.Generic.List[string]]::new()
  $current = $fullPath
  while ($true) {
    $paths.Insert(0, $current)
    if ($current.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [System.IO.Path]::GetDirectoryName($current)
    if (-not $parent -or $parent.Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) { break }
    $current = $parent
  }

  $snapshots = @()
  foreach ($component in $paths) {
    if (-not (Test-Path -LiteralPath $component)) { continue }
    $native = [DreamSkinConfigNative]::Snapshot($component, $false)
    $resolved = ConvertTo-DreamSkinComparablePath -Path $native.ResolvedPath
    $expected = ConvertTo-DreamSkinComparablePath -Path $component
    if (-not $resolved.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Managed Dream Skin path resolves outside its trusted structure: $component"
    }
    $snapshots += [pscustomobject]@{
      Path = $expected
      Identity = $native.Identity
    }
  }
  return @($snapshots)
}

function Get-DreamSkinStableFileSnapshotCore {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AllowMissing
  )
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  Assert-DreamSkinNoReparseComponents -Path $fullPath
  $exists = Test-Path -LiteralPath $fullPath
  if (-not $exists -and -not $AllowMissing) { throw "File not found: $fullPath" }
  if ($exists -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "Dream Skin config path is not a regular file: $fullPath"
  }

  $native = if ($exists) { [DreamSkinConfigNative]::Snapshot($fullPath, $true) } else { $null }
  if ($null -ne $native) {
    $resolved = ConvertTo-DreamSkinComparablePath -Path $native.ResolvedPath
    $expected = ConvertTo-DreamSkinComparablePath -Path $fullPath
    if (-not $resolved.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Dream Skin config path resolves outside its trusted structure: $fullPath"
    }
  }
  return [pscustomobject]@{
    FullPath = $fullPath
    Exists = $exists
    Bytes = if ($null -ne $native) { [byte[]]$native.Bytes } else { $null }
    Identity = if ($null -ne $native) { $native.Identity } else { $null }
    Components = @(Get-DreamSkinStablePathComponentSnapshots -Path $fullPath)
  }
}

function Assert-DreamSkinStableFileSnapshotUnchanged {
  param([Parameter(Mandatory = $true)]$Snapshot)
  $current = Get-DreamSkinStableFileSnapshotCore -Path $Snapshot.FullPath -AllowMissing
  if ([bool]$current.Exists -ne [bool]$Snapshot.Exists) {
    throw "File identity changed during the operation; retry: $($Snapshot.FullPath)"
  }
  if ($current.Exists -and ($current.Identity -cne $Snapshot.Identity -or
      -not (Test-DreamSkinBytesEqual -Left $Snapshot.Bytes -Right $current.Bytes))) {
    throw "File identity changed during the operation; retry without other writers: $($Snapshot.FullPath)"
  }
  $expectedComponents = @($Snapshot.Components)
  $currentComponents = @($current.Components)
  if ($expectedComponents.Count -ne $currentComponents.Count) {
    throw "Path identity changed during the operation; retry: $($Snapshot.FullPath)"
  }
  for ($index = 0; $index -lt $expectedComponents.Count; $index++) {
    if (-not $expectedComponents[$index].Path.Equals(
        $currentComponents[$index].Path, [System.StringComparison]::OrdinalIgnoreCase) -or
      $expectedComponents[$index].Identity -cne $currentComponents[$index].Identity) {
      throw "Path identity changed during the operation; retry: $($Snapshot.FullPath)"
    }
  }
}

function Get-DreamSkinStableFileSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$AllowMissing
  )
  $snapshot = Get-DreamSkinStableFileSnapshotCore -Path $Path -AllowMissing:$AllowMissing
  Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $snapshot
  return $snapshot
}

function ConvertFrom-DreamSkinUtf8Bytes {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][string]$Path
  )

  try {
    $offset = if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { 3 } else { 0 }
    $content = $script:DreamSkinUtf8NoBom.GetString($Bytes, $offset, $Bytes.Length - $offset)
    if ($content.IndexOf([char]0) -ge 0) {
      throw "Refusing to rewrite a config file containing NUL characters (possibly BOM-less UTF-16): $Path"
    }
    return $content
  } catch [System.Text.DecoderFallbackException] {
    throw "Refusing to rewrite a config file that is not valid UTF-8: $Path"
  }
}

function Test-DreamSkinBytesEqual {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Left,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Right
  )
  if ($Left.Length -ne $Right.Length) { return $false }
  for ($index = 0; $index -lt $Left.Length; $index++) {
    if ($Left[$index] -ne $Right[$index]) { return $false }
  }
  return $true
}

function Assert-DreamSkinFileUnchanged {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [AllowNull()][byte[]]$ExpectedBytes
  )
  if ($null -eq $ExpectedBytes) {
    if (Test-Path -LiteralPath $Path) { throw "File changed during the operation; retry without other writers: $Path" }
    return
  }
  if (-not (Test-Path -LiteralPath $Path)) { throw "File disappeared during the operation; retry: $Path" }
  $currentBytes = [System.IO.File]::ReadAllBytes($Path)
  if (-not (Test-DreamSkinBytesEqual -Left $ExpectedBytes -Right $currentBytes)) {
    throw "File changed during the operation; retry without other writers: $Path"
  }
}

function Get-DreamSkinNewLine {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)
  if ($Content.Contains("`r`n")) { return "`r`n" }
  return "`n"
}

function Read-DreamSkinUtf8File {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return (ConvertFrom-DreamSkinUtf8Bytes -Bytes $bytes -Path $Path)
}

function Write-DreamSkinUtf8FileAtomically {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Content,

    [AllowNull()]
    [byte[]]$ExpectedBytes,

    [AllowNull()]
    $ExpectedSnapshot
  )

  $bytes = $script:DreamSkinUtf8NoBom.GetBytes($Content)
  $writeArguments = @{ Path = $Path; Bytes = $bytes }
  if ($PSBoundParameters.ContainsKey('ExpectedBytes')) { $writeArguments.ExpectedBytes = $ExpectedBytes }
  if ($PSBoundParameters.ContainsKey('ExpectedSnapshot')) { $writeArguments.ExpectedSnapshot = $ExpectedSnapshot }
  Write-DreamSkinBytesAtomically @writeArguments
}

function Write-DreamSkinBytesAtomically {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
    [AllowNull()][byte[]]$ExpectedBytes,
    [AllowNull()]$ExpectedSnapshot
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if ($PSBoundParameters.ContainsKey('ExpectedSnapshot')) {
    if ($null -eq $ExpectedSnapshot -or
      -not $fullPath.Equals($ExpectedSnapshot.FullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Stable file snapshot does not match the requested path: $fullPath"
    }
    Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $ExpectedSnapshot
  }
  $directory = [System.IO.Path]::GetDirectoryName($fullPath)
  if (-not [System.IO.Directory]::Exists($directory)) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
  }
  $fileName = [System.IO.Path]::GetFileName($fullPath)
  $temporary = Join-Path $directory ".$fileName.$PID.$([guid]::NewGuid().ToString('N')).tmp"

  try {
    [System.IO.File]::WriteAllBytes($temporary, $Bytes)
    if ($PSBoundParameters.ContainsKey('ExpectedSnapshot')) {
      Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $ExpectedSnapshot
    } elseif ($PSBoundParameters.ContainsKey('ExpectedBytes')) {
      Assert-DreamSkinFileUnchanged -Path $fullPath -ExpectedBytes $ExpectedBytes
    }
    if ([System.IO.File]::Exists($fullPath)) {
      [System.IO.File]::Replace($temporary, $fullPath, $null)
    } else {
      [System.IO.File]::Move($temporary, $fullPath)
    }
  } finally {
    if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
  }
}

function Get-DreamSkinTomlKeyTokenPattern {
  param([Parameter(Mandatory = $true)][string]$Key)
  $bare = [regex]::Escape($Key)
  $doubleQuoted = [regex]::Escape('"' + $Key + '"')
  $singleQuoted = [regex]::Escape("'" + $Key + "'")
  return "(?:$bare|$doubleQuoted|$singleQuoted)"
}

function ConvertTo-DreamSkinTomlAsciiEscapeProbe {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

  $result = $Value
  $characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-'.ToCharArray()
  foreach ($character in $characters) {
    $code = ([int][char]$character).ToString('x2')
    $pattern = '(?i)\\(?:u00' + $code + '|U000000' + $code + ')'
    $result = [regex]::Replace($result, $pattern, [string]$character)
  }
  return $result
}

function Get-DreamSkinTomlArrayBracketBalance {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)

  $quote = $null
  $escaped = $false
  $balance = 0
  for ($index = 0; $index -lt $Line.Length; $index++) {
    $character = $Line[$index]
    if ($null -eq $quote) {
      if ($character -eq '#') { break }
      if ($character -eq '"' -or $character -eq "'") { $quote = $character }
      elseif ($character -eq '[') { $balance++ }
      elseif ($character -eq ']') { $balance-- }
      continue
    }
    if ($quote -eq '"') {
      if ($escaped) { $escaped = $false; continue }
      if ($character -eq '\') { $escaped = $true; continue }
    }
    if ($character -eq $quote) { $quote = $null }
  }
  return $balance
}

function Assert-DreamSkinTomlLineEditingSafe {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

  if ($Content.Contains('"""') -or $Content.Contains("'''")) {
    throw 'Refusing to rewrite TOML containing multiline strings; use single-line values before installing Dream Skin.'
  }
  foreach ($match in [regex]::Matches($Content, '(?m)^[^\r\n]*=[\t ]*\[[^\r\n]*$')) {
    if ((Get-DreamSkinTomlArrayBracketBalance -Line $match.Value) -ne 0) {
      throw 'Refusing to rewrite TOML containing multiline arrays; use single-line arrays before installing Dream Skin.'
    }
  }

  $probe = ConvertTo-DreamSkinTomlAsciiEscapeProbe -Value $Content
  if ($probe -cne $Content) {
    $desktopToken = Get-DreamSkinTomlKeyTokenPattern -Key 'desktop'
    $desktopShape = "(?m)^[\t ]*(?:\[\[?[\t ]*$desktopToken[\t ]*(?:\]|\.)|$desktopToken[\t ]*(?:\.|=))"
    $rawDesktopShapes = [regex]::Matches($Content, $desktopShape).Count
    $probedDesktopShapes = [regex]::Matches($probe, $desktopShape).Count
    if ($probedDesktopShapes -gt $rawDesktopShapes) {
      throw 'Refusing to rewrite an escaped TOML key equivalent to desktop; normalize the key spelling first.'
    }
  }
}

function Get-DreamSkinDesktopSectionPattern {
  $desktopToken = Get-DreamSkinTomlKeyTokenPattern -Key 'desktop'
  return "(?ms)^[\t ]*\[[\t ]*$desktopToken[\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|(?=\z))(?<body>.*?)(?=^[\t ]*\[\[?|\z)"
}

function Assert-DreamSkinDesktopShapeSupported {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

  Assert-DreamSkinTomlLineEditingSafe -Content $Content
  $sectionPattern = Get-DreamSkinDesktopSectionPattern
  if ([regex]::Matches($Content, $sectionPattern).Count -gt 1) {
    throw 'Refusing to rewrite multiple equivalent [desktop] tables.'
  }

  $desktopToken = Get-DreamSkinTomlKeyTokenPattern -Key 'desktop'
  if ([regex]::IsMatch($Content, "(?m)^[\t ]*\[\[[\t ]*$desktopToken[\t ]*\]\]")) {
    throw 'Refusing to rewrite a config that represents desktop as an array of tables.'
  }
  if ([regex]::IsMatch($Content, "(?m)^[\t ]*\[\[?[\t ]*$desktopToken[\t ]*\.")) {
    throw 'Refusing to rewrite nested desktop tables; normalize them to a single [desktop] table first.'
  }

  $firstTable = [regex]::Match($Content, '(?m)^[\t ]*\[\[?')
  $rootContent = if ($firstTable.Success) { $Content.Substring(0, $firstTable.Index) } else { $Content }
  if ([regex]::IsMatch($rootContent, "(?m)^[\t ]*$desktopToken[\t ]*(?:\.|=)")) {
    throw 'Refusing to rewrite root dotted or inline desktop keys; normalize them to a [desktop] table first.'
  }

  $desktop = Get-DreamSkinDesktopSection -Content $Content
  if ($null -ne $desktop) {
    $bodyProbe = ConvertTo-DreamSkinTomlAsciiEscapeProbe -Value $desktop.Body
    foreach ($key in @('appearanceTheme', 'appearanceLightCodeThemeId', 'appearanceLightChromeTheme')) {
      $keyToken = Get-DreamSkinTomlKeyTokenPattern -Key $key
      $settingShape = "(?m)^[\t ]*$keyToken[\t ]*(?:\.|=)"
      if ([regex]::Matches($bodyProbe, $settingShape).Count -gt
        [regex]::Matches($desktop.Body, $settingShape).Count) {
        throw "Refusing to rewrite an escaped TOML key equivalent to '$key'."
      }
      if ([regex]::IsMatch($desktop.Body, "(?m)^[\t ]*$keyToken[\t ]*\.")) {
        throw "Refusing to replace dotted '$key' keys in the [desktop] table."
      }
    }
  }
}

function Get-DreamSkinDesktopSection {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

  $match = [regex]::Match($Content, (Get-DreamSkinDesktopSectionPattern))
  if (-not $match.Success) { return $null }
  return [pscustomobject]@{
    Body = $match.Groups['body'].Value
    BodyStart = $match.Groups['body'].Index
    BodyLength = $match.Groups['body'].Length
    SectionStart = $match.Index
    SectionLength = $match.Length
  }
}

function Add-DreamSkinDesktopSection {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
    [Parameter(Mandatory = $true)][string]$NewLine
  )

  if ($Content.Length -eq 0) { return "[desktop]$NewLine" }
  $separator = if ($Content.EndsWith("`n")) { $NewLine } else { $NewLine + $NewLine }
  return $Content + $separator + "[desktop]$NewLine"
}

function Set-DreamSkinSectionSetting {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][string]$Line,
    [Parameter(Mandatory = $true)][string]$NewLine
  )

  $keyToken = Get-DreamSkinTomlKeyTokenPattern -Key $Key
  $pattern = "(?m)^[\t ]*$keyToken[\t ]*=.*(?:\r?\n)?"
  $matcher = [regex]::new($pattern)
  if ($matcher.Matches($Body).Count -gt 1) {
    throw "Refusing to rewrite duplicate '$Key' entries in the [desktop] section."
  }
  if ($null -eq $Line) { return $matcher.Replace($Body, '', 1) }
  $normalizedLine = $Line.TrimEnd("`r", "`n") + $NewLine
  if ($matcher.IsMatch($Body)) {
    $literalReplacement = $normalizedLine.Replace('$', '$$')
    return $matcher.Replace($Body, $literalReplacement, 1)
  }
  $separator = if ($Body.Length -eq 0 -or $Body.EndsWith("`n")) { '' } else { $NewLine }
  return $Body + $separator + $normalizedLine
}

function Get-DreamSkinSectionSettingLine {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body,
    [Parameter(Mandatory = $true)][string]$Key
  )
  $keyToken = Get-DreamSkinTomlKeyTokenPattern -Key $Key
  $matches = [regex]::Matches($Body, "(?m)^[\t ]*$keyToken[\t ]*=.*$")
  if ($matches.Count -gt 1) { throw "Refusing to inspect duplicate '$Key' entries in the [desktop] section." }
  if ($matches.Count -eq 0) { return $null }
  return $matches[0].Value.Trim()
}

function Test-DreamSkinLegacyManagedLightTrio {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)
  $desktop = Get-DreamSkinDesktopSection -Content $Content
  if ($null -eq $desktop) { return $false }
  return (
    (Get-DreamSkinSectionSettingLine -Body $desktop.Body -Key 'appearanceTheme') -ceq
      $script:DreamSkinLegacyAppearanceTheme -and
    (Get-DreamSkinSectionSettingLine -Body $desktop.Body -Key 'appearanceLightCodeThemeId') -ceq
      $script:DreamSkinManagedLightCodeTheme -and
    (Get-DreamSkinSectionSettingLine -Body $desktop.Body -Key 'appearanceLightChromeTheme') -ceq
      $script:DreamSkinManagedLightChromeTheme
  )
}

function Test-DreamSkinBaseThemeManaged {
  param([Parameter(Mandatory = $true)][string]$ConfigPath)
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $false }
  $configSnapshot = Get-DreamSkinStableFileSnapshot -Path $ConfigPath
  $content = ConvertFrom-DreamSkinUtf8Bytes -Bytes $configSnapshot.Bytes -Path $ConfigPath
  Assert-DreamSkinDesktopShapeSupported -Content $content
  $desktop = Get-DreamSkinDesktopSection -Content $content
  if ($null -eq $desktop) { return $false }
  return (
    (Get-DreamSkinSectionSettingLine -Body $desktop.Body -Key 'appearanceLightCodeThemeId') -ceq
      $script:DreamSkinManagedLightCodeTheme -or
    (Get-DreamSkinSectionSettingLine -Body $desktop.Body -Key 'appearanceLightChromeTheme') -ceq
      $script:DreamSkinManagedLightChromeTheme
  )
}

function Get-DreamSkinAppearanceMarkerPath {
  param([Parameter(Mandatory = $true)][string]$BackupPath)
  return "$BackupPath.appearance.json"
}

function Read-DreamSkinAppearanceMarker {
  param([Parameter(Mandatory = $true)][string]$BackupPath)
  $markerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath
  if (-not (Test-Path -LiteralPath $markerPath)) { return $null }
  try {
    $marker = (Read-DreamSkinUtf8File -Path $markerPath) | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Dream Skin appearance marker is unreadable; config was preserved: $markerPath"
  }
  if ($null -eq $marker -or $marker -is [string] -or $marker -is [array] -or
    [int]$marker.schemaVersion -ne 1 -or $marker.appearanceThemeManaged -isnot [bool] -or
    [bool]$marker.appearanceThemeManaged) {
    throw "Dream Skin appearance marker is invalid; config was preserved: $markerPath"
  }
  return $marker
}

function Write-DreamSkinAppearanceMarker {
  param([Parameter(Mandatory = $true)][string]$BackupPath)
  $markerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $markerPath
  }
  $marker = [ordered]@{
    schemaVersion = 1
    appearanceThemeManaged = $false
  } | ConvertTo-Json
  Write-DreamSkinUtf8FileAtomically -Path $markerPath -Content ($marker + "`r`n")
}

function Test-DreamSkinLiveConfigBackup {
  param([Parameter(Mandatory = $true)][string]$BackupPath)

  $markerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $BackupPath
    Assert-DreamSkinNoReparseComponents -Path $markerPath
  }
  if (-not (Test-Path -LiteralPath $BackupPath)) { return $false }
  if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
    throw "Dream Skin config backup is not a safe file: $BackupPath"
  }
  if ((Test-Path -LiteralPath $markerPath) -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "Dream Skin appearance marker is not a safe file: $markerPath"
  }

  $content = Read-DreamSkinUtf8File -Path $BackupPath
  Assert-DreamSkinDesktopShapeSupported -Content $content
  $null = Read-DreamSkinAppearanceMarker -BackupPath $BackupPath
  return $true
}

function Test-DreamSkinConfigCompletionEvidence {
  param([Parameter(Mandatory = $true)][string]$ArchivePath)
  $markerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $ArchivePath
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $ArchivePath
    Assert-DreamSkinNoReparseComponents -Path $markerPath
  }
  if (-not (Test-Path -LiteralPath $ArchivePath)) {
    if (Test-Path -LiteralPath $markerPath) {
      throw "Dream Skin completion evidence marker exists without its archive: $markerPath"
    }
    return $false
  }
  if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "Dream Skin completion evidence is not a safe file: $ArchivePath"
  }
  if ((Test-Path -LiteralPath $markerPath) -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw "Dream Skin completion evidence marker is not a safe file: $markerPath"
  }
  $content = Read-DreamSkinUtf8File -Path $ArchivePath
  Assert-DreamSkinDesktopShapeSupported -Content $content
  $null = Read-DreamSkinAppearanceMarker -BackupPath $ArchivePath
  return $true
}

function Test-DreamSkinRestoreCompleted {
  param(
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [Parameter(Mandatory = $true)][bool]$CompletionEvidence,
    [string]$BackupPath = (Join-Path $StateRoot 'config.before-dream-skin.toml')
  )

  $paths = @(
    $BackupPath,
    (Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath),
    (Join-Path $StateRoot 'state.json'),
    (Join-Path $StateRoot 'paused')
  )
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $StateRoot
    foreach ($path in $paths) { Assert-DreamSkinNoReparseComponents -Path $path }
  }
  if (-not $CompletionEvidence) { return $false }
  return @($paths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
}

function Remove-DreamSkinConfigCompletionEvidence {
  param([Parameter(Mandatory = $true)][string]$ArchivePath)
  $paths = @((Get-DreamSkinAppearanceMarkerPath -BackupPath $ArchivePath), $ArchivePath)
  foreach ($path in $paths) {
    if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
      Assert-DreamSkinNoReparseComponents -Path $path
    }
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Dream Skin completion evidence is not a safe file: $path"
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $path) { throw "Dream Skin completion evidence could not be removed: $path" }
  }
}

function Install-DreamSkinBaseTheme {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$BackupPath
  )

  $configSnapshot = Get-DreamSkinStableFileSnapshot -Path $ConfigPath
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $BackupPath
    Assert-DreamSkinNoReparseComponents -Path (Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath)
  }
  $originalBytes = $configSnapshot.Bytes
  $content = ConvertFrom-DreamSkinUtf8Bytes -Bytes $originalBytes -Path $ConfigPath
  $liveBackup = Test-DreamSkinLiveConfigBackup -BackupPath $BackupPath
  if (-not $liveBackup -and (Test-DreamSkinBaseThemeManaged -ConfigPath $ConfigPath)) {
    $stateRoot = Split-Path -Parent $BackupPath
    $archivePath = Join-Path $stateRoot 'config.restored.toml'
    $completionEvidence = Test-DreamSkinConfigCompletionEvidence -ArchivePath $archivePath
    if (-not (Test-DreamSkinRestoreCompleted -StateRoot $stateRoot `
      -CompletionEvidence $completionEvidence -BackupPath $BackupPath)) {
      throw 'Dream Skin managed settings exist without a recoverable baseline; config was preserved.'
    }
  }
  $appearanceMarker = Read-DreamSkinAppearanceMarker -BackupPath $BackupPath
  Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot
  $backupCreated = $false
  if (-not $liveBackup) {
    Write-DreamSkinBytesAtomically -Path $BackupPath -Bytes $originalBytes -ExpectedBytes $null
    $backupCreated = $true
  }

  $configCommitted = $false
  $retainBackupOnFailure = $false
  try {
    Assert-DreamSkinDesktopShapeSupported -Content $content
    $newLine = Get-DreamSkinNewLine -Content $content
    $desktop = Get-DreamSkinDesktopSection -Content $content
    if ($null -eq $desktop) {
      $content = Add-DreamSkinDesktopSection -Content $content -NewLine $newLine
      $desktop = Get-DreamSkinDesktopSection -Content $content
    }

    $body = $desktop.Body
    $backupContent = $null
    $legacyMigration = $null -eq $appearanceMarker -and (Test-Path -LiteralPath $BackupPath) -and
      (Test-DreamSkinLegacyManagedLightTrio -Content $content)
    if ($legacyMigration) {
      $backupContent = ConvertFrom-DreamSkinUtf8Bytes -Bytes ([System.IO.File]::ReadAllBytes($BackupPath)) -Path $BackupPath
      Assert-DreamSkinDesktopShapeSupported -Content $backupContent
      $backupDesktop = Get-DreamSkinDesktopSection -Content $backupContent
      $savedAppearance = if ($null -ne $backupDesktop) {
        Get-DreamSkinSectionSettingLine -Body $backupDesktop.Body -Key 'appearanceTheme'
      } else { $null }
      $body = Set-DreamSkinSectionSetting -Body $body -Key 'appearanceTheme' -Line $savedAppearance -NewLine $newLine
    }
    $settings = [ordered]@{
      appearanceLightCodeThemeId = $script:DreamSkinManagedLightCodeTheme
      appearanceLightChromeTheme = $script:DreamSkinManagedLightChromeTheme
    }
    foreach ($key in $settings.Keys) {
      $body = Set-DreamSkinSectionSetting -Body $body -Key $key -Line $settings[$key] -NewLine $newLine
    }

    $content = $content.Substring(0, $desktop.BodyStart) + $body +
      $content.Substring($desktop.BodyStart + $desktop.BodyLength)
    $retainBackupOnFailure = $true
    Remove-DreamSkinConfigCompletionEvidence -ArchivePath (Join-Path (Split-Path -Parent $BackupPath) 'config.restored.toml')
    Write-DreamSkinUtf8FileAtomically -Path $ConfigPath -Content $content -ExpectedBytes $originalBytes `
      -ExpectedSnapshot $configSnapshot
    $configCommitted = $true
    Write-DreamSkinAppearanceMarker -BackupPath $BackupPath
  } catch {
    if ($backupCreated -and -not $configCommitted -and -not $retainBackupOnFailure) {
      Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

function Restore-DreamSkinBaseTheme {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$BackupPath
  )

  if (-not (Test-Path -LiteralPath $BackupPath)) { throw 'No pre-install config backup is available.' }
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $BackupPath
    Assert-DreamSkinNoReparseComponents -Path (Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath)
  }
  $backupBytes = [System.IO.File]::ReadAllBytes($BackupPath)
  $backupContent = ConvertFrom-DreamSkinUtf8Bytes -Bytes $backupBytes -Path $BackupPath
  $configSnapshot = Get-DreamSkinStableFileSnapshot -Path $ConfigPath
  $currentBytes = $configSnapshot.Bytes
  $currentContent = ConvertFrom-DreamSkinUtf8Bytes -Bytes $currentBytes -Path $ConfigPath
  Assert-DreamSkinDesktopShapeSupported -Content $backupContent
  Assert-DreamSkinDesktopShapeSupported -Content $currentContent
  $newLine = Get-DreamSkinNewLine -Content $currentContent
  $backupDesktop = Get-DreamSkinDesktopSection -Content $backupContent
  $currentDesktop = Get-DreamSkinDesktopSection -Content $currentContent
  if ($null -eq $currentDesktop) {
    $currentContent = Add-DreamSkinDesktopSection -Content $currentContent -NewLine $newLine
    $currentDesktop = Get-DreamSkinDesktopSection -Content $currentContent
  }

  $body = $currentDesktop.Body
  $appearanceMarker = Read-DreamSkinAppearanceMarker -BackupPath $BackupPath
  $restoreLegacyAppearance = $null -eq $appearanceMarker -and
    (Test-DreamSkinLegacyManagedLightTrio -Content $currentContent)
  $restoreKeys = @('appearanceLightCodeThemeId', 'appearanceLightChromeTheme')
  if ($restoreLegacyAppearance) { $restoreKeys = @('appearanceTheme') + $restoreKeys }
  foreach ($key in $restoreKeys) {
    $keyToken = Get-DreamSkinTomlKeyTokenPattern -Key $key
    $pattern = "(?m)^[\t ]*$keyToken[\t ]*=.*(?:\r?\n)?"
    $saved = if ($null -ne $backupDesktop) { [regex]::Match($backupDesktop.Body, $pattern) } else { $null }
    $line = if ($null -ne $saved -and $saved.Success) { $saved.Value } else { $null }
    $body = Set-DreamSkinSectionSetting -Body $body -Key $key -Line $line -NewLine $newLine
  }
  if ($null -eq $backupDesktop -and [string]::IsNullOrWhiteSpace($body)) {
    $currentContent = $currentContent.Remove($currentDesktop.SectionStart, $currentDesktop.SectionLength)
  } else {
    $currentContent = $currentContent.Substring(0, $currentDesktop.BodyStart) + $body +
      $currentContent.Substring($currentDesktop.BodyStart + $currentDesktop.BodyLength)
  }
  Write-DreamSkinUtf8FileAtomically -Path $ConfigPath -Content $currentContent -ExpectedBytes $currentBytes `
    -ExpectedSnapshot $configSnapshot
}

function Restore-DreamSkinConfigBackup {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string]$RecoveryBackupPath
  )

  if (-not (Test-Path -LiteralPath $BackupPath)) { throw 'No pre-install config backup is available.' }
  Assert-DreamSkinNoReparseComponents -Path $BackupPath
  Assert-DreamSkinNoReparseComponents -Path $RecoveryBackupPath
  $backupBytes = [System.IO.File]::ReadAllBytes($BackupPath)
  $null = ConvertFrom-DreamSkinUtf8Bytes -Bytes $backupBytes -Path $BackupPath
  $configSnapshot = Get-DreamSkinStableFileSnapshot -Path $ConfigPath -AllowMissing
  $currentBytes = $configSnapshot.Bytes
  Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot
  if ($configSnapshot.Exists) {
    Write-DreamSkinBytesAtomically -Path $RecoveryBackupPath -Bytes $currentBytes -ExpectedBytes $null
  }

  Write-DreamSkinBytesAtomically -Path $ConfigPath -Bytes $backupBytes -ExpectedBytes $currentBytes `
    -ExpectedSnapshot $configSnapshot
}

function Publish-DreamSkinConfigBackupArchive {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [Parameter(Mandatory = $true)][string]$ArchivePath
  )

  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $BackupPath
    Assert-DreamSkinNoReparseComponents -Path $ArchivePath
  }
  if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
    throw 'No pre-install config backup is available.'
  }
  $backupMarkerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $BackupPath
  $archiveMarkerPath = Get-DreamSkinAppearanceMarkerPath -BackupPath $ArchivePath
  if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
    Assert-DreamSkinNoReparseComponents -Path $backupMarkerPath
    Assert-DreamSkinNoReparseComponents -Path $archiveMarkerPath
  }
  foreach ($path in @($backupMarkerPath, $archiveMarkerPath, $ArchivePath)) {
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "A Dream Skin config transaction artifact is not a safe file: $path"
    }
  }

  $backupBytes = [IO.File]::ReadAllBytes($BackupPath)
  $archiveBytes = if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
    [IO.File]::ReadAllBytes($ArchivePath)
  } else { $null }
  Write-DreamSkinBytesAtomically -Path $ArchivePath -Bytes $backupBytes -ExpectedBytes $archiveBytes

  $hasMarker = Test-Path -LiteralPath $backupMarkerPath -PathType Leaf
  if ($hasMarker) {
    $markerBytes = [IO.File]::ReadAllBytes($backupMarkerPath)
    $archiveMarkerBytes = if (Test-Path -LiteralPath $archiveMarkerPath -PathType Leaf) {
      [IO.File]::ReadAllBytes($archiveMarkerPath)
    } else { $null }
    Write-DreamSkinBytesAtomically -Path $archiveMarkerPath -Bytes $markerBytes -ExpectedBytes $archiveMarkerBytes
  } elseif (Test-Path -LiteralPath $archiveMarkerPath) {
    Remove-Item -LiteralPath $archiveMarkerPath -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $archiveMarkerPath) {
      throw "Config backup archive marker could not be removed: $archiveMarkerPath"
    }
  }
}
