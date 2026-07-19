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

[Setup]
AppId=com.feiaway.codex-dream-skin-studio
AppName=Codex Dream Skin Studio
AppVersion={#AppVersion}
AppPublisher=Codex Dream Skin Studio contributors
DefaultDirName={localappdata}\Programs\CodexDreamSkinStudio\versions\{#AppVersion}
DefaultGroupName=Codex Dream Skin Studio
DisableProgramGroupPage=yes
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
#if Architecture == "x64"
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#endif

[Files]
Source: "{#StageRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Codex Dream Skin Studio"; Filename: "{app}\CodexDreamSkinStudio.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\CodexDreamSkinStudio.exe"; Description: "Launch Codex Dream Skin Studio"; Flags: nowait postinstall skipifsilent unchecked

[Code]
function InitializeUninstall(): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{app}\CodexDreamSkinStudio.exe'),
    '--prepare-uninstall', '', SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) and
    (ResultCode = 0);
end;
