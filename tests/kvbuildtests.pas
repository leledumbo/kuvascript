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
  end;

implementation

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
      AssertTrue(FileExists(Out_ + PathDelim + StringReplace(Book.Objects['front'].Strings['src'], '/', PathDelim, [])));
    finally
      Data.Free;
    end;
  finally
    Diag.Free;
    L.Free;
  end;
end;

initialization
  RegisterTest(TBuildTests);

end.
