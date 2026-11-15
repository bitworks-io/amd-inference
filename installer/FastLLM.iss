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

// Keep a copy of the release being replaced (its RELEASE.json and release policy) in the user's data folder, plus a record.json
// naming the release that replaces it, so a later, explicit reinstall of exactly that version can be decided from facts the
// installer wrote and can tell a record that belongs to the installed release from a stale one. This also covers installs run
// by hand. record.json is written last, so a partial record never carries it. Best effort: it never fails or delays the install.
// With no installed release (a fresh install) any existing record is removed. Re-running the same version leaves the record
// alone. It runs from PrepareToInstall, before Setup's install step and [InstallDelete]. The version test matches the
// "version" key as RELEASE.json is written (two-space indent, one space after the colon), so "rollbackOf" never matches.
procedure RecordPreviousRelease;
var
  AppDir, RecordDir, OldRelease, OldPolicy, Text: String;
  Raw: AnsiString;
  SameVersion, Ok: Boolean;
begin
  AppDir := RemoveBackslash(ExpandConstant('{app}'));
  OldRelease := AppDir + '\RELEASE.json';
  OldPolicy := AppDir + '\config\release-policy.json';
  RecordDir := ExpandConstant('{localappdata}\Bitworks\FastLLM\state\previous-release');
  try
    if not FileExists(OldRelease) then
    begin
      if DirExists(RecordDir) then DelTree(RecordDir, True, True, True);
      Exit;
    end;
    SameVersion := False;
    if LoadStringFromFile(OldRelease, Raw) then
    begin
      Text := String(Raw);
      SameVersion := Pos('"version": "{#AppVersion}"', Text) > 0;
    end;
    if SameVersion then Exit;
    if DirExists(RecordDir) then DelTree(RecordDir, True, True, True);
    Ok := ForceDirectories(RecordDir) and CopyFile(OldRelease, RecordDir + '\RELEASE.json', False);
    if Ok and FileExists(OldPolicy) then
      Ok := CopyFile(OldPolicy, RecordDir + '\release-policy.json', False);
    if Ok then
      Ok := SaveStringToFile(RecordDir + '\record.json', '{"replacedBy":"{#AppVersion}"}', False);
    if not Ok then DelTree(RecordDir, True, True, True);
  except
    // A record that cannot be written means no reinstall is offered later; the install goes on.
  end;
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
              'and installing there would delete them. Choose an empty or new folder, or leave the default.'
  else
    RecordPreviousRelease;
end;

function DirSizeBytes(const Dir: String): Int64;
var
  FindRec: TFindRec;
  Hi, Lo: Int64;
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
        begin
          // Int64 locals: a product of the 32-bit fields would be computed in 32 bits and drop the high half of every large file.
          Hi := FindRec.SizeHigh;
          Lo := FindRec.SizeLow;
          Result := Result + Hi * 65536 * 65536 + Lo;
        end;
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir, ModelsDir, EnginesDir, ComponentsDir: String;
  Bytes: Int64;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  // The optional start-at-sign-in registration is per user and never created by Setup; remove it with the app. This runs before
  // the early exits below so a silent uninstall removes it too.
  RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'FastLLM');
  RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', 'FastLLM');
  DataDir := ExpandConstant('{localappdata}\Bitworks\FastLLM');
  ModelsDir := DataDir + '\models';
  EnginesDir := DataDir + '\engines';
  ComponentsDir := DataDir + '\components';
  if UninstallSilent or not (DirExists(ModelsDir) or DirExists(EnginesDir) or DirExists(ComponentsDir)) then Exit;
  Bytes := 0;
  if DirExists(ModelsDir) then Bytes := Bytes + DirSizeBytes(ModelsDir);
  if DirExists(EnginesDir) then Bytes := Bytes + DirSizeBytes(EnginesDir);
  if DirExists(ComponentsDir) then Bytes := Bytes + DirSizeBytes(ComponentsDir);
  // Spec 4.1: offer to delete only the downloaded models, engines and engine components; settings, consent records and logs stay.
  if MsgBox('Also delete the downloaded models and engines (' + IntToStr(Bytes div 1048576) + ' MiB)?' + #13#10 +
            ModelsDir + #13#10 + EnginesDir + #13#10 + ComponentsDir + #13#10#13#10 +
            'Settings, consent records and logs are kept. Choose No to keep the models and engines for a later install.',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
  begin
    if DirExists(ModelsDir) then DelTree(ModelsDir, True, True, True);
    if DirExists(EnginesDir) then DelTree(EnginesDir, True, True, True);
    if DirExists(ComponentsDir) then DelTree(ComponentsDir, True, True, True);
  end;
end;
