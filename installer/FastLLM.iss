; FastLLM per-user installer. Build with installer/build-installer.ps1 (never by hand).
#ifndef AppVersion
  #error AppVersion is required: ISCC /DAppVersion=YYYY.MM.DD.N /DSourceDir=<tree> /DOutputDir=<dir>
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #define OutputDir "out"
#endif

[Setup]
AppId={{377C960B-EDE4-4BE1-95C0-E21A032605EC}
AppName=FastLLM
AppVersion={#AppVersion}
AppVerName=FastLLM {#AppVersion}
AppPublisher=Bitworks LLC
AppPublisherURL=https://bitworks.io/
AppSupportURL=https://github.com/bitworks-io/amd-inference/issues
AppUpdatesURL=https://github.com/bitworks-io/amd-inference/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoCompany=Bitworks LLC
VersionInfoDescription=FastLLM Setup
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Bitworks FastLLM
DisableDirPage=yes
DisableProgramGroupPage=yes
UninstallFilesDir={app}\_uninstall
UninstallDisplayName=FastLLM
OutputDir={#OutputDir}
OutputBaseFilename=FastLLM-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile={#SourceDir}\LICENSE
SetupLogging=yes
#ifdef SignToolName
SignTool={#SignToolName}
SignedUninstaller=yes
#endif

[InstallDelete]
; Upgrade in place: remove the previous version's app files so the folder matches the new signed catalog exactly.
Type: files; Name: "{app}\*"
Type: filesandordirs; Name: "{app}\src"
Type: filesandordirs; Name: "{app}\tools"
Type: filesandordirs; Name: "{app}\config"
Type: filesandordirs; Name: "{app}\licenses"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{userprograms}\FastLLM"; Filename: "{app}\FastLLM.cmd"; WorkingDir: "{app}"

[Code]
function DirHasEntries(const Dir: String): Boolean;
var
  FindRec: TFindRec;
begin
  Result := False;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then
  try
    repeat
      if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        Result := True;
    until Result or not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

function IsFastLlmInstall(const Dir: String): Boolean;
begin
  Result := FileExists(AddBackslash(Dir) + 'FastLLM.cat') or
            FileExists(AddBackslash(Dir) + '_uninstall\unins000.dat');
end;

// [InstallDelete] clears the top level of the app folder, so /DIR= must never point Setup at a folder that holds someone
// else's files. An empty or missing folder and an existing FastLLM install (an upgrade) are fine. This runs before any
// file is deleted.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Dir: String;
begin
  Result := '';
  Dir := RemoveBackslash(ExpandConstant('{app}'));
  if DirExists(Dir) and DirHasEntries(Dir) and not IsFastLlmInstall(Dir) then
    Result := 'FastLLM was not installed. The folder ' + Dir + ' already contains files that are not part of a FastLLM installation, ' +
              'and installing there would delete them. Choose an empty or new folder, or leave the default.';
end;

function DirSizeBytes(const Dir: String): Int64;
var
  FindRec: TFindRec;
begin
  Result := 0;
  if FindFirst(AddBackslash(Dir) + '*', FindRec) then
  try
    repeat
      if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
      begin
        if (FindRec.Attributes and $10) <> 0 then
        begin
          if (FindRec.Attributes and $400) = 0 then
            Result := Result + DirSizeBytes(AddBackslash(Dir) + FindRec.Name);
        end
        else
          Result := Result + FindRec.SizeHigh * 4294967296 + FindRec.SizeLow;
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir, ModelsDir, EnginesDir: String;
  Bytes: Int64;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  DataDir := ExpandConstant('{localappdata}\Bitworks\FastLLM');
  ModelsDir := DataDir + '\models';
  EnginesDir := DataDir + '\engines';
  if UninstallSilent or not (DirExists(ModelsDir) or DirExists(EnginesDir)) then Exit;
  Bytes := 0;
  if DirExists(ModelsDir) then Bytes := Bytes + DirSizeBytes(ModelsDir);
  if DirExists(EnginesDir) then Bytes := Bytes + DirSizeBytes(EnginesDir);
  // Spec 4.1: offer to delete only the downloaded models and engines; settings, consent records and logs stay.
  if MsgBox('Also delete the downloaded models and engines (' + IntToStr(Bytes div 1048576) + ' MB)?' + #13#10 +
            ModelsDir + #13#10 + EnginesDir + #13#10#13#10 +
            'Settings, consent records and logs are kept. Choose No to keep the models and engines for a later install.',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
  begin
    if DirExists(ModelsDir) then DelTree(ModelsDir, True, True, True);
    if DirExists(EnginesDir) then DelTree(EnginesDir, True, True, True);
  end;
end;
