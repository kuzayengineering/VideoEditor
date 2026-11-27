; The Windows installer (Inno Setup 6, built by the automatic build).
; Installs for the current user only (no administrator password needed),
; adds Start menu and desktop shortcuts, and an uninstaller listed in
; Windows Settings > Apps. Projects and settings are kept on uninstall.
; Run silently by the app's own update check (/SILENT), it replaces the
; old version and starts the new one.

#define AppVersion GetEnv("VERSION")
#if AppVersion == ""
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F1C2B7E-3A54-4E1D-9B8A-5C2D7E9F0A11}
AppName=Video Editor
AppVersion={#AppVersion}
AppVerName=Video Editor {#AppVersion}
AppPublisher=Kuzay Engineering
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Video Editor
DefaultGroupName=Video Editor
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=VideoEditor-{#AppVersion}-windows-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\video_editor.exe
UninstallDisplayName=Video Editor
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Files of the old version that the new one no longer has.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Video Editor"; Filename: "{app}\video_editor.exe"
Name: "{autodesktop}\Video Editor"; Filename: "{app}\video_editor.exe"; Tasks: desktopicon

[Run]
; After a normal install: offer to start it. After an update (silent):
; start the new version straight away.
Filename: "{app}\video_editor.exe"; Description: "{cm:LaunchProgram,Video Editor}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\video_editor.exe"; Flags: nowait; Check: WizardSilent
