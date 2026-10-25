unit kvtypes;

{ In-memory form of a photobook.conf, plus the diagnostics collector. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Contnrs;

type
  TKVAnchor = (kaC, kaTL, kaTR, kaBL, kaBR);

  TKVCellKind = (ckPic, ckText);

  TKVCapPos = (cpTop, cpMiddle, cpBottom);

  { A caption or subcaption line of a cover. Present is True when the line was
    written, even if it has no text (that only earns a warning). }
  TKVCaption = record
    Present: Boolean;
    Pos: TKVCapPos;
    Text: string;       // escapes already resolved
    Line: Integer;
  end;

  TKVCell = record
    Kind: TKVCellKind;
    Path: string;       // pic: the path as written in the conf
    Anchor: TKVAnchor;  // pic: which part of the picture survives cropping
    Text: string;       // text: escapes already resolved
    Line: Integer;
  end;

  TKVPageKind = (pkGrid, pkChapter);

  TKVPage = class
  public
    Kind: TKVPageKind;
    Text: string;       // chapter title
    Line: Integer;
    Cells: array of TKVCell;
    procedure AddCell(const ACell: TKVCell);
  end;

  TKVSize = record
    W, H: Integer;
  end;

  TKVPhotobook = class
  public
    Title: string;
    Front, Back: string;            // cover paths, '' = none
    FrontLine, BackLine: Integer;
    FrontAnchor, BackAnchor: TKVAnchor;
    FrontCaption, FrontSubcaption: TKVCaption;
    BackCaption, BackSubcaption: TKVCaption;
    Rows, Cols: Integer;
    Portrait, Landscape: TKVSize;
    PortraitLine, LandscapeLine: Integer;
    Pages: TObjectList;             // of TKVPage
    constructor Create;
    destructor Destroy; override;
    function CellsPerPage: Integer;
    function Page(AIndex: Integer): TKVPage;
  end;

  { Collects "file:line: error|warning: message" lines. }
  TKVDiagnostics = class
  private
    FFileName: string;
    FMessages: TStringList;
    FErrors, FWarnings: Integer;
    procedure Add(const Severity: string; ALine: Integer; const Msg: string);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    procedure Error(ALine: Integer; const Msg: string);
    procedure Warn(ALine: Integer; const Msg: string);
    property Messages: TStringList read FMessages;
    property Errors: Integer read FErrors;
    property Warnings: Integer read FWarnings;
  end;

function KVAnchorName(AAnchor: TKVAnchor): string;
function KVParseAnchor(const S: string; out AAnchor: TKVAnchor): Boolean;
function KVCapPosName(APos: TKVCapPos): string;
function KVParseCapPos(const S: string; out APos: TKVCapPos): Boolean;

implementation

const
  AnchorNames: array[TKVAnchor] of string = ('C', 'TL', 'TR', 'BL', 'BR');
  CapPosNames: array[TKVCapPos] of string = ('top', 'middle', 'bottom');

function KVAnchorName(AAnchor: TKVAnchor): string;
begin
  Result := AnchorNames[AAnchor];
end;

function KVParseAnchor(const S: string; out AAnchor: TKVAnchor): Boolean;
var
  A: TKVAnchor;
begin
  for A := Low(TKVAnchor) to High(TKVAnchor) do
    if S = AnchorNames[A] then
    begin
      AAnchor := A;
      Exit(True);
    end;
  Result := False;
end;

function KVCapPosName(APos: TKVCapPos): string;
begin
  Result := CapPosNames[APos];
end;

function KVParseCapPos(const S: string; out APos: TKVCapPos): Boolean;
var
  P: TKVCapPos;
begin
  for P := Low(TKVCapPos) to High(TKVCapPos) do
    if S = CapPosNames[P] then
    begin
      APos := P;
      Exit(True);
    end;
  Result := False;
end;

{ TKVPage }

procedure TKVPage.AddCell(const ACell: TKVCell);
begin
  SetLength(Cells, Length(Cells) + 1);
  Cells[High(Cells)] := ACell;
end;

{ TKVPhotobook }

constructor TKVPhotobook.Create;
begin
  inherited Create;
  Pages := TObjectList.Create(True);
  FrontAnchor := kaC;
  BackAnchor := kaC;
end;

destructor TKVPhotobook.Destroy;
begin
  Pages.Free;
  inherited Destroy;
end;

function TKVPhotobook.CellsPerPage: Integer;
begin
  Result := Rows * Cols;
end;

function TKVPhotobook.Page(AIndex: Integer): TKVPage;
begin
  Result := TKVPage(Pages[AIndex]);
end;

{ TKVDiagnostics }

constructor TKVDiagnostics.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FMessages := TStringList.Create;
end;

destructor TKVDiagnostics.Destroy;
begin
  FMessages.Free;
  inherited Destroy;
end;

procedure TKVDiagnostics.Add(const Severity: string; ALine: Integer; const Msg: string);
begin
  if ALine > 0 then
    FMessages.Add(Format('%s:%d: %s: %s', [FFileName, ALine, Severity, Msg]))
  else
    FMessages.Add(Format('%s: %s: %s', [FFileName, Severity, Msg]));
end;

procedure TKVDiagnostics.Error(ALine: Integer; const Msg: string);
begin
  Inc(FErrors);
  Add('error', ALine, Msg);
end;

procedure TKVDiagnostics.Warn(ALine: Integer; const Msg: string);
begin
  Inc(FWarnings);
  Add('warning', ALine, Msg);
end;

end.
