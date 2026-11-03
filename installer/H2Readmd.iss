; Inno Setup 6. All source/output paths are relative to this script.
#define AppName "H2 Readmd"
#define AppVersion "1.0.3"
#define AppExeName "H2Readmd.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

#if !FileExists(AddBackslash(SourcePath) + ReleaseDir + "\H2Readmd.exe")
  #error Build Windows Release before compiling this installer.
#endif
#if !FileExists(AddBackslash(SourcePath) + ReleaseDir + "\flutter_windows.dll")
  #error Missing flutter_windows.dll in Release.
#endif
#if !FileExists(AddBackslash(SourcePath) + ReleaseDir + "\data\app.so")
  #error Missing data\app.so in Release.
#endif

[Setup]
; Keep this ID unchanged for future versions.
AppId={{C38DF467-0783-4B25-B4BF-6E9B1EA242D0}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=H2Readmd-Setup-{#AppVersion}-x64
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes

[Registry]
; Register a candidate only. Never write .md's default value or UserChoice.
; This private ProgID is owned by H2 Readmd; other ProgIDs are untouched.
Root: HKLM; Subkey: "Software\Classes\H2Readmd.Markdown"; ValueType: string; ValueName: ""; ValueData: "Markdown 文档"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\H2Readmd.Markdown\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{sys}\imageres.dll,-102"
Root: HKLM; Subkey: "Software\Classes\H2Readmd.Markdown\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""
; Remove only our named value from this shared Windows key at uninstall.
Root: HKLM; Subkey: "Software\Classes\.md\OpenWithProgids"; ValueType: string; ValueName: "H2Readmd.Markdown"; ValueData: ""; Flags: uninsdeletevalue
; Expose the candidate in Windows Default apps, with the application's own logo.
Root: HKLM; Subkey: "Software\H2Readmd\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\H2Readmd\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "Markdown 文档阅读与编辑器"
Root: HKLM; Subkey: "Software\H2Readmd\Capabilities"; ValueType: string; ValueName: "ApplicationIcon"; ValueData: """{app}\{#AppExeName}"",0"
Root: HKLM; Subkey: "Software\H2Readmd\Capabilities\FileAssociations"; ValueType: string; ValueName: ".md"; ValueData: "H2Readmd.Markdown"
Root: HKLM; Subkey: "Software\H2Readmd"; Flags: uninsdeletekeyifempty
Root: HKLM; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "H2Readmd"; ValueData: "Software\H2Readmd\Capabilities"; Flags: uninsdeletevalue

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Include the complete runtime bundle, all plugin DLLs and nested assets.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent runasoriginaluser

; Standard uninstall removes installed files and shortcuts, then empty folders.
; No wildcard UninstallDelete: preserve user-created Markdown documents.
