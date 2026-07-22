#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef Architecture
  #error Architecture is required
#endif
#ifndef StageRoot
  #error StageRoot is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename is required
#endif
#ifndef IconPath
  #error IconPath is required
#endif
#ifndef StageFilesManifest
  #error StageFilesManifest is required
#endif

[Setup]
#ifdef TestAppId
AppId={#TestAppId}
#else
AppId=com.feiaway.codex-dream-skin-studio
#endif
AppName=Codex Dream Skin Studio
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.0
VersionInfoProductVersion={#AppVersion}.0
VersionInfoProductTextVersion={#AppVersion}
AppPublisher=Codex Dream Skin Studio contributors
#ifdef TestDefaultDirName
DefaultDirName={#TestDefaultDirName}
#else
DefaultDirName={localappdata}\Programs\CodexDreamSkinStudio\versions\{#AppVersion}
#endif
DefaultGroupName=Codex Dream Skin Studio
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
UsePreviousAppDir=no
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile={#IconPath}
UninstallDisplayIcon={app}\CodexDreamSkinStudio.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
MinVersion=10.0.17763
#if Architecture == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#elif Architecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
  #error Unsupported Architecture
#endif

[Files]
#include StageFilesManifest

[Icons]
Name: "{group}\Codex Dream Skin Studio"; Filename: "{app}\CodexDreamSkinStudio.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\CodexDreamSkinStudio.exe"; Description: "Launch Codex Dream Skin Studio"; Flags: nowait postinstall skipifsilent unchecked

[Code]
function IsDirectoryEmpty(const DirectoryName: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := True;
  if FindFirst(AddBackslash(DirectoryName) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          Result := False;
          Exit;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function GetVersionTargetDirectory(): String;
begin
#ifdef TestDefaultDirName
  Result := '{#TestDefaultDirName}';
#else
  Result := ExpandConstant('{localappdata}\Programs\CodexDreamSkinStudio\versions\{#AppVersion}');
#endif
end;

function RefuseNonemptyVersionTarget(const DirectoryName: String): Boolean;
begin
  Result := DirExists(DirectoryName) and (not IsDirectoryEmpty(DirectoryName));
  if Result then
    SuppressibleMsgBox('The same-version target directory is not empty. Uninstall it before reinstalling.',
      mbCriticalError, MB_OK, IDOK);
end;

function InitializeSetup(): Boolean;
begin
  Result := not RefuseNonemptyVersionTarget(GetVersionTargetDirectory());
  if not Result then Abort;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  if CompareText(WizardDirValue(), GetVersionTargetDirectory()) <> 0 then
    Result := 'The versioned install directory is fixed.'
  else if RefuseNonemptyVersionTarget(WizardDirValue()) then
    Result := 'The same-version target directory is not empty.'
  else
    Result := '';
end;

function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{app}\CodexDreamSkinStudio.exe'),
    '--prepare-uninstall', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) and
    (ResultCode = 0);
end;
