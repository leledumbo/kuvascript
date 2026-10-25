unit kvparsertests;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry, kvtypes, kvparser;

type
  TParserTests = class(TTestCase)
  private
    FDiag: TKVDiagnostics;
    FPB: TKVPhotobook;
    function Parse(const Source: string): TKVPhotobook;
    procedure AssertErr(const Fragment: string);
    function Head: string;
  protected
    procedure TearDown; override;
  published
    procedure MinimalBook;
    procedure Cr_Lf_And_Cr_Newlines;
    procedure CommentsBlankLinesAndIndentation;
    procedure TextEscapes;
    procedure UnknownEscapeIsAnError;
    procedure Covers;
    procedure ConfigOrderIsStrict;
    procedure TitleMustBeFirst;
    procedure LayoutRange;
    procedure LayoutNeedsRowsAndColumns;
    procedure SizeNeedsWidthAndHeight;
    procedure NumbersHaveNoLeadingZero;
    procedure PagesFollowLayout;
    procedure CropPrefix;
    procedure CropLookalikeWithoutPathIsAPath;
    procedure PathKeepsSpaces;
    procedure BareTextIsABlankCell;
    procedure ChapterOnFreshPage;
    procedure ChapterOnPartlyFilledPageIsAnError;
    procedure NoPagesIsAnError;
    procedure UnknownStatement;
    procedure ConfigStatementAfterConfig;
    procedure KeywordsNeedAWordBoundary;
    procedure PortraitMustBePortrait;
    procedure NestedSizesDoNotWarn;
    procedure UnnestedSizesWarnWithSuggestion;
    procedure MissingFileIsReported;
  end;

implementation

const
  Conf = 'title T'#10'layout rows 1 columns 2'#10'portrait width 800 height 1200'#10 +
         'landscape width 800 height 533'#10;

function TParserTests.Head: string;
begin
  Result := Conf;
end;

function TParserTests.Parse(const Source: string): TKVPhotobook;
begin
  FreeAndNil(FDiag);
  FreeAndNil(FPB);
  FDiag := TKVDiagnostics.Create('t.conf');
  FPB := KVParse(Source, FDiag);
  Result := FPB;
end;

procedure TParserTests.TearDown;
begin
  FreeAndNil(FDiag);
  FreeAndNil(FPB);
end;

procedure TParserTests.AssertErr(const Fragment: string);
begin
  AssertTrue('expected an error, got none', FDiag.Errors > 0);
  AssertTrue('error "' + FDiag.Messages.Text + '" should mention "' + Fragment + '"',
    Pos(Fragment, FDiag.Messages.Text) > 0);
end;

procedure TParserTests.MinimalBook;
begin
  AssertNotNull(Parse(Head + 'pic a.jpg'#10));
  AssertEquals('T', FPB.Title);
  AssertEquals(1, FPB.Rows);
  AssertEquals(2, FPB.Cols);
  AssertEquals(800, FPB.Portrait.W);
  AssertEquals(1200, FPB.Portrait.H);
  AssertEquals(533, FPB.Landscape.H);
  AssertEquals(1, FPB.Pages.Count);
  AssertEquals(0, FDiag.Warnings);
end;

procedure TParserTests.Cr_Lf_And_Cr_Newlines;
begin
  AssertNotNull(Parse('title T'#13#10'layout rows 1 columns 1'#13'portrait width 1 height 2'#10 +
    'landscape width 2 height 1'#13#10'pic a.jpg'#13#10#13#10'pic b.jpg'));
  AssertEquals(2, FPB.Pages.Count);
  // a UTF-8 BOM in front is ignored
  AssertNotNull(Parse(#$EF#$BB#$BF + Head + 'pic a.jpg'));
end;

procedure TParserTests.CommentsBlankLinesAndIndentation;
begin
  AssertNotNull(Parse('-- leading comment'#10#10'  title   T  '#10'-- x \q'#10 +
    #9'layout   rows 1   columns 2 '#10'portrait width 800 height 1200'#10 +
    'landscape width 800 height 533'#10'   --'#10'  pic   a.jpg   '#10));
  AssertEquals('T', FPB.Title);
  AssertEquals('a.jpg', FPB.Page(0).Cells[0].Path);
end;

procedure TParserTests.TextEscapes;
begin
  AssertNotNull(Parse(Head + 'text one\ntwo \\ three'#10));
  AssertEquals('one'#10'two \ three', FPB.Page(0).Cells[0].Text);
end;

procedure TParserTests.UnknownEscapeIsAnError;
begin
  AssertNull(Parse(Head + 'text a\tb'#10));
  AssertErr('unknown escape');
  AssertNull(Parse(Head + 'text trailing\'#10));
  AssertErr('lone backslash');
end;

procedure TParserTests.Covers;
begin
  AssertNotNull(Parse('title T'#10'front f.jpg'#10'back b b.png'#10 +
    'layout rows 1 columns 1'#10'portrait width 1 height 2'#10'landscape width 2 height 1'#10'pic a.jpg'));
  AssertEquals('f.jpg', FPB.Front);
  AssertEquals('b b.png', FPB.Back);
  AssertNotNull(Parse('title T'#10'back b.png'#10'layout rows 1 columns 1'#10 +
    'portrait width 1 height 2'#10'landscape width 2 height 1'#10'pic a.jpg'));
  AssertEquals('', FPB.Front);
  AssertNull(Parse('title T'#10'back b.png'#10'front f.png'#10'layout rows 1 columns 1'#10 +
    'portrait width 1 height 2'#10'landscape width 2 height 1'#10'pic a.jpg'));
  AssertErr('layout');
end;

procedure TParserTests.ConfigOrderIsStrict;
begin
  AssertNull(Parse('title T'#10'portrait width 800 height 1200'#10'layout rows 1 columns 1'#10));
  AssertErr('expected "layout');
  AssertNull(Parse('title T'#10'layout rows 1 columns 1'#10'landscape width 800 height 533'#10));
  AssertErr('expected "portrait');
end;

procedure TParserTests.TitleMustBeFirst;
begin
  AssertNull(Parse('layout rows 1 columns 1'#10));
  AssertErr('expected "title');
  AssertNull(Parse(''));
  AssertErr('empty');
  AssertNull(Parse('title'#10));
  AssertErr('title needs a text');
end;

procedure TParserTests.LayoutRange;
const
  Tail = 'portrait width 1 height 2'#10'landscape width 2 height 1'#10'pic a'#10;
begin
  AssertNotNull(Parse('title T'#10'layout rows 3 columns 3'#10 + Tail));
  AssertNull(Parse('title T'#10'layout rows 4 columns 1'#10 + Tail));
  AssertErr('rows must be between 1 and 3');
  AssertNull(Parse('title T'#10'layout rows 1 columns 0'#10 + Tail));
  AssertErr('columns must be between 1 and 3');
  AssertNull(Parse('title T'#10'layout rows x columns 1'#10 + Tail));
  AssertErr('whole number');
end;

procedure TParserTests.LayoutNeedsRowsAndColumns;
begin
  AssertNull(Parse('title T'#10'layout 3x2'#10));
  AssertErr('layout rows <n> columns <n>');
  AssertNull(Parse('title T'#10'layout columns 2 rows 3'#10));
  AssertErr('layout rows <n> columns <n>');
end;

procedure TParserTests.SizeNeedsWidthAndHeight;
begin
  AssertNull(Parse('title T'#10'layout rows 1 columns 1'#10'portrait 800x1200'#10));
  AssertErr('portrait width <pixels> height <pixels>');
end;

procedure TParserTests.NumbersHaveNoLeadingZero;
begin
  AssertNull(Parse('title T'#10'layout rows 1 columns 1'#10'portrait width 0800 height 1200'#10));
  AssertErr('between 1 and');
  AssertNull(Parse('title T'#10'layout rows 1 columns 1'#10'portrait width 99999 height 1200'#10));
  AssertErr('between 1 and');
end;

procedure TParserTests.PagesFollowLayout;
var
  I: Integer;
  S: string;
begin
  S := 'title T'#10'layout rows 2 columns 3'#10'portrait width 1 height 2'#10'landscape width 2 height 1'#10;
  for I := 1 to 9 do S := S + 'pic f' + IntToStr(I) + '.jpg'#10;
  AssertNotNull(Parse(S));
  AssertEquals(2, FPB.Pages.Count);
  AssertEquals(6, Length(FPB.Page(0).Cells));
  AssertEquals(3, Length(FPB.Page(1).Cells));
  AssertEquals('f7.jpg', FPB.Page(1).Cells[0].Path);
end;

procedure TParserTests.CropPrefix;
begin
  AssertNotNull(Parse(Head + 'pic crop TL a b.jpg'#10'pic crop BR  c.jpg'#10'pic d.jpg'#10));
  AssertTrue(FPB.Page(0).Cells[0].Anchor = kaTL);
  AssertEquals('a b.jpg', FPB.Page(0).Cells[0].Path);
  AssertTrue(FPB.Page(0).Cells[1].Anchor = kaBR);
  AssertTrue(FPB.Page(1).Cells[0].Anchor = kaC);
end;

procedure TParserTests.CropLookalikeWithoutPathIsAPath;
begin
  // "crop XX" is no anchor, "crop TL" has no path after it: both are plain paths
  AssertNotNull(Parse(Head + 'pic crop XX a.jpg'#10'pic crop TL'#10));
  AssertTrue(FPB.Page(0).Cells[0].Anchor = kaC);
  AssertEquals('crop XX a.jpg', FPB.Page(0).Cells[0].Path);
  AssertEquals('crop TL', FPB.Page(0).Cells[1].Path);
  AssertNotNull(Parse(Head + 'pic cropped.jpg'#10));
  AssertEquals('cropped.jpg', FPB.Page(0).Cells[0].Path);
end;

procedure TParserTests.PathKeepsSpaces;
begin
  AssertNotNull(Parse(Head + 'pic  my holiday \ photos\a.jpg '#10));
  AssertEquals('my holiday \ photos\a.jpg', FPB.Page(0).Cells[0].Path);
end;

procedure TParserTests.BareTextIsABlankCell;
begin
  AssertNotNull(Parse(Head + 'text'#10'text   '#10));
  AssertTrue(FPB.Page(0).Cells[0].Kind = ckText);
  AssertEquals('', FPB.Page(0).Cells[0].Text);
  AssertEquals(2, Length(FPB.Page(0).Cells));
end;

procedure TParserTests.ChapterOnFreshPage;
begin
  AssertNotNull(Parse(Head + 'chapter Intro\nduction'#10'pic a.jpg'#10'pic b.jpg'#10'chapter Two'#10));
  AssertEquals(3, FPB.Pages.Count);
  AssertTrue(FPB.Page(0).Kind = pkChapter);
  AssertEquals('Intro'#10'duction', FPB.Page(0).Text);
  AssertTrue(FPB.Page(1).Kind = pkGrid);
  AssertTrue(FPB.Page(2).Kind = pkChapter);
end;

procedure TParserTests.ChapterOnPartlyFilledPageIsAnError;
begin
  AssertNull(Parse(Head + 'pic a.jpg'#10'chapter Oops'#10));
  AssertErr('t.conf:6: error: chapter found on a partly filled page (1 of 2 cells); 1 more pic/text needed');
end;

procedure TParserTests.NoPagesIsAnError;
begin
  AssertNull(Parse(Head + '-- nothing here'#10));
  AssertErr('no pages');
end;

procedure TParserTests.UnknownStatement;
begin
  AssertNull(Parse(Head + 'picture a.jpg'#10));
  AssertErr('unknown statement "picture"');
  AssertNull(Parse(Head + 'pic'#10));
  AssertErr('pic needs a path');
end;

procedure TParserTests.ConfigStatementAfterConfig;
begin
  AssertNull(Parse(Head + 'pic a.jpg'#10'title again'#10));
  AssertErr('belongs to the config');
end;

procedure TParserTests.KeywordsNeedAWordBoundary;
begin
  AssertNull(Parse(Head + 'textual'#10));
  AssertErr('unknown statement "textual"');
  AssertNull(Parse(Head + 'chapters x'#10));
  AssertErr('unknown statement');
end;

procedure TParserTests.PortraitMustBePortrait;
begin
  AssertNull(Parse('title T'#10'layout rows 1 columns 1'#10'portrait width 1200 height 800'#10 +
    'landscape width 800 height 533'#10'pic a'#10));
  AssertErr('portrait must be taller than wide');
  AssertNull(Parse('title T'#10'layout rows 1 columns 1'#10'portrait width 800 height 1200'#10 +
    'landscape width 533 height 800'#10'pic a'#10));
  AssertErr('landscape must be wider than tall');
end;

procedure TParserTests.NestedSizesDoNotWarn;
begin
  AssertNotNull(Parse(Head + 'pic a'#10));
  AssertEquals(0, FDiag.Warnings);
end;

procedure TParserTests.UnnestedSizesWarnWithSuggestion;
begin
  AssertNotNull(Parse('title T'#10'layout rows 1 columns 1'#10'portrait width 800 height 1200'#10 +
    'landscape width 1200 height 800'#10'pic a'#10));
  AssertEquals(1, FDiag.Warnings);
  AssertEquals(0, FDiag.Errors);
  AssertTrue(Pos('cell box is 1200x1200', FDiag.Messages.Text) > 0);
  AssertTrue(Pos('landscape width 800 height 533', FDiag.Messages.Text) > 0);
end;

procedure TParserTests.MissingFileIsReported;
var
  D: TKVDiagnostics;
begin
  AssertNotNull(Parse(Head + 'pic crop TL /nonexistent/a.jpg'#10'pic /nonexistent/b.txt'#10));
  D := TKVDiagnostics.Create('t.conf');
  try
    KVCheckFiles(FPB, '/', D);
    AssertEquals(2, D.Errors);
    AssertTrue(Pos('file not found: "/nonexistent/a.jpg"', D.Messages.Text) > 0);
  finally
    D.Free;
  end;
end;

initialization
  RegisterTest(TParserTests);

end.
