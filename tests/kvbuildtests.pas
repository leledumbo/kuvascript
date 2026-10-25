unit kvbuildtests;

{ Run from the repository root: the tests use examples/hello and template/. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser, kvtypes, kvparser, kvbuild;

type
  TBuildTests = class(TTestCase)
  published
    procedure TemplateFillsBothPlaceholders;
    procedure TitleIsHtmlEscapedAndNotReexpanded;
    procedure JSONIsSafeInsideScript;
    procedure BuildsTheExample;
    procedure ThreadsGiveTheSamePictures;
  end;

implementation

{ Deletes a folder written by KVBuildBook: pb.html and images/. }
procedure RemoveBuild(const Dir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(Dir + PathDelim + KVImageDir + PathDelim + '*', faAnyFile, SR) = 0 then
  try
    repeat
      DeleteFile(Dir + PathDelim + KVImageDir + PathDelim + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir + PathDelim + KVImageDir);
  DeleteFile(Dir + PathDelim + KVHtmlName);
  RemoveDir(Dir);
end;

procedure TBuildTests.TemplateFillsBothPlaceholders;
begin
  AssertEquals('<t>A</t><h1>A</h1><s>{"x":1}</s>',
    KVFillTemplate('<t>__TITLE__</t><h1>__TITLE__</h1><s>__BOOK_JSON__</s>', 'A', '{"x":1}'));
end;

procedure TBuildTests.TitleIsHtmlEscapedAndNotReexpanded;
begin
  AssertEquals('a &lt;b&gt; &amp; &quot;c&quot; __BOOK_JSON__|{}',
    KVFillTemplate('__TITLE__|__BOOK_JSON__', 'a <b> & "c" __BOOK_JSON__', '{}'));
end;

procedure TBuildTests.JSONIsSafeInsideScript;
const
  BS = #92;
var
  S: string;
begin
  S := KVScriptSafe('{"a":"</script><!-- x"}');
  AssertTrue(Pos('</', S) = 0);
  AssertTrue(Pos('<!--', S) = 0);
  AssertEquals('{"a":"<' + BS + '/script><' + BS + 'u0021-- x"}', S);
  AssertEquals(BS + 'u2028', KVScriptSafe(#$E2#$80#$A8));
  AssertEquals(BS + 'u2029', KVScriptSafe(#$E2#$80#$A9));
end;

procedure TBuildTests.BuildsTheExample;
var
  Diag: TKVDiagnostics;
  PB: TKVPhotobook;
  Opt: TKVBuildOptions;
  Stats: TKVBuildStats;
  Out_, Html, Json: string;
  L: TStringList;
  Data: TJSONData;
  Book: TJSONObject;
  P, A, B: Integer;
begin
  Out_ := GetTempDir + 'kvtests-build-' + IntToStr(GetProcessID);
  L := TStringList.Create;
  Diag := TKVDiagnostics.Create('photobook.conf');
  try
    L.LoadFromFile('examples/hello/photobook.conf');
    PB := KVParse(L.Text, Diag);
    AssertNotNull(PB);
    try
      KVCheckFiles(PB, ExpandFileName('examples/hello'), Diag);
      AssertEquals(Diag.Messages.Text, 0, Diag.Errors);
      Opt.BaseDir := ExpandFileName('examples/hello') + PathDelim;
      Opt.OutDir := Out_;
      Opt.TemplateFile := 'template/viewer.html';
      Opt.Quality := 80;
      Opt.Force := False;
      Opt.Quiet := True;
      Opt.ConfTime := 0;
      Opt.Jobs := 0;
      Stats := KVBuildBook(PB, Opt, Diag);
      AssertEquals(12, Stats.Rendered);
      // again: everything is up to date
      Stats := KVBuildBook(PB, Opt, Diag);
      AssertEquals(0, Stats.Rendered);
      AssertEquals(12, Stats.Reused);
    finally
      PB.Free;
    end;

    L.LoadFromFile(Out_ + PathDelim + KVHtmlName);
    Html := L.Text;
    AssertTrue('title filled in', Pos('<title>Hello, kuvascript', Html) > 0);
    AssertTrue('no placeholder left', (Pos('__TITLE__', Html) = 0) and (Pos('__BOOK_JSON__', Html) = 0));

    P := Pos('const BOOK = ', Html);
    AssertTrue(P > 0);
    A := P + Length('const BOOK = ');
    B := Pos('},' + #10, Copy(Html, A, MaxInt));
    Json := Copy(Html, A, B);
    Data := GetJSON(Json);
    try
      Book := Data as TJSONObject;
      AssertEquals(2, Book.Integers['rows']);
      AssertEquals(2, Book.Integers['columns']);
      AssertEquals(400, Book.Objects['portrait'].Integers['width']);
      AssertEquals(6, Book.Arrays['pages'].Count);
      AssertEquals('chapter', Book.Arrays['pages'].Objects[0].Strings['kind']);
      AssertEquals('Pictures', Book.Arrays['pages'].Objects[0].Strings['text']);
      AssertEquals('pic', Book.Arrays['pages'].Objects[1].Arrays['cells'].Objects[0].Strings['type']);
      AssertEquals('TL', Book.Arrays['pages'].Objects[1].Arrays['cells'].Objects[1].Strings['crop']);
      AssertEquals('landscape', Book.Arrays['pages'].Objects[1].Arrays['cells'].Objects[3].Strings['orient']);
      AssertEquals('Words'#10'and more', Book.Arrays['pages'].Objects[2].Strings['text']);
      AssertFalse(Book.Objects['front'].Strings['src'] = '');
      AssertEquals('TL', Book.Objects['front'].Strings['crop']);
      AssertEquals('middle', Book.Objects['front'].Objects['caption'].Strings['position']);
      AssertEquals('Hello,'#10'kuvascript', Book.Objects['front'].Objects['caption'].Strings['text']);
      AssertEquals('a tiny photobook', Book.Objects['front'].Objects['subcaption'].Strings['text']);
      AssertEquals('bottom', Book.Objects['back'].Objects['caption'].Strings['position']);
      AssertEquals('BR', Book.Objects['back'].Strings['crop']);
      AssertEquals('The end '#92'o/', Book.Objects['back'].Objects['caption'].Strings['text']);
      AssertTrue(Book.Objects['back'].Find('subcaption').IsNull);
      AssertTrue(FileExists(Out_ + PathDelim + StringReplace(Book.Objects['front'].Strings['src'], '/', PathDelim, [])));
    finally
      Data.Free;
    end;
  finally
    Diag.Free;
    L.Free;
    RemoveBuild(Out_);
  end;
end;

{ One thread and several threads must write exactly the same files. }
procedure TBuildTests.ThreadsGiveTheSamePictures;
var
  Diag: TKVDiagnostics;
  PB: TKVPhotobook;
  Opt: TKVBuildOptions;
  Stats: TKVBuildStats;
  Dir1, Dir4: string;
  L: TStringList;
  SR: TSearchRec;
  A, B: TFileStream;
  SA, SB: string;
  Count: Integer;
begin
  Dir1 := GetTempDir + 'kvtests-j1-' + IntToStr(GetProcessID);
  Dir4 := GetTempDir + 'kvtests-j4-' + IntToStr(GetProcessID);
  L := TStringList.Create;
  Diag := TKVDiagnostics.Create('photobook.conf');
  try
    L.LoadFromFile('examples/hello/photobook.conf');
    PB := KVParse(L.Text, Diag);
    AssertNotNull(PB);
    try
      Opt.BaseDir := ExpandFileName('examples/hello') + PathDelim;
      Opt.TemplateFile := 'template/viewer.html';
      Opt.Quality := 80;
      Opt.Force := True;
      Opt.Quiet := True;
      Opt.ConfTime := 0;
      Opt.OutDir := Dir1;
      Opt.Jobs := 1;
      Stats := KVBuildBook(PB, Opt, Diag);
      AssertEquals(12, Stats.Rendered);
      Opt.OutDir := Dir4;
      Opt.Jobs := 4;
      Stats := KVBuildBook(PB, Opt, Diag);
      AssertEquals(12, Stats.Rendered);
    finally
      PB.Free;
    end;

    Count := 0;
    if FindFirst(Dir1 + PathDelim + KVImageDir + PathDelim + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) <> 0 then Continue;
        A := TFileStream.Create(Dir1 + PathDelim + KVImageDir + PathDelim + SR.Name, fmOpenRead);
        B := TFileStream.Create(Dir4 + PathDelim + KVImageDir + PathDelim + SR.Name, fmOpenRead);
        try
          SetLength(SA, A.Size);
          SetLength(SB, B.Size);
          if A.Size > 0 then A.ReadBuffer(SA[1], A.Size);
          if B.Size > 0 then B.ReadBuffer(SB[1], B.Size);
          AssertTrue(SR.Name + ' differs between 1 and 4 threads', SA = SB);
          Inc(Count);
        finally
          A.Free;
          B.Free;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    AssertEquals(12, Count);
    L.LoadFromFile(Dir1 + PathDelim + KVHtmlName);
    SA := L.Text;
    L.LoadFromFile(Dir4 + PathDelim + KVHtmlName);
    AssertTrue('pb.html is the same', SA = L.Text);
  finally
    Diag.Free;
    L.Free;
    RemoveBuild(Dir1);
    RemoveBuild(Dir4);
  end;
end;

initialization
  RegisterTest(TBuildTests);

end.
