unit kvbuild;

{ Turns a parsed photobook into a folder: the rendered pictures plus pb.html,
  which is the template with the title and the book data filled in. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, Generics.Collections, fpjson, kvtypes, kvparser, kvimage;

type
  TKVBuildOptions = record
    BaseDir: string;        // where photobook.conf lives, pic paths are relative to it
    OutDir: string;
    TemplateFile: string;
    Quality: Integer;       // JPEG quality 1..100
    Force: Boolean;         // re-render even if an up to date picture exists
    Quiet: Boolean;
    ConfTime: TDateTime;    // modification time of photobook.conf
  end;

  TKVBuildStats = record
    Rendered, Reused: Integer;
  end;

const
  KVHtmlName = 'pb.html';
  KVImageDir = 'images';

{ Raises EKVImage or EInOutError on failure; warnings go to Diag. }
function KVBuildBook(PB: TKVPhotobook; const Opt: TKVBuildOptions; Diag: TKVDiagnostics): TKVBuildStats;

{ Placeholder substitution, exposed for tests. }
function KVFillTemplate(const Template, Title, BookJSON: string): string;
function KVHtmlEscape(const S: string): string;
function KVScriptSafe(const JSON: string): string;

implementation

type
  TBuilder = class
  private
    FPB: TKVPhotobook;
    FOpt: TKVBuildOptions;
    FDiag: TKVDiagnostics;
    FStats: TKVBuildStats;
    FDone: specialize TDictionary<string, string>;   // job key -> relative file
    FInfos: specialize TDictionary<string, TKVImageInfo>;
    FTotal, FCount: Integer;
    function Info(const FullPath: string; Line: Integer): TKVImageInfo;
    function Render(const Path: string; Line: Integer; TW, TH: Integer;
      Anchor: TKVAnchor; const Prefix: string): string;
    function CellToJSON(const Cell: TKVCell): TJSONObject;
    function PageToJSON(Page: TKVPage): TJSONObject;
    function SizeToJSON(const S: TKVSize): TJSONObject;
    function CaptionToJSON(const Cap: TKVCaption; WithPosition: Boolean): TJSONData;
    function CoverToJSON(const Path: string; Line: Integer; Anchor: TKVAnchor;
      const Cap, Sub: TKVCaption): TJSONData;
    function BookToJSON: TJSONObject;
    procedure CountJobs;
  public
    constructor Create(APB: TKVPhotobook; const AOpt: TKVBuildOptions; ADiag: TKVDiagnostics);
    destructor Destroy; override;
    function Run: TKVBuildStats;
  end;

{ ---- small helpers ---------------------------------------------------------- }

function Fnv64(const S: string): QWord;
var
  I: Integer;
begin
  Result := QWord($CBF29CE484222325);
  for I := 1 to Length(S) do
    Result := (Result xor Ord(S[I])) * QWord($100000001B3);
end;

{ File name made of safe characters only. }
function SafeBase(const FileName: string): string;
var
  I: Integer;
begin
  Result := ChangeFileExt(ExtractFileName(FileName), '');
  for I := 1 to Length(Result) do
    if not (Result[I] in ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-']) then
      Result[I] := '_';
  if Length(Result) > 40 then SetLength(Result, 40);
  if Result = '' then Result := 'img';
end;

function KVHtmlEscape(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&#39;';
      #10, #13: Result := Result + ' ';
    else
      Result := Result + S[I];
    end;
end;

{ Makes JSON safe to sit inside <script>: no "</script>", no "<!--", and none of
  the line separators that older JavaScript treats as line breaks in strings. }
function KVScriptSafe(const JSON: string): string;
const
  Backslash = #92;
begin
  Result := StringReplace(JSON, '</', '<' + Backslash + '/', [rfReplaceAll]);
  Result := StringReplace(Result, '<!--', '<' + Backslash + 'u0021--', [rfReplaceAll]);
  Result := StringReplace(Result, #$E2#$80#$A8, Backslash + 'u2028', [rfReplaceAll]);
  Result := StringReplace(Result, #$E2#$80#$A9, Backslash + 'u2029', [rfReplaceAll]);
end;

{ One pass, so a title that happens to contain a placeholder is left alone. }
function KVFillTemplate(const Template, Title, BookJSON: string): string;
const
  PTitle = '__TITLE__';
  PBook = '__BOOK_JSON__';
var
  PT, PB: Integer;
  Rest: string;
begin
  Result := '';
  Rest := Template;
  repeat
    PT := Pos(PTitle, Rest);
    PB := Pos(PBook, Rest);
    if (PT = 0) and (PB = 0) then Break;
    if (PB = 0) or ((PT > 0) and (PT < PB)) then
    begin
      Result := Result + Copy(Rest, 1, PT - 1) + KVHtmlEscape(Title);
      Delete(Rest, 1, PT + Length(PTitle) - 1);
    end
    else
    begin
      Result := Result + Copy(Rest, 1, PB - 1) + KVScriptSafe(BookJSON);
      Delete(Rest, 1, PB + Length(PBook) - 1);
    end;
  until False;
  Result := Result + Rest;
end;

function ReadWholeFile(const FileName: string): string;
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

procedure WriteWholeFile(const FileName, Data: string);
var
  S: TFileStream;
begin
  S := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Data) > 0 then S.WriteBuffer(Data[1], Length(Data));
  finally
    S.Free;
  end;
end;

{ ---- TBuilder ------------------------------------------------------------------- }

constructor TBuilder.Create(APB: TKVPhotobook; const AOpt: TKVBuildOptions; ADiag: TKVDiagnostics);
begin
  inherited Create;
  FPB := APB;
  FOpt := AOpt;
  FDiag := ADiag;
  FDone := specialize TDictionary<string, string>.Create;
  FInfos := specialize TDictionary<string, TKVImageInfo>.Create;
end;

destructor TBuilder.Destroy;
begin
  FDone.Free;
  FInfos.Free;
  inherited Destroy;
end;

function TBuilder.Info(const FullPath: string; Line: Integer): TKVImageInfo;
begin
  if not FInfos.TryGetValue(FullPath, Result) then
  begin
    try
      Result := KVImageInfo(FullPath);
    except
      on E: EKVImage do
      begin
        FDiag.Error(Line, E.Message);
        raise;
      end;
    end;
    FInfos.Add(FullPath, Result);
  end;
end;

{ Renders (or finds already rendered) Path as TW x TH; returns the file name
  relative to the output folder. The file name carries a hash of everything
  that influences the picture, so a file that exists is a file that is right,
  as long as it is newer than its source. }
function TBuilder.Render(const Path: string; Line: Integer; TW, TH: Integer;
  Anchor: TKVAnchor; const Prefix: string): string;
var
  Full, Key, Rel, Dest: string;
  SrcTime, DestTime: TDateTime;
  Hash: QWord;
  Inf: TKVImageInfo;
begin
  Full := KVResolvePath(FOpt.BaseDir, Path);
  Key := Format('%s|%dx%d|%s|q%d', [ExpandFileName(Full), TW, TH, KVAnchorName(Anchor), FOpt.Quality]);
  if FDone.TryGetValue(Key, Result) then Exit;

  Hash := Fnv64(Key);
  Rel := KVImageDir + '/' + Prefix + SafeBase(Full) + '-' + LowerCase(IntToHex(Hash, 16)) + '.jpg';
  Dest := IncludeTrailingPathDelimiter(FOpt.OutDir) + Rel;

  Inc(FCount);
  Inf := Info(Full, Line);
  if (Inf.Width < TW) or (Inf.Height < TH) then
    FDiag.Warn(Line, Format('%s is %dx%d, smaller than the %dx%d it is shown at; it will be enlarged',
      [Path, Inf.Width, Inf.Height, TW, TH]));

  if (not FOpt.Force) and FileExists(Dest) and
     FileAge(Dest, DestTime) and FileAge(Full, SrcTime) and
     (DestTime >= SrcTime) then
    Inc(FStats.Reused)
  else
  begin
    if not FOpt.Quiet then
      WriteLn(Format('[%d/%d] %s -> %s (%dx%d)', [FCount, FTotal, Path, Rel, TW, TH]));
    KVRenderCover(Full, Dest, TW, TH, Anchor, FOpt.Quality);
    Inc(FStats.Rendered);
  end;
  FDone.Add(Key, Rel);
  Result := Rel;
end;

function TBuilder.SizeToJSON(const S: TKVSize): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('width', S.W);
  Result.Add('height', S.H);
end;

function TBuilder.CellToJSON(const Cell: TKVCell): TJSONObject;
var
  Full: string;
  Inf: TKVImageInfo;
  Landscape: Boolean;
  Size: TKVSize;
begin
  Result := TJSONObject.Create;
  try
    if Cell.Kind = ckText then
    begin
      Result.Add('type', 'text');
      Result.Add('text', Cell.Text);
      Exit;
    end;
    Full := KVResolvePath(FOpt.BaseDir, Cell.Path);
    Inf := Info(Full, Cell.Line);
    Landscape := Inf.Width >= Inf.Height;
    if Landscape then Size := FPB.Landscape else Size := FPB.Portrait;
    Result.Add('type', 'pic');
    Result.Add('src', Render(Cell.Path, Cell.Line, Size.W, Size.H, Cell.Anchor, ''));
    Result.Add('alt', ChangeFileExt(ExtractFileName(Full), ''));
    if Landscape then
      Result.Add('orient', 'landscape')
    else
      Result.Add('orient', 'portrait');
    Result.Add('crop', KVAnchorName(Cell.Anchor));
  except
    Result.Free;
    raise;
  end;
end;

function TBuilder.PageToJSON(Page: TKVPage): TJSONObject;
var
  Cells: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  try
    if Page.Kind = pkChapter then
    begin
      Result.Add('kind', 'chapter');
      Result.Add('text', Page.Text);
    end
    else
    begin
      Result.Add('kind', 'grid');
      Cells := TJSONArray.Create;
      Result.Add('cells', Cells);
      for I := 0 to High(Page.Cells) do
        Cells.Add(CellToJSON(Page.Cells[I]));
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ The caption is kept while it is written, even without a text: a subcaption
  needs its position. A subcaption without a text is nothing. }
function TBuilder.CaptionToJSON(const Cap: TKVCaption; WithPosition: Boolean): TJSONData;
var
  O: TJSONObject;
begin
  if (not Cap.Present) or ((Cap.Text = '') and not WithPosition) then Exit(TJSONNull.Create);
  O := TJSONObject.Create;
  if WithPosition then O.Add('position', KVCapPosName(Cap.Pos));
  O.Add('text', Cap.Text);
  Result := O;
end;

{ A cover is cut to the size of one cell box, as a page with layout 1x1 would be;
  whatever the layout, the viewer fits it to the page. }
function TBuilder.CoverToJSON(const Path: string; Line: Integer; Anchor: TKVAnchor;
  const Cap, Sub: TKVCaption): TJSONData;
var
  O: TJSONObject;
  W, H: Integer;
begin
  if Path = '' then Exit(TJSONNull.Create);
  W := Max(FPB.Portrait.W, FPB.Landscape.W);
  H := Max(FPB.Portrait.H, FPB.Landscape.H);
  O := TJSONObject.Create;
  try
    O.Add('src', Render(Path, Line, W, H, Anchor, 'cover-'));
    O.Add('alt', ChangeFileExt(ExtractFileName(Path), ''));
    O.Add('crop', KVAnchorName(Anchor));
    O.Add('caption', CaptionToJSON(Cap, True));
    O.Add('subcaption', CaptionToJSON(Sub, False));
  except
    O.Free;
    raise;
  end;
  Result := O;
end;

procedure TBuilder.CountJobs;
var
  I, J: Integer;
  Seen: specialize TDictionary<string, Boolean>;
  Page: TKVPage;
  Cell: TKVCell;
begin
  // only for the "[n/total]" in the progress lines; a rough count is fine
  Seen := specialize TDictionary<string, Boolean>.Create;
  try
    if FPB.Front <> '' then Seen.AddOrSetValue('front|' + KVAnchorName(FPB.FrontAnchor), True);
    if FPB.Back <> '' then Seen.AddOrSetValue('back|' + KVAnchorName(FPB.BackAnchor), True);
    for I := 0 to FPB.Pages.Count - 1 do
    begin
      Page := FPB.Page(I);
      for J := 0 to High(Page.Cells) do
      begin
        Cell := Page.Cells[J];
        if Cell.Kind = ckPic then
          Seen.AddOrSetValue(Cell.Path + '|' + KVAnchorName(Cell.Anchor), True);
      end;
    end;
    FTotal := Seen.Count;
  finally
    Seen.Free;
  end;
end;

function TBuilder.BookToJSON: TJSONObject;
var
  Pages: TJSONArray;
  I: Integer;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('title', FPB.Title);
    Result.Add('rows', FPB.Rows);
    Result.Add('columns', FPB.Cols);
    Result.Add('portrait', SizeToJSON(FPB.Portrait));
    Result.Add('landscape', SizeToJSON(FPB.Landscape));
    Result.Add('front', CoverToJSON(FPB.Front, FPB.FrontLine, FPB.FrontAnchor,
      FPB.FrontCaption, FPB.FrontSubcaption));
    Result.Add('back', CoverToJSON(FPB.Back, FPB.BackLine, FPB.BackAnchor,
      FPB.BackCaption, FPB.BackSubcaption));
    Pages := TJSONArray.Create;
    Result.Add('pages', Pages);
    for I := 0 to FPB.Pages.Count - 1 do
      Pages.Add(PageToJSON(FPB.Page(I)));
  except
    Result.Free;
    raise;
  end;
end;

function TBuilder.Run: TKVBuildStats;
var
  Book: TJSONObject;
  Template, Html: string;
begin
  FStats.Rendered := 0;
  FStats.Reused := 0;
  FCount := 0;
  CountJobs;
  if not ForceDirectories(IncludeTrailingPathDelimiter(FOpt.OutDir) + KVImageDir) then
    raise EInOutError.CreateFmt('cannot create %s', [FOpt.OutDir]);
  Template := ReadWholeFile(FOpt.TemplateFile);
  if (Pos('__TITLE__', Template) = 0) or (Pos('__BOOK_JSON__', Template) = 0) then
    raise EInOutError.CreateFmt('%s is not a pbgen template (placeholders __TITLE__ and __BOOK_JSON__ missing)',
      [FOpt.TemplateFile]);

  Book := BookToJSON;
  try
    Html := KVFillTemplate(Template, FPB.Title, Book.AsJSON);
  finally
    Book.Free;
  end;
  WriteWholeFile(IncludeTrailingPathDelimiter(FOpt.OutDir) + KVHtmlName, Html);
  Result := FStats;
end;

function KVBuildBook(PB: TKVPhotobook; const Opt: TKVBuildOptions; Diag: TKVDiagnostics): TKVBuildStats;
var
  B: TBuilder;
begin
  B := TBuilder.Create(PB, Opt, Diag);
  try
    Result := B.Run;
  finally
    B.Free;
  end;
end;

end.
