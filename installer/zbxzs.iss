; zbxzs Windows 安装包（Inno Setup 6）
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#define MyAppName "快马小助手"
#define MyAppPublisher "桦中科技"
#define MyAppExeName "快马小助手.exe"
#define MySourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{8F3A1C2D-4B5E-47A1-9C82-6D1E8B4F3A21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppCopyright=Copyright (C) 2026 {#MyAppPublisher}
VersionInfoCompany={#MyAppPublisher}
VersionInfoCopyright=Copyright (C) 2026 {#MyAppPublisher}
VersionInfoDescription={#MyAppName}
VersionInfoProductName={#MyAppName}
VersionInfoProductTextVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=zbxzs-setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
CloseApplications=force
RestartApplications=no
AllowNoIcons=yes
MinVersion=10.0
DisableWelcomePage=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

[Messages]
WelcomeLabel1=欢迎使用 [name]
WelcomeLabel2=这将安装 [name/ver] 到您的计算机。%n%n开发商：桦中科技%n%n建议在继续之前关闭其他应用程序。
FinishedHeadingLabel=完成 [name] 安装向导
FinishedLabel=已经完成 [name] 的安装。%n%n开发商：桦中科技

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: checkedonce

[Files]
Source: "{#MySourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,*.map,HOW_TO_RUN.txt"
; 微软 WebView2 在线引导程序（约 1.7MB）：安装时若本机没有运行时，由引导程序从微软 CDN 拉取完整运行时
Source: "redist\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{app}\redist"; Flags: ignoreversion
Source: "redist\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; DestName: "MicrosoftEdgeWebview2Setup.exe"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install /norestart"; StatusMsg: "正在安装 WebView2 运行时..."; Flags: waituntilterminated; Check: NeedsWebView2
Filename: "{app}\{#MyAppExeName}"; Description: "立即运行 {#MyAppName}"; Flags: nowait postinstall

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
function WebView2Installed: Boolean;
var
  Pv: String;
  Key: String;
begin
  Result := False;
  Key := 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  if RegQueryStringValue(HKLM, Key, 'pv', Pv) and (Pv <> '') and (Pv <> '0.0.0.0') then
  begin
    Result := True;
    exit;
  end;
  Key := 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  if RegQueryStringValue(HKLM, Key, 'pv', Pv) and (Pv <> '') and (Pv <> '0.0.0.0') then
  begin
    Result := True;
    exit;
  end;
  if RegQueryStringValue(HKCU, Key, 'pv', Pv) and (Pv <> '') and (Pv <> '0.0.0.0') then
    Result := True;
end;

function NeedsWebView2: Boolean;
begin
  Result := not WebView2Installed;
end;
