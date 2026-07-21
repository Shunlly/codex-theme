$script:DreamSkinUtf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$script:DreamSkinLegacyAppearanceTheme = 'appearanceTheme = "light"'
$script:DreamSkinManagedLightCodeTheme = 'appearanceLightCodeThemeId = "codex"'
$script:DreamSkinManagedLightChromeTheme = 'appearanceLightChromeTheme = { accent = "#B65CFF", contrast = 64, fonts = { code = "Cascadia Code", ui = "Microsoft YaHei UI" }, ink = "#4A235F", opaqueWindows = true, semanticColors = { diffAdded = "#BCE8CF", diffRemoved = "#F7B8CE", skill = "#C47BFF" }, surface = "#FFF4FA" }'

function Assert-DreamSkinNoReparseComponents {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [DreamSkinConfigNative]::NormalizePath($Path)
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
using System.Security.Cryptography;
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
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint DELETE = 0x00010000;
    private const uint FILE_TRAVERSE = 0x00000020;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint CREATE_NEW = 1;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
    private const uint ERROR_FILE_NOT_FOUND = 2;
    private const uint ERROR_PATH_NOT_FOUND = 3;
    private const uint FILE_BEGIN = 0;
    private const uint FILE_RENAME_FLAG_REPLACE_IF_EXISTS = 0x00000001;
    private const uint FILE_RENAME_FLAG_POSIX_SEMANTICS = 0x00000002;
    private const uint FILE_DISPOSITION_FLAG_DELETE = 0x00000001;
    private const uint FILE_DISPOSITION_FLAG_POSIX_SEMANTICS = 0x00000002;
    private const uint FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE = 0x00000010;

    private enum FILE_INFO_BY_HANDLE_CLASS
    {
        FileDispositionInfo = 4,
        FileDispositionInfoEx = 21,
        FileRenameInfoEx = 22
    }

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

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteFile(
        SafeFileHandle file,
        byte[] buffer,
        uint bytesToWrite,
        out uint bytesWritten,
        IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadFile(
        SafeFileHandle file,
        byte[] buffer,
        uint bytesToRead,
        out uint bytesRead,
        IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFilePointerEx(
        SafeFileHandle file,
        long distance,
        out long newPosition,
        uint moveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileSizeEx(SafeFileHandle file, out long size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FlushFileBuffers(SafeFileHandle file);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle file,
        FILE_INFO_BY_HANDLE_CLASS informationClass,
        IntPtr information,
        uint bufferSize);

    private static string Identity(BY_HANDLE_FILE_INFORMATION information)
    {
        return information.VolumeSerialNumber.ToString("X8") + ":" +
            information.FileIndexHigh.ToString("X8") + ":" + information.FileIndexLow.ToString("X8");
    }

    private static BY_HANDLE_FILE_INFORMATION Inspect(SafeFileHandle handle, string path)
    {
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
        return information;
    }

    private static string ResolvedPath(SafeFileHandle handle, string path)
    {
        StringBuilder resolved = new StringBuilder(512);
        uint length = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
        if (length >= resolved.Capacity)
        {
            resolved = new StringBuilder((int)length + 1);
            length = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
        }
        if (length == 0 || length >= resolved.Capacity)
        {
            int error = Marshal.GetLastWin32Error();
            throw new IOException("Could not resolve a stable Dream Skin path handle: " + path,
                new Win32Exception(error));
        }
        return resolved.ToString();
    }

    private static string ComparablePath(string path)
    {
        string value = NormalizePath(path);
        return value.Length > 7 ? value.TrimEnd('\\') : value;
    }

    private static string NormalizeAbsolutePath(string path)
    {
        string value = path.Replace('/', '\\');
        string native;
        int componentStart;
        bool unc;
        if (value.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
        {
            native = value;
            componentStart = 8;
            unc = true;
        }
        else if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
        {
            if (value.Length < 7 || value[5] != ':' || value[6] != '\\')
                throw new IOException("Unsupported extended Dream Skin path: " + path);
            native = value;
            componentStart = 7;
            unc = false;
        }
        else if (value.StartsWith(@"\\", StringComparison.OrdinalIgnoreCase))
        {
            native = @"\\?\UNC\" + value.Substring(2);
            componentStart = 8;
            unc = true;
        }
        else if (value.Length >= 3 && value[1] == ':' && value[2] == '\\')
        {
            native = @"\\?\" + value;
            componentStart = 7;
            unc = false;
        }
        else
        {
            return null;
        }
        string[] components = native.Substring(componentStart).Split(
            new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
        if (unc && components.Length < 2)
            throw new IOException("UNC Dream Skin path lacks a server or share: " + path);
        foreach (string component in components)
        {
            if (component == "." || component == "..")
                throw new IOException("Dream Skin path is not normalized: " + path);
            ValidateComponentLength(component);
        }
        return native.Length > componentStart ? native.TrimEnd('\\') : native;
    }

    public static string NormalizePath(string path)
    {
        if (String.IsNullOrEmpty(path)) throw new ArgumentException("Dream Skin path is required.", "path");
        string absolute = NormalizeAbsolutePath(path);
        return absolute ?? NormalizeAbsolutePath(Path.GetFullPath(path));
    }

    private static void ValidateComponentLength(string component)
    {
        if (String.IsNullOrEmpty(component) || component.Length > 255)
            throw new PathTooLongException("Dream Skin path component exceeds the filesystem limit: " + component);
    }

    private static SafeFileHandle OpenStable(string path, uint access, uint shareMode, bool directory)
    {
        uint flags = FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0);
        SafeFileHandle handle = CreateFileW(NormalizePath(path), access,
            shareMode,
            IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new IOException("Could not open a stable Dream Skin path handle: " + path,
                new Win32Exception(error));
        }
        try
        {
            Inspect(handle, path);
            if (!ComparablePath(ResolvedPath(handle, path)).Equals(
                ComparablePath(path), StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Managed Dream Skin path resolves outside its trusted structure: " + path);
            }
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle TryOpenStableFile(string path, uint access, uint shareMode, out bool missing)
    {
        SafeFileHandle handle = CreateFileW(NormalizePath(path), access,
            shareMode,
            IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            missing = error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
            if (missing) return null;
            throw new IOException("Could not open a stable Dream Skin file handle: " + path,
                new Win32Exception(error));
        }
        missing = false;
        try
        {
            Inspect(handle, path);
            if (!ComparablePath(ResolvedPath(handle, path)).Equals(
                ComparablePath(path), StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Managed Dream Skin file resolves outside its trusted structure: " + path);
            }
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static SafeFileHandle TryOpenStableEntry(string path, uint shareMode, out bool missing)
    {
        SafeFileHandle handle = CreateFileW(NormalizePath(path), FILE_READ_ATTRIBUTES,
            shareMode,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            missing = error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
            if (missing) return null;
            throw new IOException("Could not open a stable Dream Skin path handle: " + path,
                new Win32Exception(error));
        }
        missing = false;
        try
        {
            Inspect(handle, path);
            if (!ComparablePath(ResolvedPath(handle, path)).Equals(
                ComparablePath(path), StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("Managed Dream Skin path resolves outside its trusted structure: " + path);
            }
            return handle;
        }
        catch
        {
            handle.Dispose();
            throw;
        }
    }

    private static void WriteAll(SafeFileHandle handle, byte[] bytes, string path)
    {
        int offset = 0;
        while (offset < bytes.Length)
        {
            int remaining = bytes.Length - offset;
            byte[] chunk;
            if (offset == 0)
            {
                chunk = bytes;
            }
            else
            {
                chunk = new byte[remaining];
                Buffer.BlockCopy(bytes, offset, chunk, 0, remaining);
            }
            uint written;
            if (!WriteFile(handle, chunk, (uint)chunk.Length, out written, IntPtr.Zero) || written == 0)
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not write the Dream Skin temporary config: " + path,
                    new Win32Exception(error));
            }
            offset += checked((int)written);
        }
        if (!FlushFileBuffers(handle))
        {
            int error = Marshal.GetLastWin32Error();
            throw new IOException("Could not flush the Dream Skin temporary config: " + path,
                new Win32Exception(error));
        }
    }

    private static byte[] ReadAll(SafeFileHandle handle, string path)
    {
        long length;
        if (!GetFileSizeEx(handle, out length) || length < 0 || length > Int32.MaxValue)
        {
            int error = Marshal.GetLastWin32Error();
            throw new IOException("Could not size the Dream Skin temporary config: " + path,
                new Win32Exception(error));
        }
        long position;
        if (!SetFilePointerEx(handle, 0, out position, FILE_BEGIN))
        {
            int error = Marshal.GetLastWin32Error();
            throw new IOException("Could not rewind the Dream Skin temporary config: " + path,
                new Win32Exception(error));
        }
        byte[] bytes = new byte[(int)length];
        int offset = 0;
        while (offset < bytes.Length)
        {
            byte[] chunk = new byte[bytes.Length - offset];
            uint read;
            if (!ReadFile(handle, chunk, (uint)chunk.Length, out read, IntPtr.Zero) || read == 0)
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not read back the Dream Skin temporary config: " + path,
                    new Win32Exception(error));
            }
            Buffer.BlockCopy(chunk, 0, bytes, offset, checked((int)read));
            offset += checked((int)read);
        }
        return bytes;
    }

    private static byte[] Hash(byte[] bytes)
    {
        using (SHA256 sha256 = SHA256.Create()) return sha256.ComputeHash(bytes);
    }

    private static bool EqualBytes(byte[] left, byte[] right)
    {
        if (left == null || right == null || left.Length != right.Length) return false;
        int difference = 0;
        for (int index = 0; index < left.Length; index++) difference |= left[index] ^ right[index];
        return difference == 0;
    }

    private static void RenameRelative(SafeFileHandle file, SafeFileHandle parent, string fileName, uint flags)
    {
        byte[] name = Encoding.Unicode.GetBytes(fileName);
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = rootOffset + IntPtr.Size;
        int nameOffset = lengthOffset + 4;
        int size = nameOffset + name.Length;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            for (int index = 0; index < size; index++) Marshal.WriteByte(buffer, index, 0);
            Marshal.WriteInt32(buffer, 0, unchecked((int)flags));
            Marshal.WriteIntPtr(buffer, rootOffset, parent.DangerousGetHandle());
            Marshal.WriteInt32(buffer, lengthOffset, name.Length);
            Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
            if (!SetFileInformationByHandle(file, FILE_INFO_BY_HANDLE_CLASS.FileRenameInfoEx,
                buffer, (uint)size))
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not commit the Dream Skin config atomically.",
                    new Win32Exception(error));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static void DeleteByHandle(SafeFileHandle file)
    {
        IntPtr buffer = Marshal.AllocHGlobal(1);
        try
        {
            Marshal.WriteByte(buffer, 0, 1);
            if (!SetFileInformationByHandle(file, FILE_INFO_BY_HANDLE_CLASS.FileDispositionInfo,
                buffer, 1))
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not remove the Dream Skin temporary config.",
                    new Win32Exception(error));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static void DeleteByHandlePosix(SafeFileHandle file, string path)
    {
        IntPtr buffer = Marshal.AllocHGlobal(4);
        try
        {
            Marshal.WriteInt32(buffer, unchecked((int)(FILE_DISPOSITION_FLAG_DELETE |
                FILE_DISPOSITION_FLAG_POSIX_SEMANTICS | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE)));
            if (!SetFileInformationByHandle(file, FILE_INFO_BY_HANDLE_CLASS.FileDispositionInfoEx,
                buffer, 4))
            {
                int error = Marshal.GetLastWin32Error();
                throw new IOException("Could not remove expected Dream Skin completion evidence: " + path,
                    new Win32Exception(error));
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public sealed class AtomicWriteTransaction : IDisposable
    {
        private readonly string path;
        private readonly string parentPath;
        private readonly string fileName;
        private readonly string candidateName;
        private readonly string temporaryName;
        private readonly string parentIdentity;
        private readonly string targetIdentity;
        private readonly bool targetExisted;
        private readonly int expectedLength;
        private readonly byte[] expectedHash;
        private SafeFileHandle parent;
        private SafeFileHandle target;
        private SafeFileHandle temporary;
        private bool temporaryAtCandidatePath;
        private bool temporaryAtInternalName;
        private bool temporaryAtTarget;
        private bool committed;
        private bool disposed;

        public bool RollbackConfirmed { get; private set; }

        internal AtomicWriteTransaction(string requestedPath, byte[] bytes)
        {
            path = NormalizePath(requestedPath);
            parentPath = Path.GetDirectoryName(path);
            fileName = Path.GetFileName(path);
            ValidateComponentLength(fileName);
            string nonce = Guid.NewGuid().ToString("N");
            candidateName = "." + nonce + ".candidate";
            temporaryName = "." + nonce + ".tmp";
            ValidateComponentLength(candidateName);
            ValidateComponentLength(temporaryName);
            expectedLength = bytes.Length;
            expectedHash = Hash(bytes);
            parentIdentity = null;
            targetIdentity = null;
            targetExisted = false;
            try
            {
                parent = OpenStable(parentPath, FILE_TRAVERSE | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, true);
                parentIdentity = Identity(Inspect(parent, parentPath));

                bool missing;
                target = TryOpenStableFile(path, FILE_READ_ATTRIBUTES | DELETE,
                    FILE_SHARE_READ, out missing);
                targetExisted = !missing;
                targetIdentity = targetExisted ? Identity(Inspect(target, path)) : null;

                string candidatePath = Path.Combine(parentPath, candidateName);
                temporary = CreateFileW(NormalizePath(candidatePath),
                    GENERIC_READ | GENERIC_WRITE | FILE_READ_ATTRIBUTES | DELETE,
                    FILE_SHARE_READ,
                    IntPtr.Zero, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
                if (temporary.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    temporary.Dispose();
                    temporary = null;
                    throw new IOException("Could not create the Dream Skin temporary config: " + candidatePath,
                        new Win32Exception(error));
                }
                temporaryAtCandidatePath = true;
                Inspect(temporary, candidatePath);
                RenameRelative(temporary, parent, temporaryName, 0);
                temporaryAtCandidatePath = false;
                temporaryAtInternalName = true;
                WriteAll(temporary, bytes, temporaryName);
                VerifyTemporaryContent();
                AssertUnchanged();
                RollbackConfirmed = true;
            }
            catch (Exception error)
            {
                try { Dispose(); }
                catch (Exception cleanupError)
                {
                    throw new IOException("Atomic write preparation and cleanup both failed.",
                        new AggregateException(error, cleanupError));
                }
                throw;
            }
        }

        private void AssertParentUnchanged()
        {
            using (SafeFileHandle currentParent = OpenStable(parentPath,
                FILE_TRAVERSE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, true))
            {
                if (Identity(Inspect(currentParent, parentPath)) != parentIdentity)
                    throw new IOException("Config parent identity changed during the atomic write: " + parentPath);
            }
        }

        private void AssertUnchanged()
        {
            AssertParentUnchanged();
            bool missing;
            using (SafeFileHandle currentTarget = TryOpenStableFile(path, FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, out missing))
            {
                if (targetExisted != !missing || (targetExisted &&
                    Identity(Inspect(currentTarget, path)) != targetIdentity))
                    throw new IOException("Config file identity changed during the atomic write: " + path);
            }
        }

        private void AssertCommitted()
        {
            AssertParentUnchanged();
            bool missing;
            using (SafeFileHandle currentTarget = TryOpenStableFile(path, FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, out missing))
            {
                if (missing || Identity(Inspect(currentTarget, path)) != Identity(Inspect(temporary, path)))
                    throw new IOException("Config path changed during the atomic commit: " + path);
            }
        }

        private void VerifyTemporaryContent()
        {
            byte[] actual = ReadAll(temporary, temporaryName);
            if (actual.Length != expectedLength || !EqualBytes(Hash(actual), expectedHash))
                throw new IOException("Dream Skin temporary config changed before atomic commit: " + path);
        }

        private bool TryRestoreOriginal(out Exception rollbackError)
        {
            try
            {
                if (temporaryAtTarget)
                {
                    if (targetExisted)
                    {
                        AssertCommitted();
                        RenameRelative(target, parent, fileName,
                            FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS);
                        temporaryAtTarget = false;
                    }
                    else
                    {
                        RenameRelative(temporary, parent, temporaryName, 0);
                        temporaryAtTarget = false;
                        temporaryAtInternalName = true;
                    }
                }
                AssertUnchanged();
                rollbackError = null;
                return true;
            }
            catch (Exception error)
            {
                rollbackError = error;
                return false;
            }
        }

        public void Commit()
        {
            if (disposed) throw new ObjectDisposedException("AtomicWriteTransaction");
            if (committed) throw new InvalidOperationException("Atomic write was already committed.");
            RollbackConfirmed = false;
            try
            {
                VerifyTemporaryContent();
                AssertUnchanged();
                if (targetExisted)
                {
                    RenameRelative(temporary, parent, fileName,
                        FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS);
                }
                else
                {
                    RenameRelative(temporary, parent, fileName, 0);
                }
                temporaryAtInternalName = false;
                temporaryAtTarget = true;
                if (!FlushFileBuffers(temporary))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new IOException("Could not flush the published Dream Skin config: " + path,
                        new Win32Exception(error));
                }
                AssertCommitted();
                committed = true;
                RollbackConfirmed = false;
            }
            catch (Exception commitError)
            {
                Exception rollbackError;
                if (TryRestoreOriginal(out rollbackError))
                {
                    RollbackConfirmed = true;
                    throw;
                }
                RollbackConfirmed = false;
                throw new IOException("Atomic config commit failed and rollback-unconfirmed recovery data was retained.",
                    new AggregateException(commitError, rollbackError));
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            Exception cleanupError = null;
            if (!committed && !temporaryAtTarget &&
                (temporaryAtCandidatePath || temporaryAtInternalName) &&
                temporary != null && !temporary.IsInvalid && !temporary.IsClosed)
            {
                try
                {
                    BY_HANDLE_FILE_INFORMATION information = Inspect(temporary, temporaryName);
                    string currentName = Path.GetFileName(ComparablePath(ResolvedPath(temporary, temporaryName)));
                    if (information.NumberOfLinks == 1 &&
                        (currentName.Equals(candidateName, StringComparison.OrdinalIgnoreCase) ||
                        currentName.Equals(temporaryName, StringComparison.OrdinalIgnoreCase)))
                    {
                        DeleteByHandle(temporary);
                    }
                }
                catch (Exception error) { cleanupError = error; }
            }
            if (temporary != null) temporary.Dispose();
            if (target != null) target.Dispose();
            if (parent != null) parent.Dispose();
            if (cleanupError != null) throw cleanupError;
        }
    }

    public sealed class MissingPathGuard : IDisposable
    {
        private readonly string anchorPath;
        private readonly string firstMissingPath;
        private readonly string anchorIdentity;
        private SafeFileHandle anchor;

        private static SafeFileHandle FindNearestExistingAncestor(string requestedPath,
            out string trustedAnchorPath, out string missingPath)
        {
            string current = requestedPath;
            missingPath = null;
            while (true)
            {
                bool missing;
                SafeFileHandle existing = TryOpenStableEntry(current,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, out missing);
                if (!missing)
                {
                    try
                    {
                        if (missingPath == null)
                            throw new IOException("Config appeared during missing-config restore: " + requestedPath);
                        if ((Inspect(existing, current).FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
                            throw new IOException("Missing-config trusted ancestor is not a directory: " + current);
                        trustedAnchorPath = current;
                        return existing;
                    }
                    catch
                    {
                        existing.Dispose();
                        throw;
                    }
                }
                missingPath = current;
                string parentPath = Path.GetDirectoryName(current);
                if (String.IsNullOrEmpty(parentPath) ||
                    parentPath.Equals(current, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException("Could not find a trusted ancestor for missing config: " + requestedPath);
                }
                current = parentPath;
            }
        }

        internal MissingPathGuard(string requestedPath)
        {
            string fullPath = NormalizePath(requestedPath);
            anchorPath = null;
            firstMissingPath = null;
            anchorIdentity = null;
            string trustedAnchorPath;
            string missingPath;
            try
            {
                anchor = FindNearestExistingAncestor(fullPath, out trustedAnchorPath, out missingPath);
                anchorPath = trustedAnchorPath;
                firstMissingPath = missingPath;
                anchorIdentity = Identity(Inspect(anchor, anchorPath));
                AssertUnchanged();
            }
            catch
            {
                if (anchor != null) anchor.Dispose();
                anchor = null;
                throw;
            }
        }

        public void AssertUnchanged()
        {
            if (anchor == null) throw new ObjectDisposedException("MissingPathGuard");
            using (SafeFileHandle currentAnchor = OpenStable(anchorPath, FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE, true))
            {
                if (Identity(Inspect(currentAnchor, anchorPath)) != anchorIdentity)
                    throw new IOException("Config ancestor identity changed while config was absent: " + anchorPath);
            }
            bool missing;
            using (SafeFileHandle current = TryOpenStableEntry(firstMissingPath,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, out missing))
            {
                if (!missing)
                    throw new IOException("Config path component appeared during missing-config restore: " + firstMissingPath);
            }
        }

        public void Complete()
        {
            AssertUnchanged();
            anchor.Dispose();
            anchor = null;
        }

        public void Dispose()
        {
            if (anchor == null) return;
            try { AssertUnchanged(); }
            finally
            {
                anchor.Dispose();
                anchor = null;
            }
        }
    }

    public static AtomicWriteTransaction BeginAtomicWrite(string path, byte[] bytes)
    {
        if (bytes == null) throw new ArgumentNullException("bytes");
        return new AtomicWriteTransaction(path, bytes);
    }

    public static MissingPathGuard HoldMissingPath(string path)
    {
        return new MissingPathGuard(path);
    }

    public static void DeleteExpectedFile(string path, string expectedIdentity, byte[] expectedBytes)
    {
        if (expectedIdentity == null) throw new ArgumentNullException("expectedIdentity");
        if (expectedBytes == null) throw new ArgumentNullException("expectedBytes");
        string fullPath = NormalizePath(path);
        ValidateComponentLength(Path.GetFileName(fullPath));
        bool missing;
        using (SafeFileHandle file = TryOpenStableFile(fullPath,
            GENERIC_READ | FILE_READ_ATTRIBUTES | DELETE, FILE_SHARE_READ, out missing))
        {
            if (missing)
                throw new IOException("Expected Dream Skin completion evidence disappeared: " + fullPath);
            if (Identity(Inspect(file, fullPath)) != expectedIdentity)
                throw new IOException("Dream Skin completion evidence identity changed: " + fullPath);
            byte[] actual = ReadAll(file, fullPath);
            if (actual.Length != expectedBytes.Length || !EqualBytes(Hash(actual), Hash(expectedBytes)))
                throw new IOException("Dream Skin completion evidence bytes changed: " + fullPath);
            DeleteByHandlePosix(file, fullPath);
        }
        bool stillMissing;
        using (SafeFileHandle current = TryOpenStableFile(fullPath, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, out stillMissing))
        {
            if (!stillMissing)
                throw new IOException("Unexpected completion evidence appeared after deletion: " + fullPath);
        }
    }

    public static DreamSkinNativePathSnapshot Snapshot(string path, bool readBytes)
    {
        uint access = readBytes ? GENERIC_READ : FILE_READ_ATTRIBUTES;
        uint flags = FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS;
        using (SafeFileHandle handle = CreateFileW(
            NormalizePath(path),
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
  return [DreamSkinConfigNative]::NormalizePath($Path)
}

function Get-DreamSkinStablePathComponentSnapshots {
  param([Parameter(Mandatory = $true)][string]$Path)
  $fullPath = [DreamSkinConfigNative]::NormalizePath($Path)
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
  $fullPath = [DreamSkinConfigNative]::NormalizePath($Path)
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
    $ExpectedSnapshot,

    [AllowNull()]
    $PreparedTransaction
  )

  $bytes = $script:DreamSkinUtf8NoBom.GetBytes($Content)
  $writeArguments = @{ Path = $Path; Bytes = $bytes }
  if ($PSBoundParameters.ContainsKey('ExpectedBytes')) { $writeArguments.ExpectedBytes = $ExpectedBytes }
  if ($PSBoundParameters.ContainsKey('ExpectedSnapshot')) { $writeArguments.ExpectedSnapshot = $ExpectedSnapshot }
  if ($PSBoundParameters.ContainsKey('PreparedTransaction')) {
    $writeArguments.PreparedTransaction = $PreparedTransaction
  }
  Write-DreamSkinBytesAtomically @writeArguments
}

function Write-DreamSkinBytesAtomically {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
    [AllowNull()][byte[]]$ExpectedBytes,
    [AllowNull()]$ExpectedSnapshot,
    [AllowNull()]$PreparedTransaction
  )

  $fullPath = [DreamSkinConfigNative]::NormalizePath($Path)
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
  $transaction = if ($PSBoundParameters.ContainsKey('PreparedTransaction')) {
    if ($null -eq $PreparedTransaction) { throw 'Prepared atomic write transaction is missing.' }
    $PreparedTransaction
  } else { $null }
  try {
    if ($null -eq $transaction) {
      $transaction = [DreamSkinConfigNative]::BeginAtomicWrite($fullPath, $Bytes)
    }
    if ($PSBoundParameters.ContainsKey('ExpectedSnapshot')) {
      Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $ExpectedSnapshot
    } elseif ($PSBoundParameters.ContainsKey('ExpectedBytes')) {
      Assert-DreamSkinFileUnchanged -Path $fullPath -ExpectedBytes $ExpectedBytes
    }
    $transaction.Commit()
  } finally {
    if ($null -ne $transaction) { $transaction.Dispose() }
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
  param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [object[]]$Snapshots
  )
  if (-not $PSBoundParameters.ContainsKey('Snapshots')) {
    $Snapshots = @(Get-DreamSkinConfigCompletionEvidenceSnapshots -ArchivePath $ArchivePath)
  }
  foreach ($snapshot in $Snapshots) {
    Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $snapshot
  }
  foreach ($snapshot in $Snapshots) {
    if (-not $snapshot.Exists) { continue }
    [DreamSkinConfigNative]::DeleteExpectedFile(
      $snapshot.FullPath, $snapshot.Identity, [byte[]]$snapshot.Bytes)
  }
}

function Get-DreamSkinConfigCompletionEvidenceSnapshots {
  param([Parameter(Mandatory = $true)][string]$ArchivePath)
  $snapshots = @()
  foreach ($path in @($ArchivePath, (Get-DreamSkinAppearanceMarkerPath -BackupPath $ArchivePath))) {
    if (Get-Command Assert-DreamSkinNoReparseComponents -ErrorAction SilentlyContinue) {
      Assert-DreamSkinNoReparseComponents -Path $path
    }
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Dream Skin completion evidence is not a safe file: $path"
    }
    $snapshots += Get-DreamSkinStableFileSnapshot -Path $path -AllowMissing
  }
  return @($snapshots)
}

function Restore-DreamSkinConfigCompletionEvidenceSnapshots {
  param([Parameter(Mandatory = $true)][object[]]$Snapshots)
  foreach ($snapshot in $Snapshots) {
    if (-not $snapshot.Exists) {
      Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $snapshot
      continue
    }
    $current = Get-DreamSkinStableFileSnapshot -Path $snapshot.FullPath -AllowMissing
    if ($current.Exists) {
      if ($current.Identity -ceq $snapshot.Identity -and
        (Test-DreamSkinBytesEqual -Left $snapshot.Bytes -Right $current.Bytes)) { continue }
      throw "Dream Skin completion evidence changed during rollback: $($snapshot.FullPath)"
    }
    Write-DreamSkinBytesAtomically -Path $snapshot.FullPath -Bytes $snapshot.Bytes `
      -ExpectedBytes $current.Bytes -ExpectedSnapshot $current
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
  $stateRoot = Split-Path -Parent $BackupPath
  $archivePath = Join-Path $stateRoot 'config.restored.toml'
  $completionEvidenceSnapshots = @(Get-DreamSkinConfigCompletionEvidenceSnapshots -ArchivePath $archivePath)
  if (-not $liveBackup -and (Test-DreamSkinBaseThemeManaged -ConfigPath $ConfigPath)) {
    $completionEvidence = Test-DreamSkinConfigCompletionEvidence -ArchivePath $archivePath
    if (-not (Test-DreamSkinRestoreCompleted -StateRoot $stateRoot `
      -CompletionEvidence $completionEvidence -BackupPath $BackupPath)) {
      throw 'Dream Skin managed settings exist without a recoverable baseline; config was preserved.'
    }
  }
  $appearanceMarker = Read-DreamSkinAppearanceMarker -BackupPath $BackupPath
  Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot
  $backupCreated = $false
  $configCommitted = $false
  $completionEvidenceInvalidationStarted = $false
  $configWrite = $null
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
    $configWrite = [DreamSkinConfigNative]::BeginAtomicWrite(
      [DreamSkinConfigNative]::NormalizePath($ConfigPath), $script:DreamSkinUtf8NoBom.GetBytes($content))
    Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot
    if (-not $liveBackup) {
      Write-DreamSkinBytesAtomically -Path $BackupPath -Bytes $originalBytes -ExpectedBytes $null
      $backupCreated = $true
    }
    $completionEvidenceInvalidationStarted = $true
    Remove-DreamSkinConfigCompletionEvidence -ArchivePath $archivePath -Snapshots $completionEvidenceSnapshots
    Write-DreamSkinUtf8FileAtomically -Path $ConfigPath -Content $content -ExpectedBytes $originalBytes `
      -ExpectedSnapshot $configSnapshot -PreparedTransaction $configWrite
    $configCommitted = $true
    Write-DreamSkinAppearanceMarker -BackupPath $BackupPath
  } catch {
    $installError = $_
    $proofRestoreError = $null
    $rollbackConfirmed = $null -eq $configWrite -or $configWrite.RollbackConfirmed
    if ($completionEvidenceInvalidationStarted -and -not $configCommitted -and $rollbackConfirmed) {
      try {
        Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot
        Restore-DreamSkinConfigCompletionEvidenceSnapshots -Snapshots $completionEvidenceSnapshots
      } catch {
        $proofRestoreError = $_
      }
    }
    if ($backupCreated -and -not $configCommitted -and $rollbackConfirmed -and
      $null -eq $proofRestoreError) {
      Remove-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $proofRestoreError) {
      throw "Dream Skin install failed: $($installError.Exception.Message) Completion evidence rollback failed: $($proofRestoreError.Exception.Message)"
    }
    throw $installError
  } finally {
    if ($null -ne $configWrite) { $configWrite.Dispose() }
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
  $configWrite = $null
  $configCommitted = $false
  $recoveryCreated = $false
  try {
    $configWrite = [DreamSkinConfigNative]::BeginAtomicWrite(
      [DreamSkinConfigNative]::NormalizePath($ConfigPath), $backupBytes)
    Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot
    if ($configSnapshot.Exists) {
      Write-DreamSkinBytesAtomically -Path $RecoveryBackupPath -Bytes $currentBytes -ExpectedBytes $null
      $recoveryCreated = $true
    }
    Write-DreamSkinBytesAtomically -Path $ConfigPath -Bytes $backupBytes -ExpectedBytes $currentBytes `
      -ExpectedSnapshot $configSnapshot -PreparedTransaction $configWrite
    $configCommitted = $true
  } catch {
    $restoreError = $_
    $rollbackConfirmed = $null -eq $configWrite -or $configWrite.RollbackConfirmed
    if ($rollbackConfirmed) {
      try { Assert-DreamSkinStableFileSnapshotUnchanged -Snapshot $configSnapshot }
      catch { $rollbackConfirmed = $false }
    }
    if ($recoveryCreated -and -not $configCommitted -and $rollbackConfirmed) {
      Remove-Item -LiteralPath $RecoveryBackupPath -Force -ErrorAction SilentlyContinue
    }
    throw $restoreError
  } finally {
    if ($null -ne $configWrite) { $configWrite.Dispose() }
  }
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
