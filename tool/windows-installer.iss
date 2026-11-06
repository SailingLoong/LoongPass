#ifndef ReleaseVersion
  #error ReleaseVersion is required
#endif

[Setup]
AppId={{6B634C34-E4DA-4CF0-90AE-C667BBAD4521}
AppName=LoongPass
AppVersion={#ReleaseVersion}
AppPublisher=SailingLoong
AppPublisherURL=https://loongpass.com
DefaultDirName={localappdata}\Programs\LoongPass
DefaultGroupName=LoongPass
UninstallDisplayIcon={app}\LoongPass.exe
PrivilegesRequired=lowest
MinVersion=10.0
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDirectory}
OutputBaseFilename=LoongPass-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
CloseApplicationsFilter=LoongPass.exe
RestartApplications=no
AppMutex=Local\SailingLoong.LoongPass
LicenseFile=..\LICENSE
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\LoongPass"; Filename: "{app}\LoongPass.exe"
Name: "{autodesktop}\LoongPass"; Filename: "{app}\LoongPass.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts"; Flags: unchecked

[Run]
Filename: "{app}\LoongPass.exe"; Description: "Launch LoongPass"; Flags: nowait postinstall skipifsilent
Filename: "{app}\LoongPass.exe"; Flags: nowait skipifnotsilent; Check: ShouldRelaunch

[Code]
function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:RELAUNCH|0}') = '1';
end;
