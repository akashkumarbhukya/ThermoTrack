#define MyAppName "ThermoTrack"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Akash kumar"
#define MyAppExeName "ThermoTrack.exe"

[Setup]
AppId={{A7C9DFA1-09C2-4BA0-9D2C-4F26C6F3A8A2}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\ThermoTrack
DefaultGroupName=ThermoTrack
OutputDir=..\dist
OutputBaseFilename=ThermoTrack-Setup-x64
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
SetupLogging=yes

[Files]
Source: "..\publish\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\ThermoTrack"; Filename: "{app}\ThermoTrack.exe"
Name: "{autodesktop}\ThermoTrack"; Filename: "{app}\ThermoTrack.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{app}\MicrosoftEdgeWebView2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing or checking the Microsoft WebView2 runtime..."; Flags: waituntilterminated
Filename: "{app}\ThermoTrack.exe"; Description: "Launch ThermoTrack"; Flags: nowait postinstall skipifsilent

