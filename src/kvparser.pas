unit kvparser;

{ Parser and checks for photobook.conf, following docs/grammar.txt.

  The language is line oriented: every statement is one line, so the parser
  works line by line instead of with a separate tokenizer. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, kvtypes;

const
  KVMaxGrid = 3;
  KVMaxPixels = 16384;

{ Parses Source. Returns nil if anything is wrong; the details are in Diag.
  Warnings do not make the result nil. File names are not looked at here. }
function KVParse(const Source: string; Diag: TKVDiagnostics): TKVPhotobook;

{ Reports pic/front/back paths that do not point at a readable image of a
  supported type. }
procedure KVCheckFiles(PB: TKVPhotobook; const BaseDir: string; Diag: TKVDiagnostics);

function KVResolvePath(const BaseDir, APath: string): string;
function KVIsSupportedImage(const FileName: string): Boolean;

implementation

type
  TStmt = record
    Line: Integer;   // 1-based
    Text: string;    // trimmed
  end;

  TParser = class
  private
    FLines: TStringList;
    FPos: Integer;
    FDiag: TKVDiagnostics;
    FPB: TKVPhotobook;
    FCur: TKVPage;   // grid page being filled, nil if the last one is complete
    function NextStmt(out St: TStmt): Boolean;
    function ParseConfig: Boolean;
    procedure ParsePages;
    function ExpectKeyword(const St: TStmt; const KW, Usage: string; out Rest: string): Boolean;
    function ParseCount(const Tok, What: string; Line, Lo, Hi: Integer; out V: Integer): Boolean;
    function ParseSize(const St: TStmt; const Rest, KW: string; out Size: TKVSize): Boolean;
    function ParseText(const Raw: string; Line: Integer; out S: string): Boolean;
    procedure ParsePic(const St: TStmt; const Rest: string);
    procedure AddCell(const ACell: TKVCell);
    procedure AddChapter(const St: TStmt; const Rest: string);
    procedure CheckSizes;
  public
    constructor Create(ADiag: TKVDiagnostics);
    destructor Destroy; override;
    function Run(const Source: string): TKVPhotobook;
  end;

function IsWS(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

function TrimWS(const S: string): string;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and IsWS(S[A]) do Inc(A);
  while (B >= A) and IsWS(S[B]) do Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

{ Splits on "\r\n", "\n" or "\r"; "\r\n" counts as one newline. }
procedure SplitLines(const S: string; Lines: TStringList);
var
  I, Start, N: Integer;
begin
  N := Length(S);
  I := 1;
  if (N >= 3) and (S[1] = #$EF) and (S[2] = #$BB) and (S[3] = #$BF) then
    I := 4; // UTF-8 byte order mark
  Start := I;
  while I <= N do
    case S[I] of
      #10:
      begin
        Lines.Add(Copy(S, Start, I - Start));
        Inc(I);
        Start := I;
      end;
      #13:
      begin
        Lines.Add(Copy(S, Start, I - Start));
        Inc(I);
        if (I <= N) and (S[I] = #10) then Inc(I);
        Start := I;
      end;
    else
      Inc(I);
    end;
  if Start <= N then
    Lines.Add(Copy(S, Start, N - Start + 1));
end;

{ True if Line starts with the word KW (followed by whitespace or the end of
  the line); Rest is what follows, trimmed. }
function TakeKeyword(const Line, KW: string; out Rest: string): Boolean;
var
  N: Integer;
begin
  Rest := '';
  N := Length(KW);
  if Copy(Line, 1, N) <> KW then Exit(False);
  if (Length(Line) > N) and not IsWS(Line[N + 1]) then Exit(False);
  Rest := TrimWS(Copy(Line, N + 1, MaxInt));
  Result := True;
end;

function FirstWord(const S: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and not IsWS(S[I]) do Inc(I);
  Result := Copy(S, 1, I - 1);
end;

{ Splits S at whitespace runs. }
procedure SplitWords(const S: string; Words: TStringList);
var
  I, Start: Integer;
begin
  I := 1;
  while I <= Length(S) do
  begin
    while (I <= Length(S)) and IsWS(S[I]) do Inc(I);
    Start := I;
    while (I <= Length(S)) and not IsWS(S[I]) do Inc(I);
    if I > Start then Words.Add(Copy(S, Start, I - Start));
  end;
end;

{ TParser }

constructor TParser.Create(ADiag: TKVDiagnostics);
begin
  inherited Create;
  FDiag := ADiag;
  FLines := TStringList.Create;
end;

destructor TParser.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

{ Next line that is neither blank nor a comment. }
function TParser.NextStmt(out St: TStmt): Boolean;
var
  S: string;
begin
  while FPos < FLines.Count do
  begin
    S := TrimWS(FLines[FPos]);
    Inc(FPos);
    if (S = '') or (Copy(S, 1, 2) = '--') then Continue;
    St.Line := FPos;
    St.Text := S;
    Exit(True);
  end;
  St.Line := 0;
  St.Text := '';
  Result := False;
end;

function TParser.ParseText(const Raw: string; Line: Integer; out S: string): Boolean;
var
  I: Integer;
begin
  S := '';
  I := 1;
  while I <= Length(Raw) do
  begin
    if Raw[I] = '\' then
    begin
      if I = Length(Raw) then
      begin
        FDiag.Error(Line, 'text ends with a lone backslash (use \\ for a literal backslash)');
        Exit(False);
      end;
      case Raw[I + 1] of
        'n': S := S + #10;
        '\': S := S + '\';
      else
        FDiag.Error(Line, Format('unknown escape "\%s" (only \n and \\ exist)', [Raw[I + 1]]));
        Exit(False);
      end;
      Inc(I, 2);
    end
    else
    begin
      S := S + Raw[I];
      Inc(I);
    end;
  end;
  Result := True;
end;

{ A number as the grammar has it: digits, no leading zero, within Lo..Hi. }
function TParser.ParseCount(const Tok, What: string; Line, Lo, Hi: Integer; out V: Integer): Boolean;
var
  I: Integer;
  Big: Int64;
begin
  V := 0;
  Result := False;
  if Tok = '' then Exit;
  for I := 1 to Length(Tok) do
    if not (Tok[I] in ['0'..'9']) then
    begin
      FDiag.Error(Line, Format('%s must be a whole number, found "%s"', [What, Tok]));
      Exit;
    end;
  if (Tok[1] = '0') then
  begin
    FDiag.Error(Line, Format('%s must be between %d and %d, found "%s"', [What, Lo, Hi, Tok]));
    Exit;
  end;
  Big := 0;
  for I := 1 to Length(Tok) do
  begin
    Big := Big * 10 + Ord(Tok[I]) - Ord('0');
    if Big > Hi then Break;
  end;
  if (Big < Lo) or (Big > Hi) then
  begin
    FDiag.Error(Line, Format('%s must be between %d and %d, found "%s"', [What, Lo, Hi, Tok]));
    Exit;
  end;
  V := Big;
  Result := True;
end;

{ Fails (with a message about the config order) unless St starts with KW. }
function TParser.ExpectKeyword(const St: TStmt; const KW, Usage: string; out Rest: string): Boolean;
begin
  Result := TakeKeyword(St.Text, KW, Rest);
  if not Result then
    FDiag.Error(St.Line, Format(
      'expected "%s" here, found "%s" (the config is title, [front], [back], layout, portrait, landscape, in that order)',
      [Usage, FirstWord(St.Text)]));
end;

function TParser.ParseSize(const St: TStmt; const Rest, KW: string; out Size: TKVSize): Boolean;
var
  Words: TStringList;
  Usage: string;
begin
  Result := False;
  Usage := KW + ' width <pixels> height <pixels>';
  Words := TStringList.Create;
  try
    SplitWords(Rest, Words);
    if (Words.Count <> 4) or (Words[0] <> 'width') or (Words[2] <> 'height') then
    begin
      FDiag.Error(St.Line, 'expected "' + Usage + '"');
      Exit;
    end;
    Result := ParseCount(Words[1], KW + ' width', St.Line, 1, KVMaxPixels, Size.W) and
              ParseCount(Words[3], KW + ' height', St.Line, 1, KVMaxPixels, Size.H);
  finally
    Words.Free;
  end;
end;

function TParser.ParseConfig: Boolean;
var
  St: TStmt;
  Rest: string;
  Words: TStringList;
begin
  Result := False;

  if not NextStmt(St) then
  begin
    FDiag.Error(0, 'the file is empty, expected "title <text>"');
    Exit;
  end;
  if not ExpectKeyword(St, 'title', 'title <text>', Rest) then Exit;
  if Rest = '' then
  begin
    FDiag.Error(St.Line, 'title needs a text');
    Exit;
  end;
  if not ParseText(Rest, St.Line, FPB.Title) then Exit;

  if not NextStmt(St) then
  begin
    FDiag.Error(0, 'expected "layout rows <n> columns <n>" after the title');
    Exit;
  end;

  if TakeKeyword(St.Text, 'front', Rest) then
  begin
    if Rest = '' then
    begin
      FDiag.Error(St.Line, 'front needs a path');
      Exit;
    end;
    FPB.Front := Rest;
    FPB.FrontLine := St.Line;
    if not NextStmt(St) then
    begin
      FDiag.Error(0, 'expected "layout rows <n> columns <n>"');
      Exit;
    end;
  end;

  if TakeKeyword(St.Text, 'back', Rest) then
  begin
    if Rest = '' then
    begin
      FDiag.Error(St.Line, 'back needs a path');
      Exit;
    end;
    FPB.Back := Rest;
    FPB.BackLine := St.Line;
    if not NextStmt(St) then
    begin
      FDiag.Error(0, 'expected "layout rows <n> columns <n>"');
      Exit;
    end;
  end;

  if not ExpectKeyword(St, 'layout', 'layout rows <n> columns <n>', Rest) then Exit;
  Words := TStringList.Create;
  try
    SplitWords(Rest, Words);
    if (Words.Count <> 4) or (Words[0] <> 'rows') or (Words[2] <> 'columns') then
    begin
      FDiag.Error(St.Line, 'expected "layout rows <n> columns <n>"');
      Exit;
    end;
    if not (ParseCount(Words[1], 'rows', St.Line, 1, KVMaxGrid, FPB.Rows) and
            ParseCount(Words[3], 'columns', St.Line, 1, KVMaxGrid, FPB.Cols)) then
      Exit;
  finally
    Words.Free;
  end;

  if not NextStmt(St) then
  begin
    FDiag.Error(0, 'expected "portrait width <pixels> height <pixels>"');
    Exit;
  end;
  if not ExpectKeyword(St, 'portrait', 'portrait width <pixels> height <pixels>', Rest) then Exit;
  if not ParseSize(St, Rest, 'portrait', FPB.Portrait) then Exit;
  FPB.PortraitLine := St.Line;

  if not NextStmt(St) then
  begin
    FDiag.Error(0, 'expected "landscape width <pixels> height <pixels>"');
    Exit;
  end;
  if not ExpectKeyword(St, 'landscape', 'landscape width <pixels> height <pixels>', Rest) then Exit;
  if not ParseSize(St, Rest, 'landscape', FPB.Landscape) then Exit;
  FPB.LandscapeLine := St.Line;

  CheckSizes;
  Result := True;
end;

{ portrait must be portrait, landscape must be landscape (errors); the two
  should nest, otherwise the cell box has dead space (warning). }
procedure TParser.CheckSizes;
var
  P, L: TKVSize;
  BoxW, BoxH, Fit: Integer;
  Suggest: string;
begin
  P := FPB.Portrait;
  L := FPB.Landscape;
  if P.W >= P.H then
    FDiag.Error(FPB.PortraitLine, Format('portrait must be taller than wide, found %dx%d', [P.W, P.H]));
  if L.W <= L.H then
    FDiag.Error(FPB.LandscapeLine, Format('landscape must be wider than tall, found %dx%d', [L.W, L.H]));
  if FDiag.Errors > 0 then Exit;

  if ((P.W <= L.W) and (P.H <= L.H)) or ((L.W <= P.W) and (L.H <= P.H)) then Exit;

  BoxW := P.W;
  if L.W > BoxW then BoxW := L.W;
  BoxH := P.H;
  if L.H > BoxH then BoxH := L.H;
  Suggest := '';
  Fit := Round(P.W * L.H / L.W);
  if Fit <= P.H then
    Suggest := Format(' For a snug fit, make one size fit inside the other, e.g. landscape width %d height %d.',
      [P.W, Fit]);
  FDiag.Warn(FPB.LandscapeLine, Format(
    'portrait %dx%d and landscape %dx%d do not fit inside each other, so the cell box is %dx%d: ' +
    'portrait pictures fill %d%% of it and landscape ones %d%%.%s',
    [P.W, P.H, L.W, L.H, BoxW, BoxH,
     Round(100 * P.W * P.H / (BoxW * BoxH)), Round(100 * L.W * L.H / (BoxW * BoxH)), Suggest]));
end;

procedure TParser.AddCell(const ACell: TKVCell);
begin
  if FCur = nil then
  begin
    FCur := TKVPage.Create;
    FCur.Kind := pkGrid;
    FCur.Line := ACell.Line;
    FPB.Pages.Add(FCur);
  end;
  FCur.AddCell(ACell);
  if Length(FCur.Cells) = FPB.CellsPerPage then FCur := nil;
end;

procedure TParser.ParsePic(const St: TStmt; const Rest: string);
var
  Cell: TKVCell;
  After, Tok, Path: string;
  Anch: TKVAnchor;
  Sp: Integer;
begin
  if Rest = '' then
  begin
    FDiag.Error(St.Line, 'pic needs a path');
    Exit;
  end;
  Anch := kaC;
  Path := Rest;
  // "crop <anchor> " in front is crop, whatever the rest looks like
  if TakeKeyword(Rest, 'crop', After) and (After <> '') then
  begin
    Sp := 1;
    while (Sp <= Length(After)) and not IsWS(After[Sp]) do Inc(Sp);
    Tok := Copy(After, 1, Sp - 1);
    After := TrimWS(Copy(After, Sp, MaxInt));
    if (After <> '') and KVParseAnchor(Tok, Anch) then
      Path := After
    else
      Anch := kaC;
  end;
  Cell.Kind := ckPic;
  Cell.Path := Path;
  Cell.Anchor := Anch;
  Cell.Text := '';
  Cell.Line := St.Line;
  AddCell(Cell);
end;

procedure TParser.AddChapter(const St: TStmt; const Rest: string);
var
  Page: TKVPage;
  Filled, Per: Integer;
begin
  if Rest = '' then
  begin
    FDiag.Error(St.Line, 'chapter needs a text');
    Exit;
  end;
  if FCur <> nil then
  begin
    Filled := Length(FCur.Cells);
    Per := FPB.CellsPerPage;
    FDiag.Error(St.Line, Format(
      'chapter found on a partly filled page (%d of %d cells); %d more pic/text needed before it. ' +
      'Use bare "text" lines to fill the rest with blanks.', [Filled, Per, Per - Filled]));
    Exit;
  end;
  Page := TKVPage.Create;
  Page.Kind := pkChapter;
  Page.Line := St.Line;
  if not ParseText(Rest, St.Line, Page.Text) then
  begin
    Page.Free;
    Exit;
  end;
  FPB.Pages.Add(Page);
end;

procedure TParser.ParsePages;
var
  St: TStmt;
  Rest, Txt: string;
  Cell: TKVCell;
begin
  FCur := nil;
  while NextStmt(St) do
  begin
    if TakeKeyword(St.Text, 'pic', Rest) then
      ParsePic(St, Rest)
    else if TakeKeyword(St.Text, 'text', Rest) then
    begin
      if ParseText(Rest, St.Line, Txt) then
      begin
        Cell.Kind := ckText;
        Cell.Path := '';
        Cell.Anchor := kaC;
        Cell.Text := Txt;
        Cell.Line := St.Line;
        AddCell(Cell);
      end;
    end
    else if TakeKeyword(St.Text, 'chapter', Rest) then
      AddChapter(St, Rest)
    else if (FirstWord(St.Text) = 'title') or (FirstWord(St.Text) = 'front') or
            (FirstWord(St.Text) = 'back') or (FirstWord(St.Text) = 'layout') or
            (FirstWord(St.Text) = 'portrait') or (FirstWord(St.Text) = 'landscape') then
      FDiag.Error(St.Line, Format('"%s" belongs to the config at the top of the file', [FirstWord(St.Text)]))
    else
      FDiag.Error(St.Line, Format('unknown statement "%s" (expected pic, text or chapter)', [FirstWord(St.Text)]));
  end;
  if FPB.Pages.Count = 0 then
    FDiag.Error(0, 'the photobook has no pages (add some pic, text or chapter lines)');
end;

function TParser.Run(const Source: string): TKVPhotobook;
begin
  FPB := TKVPhotobook.Create;
  SplitLines(Source, FLines);
  FPos := 0;
  if ParseConfig then ParsePages;
  if FDiag.Errors > 0 then
  begin
    FreeAndNil(FPB);
    Exit(nil);
  end;
  Result := FPB;
end;

function KVParse(const Source: string; Diag: TKVDiagnostics): TKVPhotobook;
var
  P: TParser;
begin
  P := TParser.Create(Diag);
  try
    Result := P.Run(Source);
  finally
    P.Free;
  end;
end;

{ ---- files ---------------------------------------------------------------- }

function IsAbsolute(const P: string): Boolean;
begin
  Result := (P <> '') and (P[1] in AllowDirectorySeparators);
  {$IFDEF MSWINDOWS}
  Result := Result or ((Length(P) >= 2) and (P[2] = ':'));
  {$ENDIF}
end;

function KVResolvePath(const BaseDir, APath: string): string;
begin
  if IsAbsolute(APath) then
    Result := APath
  else
    Result := IncludeTrailingPathDelimiter(BaseDir) + APath;
end;

function KVIsSupportedImage(const FileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  Result := (Ext = '.jpg') or (Ext = '.jpeg') or (Ext = '.png');
end;

procedure CheckOne(const BaseDir, APath: string; Line: Integer; Diag: TKVDiagnostics);
var
  FN: string;
begin
  FN := KVResolvePath(BaseDir, APath);
  if not FileExists(FN) then
  begin
    if Copy(APath, 1, 5) = 'crop ' then
      Diag.Error(Line, Format(
        'file not found: "%s" (a crop prefix is "crop TL|TR|BL|BR|C <path>")', [APath]))
    else
      Diag.Error(Line, Format('file not found: "%s"', [APath]));
  end
  else if not KVIsSupportedImage(FN) then
    Diag.Error(Line, Format('unsupported image type: "%s" (only .jpg, .jpeg and .png)', [APath]));
end;

procedure KVCheckFiles(PB: TKVPhotobook; const BaseDir: string; Diag: TKVDiagnostics);
var
  I, J: Integer;
  Page: TKVPage;
begin
  if PB.Front <> '' then CheckOne(BaseDir, PB.Front, PB.FrontLine, Diag);
  if PB.Back <> '' then CheckOne(BaseDir, PB.Back, PB.BackLine, Diag);
  for I := 0 to PB.Pages.Count - 1 do
  begin
    Page := PB.Page(I);
    for J := 0 to High(Page.Cells) do
      if Page.Cells[J].Kind = ckPic then
        CheckOne(BaseDir, Page.Cells[J].Path, Page.Cells[J].Line, Diag);
  end;
end;

end.
