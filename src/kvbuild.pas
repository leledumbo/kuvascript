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
    Jobs: Integer;          // pictures rendered at the same time, 0 = one per available thread
  end;

  TKVBuildStats = record
    Rendered, Reused: Integer;
  end;

const
  KVHtmlName = 'pb.html';
  KVImageDir = 'images';

{ Number of threads that can run at the same time here (at least 1). }
function KVCpuCount: Integer;

{ Raises EKVImage or EInOutError on failure; warnings go to Diag. }
function KVBuildBook(PB: TKVPhotobook; const Opt: TKVBuildOptions; Diag: TKVDiagnostics): TKVBuildStats;

{ Placeholder substitution, exposed for tests. }
function KVFillTemplate(const Template, Title, BookJSON: string): string;
function KVHtmlEscape(const S: string): string;
function KVScriptSafe(const JSON: string): string;

implementation

type
  TRenderJob = record
    Path: string;       // as written in the conf, for messages
    Source, Dest: string;
    Rel: string;
    W, H: Integer;
    Anchor: TKVAnchor;
  end;

  TBuilder = class;

  { Takes jobs off the builder's list until it is empty. }
  TRenderWorker = class(TThread)
  private
    FOwner: TBuilder;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TBuilder);
  end;

  TBuilder = class
  private
    FPB: TKVPhotobook;
    FOpt: TKVBuildOptions;
    FDiag: TKVDiagnostics;
    FStats: TKVBuildStats;
    FDone: specialize TDictionary<string, string>;   // job key -> relative file
    FInfos: specialize TDictionary<string, TKVImageInfo>;
    FJobs: array of TRenderJob;
    FNext: Integer;            // next job to take, shared by the workers
    FLock: TRTLCriticalSection;
    FFailure: string;          // first error of any worker, '' = none
    FStarted: Integer;
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
    procedure RunJob(Index: Integer);
    procedure RunJobs;
    procedure WorkerLoop;
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
  InitCriticalSection(FLock);
end;

destructor TBuilder.Destroy;
begin
  DoneCriticalSection(FLock);
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

{ Plans the rendering of Path as TW x TH and returns the file name relative to
  the output folder. Nothing is rendered here: a picture that is not up to date
  becomes a job, run later by RunJobs, possibly several at a time. The file name
  carries a hash of everything that influences the picture, so a file that exists
  is a file that is right, as long as it is newer than its source. }
function TBuilder.Render(const Path: string; Line: Integer; TW, TH: Integer;
  Anchor: TKVAnchor; const Prefix: string): string;
var
  Full, Key, Rel, Dest: string;
  SrcTime, DestTime: TDateTime;
  Hash: QWord;
  Inf: TKVImageInfo;
  Job: TRenderJob;
begin
  Full := KVResolvePath(FOpt.BaseDir, Path);
  Key := Format('%s|%dx%d|%s|q%d', [ExpandFileName(Full), TW, TH, KVAnchorName(Anchor), FOpt.Quality]);
  if FDone.TryGetValue(Key, Result) then Exit;

  Hash := Fnv64(Key);
  Rel := KVImageDir + '/' + Prefix + SafeBase(Full) + '-' + LowerCase(IntToHex(Hash, 16)) + '.jpg';
  Dest := IncludeTrailingPathDelimiter(FOpt.OutDir) + Rel;

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
    Job.Path := Path;
    Job.Source := Full;
    Job.Dest := Dest;
    Job.Rel := Rel;
    Job.W := TW;
    Job.H := TH;
    Job.Anchor := Anchor;
    SetLength(FJobs, Length(FJobs) + 1);
    FJobs[High(FJobs)] := Job;
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

{ ---- rendering the planned pictures --------------------------------------- }

function KVCpuCount: Integer;
begin
  Result := TThread.ProcessorCount;
  if Result < 1 then Result := 1;
end;

procedure TBuilder.RunJob(Index: Integer);
var
  Job: TRenderJob;
begin
  Job := FJobs[Index];
  if not FOpt.Quiet then
  begin
    EnterCriticalSection(FLock);
    try
      Inc(FStarted);
      WriteLn(Format('[%d/%d] %s -> %s (%dx%d)', [FStarted, Length(FJobs), Job.Path, Job.Rel, Job.W, Job.H]));
      Flush(Output);
    finally
      LeaveCriticalSection(FLock);
    end;
  end;
  KVRenderCover(Job.Source, Job.Dest, Job.W, Job.H, Job.Anchor, FOpt.Quality);
end;

{ Used by every worker (and by the main thread when there is just one). After a
  failure the others stop taking new jobs, the pictures in flight are finished. }
procedure TBuilder.WorkerLoop;
var
  I: Integer;
begin
  repeat
    if FFailure <> '' then Exit;
    I := InterlockedIncrement(FNext) - 1;
    if I >= Length(FJobs) then Exit;
    try
      RunJob(I);
    except
      on E: Exception do
      begin
        EnterCriticalSection(FLock);
        try
          if FFailure = '' then FFailure := E.Message;
        finally
          LeaveCriticalSection(FLock);
        end;
      end;
    end;
  until False;
end;

constructor TRenderWorker.Create(AOwner: TBuilder);
begin
  FOwner := AOwner;
  inherited Create(False);
end;

procedure TRenderWorker.Execute;
begin
  FOwner.WorkerLoop;
end;

procedure TBuilder.RunJobs;
var
  Count, I: Integer;
  Workers: array of TRenderWorker;
begin
  if Length(FJobs) = 0 then Exit;
  Count := FOpt.Jobs;
  if Count <= 0 then Count := KVCpuCount;
  if Count > Length(FJobs) then Count := Length(FJobs);
  FNext := 0;
  FStarted := 0;
  FFailure := '';
  if (Count > 1) and not FOpt.Quiet then
    WriteLn(Format('rendering %d pictures with %d threads', [Length(FJobs), Count]));
  if Count <= 1 then
    WorkerLoop
  else
  begin
    SetLength(Workers, Count);
    for I := 0 to Count - 1 do
      Workers[I] := TRenderWorker.Create(Self);
    for I := 0 to Count - 1 do
    begin
      Workers[I].WaitFor;
      Workers[I].Free;
    end;
  end;
  if FFailure <> '' then raise EKVImage.Create(FFailure);
  FStats.Rendered := Length(FJobs);
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
  FJobs := nil;
  if not ForceDirectories(IncludeTrailingPathDelimiter(FOpt.OutDir) + KVImageDir) then
    raise EInOutError.CreateFmt('cannot create %s', [FOpt.OutDir]);
  Template := ReadWholeFile(FOpt.TemplateFile);
  if (Pos('__TITLE__', Template) = 0) or (Pos('__BOOK_JSON__', Template) = 0) then
    raise EInOutError.CreateFmt('%s is not a pbgen template (placeholders __TITLE__ and __BOOK_JSON__ missing)',
      [FOpt.TemplateFile]);

  Book := BookToJSON;   // plans the pictures too
  try
    RunJobs;
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
