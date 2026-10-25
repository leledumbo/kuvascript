program kuvascript;

{ kuvascript: builds an HTML photobook from a folder holding photobook.conf
  and the pictures it mentions. See README.md. }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, kvtypes, kvparser, kvimage, kvbuild;

const
  Version = '0.1.0';
  ConfName = 'photobook.conf';
  TemplateName = 'viewer.html';
  ExitOK = 0;
  ExitConf = 1;     // problems in photobook.conf or the files it names
  ExitFailure = 2;  // bad command line, unreadable template, disk trouble...

type
  TArgs = record
    InputDir, OutDir, Template: string;
    Quality: Integer;
    Force, Quiet, CheckOnly, Help, ShowVersion: Boolean;
  end;

procedure Usage;
begin
  WriteLn('kuvascript ', Version, ' - HTML photobook generator');
  WriteLn;
  WriteLn('usage: kuvascript [options] <directory>');
  WriteLn;
  WriteLn('  <directory> holds photobook.conf and the pictures it refers to.');
  WriteLn('  The photobook is written to <directory>/output/pb.html by default.');
  WriteLn;
  WriteLn('options:');
  WriteLn('  -o, --output <dir>      where to write pb.html and images/');
  WriteLn('  -t, --template <file>   viewer template (default: template/viewer.html, found');
  WriteLn('                          next to or above the executable)');
  WriteLn('  -q, --quality <1-100>   JPEG quality of the rendered pictures (default 90)');
  WriteLn('  -f, --force             render every picture again');
  WriteLn('  -c, --check             only check photobook.conf and the files, write nothing');
  WriteLn('      --quiet             no progress output');
  WriteLn('  -V, --version');
  WriteLn('  -h, --help');
end;

function ParseArgs(out A: TArgs): Boolean;
var
  I: Integer;
  S: string;

  function Value(const Name: string): string;
  begin
    if I >= ParamCount then
    begin
      WriteLn(StdErr, 'kuvascript: ', Name, ' needs a value');
      Result := '';
      Halt(ExitFailure);
    end;
    Inc(I);
    Result := ParamStr(I);
  end;

begin
  A.InputDir := '';
  A.OutDir := '';
  A.Template := '';
  A.Quality := 90;
  A.Force := False;
  A.Quiet := False;
  A.CheckOnly := False;
  A.Help := False;
  A.ShowVersion := False;
  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (S = '-o') or (S = '--output') then A.OutDir := Value(S)
    else if (S = '-t') or (S = '--template') then A.Template := Value(S)
    else if (S = '-q') or (S = '--quality') then
    begin
      A.Quality := StrToIntDef(Value(S), 0);
      if (A.Quality < 1) or (A.Quality > 100) then
      begin
        WriteLn(StdErr, 'kuvascript: quality must be a number from 1 to 100');
        Exit(False);
      end;
    end
    else if (S = '-f') or (S = '--force') then A.Force := True
    else if (S = '-c') or (S = '--check') then A.CheckOnly := True
    else if S = '--quiet' then A.Quiet := True
    else if (S = '-h') or (S = '--help') then A.Help := True
    else if (S = '-V') or (S = '--version') then A.ShowVersion := True
    else if (Length(S) > 1) and (S[1] = '-') then
    begin
      WriteLn(StdErr, 'kuvascript: unknown option ', S, ' (see --help)');
      Exit(False);
    end
    else if A.InputDir = '' then A.InputDir := S
    else
    begin
      WriteLn(StdErr, 'kuvascript: only one directory please, found "', S, '" as well');
      Exit(False);
    end;
    Inc(I);
  end;
  Result := True;
end;

{ The template lives in ./template or ../template (run from bin/), in
  ../share/kuvascript (after make install), or in a system wide share directory. }
function FindTemplate(const Given: string): string;
var
  Exe: string;
  Candidates: array[0..4] of string;
  I: Integer;
begin
  if Given <> '' then Exit(Given);
  Exe := ExtractFilePath(ExpandFileName(ParamStr(0)));
  Candidates[0] := Exe + 'template' + DirectorySeparator + TemplateName;
  Candidates[1] := Exe + '..' + DirectorySeparator + 'template' + DirectorySeparator + TemplateName;
  Candidates[2] := Exe + '..' + DirectorySeparator + 'share' + DirectorySeparator + 'kuvascript' +
    DirectorySeparator + TemplateName;
  Candidates[3] := '/usr/local/share/kuvascript/' + TemplateName;
  Candidates[4] := '/usr/share/kuvascript/' + TemplateName;
  for I := 0 to High(Candidates) do
    if FileExists(Candidates[I]) then Exit(Candidates[I]);
  Result := '';
end;

function ReadText(const FileName: string): string;
var
  S: TFileStream;
begin
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, S.Size);
    if S.Size > 0 then S.ReadBuffer(Result[1], S.Size);
  finally
    S.Free;
  end;
end;

procedure PrintDiagnostics(Diag: TKVDiagnostics);
var
  I: Integer;
begin
  for I := 0 to Diag.Messages.Count - 1 do
    WriteLn(StdErr, Diag.Messages[I]);
  Flush(StdErr);
end;

function Plural(N: Integer; const One, Many: string): string;
begin
  if N = 1 then Result := Format('%d %s', [N, One]) else Result := Format('%d %s', [N, Many]);
end;

function Run: Integer;
var
  A: TArgs;
  ConfFile, BaseDir, Template: string;
  Diag: TKVDiagnostics;
  PB: TKVPhotobook;
  Opt: TKVBuildOptions;
  Stats: TKVBuildStats;
  ConfTime: TDateTime;
  Pics, I, J: Integer;
begin
  if not ParseArgs(A) then Exit(ExitFailure);
  if A.ShowVersion then
  begin
    WriteLn('kuvascript ', Version);
    Exit(ExitOK);
  end;
  if A.Help or (A.InputDir = '') then
  begin
    Usage;
    if A.Help then Exit(ExitOK) else Exit(ExitFailure);
  end;

  if not DirectoryExists(A.InputDir) then
  begin
    WriteLn(StdErr, 'kuvascript: ', A.InputDir, ' is not a directory');
    Exit(ExitFailure);
  end;
  BaseDir := ExpandFileName(IncludeTrailingPathDelimiter(A.InputDir));
  ConfFile := BaseDir + ConfName;
  if not FileExists(ConfFile) then
  begin
    WriteLn(StdErr, 'kuvascript: no ', ConfName, ' in ', A.InputDir);
    Exit(ExitFailure);
  end;

  Diag := TKVDiagnostics.Create(ConfName);
  try
    PB := KVParse(ReadText(ConfFile), Diag);
    if PB <> nil then
    try
      KVCheckFiles(PB, BaseDir, Diag);
      if Diag.Errors = 0 then
      begin
        Pics := 0;
        for I := 0 to PB.Pages.Count - 1 do
          for J := 0 to High(PB.Page(I).Cells) do
            if PB.Page(I).Cells[J].Kind = ckPic then Inc(Pics);
        if A.CheckOnly then
        begin
          PrintDiagnostics(Diag);
          WriteLn(Format('%s: ok, %s, %s', [ConfName,
            Plural(PB.Pages.Count, 'page', 'pages'), Plural(Pics, 'picture', 'pictures')]));
          Exit(ExitOK);
        end;

        Template := FindTemplate(A.Template);
        if (Template = '') or not FileExists(Template) then
        begin
          WriteLn(StdErr, 'kuvascript: viewer template not found; use --template <file>');
          Exit(ExitFailure);
        end;

        Opt.BaseDir := BaseDir;
        if A.OutDir <> '' then Opt.OutDir := A.OutDir
        else Opt.OutDir := BaseDir + 'output';
        Opt.TemplateFile := Template;
        Opt.Quality := A.Quality;
        Opt.Force := A.Force;
        Opt.Quiet := A.Quiet;
        if FileAge(ConfFile, ConfTime) then Opt.ConfTime := ConfTime else Opt.ConfTime := 0;
        try
          Stats := KVBuildBook(PB, Opt, Diag);
        except
          on E: Exception do
          begin
            PrintDiagnostics(Diag);
            WriteLn(StdErr, 'kuvascript: ', E.Message);
            if Diag.Errors > 0 then Exit(ExitConf) else Exit(ExitFailure);
          end;
        end;
        PrintDiagnostics(Diag);
        WriteLn(Format('%s: %s, %s rendered, %s up to date -> %s', [
          PB.Title, Plural(PB.Pages.Count, 'page', 'pages'),
          Plural(Stats.Rendered, 'picture', 'pictures'),
          Plural(Stats.Reused, 'picture', 'pictures'),
          IncludeTrailingPathDelimiter(Opt.OutDir) + KVHtmlName]));
        Exit(ExitOK);
      end;
    finally
      PB.Free;
    end;
    PrintDiagnostics(Diag);
    WriteLn(StdErr, Format('%s: %s', [ConfName, Plural(Diag.Errors, 'error', 'errors')]));
    Result := ExitConf;
  finally
    Diag.Free;
  end;
end;

begin
  ExitCode := Run;
end.
